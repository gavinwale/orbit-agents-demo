// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LPPositionNFT
 * @notice ERC721 NFT representing LP positions in prediction markets
 * @dev Each NFT represents a unique LP position with its own bins and shares
 *      Similar to Uniswap V3's NonfungiblePositionManager
 */
contract LPPositionNFT is ERC721Enumerable, Ownable {
    // ============ Structs ============

    /// @notice LP Position data stored per NFT
    struct Position {
        uint256 marketId;           // Which market this position belongs to
        uint128 initialYesInLP;     // YES tokens initially added to LP bins
        uint128 initialNoInLP;      // NO tokens initially added to LP bins
        uint128 currentYesInLP;     // Current YES tokens in LP bins (after swaps)
        uint128 currentNoInLP;      // Current NO tokens in LP bins (after swaps)
        uint128 currentYesHeld;     // YES tokens withdrawn from LP (held by LPManager)
        uint128 currentNoHeld;      // NO tokens withdrawn from LP (held by LPManager)
        uint64 targetYesRatio;      // Target YES ratio for rebalancing (1e18 = 100%)
        uint40 createdAt;           // Position creation timestamp
        bool settled;               // Whether position has been settled
    }

    /// @notice Bin data for a position
    struct BinData {
        int24[] binIds;             // Array of bin IDs where liquidity was added
        uint256[] shares;           // Shares in each bin (parallel array)
    }

    // ============ State ============

    /// @notice Position data: tokenId => Position
    mapping(uint256 => Position) public positions;

    /// @notice Bin data: tokenId => BinData
    mapping(uint256 => BinData) private _binData;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Authorized minter (LPManager)
    address public minter;

    // ============ Events ============

    event PositionCreated(
        uint256 indexed tokenId,
        uint256 indexed marketId,
        address indexed owner,
        uint128 yesInLP,
        uint128 noInLP,
        uint64 targetYesRatio
    );

    event PositionUpdated(
        uint256 indexed tokenId,
        uint128 currentYesInLP,
        uint128 currentNoInLP,
        uint128 currentYesHeld,
        uint128 currentNoHeld
    );

    event PositionSettled(uint256 indexed tokenId);

    // ============ Constructor ============

    constructor() ERC721("Orbit LP Position", "ORBIT-LP") Ownable(msg.sender) {}

    // ============ Admin Functions ============

    /// @notice Set the authorized minter (LPManager)
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "LPPositionNFT: ZERO_MINTER");
        minter = _minter;
    }

    // ============ Minter Functions ============

    modifier onlyMinter() {
        require(msg.sender == minter, "LPPositionNFT: NOT_MINTER");
        _;
    }

    /**
     * @notice Mint a new LP position NFT
     * @param to Owner of the new position
     * @param marketId Market ID
     * @param yesInLP YES tokens added to LP
     * @param noInLP NO tokens added to LP
     * @param yesHeld YES tokens held (not in LP)
     * @param noHeld NO tokens held (not in LP)
     * @param targetYesRatio Target YES ratio
     * @param binIds Bin IDs where liquidity was added
     * @param shares Shares in each bin
     * @return tokenId The minted token ID
     */
    function mint(
        address to,
        uint256 marketId,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld,
        uint64 targetYesRatio,
        int24[] calldata binIds,
        uint256[] calldata shares
    ) external onlyMinter returns (uint256 tokenId) {
        require(binIds.length == shares.length, "LPPositionNFT: LENGTH_MISMATCH");

        tokenId = nextTokenId++;

        positions[tokenId] = Position({
            marketId: marketId,
            initialYesInLP: yesInLP,
            initialNoInLP: noInLP,
            currentYesInLP: yesInLP,
            currentNoInLP: noInLP,
            currentYesHeld: yesHeld,
            currentNoHeld: noHeld,
            targetYesRatio: targetYesRatio,
            createdAt: uint40(block.timestamp),
            settled: false
        });

        // Store bin data
        _binData[tokenId].binIds = binIds;
        _binData[tokenId].shares = shares;

        _mint(to, tokenId);

        emit PositionCreated(tokenId, marketId, to, yesInLP, noInLP, targetYesRatio);
    }

    /**
     * @notice Update position's LP balances (after swaps affect bins)
     * @param tokenId Position token ID
     * @param yesInLP New YES in LP
     * @param noInLP New NO in LP
     */
    function updateLPBalances(
        uint256 tokenId,
        uint128 yesInLP,
        uint128 noInLP
    ) external onlyMinter {
        Position storage pos = positions[tokenId];
        pos.currentYesInLP = yesInLP;
        pos.currentNoInLP = noInLP;

        emit PositionUpdated(tokenId, yesInLP, noInLP, pos.currentYesHeld, pos.currentNoHeld);
    }

    /**
     * @notice Update position's held balances (after withdrawal from LP)
     * @param tokenId Position token ID
     * @param yesHeld New YES held
     * @param noHeld New NO held
     */
    function updateHeldBalances(
        uint256 tokenId,
        uint128 yesHeld,
        uint128 noHeld
    ) external onlyMinter {
        Position storage pos = positions[tokenId];
        pos.currentYesHeld = yesHeld;
        pos.currentNoHeld = noHeld;

        emit PositionUpdated(tokenId, pos.currentYesInLP, pos.currentNoInLP, yesHeld, noHeld);
    }

    /**
     * @notice Update both LP and held balances atomically
     * @param tokenId Position token ID
     * @param yesInLP New YES in LP
     * @param noInLP New NO in LP
     * @param yesHeld New YES held
     * @param noHeld New NO held
     */
    function updatePosition(
        uint256 tokenId,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld
    ) external onlyMinter {
        Position storage pos = positions[tokenId];
        pos.currentYesInLP = yesInLP;
        pos.currentNoInLP = noInLP;
        pos.currentYesHeld = yesHeld;
        pos.currentNoHeld = noHeld;

        emit PositionUpdated(tokenId, yesInLP, noInLP, yesHeld, noHeld);
    }

    /**
     * @notice Update bin shares after partial withdrawal
     * @param tokenId Position token ID
     * @param newShares New shares array (same length as binIds)
     */
    function updateShares(
        uint256 tokenId,
        uint256[] calldata newShares
    ) external onlyMinter {
        require(newShares.length == _binData[tokenId].binIds.length, "LPPositionNFT: LENGTH_MISMATCH");
        _binData[tokenId].shares = newShares;
    }

    /**
     * @notice Mark position as settled
     * @param tokenId Position token ID
     */
    function markSettled(uint256 tokenId) external onlyMinter {
        positions[tokenId].settled = true;
        emit PositionSettled(tokenId);
    }

    // ============ View Functions ============

    /**
     * @notice Get position data
     * @param tokenId Position token ID
     * @return Position struct
     */
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @notice Get bin data for a position
     * @param tokenId Position token ID
     * @return binIds Array of bin IDs
     * @return shares Array of shares
     */
    function getBinData(uint256 tokenId) external view returns (int24[] memory binIds, uint256[] memory shares) {
        return (_binData[tokenId].binIds, _binData[tokenId].shares);
    }

    /**
     * @notice Get total position value (LP + held)
     * @param tokenId Position token ID
     * @return totalYes Total YES tokens
     * @return totalNo Total NO tokens
     */
    function getTotalPosition(uint256 tokenId) external view returns (uint128 totalYes, uint128 totalNo) {
        Position memory pos = positions[tokenId];
        totalYes = pos.currentYesInLP + pos.currentYesHeld;
        totalNo = pos.currentNoInLP + pos.currentNoHeld;
    }

    /**
     * @notice Get current YES ratio
     * @param tokenId Position token ID
     * @return ratio Current YES ratio (1e18 precision)
     */
    function getCurrentRatio(uint256 tokenId) external view returns (uint256 ratio) {
        Position memory pos = positions[tokenId];
        uint256 totalYes = uint256(pos.currentYesInLP) + uint256(pos.currentYesHeld);
        uint256 totalNo = uint256(pos.currentNoInLP) + uint256(pos.currentNoHeld);
        uint256 total = totalYes + totalNo;

        if (total == 0) {
            return pos.targetYesRatio;
        }

        ratio = (totalYes * 1e18) / total;
    }

    /**
     * @notice Get all position token IDs for a market
     * @param owner Owner address
     * @param marketId Market ID
     * @return tokenIds Array of token IDs
     */
    function getPositionsForMarket(
        address owner,
        uint256 marketId
    ) external view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(owner);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, i);
            if (positions[tokenId].marketId == marketId) {
                temp[count++] = tokenId;
            }
        }

        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = temp[i];
        }
    }
}
