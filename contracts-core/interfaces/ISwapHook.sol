// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISwapHook
 * @notice Interface for swap hook contracts
 * @dev Called by MarketCore after each swap to allow for limit order execution,
 *      LP withdrawals, and other post-swap logic
 */
interface ISwapHook {
    /// @notice Called after a swap is executed
    /// @param marketId Market ID
    /// @param oldActiveId Active bin ID before the swap
    /// @param newActiveId Active bin ID after the swap
    /// @return success Whether the hook executed successfully
    function afterSwap(
        uint256 marketId,
        int24 oldActiveId,
        int24 newActiveId
    ) external returns (bool success);
}
