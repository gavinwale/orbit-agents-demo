// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IOptimisticOracle
 * @notice Minimal interface for reading Optimistic Oracle resolution state
 */
interface IOptimisticOracle {
    enum ResolutionStatus {
        Unresolved,
        Proposed,
        Challenged,
        Resolved,
        Invalid
    }

    struct Resolution {
        uint256 resolutionId;
        uint256 marketId;
        bytes32 proposedOutcome;
        address proposer;
        uint256 proposeTime;
        uint256 endTime;
        uint256 disputeWindowTime;
        uint256 bondAmount;
        ResolutionStatus status;
    }

    /// @notice Get final outcome for a market
    /// @return outcome The winning outcome (bytes32)
    /// @return resolved True if the resolution is finalized
    /// @return invalid True if the market was invalidated (Rule dispute)
    function getFinalOutcome(uint256 marketId)
        external view returns (bytes32 outcome, bool resolved, bool invalid);

    /// @notice Get full resolution data for a market
    function getResolution(uint256 marketId)
        external view returns (Resolution memory);
}
