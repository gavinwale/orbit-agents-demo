// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OutcomeToken
 * @notice Singleton ERC-1155 contract managing all YES/NO outcome tokens across all markets
 * @dev Token ID encoding:
 *      - YES token: marketId * 2
 *      - NO token:  marketId * 2 + 1
 *
 *      Only authorized minters (MarketCore) can mint/burn tokens.
 */
contract OutcomeToken is ERC1155, Ownable {
    // ============ State Variables ============

    /// @notice Address authorized to mint/burn tokens (MarketCore contract)
    address public minter;

    /// @notice Next market ID to be assigned
    uint256 public nextMarketId;

    /// @notice Total supply per token ID
    mapping(uint256 => uint256) public totalSupply;

    // ============ Events ============

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event MarketTokensCreated(uint256 indexed marketId, uint256 yesTokenId, uint256 noTokenId);

    // ============ Errors ============

    error NotMinter();
    error ZeroAddress();

    // ============ Constructor ============

    constructor() ERC1155("") Ownable(msg.sender) {}

    // ============ Modifiers ============

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    // ============ Token ID Encoding ============

    /**
     * @notice Get YES token ID for a market
     * @param marketId Market ID
     * @return tokenId YES token ID
     */
    function getYesTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }

    /**
     * @notice Get NO token ID for a market
     * @param marketId Market ID
     * @return tokenId NO token ID
     */
    function getNoTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    /**
     * @notice Decode token ID to get market ID and outcome type
     * @param tokenId Token ID
     * @return marketId Market ID
     * @return isYes True if YES token, false if NO token
     */
    function decodeTokenId(uint256 tokenId) public pure returns (uint256 marketId, bool isYes) {
        marketId = tokenId / 2;
        isYes = (tokenId % 2 == 0);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the minter address (MarketCore contract)
     * @param _minter New minter address
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert ZeroAddress();
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    // ============ Minting Functions ============

    /**
     * @notice Register a new market and return its ID
     * @dev Only callable by minter (MarketCore)
     * @return marketId The assigned market ID
     */
    function registerMarket() external onlyMinter returns (uint256 marketId) {
        marketId = nextMarketId;
        nextMarketId++;
        emit MarketTokensCreated(marketId, getYesTokenId(marketId), getNoTokenId(marketId));
    }

    /**
     * @notice Mint YES tokens for a market
     * @param marketId Market ID
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mintYes(uint256 marketId, address to, uint256 amount) external onlyMinter {
        uint256 tokenId = getYesTokenId(marketId);
        totalSupply[tokenId] += amount;
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Mint NO tokens for a market
     * @param marketId Market ID
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mintNo(uint256 marketId, address to, uint256 amount) external onlyMinter {
        uint256 tokenId = getNoTokenId(marketId);
        totalSupply[tokenId] += amount;
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Mint both YES and NO tokens for a market
     * @param marketId Market ID
     * @param to Recipient address
     * @param amount Amount to mint (same for both)
     */
    function mintPair(uint256 marketId, address to, uint256 amount) external onlyMinter {
        uint256 yesId = getYesTokenId(marketId);
        uint256 noId = getNoTokenId(marketId);

        totalSupply[yesId] += amount;
        totalSupply[noId] += amount;

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = yesId;
        ids[1] = noId;
        amounts[0] = amount;
        amounts[1] = amount;

        _mintBatch(to, ids, amounts, "");
    }

    /**
     * @notice Burn YES tokens for a market
     * @param marketId Market ID
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnYes(uint256 marketId, address from, uint256 amount) external onlyMinter {
        uint256 tokenId = getYesTokenId(marketId);
        totalSupply[tokenId] -= amount;
        _burn(from, tokenId, amount);
    }

    /**
     * @notice Burn NO tokens for a market
     * @param marketId Market ID
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnNo(uint256 marketId, address from, uint256 amount) external onlyMinter {
        uint256 tokenId = getNoTokenId(marketId);
        totalSupply[tokenId] -= amount;
        _burn(from, tokenId, amount);
    }

    /**
     * @notice Burn both YES and NO tokens for a market
     * @param marketId Market ID
     * @param from Address to burn from
     * @param amount Amount to burn (same for both)
     */
    function burnPair(uint256 marketId, address from, uint256 amount) external onlyMinter {
        uint256 yesId = getYesTokenId(marketId);
        uint256 noId = getNoTokenId(marketId);

        totalSupply[yesId] -= amount;
        totalSupply[noId] -= amount;

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = yesId;
        ids[1] = noId;
        amounts[0] = amount;
        amounts[1] = amount;

        _burnBatch(from, ids, amounts);
    }

    // ============ View Functions ============

    /**
     * @notice Get YES token balance for a user in a market
     * @param marketId Market ID
     * @param account User address
     * @return balance YES token balance
     */
    function yesBalance(uint256 marketId, address account) external view returns (uint256) {
        return balanceOf(account, getYesTokenId(marketId));
    }

    /**
     * @notice Get NO token balance for a user in a market
     * @param marketId Market ID
     * @param account User address
     * @return balance NO token balance
     */
    function noBalance(uint256 marketId, address account) external view returns (uint256) {
        return balanceOf(account, getNoTokenId(marketId));
    }

    /**
     * @notice Get total supply of YES tokens for a market
     * @param marketId Market ID
     * @return supply Total YES token supply
     */
    function yesTotalSupply(uint256 marketId) external view returns (uint256) {
        return totalSupply[getYesTokenId(marketId)];
    }

    /**
     * @notice Get total supply of NO tokens for a market
     * @param marketId Market ID
     * @return supply Total NO token supply
     */
    function noTotalSupply(uint256 marketId) external view returns (uint256) {
        return totalSupply[getNoTokenId(marketId)];
    }

    // ============ ERC-1155 URI ============

    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        // Can be overridden or set via setURI for metadata
        return "";
    }
}
