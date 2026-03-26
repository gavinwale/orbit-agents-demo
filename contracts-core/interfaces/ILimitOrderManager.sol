// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILimitOrderManager
 * @notice Interface for limit order management in prediction markets using aggregated LP positions
 * @dev Architecture:
 *      - Each (marketId, binId, direction) has ONE aggregated LP position
 *      - Users add to the aggregated position, tracking their share
 *      - On price crossing: ONE removeLiquidity call (O(1) complexity)
 *      - Users claim their share of proceeds later
 *
 *      Limit orders work by:
 *      1. User deposits USDC/tokens to place a limit order at a target price
 *      2. Funds are added to the aggregated LP position at the target bin
 *      3. When price crosses the target bin via swap, the position is "triggered"
 *      4. User can claim their share of filled tokens or withdraw if not triggered
 */
interface ILimitOrderManager {
    // ============ Enums ============

    /// @notice Order type
    enum OrderType {
        BuyYes,   // User deposits USDC, wants to buy YES at lower price (adds NO as LP at higher binId)
        BuyNo,    // User deposits USDC, wants to buy NO at higher price (adds YES as LP at lower binId)
        SellYes,  // User deposits YES, wants to sell at higher price for USDC (adds YES as LP at lower binId)
        SellNo    // User deposits NO, wants to sell at lower price for USDC (adds NO as LP at higher binId)
    }

    /// @notice Order status
    enum OrderStatus {
        Active,    // Order is active in the aggregated position
        Claimable, // Position has been triggered, user can claim
        Claimed,   // User has claimed their share
        Withdrawn  // User withdrew before trigger
    }

    /// @notice Aggregated position status
    enum PositionStatus {
        Empty,     // No liquidity in this position
        Active,    // Position has liquidity, waiting for trigger
        Triggered  // Price has crossed, position settled
    }

    // ============ Structs ============

    /// @notice Individual user's order within an aggregated position
    struct UserOrder {
        uint256 marketId;        // Market ID
        address owner;           // Caller that placed the order (Router or direct)
        OrderType orderType;     // Order type (BuyYes/BuyNo/SellYes/SellNo)
        int24 targetBinId;       // Target bin ID for the order
        uint128 depositAmount;   // Amount deposited (USDC for Buy, tokens for Sell)
        uint128 shares;          // User's share of the aggregated position
        OrderStatus status;      // Current order status
        uint40 createdAt;        // Creation timestamp
        uint64 cycle;            // Position cycle when order was created
        address beneficiary;     // Real user who owns the order (for events/indexing) — appended for UUPS compatibility
    }

    /// @notice Aggregated LP position for a (marketId, binId, orderType)
    /// @dev Each OrderType gets its own isolated position to avoid cross-contamination
    struct AggregatedPosition {
        uint256 totalShares;     // Total shares in this position
        uint256 lpShares;        // LP shares from MarketCore
        uint128 totalDeposited;  // Total amount deposited
        uint128 heldYes;         // YES tokens held in contract (for SellYes orders, not added to LP)
        uint128 heldNo;          // NO tokens held in contract (for SellNo orders, not added to LP)
        uint128 settledYes;      // YES tokens received after trigger (for claims)
        uint128 settledNo;       // NO tokens received after trigger (for claims)
        uint128 settledUsdc;     // USDC received after trigger (for sell order claims)
        PositionStatus status;   // Position status
        uint64 cycle;            // Current cycle number (increments on each trigger->reset)
    }

    // ============ Events ============

    event LimitOrderCreated(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed beneficiary,
        OrderType orderType,
        int24 targetBinId,
        uint128 amount,
        uint128 shares
    );

    event LimitOrderWithdrawn(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed beneficiary,
        uint128 refundAmount
    );

    event LimitOrderClaimed(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed beneficiary,
        uint128 claimedAmount
    );

    event AggregatedPositionTriggered(
        uint256 indexed marketId,
        int24 indexed binId,
        bool indexed isHighBin,
        uint128 yesReceived,
        uint128 noReceived
    );

