// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../tokens/LPPositionNFT.sol";

/**
 * @title ILPManager
 * @notice Interface for LP position management with time decay and rebalancing
 * @dev Manages LP positions as NFTs, each with independent bins and shares
 *      Implements pm-amm style liquidity decay: L(t) = L0 * sqrt((T-t)/T)
 */
interface ILPManager {
    // ============ Structs ============

    /// @notice Market LP state (shared across all positions in a market)
    struct MarketLPState {
        uint128 totalInitialLiquidity;  // Total USDC contributed
        uint40 tradingStartTime;        // When trading starts
        uint40 tradingEndTime;          // When trading ends
        uint40 lastGlobalWithdrawTime;  // Last collective withdrawal time
        uint128 accumulatedFees;        // Fees accumulated for LPs
    }

    // ============ Events ============

    event LPPositionCreated(
        uint256 indexed tokenId,
        uint256 indexed marketId,
        address indexed provider,
        uint128 yesInLP,
        uint128 noInLP,
        uint64 targetYesRatio
    );

    event LPWithdrawalTriggered(
        uint256 indexed marketId,
        uint40 timestamp,
        uint256 decayFactor
    );

    event PositionWithdrawn(
        uint256 indexed tokenId,
        uint128 yesWithdrawn,
        uint128 noWithdrawn
    );

    event RebalanceExecuted(
        uint256 indexed tokenId,
        int128 yesChange,  // Positive = gained YES, negative = lost YES
        int128 noChange
    );

    event CollectiveRebalanceExecuted(
        uint256 indexed marketId,
        int128 netYesToNoSwap,  // Positive = net YES->NO, negative = net NO->YES
        uint128 amountSwapped
    );

    event LPSettled(
        uint256 indexed tokenId,
        address indexed provider,
        uint128 payout
    );

