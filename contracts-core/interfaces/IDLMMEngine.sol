// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/FeeHelper.sol";

/**
 * @title IDLMMEngine
 * @notice Interface for the DLMM trading engine (singleton)
 */
interface IDLMMEngine {
    // ============ Structs ============

    /// @notice Bin data for swap calculations
    struct BinData {
        int24 binId;
        uint128 reserveX; // YES reserve
        uint128 reserveY; // NO reserve
    }

    /// @notice Swap calculation result
    struct SwapResult {
        uint128 amountOut;
        uint128 amountInUsed;
        uint128 fee;
        int24 newActiveId;
        BinUpdate[] binUpdates;
    }

    /// @notice Bin update after swap
    struct BinUpdate {
        int24 binId;
        int128 deltaX; // Change in YES reserve (can be negative)
        int128 deltaY; // Change in NO reserve (can be negative)
    }

    // ============ Events ============

    event FeeParametersSet(
        address indexed sender,
        uint16 baseFactor,
        uint16 filterPeriod,
        uint16 decayPeriod,
        uint16 reductionFactor,
        uint24 variableFeeControl,
        uint16 protocolShare,
        uint24 maxVolatilityAccumulator
    );

    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    // ============ View Functions ============

    /// @notice Get the bin step (fixed at 10 basis points)
    function BIN_STEP() external pure returns (uint16);

    /// @notice Get current fee parameters
    function feeParameters() external view returns (
        uint16 binStep,
        uint16 baseFactor,
        uint16 filterPeriod,
        uint16 decayPeriod,
        uint16 reductionFactor,
        uint24 variableFeeControl,
        uint16 protocolShare,
        uint24 maxVolatilityAccumulator
    );

    /// @notice Get fee recipient address
    function feeRecipient() external view returns (address);

    // ============ Price/Probability Functions (Pure) ============

    /// @notice Get price from bin ID
    /// @param id Bin ID (signed)
    /// @return price Price in 128.128 fixed point (1 YES = price NO)
    function getPriceFromId(int24 id) external pure returns (uint256 price);

    /// @notice Get YES probability from bin ID
    /// @param id Bin ID (signed)
    /// @return probability YES probability in 1e18 precision
    function getProbabilityFromId(int24 id) external pure returns (uint256 probability);

    /// @notice Get bin ID for a probability slot
    /// @param slot Slot index (0-98, where 0=1%, 49=50%, 98=99%)
    /// @return binId The canonical bin ID for this slot
    function getBinIdForSlot(uint256 slot) external pure returns (int24 binId);

    /// @notice Check if bin ID is valid (maps to 1% probability step)
    /// @param id Bin ID to check
    /// @return valid True if valid
    function isValidBinId(int24 id) external pure returns (bool valid);

    /// @notice Get bin ID from price
    /// @param price Price in 128.128 fixed point
    /// @return id Bin ID
    function getIdFromPrice(uint256 price) external pure returns (int24 id);

    // ============ Fee Functions ============

    /// @notice Calculate total fee rate
    /// @param volatilityAccumulator Current volatility accumulator
    /// @return totalFee Total fee in 1e18 precision
    function getTotalFee(uint24 volatilityAccumulator) external view returns (uint128 totalFee);

    /// @notice Calculate fee amount for given input
    /// @param amountIn Input amount
    /// @param volatilityAccumulator Current volatility accumulator
    /// @return fee Fee amount
    function calculateFee(uint128 amountIn, uint24 volatilityAccumulator) external view returns (uint128 fee);

    /// @notice Get protocol fee portion
    /// @param fee Total fee
    /// @return protocolFee Protocol fee amount
    function getProtocolFee(uint128 fee) external view returns (uint128 protocolFee);

    // ============ Swap Calculation Functions ============

    /// @notice Calculate swap output (view function for quotes)
    /// @param amountIn Input amount (after fee deduction by caller)
    /// @param swapForY True if swapping YES for NO
    /// @param activeId Current active bin ID
    /// @param bins Array of bin data to consider
    /// @return result Swap calculation result
    function calculateSwapOut(
        uint128 amountIn,
        bool swapForY,
        int24 activeId,
        BinData[] calldata bins
    ) external view returns (SwapResult memory result);

    /// @notice Calculate required input for desired output
    /// @param amountOut Desired output amount
    /// @param swapForY True if swapping YES for NO
    /// @param activeId Current active bin ID
    /// @param bins Array of bin data to consider
    /// @return amountIn Required input amount (before fee)
    /// @return fee Fee amount
    function calculateSwapIn(
        uint128 amountOut,
        bool swapForY,
        int24 activeId,
        BinData[] calldata bins
    ) external view returns (uint128 amountIn, uint128 fee);

    // ============ Volatility Functions ============

    /// @notice Calculate updated volatility parameters
    /// @param currentParams Current volatility parameters
    /// @param activeId Current active bin ID
    /// @return newVolatilityAccumulator Updated volatility accumulator
    /// @return newVolatilityReference Updated volatility reference
    function calculateVolatilityUpdate(
        FeeHelper.VolatilityParameters calldata currentParams,
        int24 activeId
    ) external view returns (uint24 newVolatilityAccumulator, uint24 newVolatilityReference);

    // ============ Admin Functions ============

    /// @notice Set fee parameters (owner only)
    function setFeeParameters(
        uint16 baseFactor,
        uint16 filterPeriod,
        uint16 decayPeriod,
        uint16 reductionFactor,
        uint24 variableFeeControl,
        uint16 protocolShare,
        uint24 maxVolatilityAccumulator
    ) external;

    /// @notice Set fee recipient (owner only)
    function setFeeRecipient(address newRecipient) external;
}
