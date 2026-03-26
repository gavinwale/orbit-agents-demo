// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";

/**
 * @title PriceMath
 * @notice Library for DLMM price calculations (Meteora-style)
 * @dev Implements price = (1 + binStep/BASIS_POINT_MAX)^binId using fixed-point math
 *
 *      Meteora-style bin ID:
 *      - binId = 0  → price = 1 (1:1 exchange rate)
 *      - binId > 0  → price > 1
 *      - binId < 0  → price < 1
 */
library PriceMath {
    /// @notice Maximum value for uint128
    uint256 private constant MAX_U128 = type(uint128).max;

    /// @notice Calculate price from bin ID (Meteora-style, no offset)
    /// @dev price = (1 + binStep/10000)^binId
    /// @param binStep Bin step in basis points
    /// @param binId Bin ID (signed, can be negative)
    /// @return price Price in 128.128 fixed point format
    function getPriceFromId(uint16 binStep, int24 binId) internal pure returns (uint256 price) {
        // Calculate base = 1 + binStep / BASIS_POINT_MAX
        // In fixed point: base = SCALE + (binStep * SCALE / BASIS_POINT_MAX)
        uint256 base = Constants.SCALE + (uint256(binStep) * Constants.SCALE / Constants.BASIS_POINT_MAX);

        // Calculate price = base^binId
        if (binId >= 0) {
            price = _pow(base, uint256(int256(binId)));
        } else {
            // For negative exponent: price = SCALE^2 / base^|binId|
            uint256 inversePow = _pow(base, uint256(int256(-binId)));
            price = _mulDiv(Constants.SCALE, Constants.SCALE, inversePow);
        }
    }

    /// @notice Calculate bin ID from price (Meteora-style, no offset)
    /// @dev binId = log(price) / log(1 + binStep/10000)
    /// @param binStep Bin step in basis points
    /// @param price Price in 128.128 fixed point format
    /// @return binId Bin ID (signed)
    function getIdFromPrice(uint16 binStep, uint256 price) internal pure returns (int24 binId) {
        require(price > 0, "PriceMath: ZERO_PRICE");

        // Calculate base = 1 + binStep / BASIS_POINT_MAX
        uint256 base = Constants.SCALE + (uint256(binStep) * Constants.SCALE / Constants.BASIS_POINT_MAX);

        // Use binary search to find binId such that getPriceFromId(binStep, binId) ~= price
        int256 result = _log(price, base);

        // Clamp to int24 range
        require(result >= type(int24).min && result <= type(int24).max, "PriceMath: ID_OUT_OF_RANGE");

        binId = int24(result);
    }

    /// @notice Calculate composition factor (percentage of Y in bin)
    /// @dev c = reserveY / (price * reserveX + reserveY)
    /// @param price Price in 128.128 fixed point
    /// @param reserveX Reserve of token X
    /// @param reserveY Reserve of token Y
    /// @return c Composition factor in 1e18 precision (0 = all X, 1e18 = all Y)
    function getComposition(
        uint256 price,
        uint128 reserveX,
        uint128 reserveY
    ) internal pure returns (uint256 c) {
        if (reserveX == 0 && reserveY == 0) return 0;

        // L = price * x + y (in SCALE precision)
        uint256 priceTimesX = (price * uint256(reserveX)) / Constants.SCALE;
        uint256 L = priceTimesX + uint256(reserveY);

        if (L == 0) return 0;

        // c = y / L
        c = (uint256(reserveY) * Constants.PRECISION) / L;
    }

    /// @notice Calculate liquidity from reserves
    /// @dev L = price * x + y
    /// @param price Price in 128.128 fixed point
    /// @param reserveX Reserve of token X
    /// @param reserveY Reserve of token Y
    /// @return L Liquidity amount
    function getLiquidityFromReserves(
        uint256 price,
        uint128 reserveX,
        uint128 reserveY
    ) internal pure returns (uint256 L) {
        L = (price * uint256(reserveX)) / Constants.SCALE + uint256(reserveY);
    }

    /// @notice Calculate token amounts from liquidity and composition
    /// @dev x = L * (1 - c) / price, y = L * c
    /// @param price Price in 128.128 fixed point
    /// @param L Liquidity amount
    /// @param c Composition factor (0-1e18)
    /// @return amountX Amount of token X
    /// @return amountY Amount of token Y
    function getAmountsFromLiquidity(
        uint256 price,
        uint256 L,
        uint256 c
    ) internal pure returns (uint128 amountX, uint128 amountY) {
        require(c <= Constants.PRECISION, "PriceMath: INVALID_COMPOSITION");

        // y = L * c / PRECISION
        amountY = uint128((L * c) / Constants.PRECISION);

        // x = L * (1 - c) / price
        uint256 oneMinusC = Constants.PRECISION - c;
        amountX = uint128((L * oneMinusC * Constants.SCALE) / (Constants.PRECISION * price));
    }

    /// @notice Power function using binary exponentiation
    /// @param base Base in SCALE precision
    /// @param exp Exponent (integer)
    /// @return result base^exp in SCALE precision
    function _pow(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = Constants.SCALE;

        while (exp > 0) {
            if (exp & 1 == 1) {
                result = _mulDiv(result, base, Constants.SCALE);
            }
            base = _mulDiv(base, base, Constants.SCALE);
            exp >>= 1;
        }
    }

    /// @notice Safe multiplication with division to handle intermediate overflow
    /// @dev Uses 512-bit intermediate precision: (a * b) / c
    /// @param a First multiplicand
    /// @param b Second multiplicand
    /// @param c Divisor
    /// @return result (a * b) / c
    function _mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = a * b
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Short circuit if no overflow
        if (prod1 == 0) {
            return prod0 / c;
        }

        // Make sure the result is less than 2^256
        require(prod1 < c, "PriceMath: OVERFLOW");

        // 512 by 256 division
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, c)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of c
        uint256 twos = c & (~c + 1);
        assembly {
            c := div(c, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }

        // These operations are designed to use modular arithmetic (wrapping)
        unchecked {
            prod0 |= prod1 * twos;

            // Compute the modular inverse of c using Newton-Raphson iteration
            uint256 inv = (3 * c) ^ 2;
            inv *= 2 - c * inv;
            inv *= 2 - c * inv;
            inv *= 2 - c * inv;
            inv *= 2 - c * inv;
            inv *= 2 - c * inv;
            inv *= 2 - c * inv;

            result = prod0 * inv;
        }
    }

    /// @notice Logarithm approximation using binary search
    /// @param value Value to find log of (in SCALE precision)
    /// @param base Base of logarithm (in SCALE precision)
    /// @return result log_base(value) as integer
    function _log(uint256 value, uint256 base) internal pure returns (int256 result) {
        if (value == Constants.SCALE) return 0;

        bool negative = value < Constants.SCALE;
        if (negative) {
            // For value < SCALE, result is negative
            // log(value) = -log(SCALE^2/value)
            value = _mulDiv(Constants.SCALE, Constants.SCALE, value);
        }

        // Binary search for the exponent
        result = 0;
        uint256 tempBase = base;
        uint256 power = 1;

        // Find approximate result using doubling
        while (tempBase <= value) {
            tempBase = _mulDiv(tempBase, tempBase, Constants.SCALE);
            power *= 2;
        }

        // Binary search refinement
        for (uint256 bit = power / 2; bit > 0; bit /= 2) {
            uint256 testPow = _pow(base, uint256(result) + bit);
            if (testPow <= value) {
                result += int256(bit);
            }
        }

        if (negative) {
            result = -result;
        }
    }
}