    event TwapLongWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event TwapShortWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event MaxPriceDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);

    // ============ Position Management ============

    /// @notice Create a new LP position NFT
    /// @param marketId Market ID
    /// @param provider LP provider address (will own the NFT)
    /// @param yesInLP YES tokens to add to LP
    /// @param noInLP NO tokens to add to LP
    /// @param yesHeld YES tokens to hold (not in LP)
    /// @param noHeld NO tokens to hold (not in LP)
    /// @param targetYesRatio Target YES ratio for rebalancing
    /// @param binIds Bin IDs where liquidity will be added
    /// @param shares Shares received in each bin
    /// @return tokenId The minted NFT token ID
    function createPosition(
        uint256 marketId,
        address provider,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld,
        uint64 targetYesRatio,
        int24[] calldata binIds,
        uint256[] calldata shares
    ) external returns (uint256 tokenId);

    /// @notice Initialize market LP state
    /// @param marketId Market ID
    /// @param tradingStartTime When trading starts
    /// @param tradingEndTime When trading ends
    /// @param totalLiquidity Total USDC in the market
    function initializeMarketLPState(
        uint256 marketId,
        uint40 tradingStartTime,
        uint40 tradingEndTime,
        uint128 totalLiquidity
    ) external;

    /// @notice Initialize aggregated pool info for Stage1 LP positions
    /// @param marketId Market ID
    /// @param yesBiasedStartSlot Start slot for YES-biased pool
    /// @param yesBiasedEndSlot End slot for YES-biased pool
    /// @param yesBiasedTotalShares Total shares in YES-biased pool
    /// @param noBiasedStartSlot Start slot for NO-biased pool
    /// @param noBiasedEndSlot End slot for NO-biased pool
    /// @param noBiasedTotalShares Total shares in NO-biased pool
    /// @param yesBiasedOverlapSharesInit YES-biased pool's shares at the overlap bin
    /// @param noBiasedOverlapSharesInit NO-biased pool's shares at the overlap bin
    function initializeAggregatedPools(
        uint256 marketId,
        uint8 yesBiasedStartSlot,
        uint8 yesBiasedEndSlot,
        uint128 yesBiasedTotalShares,
        uint8 noBiasedStartSlot,
        uint8 noBiasedEndSlot,
        uint128 noBiasedTotalShares,
        uint256 yesBiasedOverlapSharesInit,
        uint256 noBiasedOverlapSharesInit
    ) external;

    /// @notice Create an aggregated LP position (no bin data stored, uses pool share ratio)
    /// @param marketId Market ID
    /// @param provider LP provider address
    /// @param yesInLP YES tokens in LP
    /// @param noInLP NO tokens in LP
    /// @param yesHeld YES tokens held
    /// @param noHeld NO tokens held
    /// @param targetYesRatio Target YES ratio
    /// @param poolShareRatio Share of the aggregated pool (1e18 = 100%)
    /// @return tokenId The minted position NFT token ID
    function createAggregatedPosition(
        uint256 marketId,
        address provider,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld,
        uint64 targetYesRatio,
        uint256 poolShareRatio
    ) external returns (uint256 tokenId);

    // ============ Time Decay Functions ============

    /// @notice Get current liquidity decay factor
    /// @dev L(t) = L0 * sqrt((T-t)/T), minimum 10%
    /// @param marketId Market ID
    /// @return decayFactor Decay factor in 1e18 precision (1e18 = 100%)
    function getDecayFactor(uint256 marketId) external view returns (uint256 decayFactor);

    // ============ LP Withdrawal ============

    /// @notice Trigger decay-based withdrawal for a specific position
    /// @param tokenId Position NFT token ID
    /// @return yesWithdrawn YES tokens withdrawn
    /// @return noWithdrawn NO tokens withdrawn
    function triggerPositionWithdrawal(uint256 tokenId) external returns (uint128 yesWithdrawn, uint128 noWithdrawn);

    /// @notice Check if withdrawal can be triggered for a market
    /// @param marketId Market ID
    /// @return canTrigger True if minimum interval has passed
    function canTriggerWithdrawal(uint256 marketId) external view returns (bool canTrigger);

    // ============ Rebalancing ============

    /// @notice Calculate rebalance amounts for a position
    /// @param tokenId Position NFT token ID
    /// @return needsSwap Whether this position needs rebalancing
    /// @return swapYesToNo True if need to swap YES for NO
    /// @return swapAmount Amount to swap
    function calculateRebalance(
        uint256 tokenId
    ) external view returns (bool needsSwap, bool swapYesToNo, uint128 swapAmount);

    /// @notice Execute rebalance for a single position
    /// @param tokenId Position NFT token ID
    /// @return amountSwapped Amount of tokens swapped
    function executeRebalance(uint256 tokenId) external returns (uint128 amountSwapped);

    /// @notice Trigger withdrawal and rebalance for all positions in a market
    /// @dev Aggregates all LP rebalance needs into a single net swap
    /// @param marketId Market ID
    /// @return totalWithdrawnYes Total YES withdrawn across all positions
    /// @return totalWithdrawnNo Total NO withdrawn across all positions
    /// @return netSwapAmount Net swap amount executed (0 if no swap needed)
    function triggerMarketWithdrawalAndRebalance(uint256 marketId)
        external
        returns (uint128 totalWithdrawnYes, uint128 totalWithdrawnNo, uint128 netSwapAmount);

    // ============ Settlement ============

    /// @notice Settle LP position after market resolution
    /// @param tokenId Position NFT token ID
    /// @return payout Token payout amount
    function settlePosition(uint256 tokenId) external returns (uint128 payout);

    // ============ View Functions ============

    /// @notice Get market LP state
    function getMarketLPState(uint256 marketId) external view returns (MarketLPState memory);

    /// @notice Get position NFT contract
    function positionNFT() external view returns (LPPositionNFT);

    /// @notice Get minimum withdrawal interval
    function MIN_WITHDRAWAL_INTERVAL() external view returns (uint40);

    /// @notice Get minimum liquidity ratio at expiry
    function MIN_LIQUIDITY_RATIO() external view returns (uint64);

    // ============ TWAP Configuration ============

    /// @notice Get TWAP long window for manipulation detection
    function twapLongWindow() external view returns (uint256);

    /// @notice Get TWAP short window for manipulation detection
    function twapShortWindow() external view returns (uint256);

    /// @notice Get maximum price deviation threshold
    function maxPriceDeviation() external view returns (uint256);

    /// @notice Set TWAP parameters (owner only)
    function setTwapParams(uint256 _longWindow, uint256 _shortWindow, uint256 _maxDeviation) external;
}
