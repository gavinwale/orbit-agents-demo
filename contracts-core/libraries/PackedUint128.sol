// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PackedUint128
 * @notice Library for packing/unpacking two uint128 values into a single bytes32
 * @dev Used to efficiently pass around pairs of token amounts
 */
library PackedUint128 {
    /// @notice Pack two uint128 values into bytes32
    /// @param x First value (stored in upper 128 bits)
    /// @param y Second value (stored in lower 128 bits)
    /// @return packed The packed value
    function encode(uint128 x, uint128 y) internal pure returns (bytes32 packed) {
        packed = bytes32((uint256(x) << 128) | uint256(y));
    }

    /// @notice Unpack bytes32 into two uint128 values
    /// @param packed The packed value
    /// @return x First value (from upper 128 bits)
    /// @return y Second value (from lower 128 bits)
    function decode(bytes32 packed) internal pure returns (uint128 x, uint128 y) {
        x = uint128(uint256(packed) >> 128);
        y = uint128(uint256(packed));
    }

    /// @notice Get the X (first) value from packed bytes32
    /// @param packed The packed value
    /// @return x The X value
    function decodeX(bytes32 packed) internal pure returns (uint128 x) {
        x = uint128(uint256(packed) >> 128);
    }

    /// @notice Get the Y (second) value from packed bytes32
    /// @param packed The packed value
    /// @return y The Y value
    function decodeY(bytes32 packed) internal pure returns (uint128 y) {
        y = uint128(uint256(packed));
    }

    /// @notice Add two packed values
    /// @param a First packed value
    /// @param b Second packed value
    /// @return result Sum of packed values
    function add(bytes32 a, bytes32 b) internal pure returns (bytes32 result) {
        (uint128 ax, uint128 ay) = decode(a);
        (uint128 bx, uint128 by) = decode(b);
        result = encode(ax + bx, ay + by);
    }

    /// @notice Subtract packed values (a - b)
    /// @param a First packed value
    /// @param b Second packed value
    /// @return result Difference of packed values
    function sub(bytes32 a, bytes32 b) internal pure returns (bytes32 result) {
        (uint128 ax, uint128 ay) = decode(a);
        (uint128 bx, uint128 by) = decode(b);
        result = encode(ax - bx, ay - by);
    }

    /// @notice Check if packed value is zero
    /// @param packed The packed value
    /// @return True if both values are zero
    function isZero(bytes32 packed) internal pure returns (bool) {
        return packed == bytes32(0);
    }

    /// @notice Get the greater of X or Y
    /// @param packed The packed value
    /// @return max The greater value
    function max(bytes32 packed) internal pure returns (uint128) {
        (uint128 x, uint128 y) = decode(packed);
        return x > y ? x : y;
    }

    /// @notice Create packed value with only X
    /// @param x The X value
    /// @return packed Packed value with Y = 0
    function encodeX(uint128 x) internal pure returns (bytes32 packed) {
        packed = bytes32(uint256(x) << 128);
    }

    /// @notice Create packed value with only Y
    /// @param y The Y value
    /// @return packed Packed value with X = 0
    function encodeY(uint128 y) internal pure returns (bytes32 packed) {
        packed = bytes32(uint256(y));
    }
}
