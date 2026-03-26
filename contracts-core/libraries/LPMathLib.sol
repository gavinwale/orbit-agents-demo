// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LPMathLib
 * @notice Externally deployed library for LP position computation
 * @dev Reduces LPManager bytecode by moving pure computation here.
 *      Deployed as a separate contract and linked at compile time.
 */
library LPMathLib {
    uint256 private constant PRECISION = 1e18;

    /// @notice Calculate rebalance needs for an LP position
    /// @param currentYesInLP YES tokens currently in LP
    /// @param currentNoInLP NO tokens currently in LP
    /// @param currentYesHeld YES tokens currently held
    /// @param currentNoHeld NO tokens currently held
    /// @param targetYesRatio Target YES ratio (1e18 precision)
    /// @param settled Whether position is settled
    /// @return needsSwap Whether a swap is needed
    /// @return swapYesToNo Direction of swap
    /// @return swapAmount Amount to swap
    function calculateRebalance(
        uint128 currentYesInLP,
        uint128 currentNoInLP,
        uint128 currentYesHeld,
        uint128 currentNoHeld,
        uint64 targetYesRatio,
        bool settled
    ) public pure returns (bool needsSwap, bool swapYesToNo, uint128 swapAmount) {
        if (settled) {
            return (false, false, 0);
        }

        uint256 totalYes = uint256(currentYesInLP) + uint256(currentYesHeld);
        uint256 totalNo = uint256(currentNoInLP) + uint256(currentNoHeld);
        uint256 totalValue = totalYes + totalNo;

        if (totalValue == 0) {
            return (false, false, 0);
        }

        uint256 currentYesRatio = (totalYes * PRECISION) / totalValue;
        uint256 targetRatio = uint256(targetYesRatio);
        uint256 tolerance = PRECISION / 100;

        if (currentYesRatio > targetRatio + tolerance) {
            needsSwap = true;
            swapYesToNo = true;
            uint256 targetTotalYes = (targetRatio * totalValue) / PRECISION;
            uint256 idealSwapAmount = totalYes > targetTotalYes ? totalYes - targetTotalYes : 0;
            swapAmount = idealSwapAmount > currentYesHeld
                ? currentYesHeld
                : uint128(idealSwapAmount);
        } else if (currentYesRatio + tolerance < targetRatio) {
            needsSwap = true;
            swapYesToNo = false;
            uint256 targetTotalNo = ((PRECISION - targetRatio) * totalValue) / PRECISION;
            uint256 idealSwapAmount = totalNo > targetTotalNo ? totalNo - targetTotalNo : 0;
            swapAmount = idealSwapAmount > currentNoHeld
                ? currentNoHeld
                : uint128(idealSwapAmount);
        }

        if (swapAmount == 0) {
            needsSwap = false;
        }
    }

    /// @notice Compute internal matching between YES and NO sellers, update arrays in-place
    /// @dev Arrays are modified in-place (DELEGATECALL shares memory). Returns match amounts and new totals.
    function computeInternalMatch(
        uint128[] memory yesToSell,
        uint128[] memory noToSell,
        uint128 totalYesToSell,
        uint128 totalNoToSell,
        uint256 currentPrice
    ) public pure returns (
        uint128 matchedYes,
        uint128 matchedNo,
        uint128 newTotalYesToSell,
        uint128 newTotalNoToSell
    ) {
        uint256 yesSellerWantNo = (uint256(totalYesToSell) * currentPrice) / PRECISION;
        uint256 noSellerOfferNo = uint256(totalNoToSell);
        uint256 internalMatchNo = yesSellerWantNo < noSellerOfferNo ? yesSellerWantNo : noSellerOfferNo;

        if (internalMatchNo == 0 || totalYesToSell == 0 || totalNoToSell == 0) {
            return (0, 0, totalYesToSell, totalNoToSell);
        }

        matchedYes = uint128((internalMatchNo * PRECISION) / currentPrice);
        matchedNo = uint128(internalMatchNo);

        if (yesSellerWantNo <= noSellerOfferNo) {
            for (uint256 i = 0; i < yesToSell.length; i++) {
                yesToSell[i] = 0;
            }
            uint256 remainingRatio = ((noSellerOfferNo - internalMatchNo) * PRECISION) / noSellerOfferNo;
            for (uint256 i = 0; i < noToSell.length; i++) {
                noToSell[i] = uint128((uint256(noToSell[i]) * remainingRatio) / PRECISION);
            }
            newTotalYesToSell = 0;
            newTotalNoToSell = uint128(noSellerOfferNo - internalMatchNo);
        } else {
            for (uint256 i = 0; i < noToSell.length; i++) {
                noToSell[i] = 0;
            }
            uint256 remainingYes = (yesSellerWantNo - internalMatchNo) * PRECISION / currentPrice;
            uint256 remainingRatio = (remainingYes * PRECISION) / uint256(totalYesToSell);
            for (uint256 i = 0; i < yesToSell.length; i++) {
                yesToSell[i] = uint128((uint256(yesToSell[i]) * remainingRatio) / PRECISION);
            }
            newTotalNoToSell = 0;
            newTotalYesToSell = uint128(remainingYes);
        }
    }

    /// @notice Integer square root using Babylonian method
    /// @param x Value to take sqrt of
    /// @return y Square root result
    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
