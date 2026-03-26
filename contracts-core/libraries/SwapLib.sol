// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ProbabilityMath.sol";
import "./FeeHelper.sol";
import "./Constants.sol";

/**
 * @title SwapLib
 * @notice Externally deployed library for swap computation
 * @dev Reduces MarketCore bytecode by moving computation-heavy view logic here.
 *      Deployed as a separate contract and linked at compile time.
 */
library SwapLib {
    /// @notice Simulate swap output using in-memory reserves (no storage access)
    /// @param amountIn Amount to swap (after fee)
    /// @param swapForNo True if swapping YES for NO
    /// @param activeSlot Current active slot index
    /// @param reservesX YES reserves per slot (memory)
    /// @param reservesY NO reserves per slot (memory)
    /// @param slotPrices Price per slot in 128.128 fixed point (memory)
    /// @param totalBins Total number of prediction bins
    /// @return amountOut Output amount
    function simulateSwapOut(
        uint128 amountIn,
        bool swapForNo,
        uint256 activeSlot,
        uint128[] memory reservesX,
        uint128[] memory reservesY,
        uint256[] memory slotPrices,
        uint256 totalBins
    ) public pure returns (uint128 amountOut) {
        uint128 amountInLeft = amountIn;
        uint256 currentSlot = activeSlot;

        while (amountInLeft > 0) {
            uint256 price = slotPrices[currentSlot];

            (uint128 binAmountOut, uint128 binAmountIn) = ProbabilityMath.getSwapAmount(
                price, reservesX[currentSlot], reservesY[currentSlot], amountInLeft, swapForNo
            );

            if (binAmountOut > 0) {
                amountOut += binAmountOut;
                amountInLeft -= binAmountIn;
            }

            if (amountInLeft > 0) {
                if (swapForNo) {
                    if (currentSlot == 0) break;
                    currentSlot--;
                } else {
                    if (currentSlot >= totalBins - 1) break;
                    currentSlot++;
                }
                if (reservesX[currentSlot] == 0 && reservesY[currentSlot] == 0) break;
            }
        }
    }

    /// @notice Compute optimal sell swap amount using binary search
    /// @param totalAmount Total token amount to sell
    /// @param swapForNo True if selling YES (swap YES for NO)
    /// @param activeSlot Current active slot index
    /// @param reservesX YES reserves per slot (memory)
    /// @param reservesY NO reserves per slot (memory)
    /// @param slotPrices Price per slot (memory)
    /// @param totalFee Total fee rate in 1e18 precision
    /// @param totalBins Total number of prediction bins
    /// @return optimalSwapAmount Optimal amount to swap
    function computeOptimalSell(
        uint128 totalAmount,
        bool swapForNo,
        uint256 activeSlot,
        uint128[] memory reservesX,
        uint128[] memory reservesY,
        uint256[] memory slotPrices,
        uint128 totalFee,
        uint256 totalBins
    ) public pure returns (uint128 optimalSwapAmount) {
        uint128 lo = 0;
        uint128 hi = totalAmount;
        uint128 tolerance = totalAmount / 10000;
        if (tolerance == 0) tolerance = 1;

        for (uint256 iter = 0; iter < 30; iter++) {
            if (hi - lo <= tolerance) break;
            uint128 mid = lo + (hi - lo) / 2;

            uint128 midFee = FeeHelper.getFeeAmount(mid, totalFee);
            uint128 midAfterFee = mid - midFee;
            uint128 midOut = simulateSwapOut(midAfterFee, swapForNo, activeSlot, reservesX, reservesY, slotPrices, totalBins);

            if (midOut > totalAmount - mid) {
                hi = mid;
            } else {
                lo = mid;
            }
        }

        optimalSwapAmount = lo;
    }
}
