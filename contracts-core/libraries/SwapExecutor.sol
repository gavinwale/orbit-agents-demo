// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IMarketCore.sol";
import "./ProbabilityMath.sol";
import "./Constants.sol";

/**
 * @title SwapExecutor
 * @notice Externally deployed library for swap execution logic
 * @dev Reduces MarketCore bytecode by moving the swap loop + binary search here.
 *      Deployed as a separate contract and linked at compile time (delegatecall).
 */
library SwapExecutor {
    /// @notice Execute swap across bins, updating reserves in-place
    /// @param bins Storage reference to bins mapping for the given marketId
    /// @param slotBinIds Cached slot → binId array (storage)
    /// @param slotPrices Cached slot → price array (storage)
    /// @param amountIn Amount to swap (after fee)
    /// @param swapForNo True if swapping YES for NO
    /// @param currentId Current active bin ID
    /// @return amountOut Total output amount
    /// @return newActiveId Updated active bin ID
    /// @return touchedBins Array of bin IDs whose reserves changed
    function executeSwap(
        mapping(int24 => IMarketCore.Bin) storage bins,
        int24[99] storage slotBinIds,
        uint256[99] storage slotPrices,
        uint128 amountIn,
        bool swapForNo,
        int24 currentId
    ) public returns (uint128 amountOut, int24 newActiveId, int24[] memory touchedBins) {
        newActiveId = currentId;
        uint128 amountInLeft = amountIn;

        // Pre-allocate array for touched bins (max possible = TOTAL_PREDICTION_BINS)
        int24[] memory _touched = new int24[](Constants.TOTAL_PREDICTION_BINS);
        uint256 touchedCount = 0;

        // Find initial slot for current active bin
        uint256 currentSlot = findSlotForBin(slotBinIds, newActiveId);

        while (amountInLeft > 0) {
            int24 binId = slotBinIds[currentSlot];

            IMarketCore.Bin storage bin = bins[binId];
            uint256 price = slotPrices[currentSlot];

            (uint128 binAmountOut, uint128 binAmountIn) = ProbabilityMath.getSwapAmount(
                price,
                bin.reserveX,
                bin.reserveY,
                amountInLeft,
                swapForNo
            );

            if (binAmountOut > 0) {
                // Update bin reserves
                if (swapForNo) {
                    bin.reserveX += binAmountIn;
                    bin.reserveY -= binAmountOut;
                } else {
                    bin.reserveY += binAmountIn;
                    bin.reserveX -= binAmountOut;
                }

                _touched[touchedCount] = binId;
                touchedCount++;

                amountOut += binAmountOut;
                amountInLeft -= binAmountIn;
            }

            newActiveId = binId;

            // Move to next bin if needed (jump by slot)
            // Direction: trades push probability toward the side being bought
            //   - Buying YES (swapForNo=false): P_yes rises → higher slot number
            //   - Buying NO (swapForNo=true): P_yes falls → lower slot number
            if (amountInLeft > 0) {
                if (swapForNo) {
                    // Buying NO → P_yes decreases → move to lower slot
                    if (currentSlot == 0) break;
                    currentSlot--;
                } else {
                    // Buying YES → P_yes increases → move to higher slot
                    if (currentSlot >= Constants.TOTAL_PREDICTION_BINS - 1) break;
                    currentSlot++;
                }

                int24 nextBinId = slotBinIds[currentSlot];
                IMarketCore.Bin memory nextBin = bins[nextBinId];
                if (nextBin.reserveX == 0 && nextBin.reserveY == 0) {
                    break;
                }
            }
        }

        // Resize touchedBins to actual count
        touchedBins = _touched;
        assembly {
            mstore(touchedBins, touchedCount)
        }
    }

    /// @notice Find the nearest slot index for a given binId
    /// @dev Binary search on slotBinIds which is monotonically INCREASING (slot 0 = lowest binId)
    /// @param slotBinIds Cached slot → binId array (storage)
    /// @param binId The bin ID to search for
    /// @return slot The nearest slot index
    function findSlotForBin(
        int24[99] storage slotBinIds,
        int24 binId
    ) public view returns (uint256 slot) {
        uint256 lo = 0;
        uint256 hi = Constants.TOTAL_PREDICTION_BINS;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (slotBinIds[mid] < binId) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is now the first slot where slotBinIds[slot] >= binId
        // Find closest match between lo and lo-1
        if (lo >= Constants.TOTAL_PREDICTION_BINS) return Constants.TOTAL_PREDICTION_BINS - 1;
        if (lo == 0) return 0;
        int24 diff1 = binId - slotBinIds[lo - 1];
        int24 diff2 = slotBinIds[lo] - binId;
        return diff1 <= diff2 ? lo - 1 : lo;
    }
}
