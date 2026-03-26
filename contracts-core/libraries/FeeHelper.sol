// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";

/**
 * @title FeeHelper
 * @notice Library for dynamic fee calculations in DLMM
 * @dev Implements base fee + variable fee based on volatility
 */
library FeeHelper {
    /// @notice Fee parameters packed into a struct
    struct FeeParameters {
        uint16 binStep;
        uint16 baseFactor;
        uint16 filterPeriod;
        uint16 decayPeriod;
        uint16 reductionFactor;
        uint24 variableFeeControl;
        uint16 protocolShare;
        uint24 maxVolatilityAccumulator;
    }

    /// @notice Volatility parameters
    struct VolatilityParameters {
        uint24 volatilityAccumulator;
        uint24 volatilityReference;
        uint24 idReference;
        uint40 timeOfLastUpdate;
    }

    /// @notice Calculate base fee
    /// @dev baseFee = baseFactor * binStep * 1e10
    /// @param binStep Bin step in basis points
    /// @param baseFactor Base factor
    /// @return baseFee Base fee in 1e18 precision
    function getBaseFee(uint16 binStep, uint16 baseFactor) internal pure returns (uint128 baseFee) {
        // baseFee = baseFactor * binStep * 1e10 (to get 1e18 precision)
        // For example: baseFactor=10, binStep=25 => baseFee = 10 * 25 * 1e10 = 2.5e12
        // This represents 0.00025% fee when divided by 1e18
        unchecked {
            baseFee = uint128(uint256(baseFactor) * uint256(binStep) * 1e10);
        }
    }

    /// @notice Calculate variable fee based on volatility
    /// @dev variableFee = (volatilityAccumulator * binStep)^2 * variableFeeControl / SCALE
    /// @param binStep Bin step in basis points
    /// @param variableFeeControl Variable fee control parameter
    /// @param volatilityAccumulator Current volatility accumulator
    /// @return variableFee Variable fee in 1e18 precision
    function getVariableFee(
        uint16 binStep,
        uint24 variableFeeControl,
        uint24 volatilityAccumulator
    ) internal pure returns (uint128 variableFee) {
        if (variableFeeControl == 0 || volatilityAccumulator == 0) {
            return 0;
        }

        unchecked {
            // vFee = ((va * binStep)^2 * vfc + OFFSET) / SCALE
            uint256 prod = uint256(volatilityAccumulator) * uint256(binStep);
            uint256 prodSquared = prod * prod;
            uint256 vFee = (prodSquared * uint256(variableFeeControl) + Constants.VARIABLE_FEE_OFFSET)
                / Constants.VARIABLE_FEE_SCALE;

            variableFee = uint128(vFee);
        }
    }

    /// @notice Calculate total fee (base + variable)
    /// @param params Fee parameters
    /// @param volatilityAccumulator Current volatility
    /// @return totalFee Total fee in 1e18 precision
    function getTotalFee(
        FeeParameters memory params,
        uint24 volatilityAccumulator
    ) internal pure returns (uint128 totalFee) {
        uint128 baseFee = getBaseFee(params.binStep, params.baseFactor);
        uint128 variableFee = getVariableFee(
            params.binStep,
            params.variableFeeControl,
            volatilityAccumulator
        );

        totalFee = baseFee + variableFee;

        // Cap at maximum fee
        if (totalFee > Constants.MAX_FEE) {
            totalFee = Constants.MAX_FEE;
        }
    }

    /// @notice Calculate fee amount from swap amount
    /// @param amount Swap amount
    /// @param totalFee Total fee rate in 1e18 precision
    /// @return fee Fee amount
    function getFeeAmount(uint128 amount, uint128 totalFee) internal pure returns (uint128 fee) {
        unchecked {
            fee = uint128((uint256(amount) * uint256(totalFee)) / Constants.FEE_PRECISION);
        }
    }

    /// @notice Calculate fee amount with composition fee
    /// @dev compositionFee = amount * totalFee * (1 + totalFee) / FEE_PRECISION^2
    /// @param amount Swap amount
    /// @param totalFee Total fee rate
    /// @return fee Fee amount including composition fee
    function getFeeAmountWithComposition(
        uint128 amount,
        uint128 totalFee
    ) internal pure returns (uint128 fee) {
        unchecked {
            // fee = amount * totalFee * (1 + totalFee) / PRECISION^2
            uint256 feeWithComp = uint256(amount) * uint256(totalFee)
                * (Constants.FEE_PRECISION + uint256(totalFee))
                / (Constants.FEE_PRECISION * Constants.FEE_PRECISION);
            fee = uint128(feeWithComp);
        }
    }

    /// @notice Calculate protocol fee from total fee
    /// @param feeAmount Total fee amount
    /// @param protocolShare Protocol share in basis points
    /// @return protocolFee Protocol fee amount
    function getProtocolFee(
        uint128 feeAmount,
        uint16 protocolShare
    ) internal pure returns (uint128 protocolFee) {
        unchecked {
            protocolFee = uint128(
                (uint256(feeAmount) * uint256(protocolShare)) / Constants.BASIS_POINT_MAX
            );
        }
    }

    /// @notice Update volatility accumulator based on price movement
    /// @param params Fee parameters
    /// @param volParams Current volatility parameters
    /// @param activeId New active bin ID
    /// @return newVolatilityAccumulator Updated volatility accumulator
    /// @return newVolatilityReference Updated volatility reference
    function updateVolatilityAccumulator(
        FeeParameters memory params,
        VolatilityParameters memory volParams,
        uint24 activeId
    ) internal view returns (uint24 newVolatilityAccumulator, uint24 newVolatilityReference) {
        uint256 deltaTime = block.timestamp - volParams.timeOfLastUpdate;

        // Calculate volatility from bin delta
        uint24 binDelta;
        if (activeId > volParams.idReference) {
            binDelta = activeId - volParams.idReference;
        } else {
            binDelta = volParams.idReference - activeId;
        }

        // Decay the volatility reference
        newVolatilityReference = volParams.volatilityReference;
        if (deltaTime > 0 && params.decayPeriod > 0) {
            uint256 decayFactor = (deltaTime * Constants.BASIS_POINT_MAX) / uint256(params.decayPeriod);
            if (decayFactor >= Constants.BASIS_POINT_MAX) {
                newVolatilityReference = 0;
            } else {
                newVolatilityReference = uint24(
                    (uint256(volParams.volatilityReference) * (Constants.BASIS_POINT_MAX - decayFactor))
                    / Constants.BASIS_POINT_MAX
                );
            }
        }

        // Update volatility accumulator
        // va = vr + binDelta * reductionFactor
        uint256 newVa = uint256(newVolatilityReference)
            + (uint256(binDelta) * uint256(params.reductionFactor)) / Constants.BASIS_POINT_MAX;

        // Cap at max
        if (newVa > params.maxVolatilityAccumulator) {
            newVa = params.maxVolatilityAccumulator;
        }

        newVolatilityAccumulator = uint24(newVa);
    }

    /// @notice Update volatility reference after filter period
    /// @param params Fee parameters
    /// @param volParams Current volatility parameters
    /// @return newVolatilityReference Updated volatility reference
    function updateVolatilityReference(
        FeeParameters memory params,
        VolatilityParameters memory volParams
    ) internal view returns (uint24 newVolatilityReference) {
        uint256 deltaTime = block.timestamp - volParams.timeOfLastUpdate;

        if (deltaTime >= params.filterPeriod) {
            // After filter period, reference becomes accumulator
            newVolatilityReference = volParams.volatilityAccumulator;
        } else {
            newVolatilityReference = volParams.volatilityReference;
        }
    }
}
