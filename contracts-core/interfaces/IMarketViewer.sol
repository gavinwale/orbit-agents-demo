// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMarketViewer
 * @notice Interface for the market viewer contract (swap quotes + computations)
 */
interface IMarketViewer {
    /// @notice Get swap output quote
    function getSwapOut(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo
    ) external view returns (uint128 amountOut, uint128 fee);

    /// @notice Get required input for desired output
    function getSwapIn(
        uint256 marketId,
        uint128 amountOut,
        bool swapForNo
    ) external view returns (uint128 amountIn, uint128 fee);

    /// @notice Compute optimal swap amount for selling tokens
    function computeOptimalSellSwap(
        uint256 marketId,
        uint128 totalAmount,
        bool swapForNo
    ) external view returns (uint128 optimalSwapAmount);

    /// @notice Get TWAP price for a market
    function getTWAP(uint256 marketId, uint256 window) external view returns (uint256 twap);

    /// @notice Check if current price appears manipulated
    function isPriceManipulated(
        uint256 marketId,
        uint256 longWindow,
        uint256 shortWindow,
        uint256 maxDeviation
    ) external view returns (bool manipulated);

    /// @notice Get current spot price for a market
    function getSpotPrice(uint256 marketId) external view returns (uint256 price);

    // ============ Aggregated Market Status ============

    enum MarketStatus {
        Fundraising,       // 0: Factory phase=Fundraising
        Trading,           // 1: Active trading (before tradingEndTime, not resolved)
        TradingHalted,     // 2: tradingEndTime passed, oracle not yet resolved
        Proposed,          // 3: Oracle outcome proposed (challenge window open)
        Challenged,        // 4: Oracle outcome disputed, arbitration in progress
        Resolvable,        // 5: Oracle finalized, MarketCore not yet written
        Settled            // 6: MarketCore resolved=true
    }

    struct MarketStatusInfo {
        MarketStatus status;
        uint40 tradingEndTime;
        bool yesWins;
    }

    /// @notice Get aggregated market status across Factory, MarketCore, and Oracle
    function getMarketStatus(uint256 marketId) external view returns (MarketStatusInfo memory);
}
