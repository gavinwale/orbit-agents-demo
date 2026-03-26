// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IOptimisticOracle.sol";

/**
 * @title MockOptimisticOracle
 * @notice Test mock for Optimistic Oracle — allows directly setting resolution state
 */
contract MockOptimisticOracle is IOptimisticOracle {
    mapping(uint256 => Resolution) private _resolutions;

    function setResolution(
        uint256 marketId,
        bytes32 outcome,
        ResolutionStatus status
    ) external {
        _resolutions[marketId] = Resolution({
            resolutionId: marketId,
            marketId: marketId,
            proposedOutcome: outcome,
            proposer: msg.sender,
            proposeTime: block.timestamp,
            endTime: block.timestamp,
            disputeWindowTime: 3 hours,
            bondAmount: 0,
            status: status
        });
    }

    function getFinalOutcome(uint256 marketId)
        external view override returns (bytes32 outcome, bool resolved, bool invalid)
    {
        Resolution memory r = _resolutions[marketId];

        if (r.status == ResolutionStatus.Resolved) {
            return (r.proposedOutcome, true, false);
        }
        if (r.status == ResolutionStatus.Invalid) {
            return (bytes32(0), false, true);
        }
        // Unresolved, Proposed, Challenged
        return (r.proposedOutcome, false, false);
    }

    function getResolution(uint256 marketId)
        external view override returns (Resolution memory)
    {
        return _resolutions[marketId];
    }
}
