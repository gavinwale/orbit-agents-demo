// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IDLMMEngine.sol";

/**
 * @title IMarketCore
 * @notice Interface for the singleton market core contract
 */
interface IMarketCore {
    // ============ Structs ============

    /// @notice Bin reserve data
    struct Bin {
        uint128 reserveX; // YES reserve
        uint128 reserveY; // NO reserve
    }

    /// @notice Market metadata
    struct MarketInfo {
        string question;
        address creator;
        uint40 createdAt;
        bool exists;
        bool resolved;
        bool yesWins;
        bool paused;
    }

    // ============ Events ============

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        int24 initialActiveId
    );

    event OutcomesMinted(
        uint256 indexed marketId,
        address indexed sender,
        address indexed to,
        uint256 amount
    );

    event OutcomesBurned(
        uint256 indexed marketId,
        address indexed sender,
        address indexed to,
        uint256 amount
    );

    event Swap(
        uint256 indexed marketId,
        address indexed sender,
        address to,
        int24 activeId,
        uint128 amountIn,
        uint128 amountOut,
        uint128 fee,
        bool swapForNo
    );

    event LiquidityAdded(
        uint256 indexed marketId,
        address indexed sender,
        address to,
        int24[] binIds,
        uint128[] amountsYes,
        uint128[] amountsNo,
        uint256[] shares
    );

    event LiquidityRemoved(
        uint256 indexed marketId,
        address indexed sender,
        address to,
        int24[] binIds,
        uint256[] shares,
        uint128 totalAmountYes,
        uint128 totalAmountNo
    );

    event ProtocolFeesCollected(
        uint256 indexed marketId,
        address indexed to,
        uint128 fees
    );

    event MarketResolved(uint256 indexed marketId, bool yesWins);

    event Redeemed(
        uint256 indexed marketId,
        address indexed user,
        address to,
        uint256 payout
    );

    event ActiveIdUpdated(
        uint256 indexed marketId,
        int24 oldActiveId,
        int24 newActiveId
    );

    event AuthorizedSwapCallerUpdated(
        address indexed caller,
        bool authorized
    );

    event AuthorizedHookCallerUpdated(
        address indexed caller,
        bool authorized
    );

    event BinsUpdated(
        uint256 indexed marketId,
        int24[] binIds,
        uint128[] reservesYes,
        uint128[] reservesNo
    );

    // ============ Market Creation ============

    /// @notice Reserve a market ID in OutcomeToken without creating market state
    /// @dev Used by MarketFactory to decouple ID reservation from market activation
    /// @return marketId The reserved sequential market ID
    function reserveMarketId() external returns (uint256 marketId);

    /// @notice Activate a pre-reserved market ID with full market state
    /// @dev Used by MarketFactory after fundraising completes
    /// @param marketId Pre-reserved market ID from reserveMarketId()
    /// @param question Market question/description
    /// @param initialActiveId Initial active bin ID
    function activateMarket(
        uint256 marketId,
        string calldata question,
        int24 initialActiveId
    ) external;

    // ============ Token Minting/Burning ============

    /// @notice Mint YES and NO outcome tokens by depositing collateral
    /// @param marketId Market ID
    /// @param amount Amount of collateral to deposit (mints equal YES and NO)
    /// @param to Recipient address
    function mintOutcomes(uint256 marketId, uint256 amount, address to) external;

    /// @notice Burn equal YES and NO tokens to receive collateral
    /// @param marketId Market ID
    /// @param amount Amount of each token to burn
    /// @param to Recipient address for collateral
    function burnOutcomes(uint256 marketId, uint256 amount, address to) external;

    /// @notice Burn outcomes callable during swap hook (no reentrancy guard)
    function burnOutcomesFromHook(uint256 marketId, uint256 amount, address to) external;

    // ============ View Functions ============

    /// @notice Get bin reserves for a market
    /// @param marketId Market ID
    /// @param binId Bin ID
    /// @return reserveX YES token reserve
    /// @return reserveY NO token reserve
    function getBin(uint256 marketId, int24 binId) external view returns (uint128 reserveX, uint128 reserveY);

    /// @notice Get user's LP shares in a specific bin
    /// @param marketId Market ID
    /// @param binId Bin ID
    /// @param user User address
    /// @return shares User's LP shares
    function getUserBinShares(uint256 marketId, int24 binId, address user) external view returns (uint256 shares);

    /// @notice Get user's LP shares for multiple bins in one call
    /// @param marketId Market ID
    /// @param binIds Array of bin IDs
    /// @param user User address
    /// @return shares Array of user's LP shares per bin
    function getBatchUserBinShares(uint256 marketId, int24[] calldata binIds, address user) external view returns (uint256[] memory shares);

    /// @notice Get current YES probability for a market
    /// @param marketId Market ID
    /// @return probability YES probability in 1e18 precision
    function getCurrentProbability(uint256 marketId) external view returns (uint256 probability);

    /// @notice Get current price for a market
    /// @param marketId Market ID
    /// @return price Price in 128.128 fixed point
    function getCurrentPrice(uint256 marketId) external view returns (uint256 price);

    /// @notice Get accumulated protocol fees for a market
    /// @param marketId Market ID
    /// @return fees Protocol fees
    function getProtocolFees(uint256 marketId) external view returns (uint128 fees);

    // ============ Swap Functions ============

    /// @notice Execute a swap
    /// @param marketId Market ID
    /// @param amountIn Input amount
    /// @param swapForNo True if swapping YES for NO
    /// @param to Recipient address
    /// @return amountOut Output amount
    function swap(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo,
        address to
    ) external returns (uint128 amountOut);

    /// @notice Execute a swap from within a hook callback (bypasses nonReentrant)
    /// @dev Only callable by authorized hook callers during afterSwap execution
    function swapFromHook(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo,
        address to
    ) external returns (uint128 amountOut);

    // ============ Liquidity Functions ============

    /// @notice Add liquidity to bins
    /// @param marketId Market ID
    /// @param binIds Array of bin IDs
    /// @param amountsYes Array of YES token amounts
    /// @param amountsNo Array of NO token amounts
    /// @param to Recipient of LP tokens
    /// @return shares Array of LP shares minted
    function addLiquidity(
        uint256 marketId,
        int24[] calldata binIds,
        uint128[] calldata amountsYes,
        uint128[] calldata amountsNo,
        address to
    ) external returns (uint256[] memory shares);

    /// @notice Remove liquidity from bins
    /// @param marketId Market ID
    /// @param binIds Array of bin IDs
    /// @param sharesToBurn Array of LP shares to burn
    /// @param to Recipient of outcome tokens
    /// @return totalAmountYes Total YES tokens returned
    /// @return totalAmountNo Total NO tokens returned
    function removeLiquidity(
        uint256 marketId,
        int24[] calldata binIds,
        uint256[] calldata sharesToBurn,
        address to
    ) external returns (uint128 totalAmountYes, uint128 totalAmountNo);

    /// @notice Remove liquidity callable during swap hook (no reentrancy guard)
    /// @dev Only callable when MarketCore._inSwapHook is true
    function removeLiquidityFromHook(
        uint256 marketId,
        int24[] calldata binIds,
        uint256[] calldata sharesToBurn,
        address to
    ) external returns (uint128 totalAmountYes, uint128 totalAmountNo);

    /// @notice Add liquidity callable during swap hook (no reentrancy guard)
    /// @dev Only callable when MarketCore._inSwapHook is true
    function addLiquidityFromHook(
        uint256 marketId,
        int24[] calldata binIds,
        uint128[] calldata amountsYes,
        uint128[] calldata amountsNo,
        address to
    ) external returns (uint256[] memory shares);

    // ============ Protocol Fee Functions ============

    /// @notice Collect accumulated protocol fees
    /// @param marketId Market ID
    /// @return fees Amount of fees collected
    function collectProtocolFees(uint256 marketId) external returns (uint128 fees);

    // ============ Market Resolution ============

    /// @notice Resolve the market via Optimistic Oracle (permissionless)
    /// @param marketId Market ID
    function resolveMarket(uint256 marketId) external;

    /// @notice Redeem winning tokens for collateral
    /// @param marketId Market ID
    /// @param to Recipient address
    /// @return payout Amount of collateral paid out
    function redeem(uint256 marketId, address to) external returns (uint256 payout);

    // ============ Admin Functions ============

    /// @notice Pause/unpause a market (owner only)
    /// @param marketId Market ID
    /// @param _paused Paused state
    function setPaused(uint256 marketId, bool _paused) external;

    /// @notice Force volatility decay
    /// @param marketId Market ID
    function forceDecay(uint256 marketId) external;

    // ============ State Accessors ============

    /// @notice Get market info
    /// @param marketId Market ID
    /// @return question Market question
    /// @return creator Market creator
    /// @return createdAt Creation timestamp
    /// @return exists Whether market exists
    /// @return resolved Whether market is resolved
    /// @return yesWins Whether YES won (if resolved)
    /// @return paused Whether market is paused
    function markets(uint256 marketId) external view returns (
        string memory question,
        address creator,
        uint40 createdAt,
        bool exists,
        bool resolved,
        bool yesWins,
        bool paused
    );

    /// @notice Get active bin ID for a market
    /// @param marketId Market ID
    /// @return activeId Current active bin ID
    function activeIds(uint256 marketId) external view returns (int24 activeId);

    /// @notice Get total collateral held for a market
    /// @param marketId Market ID
    /// @return amount Total collateral amount
    function totalCollateral(uint256 marketId) external view returns (uint256 amount);

    // ============ Swap Hook ============

    /// @notice Set the swap hook address (for limit orders, LP withdrawals, etc.)
    /// @param hook Address of the swap hook contract
    function setSwapHook(address hook) external;

    /// @notice Get the current swap hook address
    /// @return hook Address of the swap hook contract
    function swapHook() external view returns (address hook);

    // ============ Swap Access Control ============

    /// @notice Set authorized swap caller (owner only)
    /// @param caller Address to authorize/deauthorize
    /// @param authorized Whether the address is authorized
    function setAuthorizedSwapCaller(address caller, bool authorized) external;

    /// @notice Check if an address is authorized to call swap
    /// @param caller Address to check
    /// @return Whether the address is authorized
    function authorizedSwapCallers(address caller) external view returns (bool);

    /// @notice Set authorized hook caller (owner only)
    /// @param caller Address to authorize/deauthorize (e.g., LimitOrderManager, LPManager)
    /// @param authorized Whether the address is authorized
    function setAuthorizedHookCaller(address caller, bool authorized) external;

    /// @notice Check if an address is authorized to call *FromHook functions
    /// @param caller Address to check
    /// @return Whether the address is authorized
    function authorizedHookCallers(address caller) external view returns (bool);

    // ============ Price Oracle ============

    /// @notice Get oracle state for viewer/off-chain use
    function getOracleState(uint256 marketId) external view returns (
        uint16 index,
        uint16 cardinality,
        uint40[] memory timestamps,
        uint216[] memory cumulatives
    );

    // ============ Batch Getters (for MarketViewer) ============

    /// @notice Get all 99 bin reserves for a market (ordered by slot 0-98)
    function getBatchBinReserves(uint256 marketId) external view returns (uint128[] memory reservesX, uint128[] memory reservesY);

    /// @notice Get cached slot → binId and slot → price arrays
    function getSlotData() external view returns (int24[99] memory binIds, uint256[99] memory prices);

    /// @notice Get volatility parameters for a market
    function volatilityParams(uint256 marketId) external view returns (
        uint24 volatilityAccumulator,
        uint24 volatilityReference,
        uint24 idReference,
        uint40 timeOfLastUpdate
    );
}
