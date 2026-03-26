// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILPFeeCollector
 * @notice Interface for collecting LP fee accounting
 * @dev Called by MarketCore after each swap to track LP fees
 */
interface ILPFeeCollector {
    /// @notice Record LP fee earned from a swap
    /// @param marketId Market ID
    /// @param lpFee Amount of LP fee (in outcome tokens added to bin)
    function recordLPFee(uint256 marketId, uint128 lpFee) external;
}