    event BinCrossed(
        uint256 indexed marketId,
        int24 fromBinId,
        int24 toBinId,
        uint256 positionsTriggered
    );

    // ============ Order Management ============

    /// @notice Place a limit order (adds to aggregated position)
    /// @dev Order placement rules:
    ///      - BuyYes: target binId > current (lower YES probability), deposit USDC
    ///      - BuyNo: target binId < current (higher YES probability), deposit USDC
    ///      - SellYes: target binId < current (higher YES probability), deposit YES tokens
    ///      - SellNo: target binId > current (lower YES probability), deposit NO tokens
    /// @param marketId Market ID
    /// @param orderType Order type (BuyYes/BuyNo/SellYes/SellNo)
    /// @param targetBinId Target bin ID for the order
    /// @param amount Amount to deposit (USDC for Buy orders, tokens for Sell orders)
    /// @param onBehalfOf Real user address (beneficiary) for event indexing
    /// @return orderId The created order ID
    function placeLimitOrder(
        uint256 marketId,
        OrderType orderType,
        int24 targetBinId,
        uint128 amount,
        address onBehalfOf
    ) external returns (uint256 orderId);

    /// @notice Withdraw from an active (not triggered) limit order
    /// @dev Returns proportional share of the aggregated position
    /// @param orderId Order ID to withdraw
    /// @return refundAmount Amount refunded
    function withdrawOrder(uint256 orderId) external returns (uint128 refundAmount);

    /// @notice Claim proceeds from a triggered limit order
    /// @dev Only callable when position status is Triggered
    /// @param orderId Order ID to claim
    /// @return claimedAmount Amount of tokens/USDC claimed
    function claimOrder(uint256 orderId) external returns (uint128 claimedAmount);

    // ============ Swap Hook ============

    /// @notice Called by SwapHookRouter after each swap to trigger crossed positions
    /// @dev O(1) per bin - only processes aggregated positions, not individual orders
    /// @param marketId Market ID
    /// @param oldActiveId Previous active bin ID
    /// @param newActiveId New active bin ID after swap
    /// @return success Always true (reverts on failure in strict mode)
    function afterSwap(
        uint256 marketId,
        int24 oldActiveId,
        int24 newActiveId
    ) external returns (bool success);

    // ============ View Functions ============

    /// @notice Get order details
    /// @param orderId Order ID
    /// @return order The order details
    function getOrder(uint256 orderId) external view returns (UserOrder memory order);

    /// @notice Get user's orders for a market
    /// @param marketId Market ID
    /// @param user User address
    /// @return orderIds Array of order IDs
    function getUserOrders(uint256 marketId, address user) external view returns (uint256[] memory orderIds);

    /// @notice Get aggregated position for a bin and order type
    /// @param marketId Market ID
    /// @param binId Bin ID
    /// @param orderType Order type (each type has its own isolated position)
    /// @return position The aggregated position
    function getAggregatedPosition(
        uint256 marketId,
        int24 binId,
        OrderType orderType
    ) external view returns (AggregatedPosition memory position);

    /// @notice Get total order count
    /// @return count Total number of orders created
    function orderCount() external view returns (uint256 count);

    /// @notice Check if a bin has active aggregated positions
    /// @param marketId Market ID
    /// @param binId Bin ID
    /// @return hasPosition True if bin has active positions
    function binHasPosition(uint256 marketId, int24 binId) external view returns (bool hasPosition);

    /// @notice Get the bin ID for a target YES probability
    /// @param targetProbability Target YES probability (1e18 precision, e.g., 0.25e18 for 25%)
    /// @return binId Corresponding bin ID
    function getBinIdForProbability(uint256 targetProbability) external view returns (int24 binId);

    /// @notice Calculate claimable amount for an order
    /// @param orderId Order ID
    /// @return amount Claimable amount (0 if not claimable)
    function getClaimableAmount(uint256 orderId) external view returns (uint128 amount);

    // ============ Constants ============

    /// @notice Minimum order amount (10 USDC)
    function MIN_ORDER_AMOUNT() external view returns (uint128);
}
