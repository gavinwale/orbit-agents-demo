// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/ISwapHook.sol";

/**
 * @title SwapHookRouter
 * @notice Routes afterSwap calls to multiple hook contracts
 * @dev MarketCore supports a single swapHook address. This contract acts as
 *      a multiplexer, dispatching afterSwap to both LimitOrderManager (for
 *      limit order fills) and LPManager (for time-decay LP withdrawal).
 *
 *      Execution order:
 *      1. LimitOrderManager — fill triggered limit orders first
 *      2. LPManager — check time decay and withdraw LP if interval passed
 */
contract SwapHookRouter is ISwapHook, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Array of registered hook contracts
    ISwapHook[] public hooks;

    /// @notice Whether to use strict mode (revert on hook failure)
    /// @dev Default is true for aggregated LP architecture (O(1) processing)
    bool public strictMode;

    // ============ Storage Gap ============

    uint256[50] private __gap;

    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);
    event HookFailed(address indexed hook, uint256 indexed marketId, bytes reason);
    event StrictModeUpdated(bool newMode);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        strictMode = true;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Add a hook contract to the dispatch list
    /// @param hook Address of the ISwapHook contract
    function addHook(address hook) external onlyOwner {
        require(hook != address(0), "SwapHookRouter: ZERO_ADDRESS");
        // Prevent duplicates
        for (uint256 i = 0; i < hooks.length; i++) {
            require(address(hooks[i]) != hook, "SwapHookRouter: DUPLICATE");
        }
        hooks.push(ISwapHook(hook));
        emit HookAdded(hook);
    }

    /// @notice Remove a hook contract from the dispatch list
    /// @param hook Address to remove
    function removeHook(address hook) external onlyOwner {
        uint256 len = hooks.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(hooks[i]) == hook) {
                hooks[i] = hooks[len - 1];
                hooks.pop();
                emit HookRemoved(hook);
                return;
            }
        }
        revert("SwapHookRouter: NOT_FOUND");
    }

    /// @notice Set strict mode
    /// @param _strictMode True to revert on hook failure, false to continue
    function setStrictMode(bool _strictMode) external onlyOwner {
        strictMode = _strictMode;
        emit StrictModeUpdated(_strictMode);
    }

    /// @inheritdoc ISwapHook
    /// @dev Uses try-catch to prevent hook failures from blocking swaps
    ///      In non-strict mode, failed hooks emit HookFailed event and continue
    ///      In strict mode, any hook failure reverts the entire swap
    function afterSwap(
        uint256 marketId,
        int24 oldActiveId,
        int24 newActiveId
    ) external override returns (bool success) {
        uint256 len = hooks.length;
        for (uint256 i = 0; i < len; i++) {
            ISwapHook hook = hooks[i];

            if (strictMode) {
                // Strict mode: revert on failure
                bool hookSuccess = hook.afterSwap(marketId, oldActiveId, newActiveId);
                require(hookSuccess, "SwapHookRouter: HOOK_FAILED");
            } else {
                // Non-strict mode: catch failures and continue
                try hook.afterSwap(marketId, oldActiveId, newActiveId) returns (bool hookSuccess) {
                    if (!hookSuccess) {
                        emit HookFailed(address(hook), marketId, "returned false");
                    }
                } catch (bytes memory reason) {
                    emit HookFailed(address(hook), marketId, reason);
                    // Continue to next hook instead of reverting
                }
            }
        }
        return true;
    }

    /// @notice Get number of registered hooks
    function hookCount() external view returns (uint256) {
        return hooks.length;
    }
}
