// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Constants
 * @notice Constants used across Prediction Market DLMM contracts
 */
library Constants {
    /// @notice Precision for fixed-point calculations (1e18)
    uint256 internal constant PRECISION = 1e18;

    /// @notice Scale for 128.128 fixed point (2^128)
    uint256 internal constant SCALE = 1 << 128;

    /// @notice Maximum basis points (100%)
    uint256 internal constant BASIS_POINT_MAX = 10_000;

    // ============ Prediction Market Constants ============

    /// @notice Default bin step for prediction markets (0.1% = 10 basis points)
    uint16 internal constant DEFAULT_BIN_STEP = 10;

    /// @notice Minimum bin ID for prediction market (corresponds to ~1% probability)
    /// @dev Actual binId for 1% probability is ~-4605, giving some margin
    int24 internal constant MIN_PREDICTION_BIN_ID = -4610;

    /// @notice Maximum bin ID for prediction market (corresponds to ~99% probability)
    /// @dev Actual binId for 99% probability is ~+4600, giving some margin
    int24 internal constant MAX_PREDICTION_BIN_ID = 4610;

    /// @notice Total number of valid prediction bins (99 discrete probability steps: 1% to 99%)
    uint24 internal constant TOTAL_PREDICTION_BINS = 99;

    /// @notice Probability step per bin (exactly 1%)
    uint256 internal constant PROB_STEP = 1e16; // 0.01 * 1e18

    /// @notice Minimum probability (1% = 0.01)
    uint256 internal constant MIN_PROBABILITY = 1e16; // 0.01 * 1e18

    /// @notice Maximum probability (99% = 0.99)
    uint256 internal constant MAX_PROBABILITY = 99e16; // 0.99 * 1e18

    /// @notice Probability precision divisor (100 for 1% steps)
    uint256 internal constant PROB_DIVISOR = 100;

    // ============ Fee Constants ============

    /// @notice Maximum fee rate (5%)
    uint128 internal constant MAX_FEE = 0.05e18;

    /// @notice Fee precision
    uint256 internal constant FEE_PRECISION = 1e18;

    /// @notice Maximum protocol share (25%)
    uint16 internal constant MAX_PROTOCOL_SHARE = 2_500;

    // ============ Utility Constants ============

    /// @notice Mask for uint128 (lower 128 bits)
    uint256 internal constant MASK_UINT128 = type(uint128).max;

    /// @notice Mask for uint24 (lower 24 bits)
    uint256 internal constant MASK_UINT24 = type(uint24).max;

    /// @notice Mask for uint1 (lowest bit)
    uint256 internal constant MASK_UINT1 = 1;

    /// @notice Offset for variable fee calculation
    uint256 internal constant VARIABLE_FEE_OFFSET = 99_999_999_999;

    /// @notice Scale for variable fee calculation
    uint256 internal constant VARIABLE_FEE_SCALE = 100_000_000_000;

    // ============ Legacy Constants (kept for compatibility) ============

    /// @notice Minimum bin step
    uint16 internal constant MIN_BIN_STEP = 1;

    /// @notice Maximum bin step
    uint16 internal constant MAX_BIN_STEP = 100;
}
