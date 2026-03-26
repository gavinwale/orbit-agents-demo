// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OptimisticOracleArbitration is ReentrancyGuard {
    // ==================== State Variables ====================

    address public admin;

    // Bond Token address
    IERC20 public bondToken;
    // Outcome submission Bond (200 U)
    uint256 public proposeBond;
    // Dispute Bond (200 U)
    uint256 public challengeBond;
    // Challenge window (default 3 hours, adjustable by admin)
    uint256 public challengeWindow;
    // Reserve fund balance
    uint256 public reserveFund;

    // ==================== Enums ====================

    enum ResolutionStatus {
        Unresolved,
        Proposed,
        Challenged,
        Resolved,
        Invalid
    }
    enum DisputeType {
        Outcome,
        Rule
    }

    // ==================== Structs ====================

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

    struct Dispute {
        uint256 disputeId;
        uint256 resolutionId;
        uint256 marketId;
        DisputeType disputeType;
        bytes32 challengedOutcome;
        address challenger;
        uint256 bondAmount;
        uint256 disputeTime;
        bool resolved;
        string reason; // URL of the dispute description, can be centralized https or IPFS CID
    }

    struct Vote {
        bool support;
        bool voted;
    }

    struct Arbitration {
        uint256 disputeId;
        uint256 resolutionId;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 startTime;
        bool finalized;
        bytes32 finalOutcome; // Only used for outcome dispute
        bool invalidate; // Whether to invalidate the market
    }

    // ==================== Main Storage ====================

    mapping(address => bool) public arbitrators;

    struct Proposer {
        bool active; // Whether the proposer is active
        bool isPlatform; // Whether it is a platform account
    }

    mapping(address => Proposer) public proposers;

    // marketId => Resolution
    mapping(uint256 => Resolution) public resolutions;

    // disputeId => Dispute
    mapping(uint256 => Dispute) public disputes;

    // disputeId => Arbitration
    mapping(uint256 => Arbitration) public arbitrations;

    // disputeId => arbitrator => Vote
    mapping(uint256 => mapping(address => Vote)) public arbitrationVotes;

    // Number of arbitrators
    uint256 public arbitratorCount;

    // ==================== Error Definitions ====================

    error OnlyAdmin();
    error OnlyArbitrator();
    error InvalidProposer();
    error InvalidStatus();
    error InvalidStatusTransition();
    error NotWithinChallengeWindow();
    error AlreadyVoted();
    error MarketAlreadyExists();
    error MarketNotExists();
    error MarketAlreadyResolved();
    error MarketAlreadyChallenged();
    error MarketNotOver();
    error InvalidArbitratorAddress();
    error InsufficientBond();
    error BondTransferFailed();
    error VoteAlreadyFinalized();
    error InvalidResolutionId();
    error InvalidDisputeId();

    // ==================== Core Events ====================

    event ResolutionCreated(
        uint256 indexed resolutionId,
        uint256 indexed marketId,
        address proposer,
        uint256 bondAmount,
        uint256 createTime,
        uint256 disputeWindowTime,
        uint256 endTime
    );

    // Outcome proposal event
    event OutcomeProposed(
        uint256 indexed resolutionId,
        uint256 indexed marketId,
        bytes32 proposedOutcome,
        address proposer,
        uint256 proposeTime
    );

    // Dispute creation event
    event DisputeCreated(
        uint256 indexed disputeId,
        uint256 indexed resolutionId,
        uint256 indexed marketId,
        DisputeType disputeType,
        bytes32 challengedOutcome,
        address challenger,
        uint256 bondAmount,
        uint256 disputeTime,
        string reason
    );

    // Voting event
    event VoteCast(
        uint256 indexed resolutionId,
        uint256 indexed disputeId,
        address indexed arbitrator,
        bool support,
        uint256 timestamp
    );

    // Arbitration finalized event
    event ArbitrationFinalized(
        uint256 indexed resolutionId,
        uint256 indexed disputeId,
        uint256 indexed marketId,
        bytes32 finalOutcome,
        bool invalidate,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 finalizeTime
    );

    // Auto-confirmation event (no challenge expired)
    event AutoConfirmed(
        uint256 indexed resolutionId,
        uint256 indexed marketId,
        uint256 confirmTime
    );

    // Bond distribution event
    event BondDistributed(
        uint256 indexed resolutionId,
        address indexed recipient,
        uint256 indexed marketId,
        uint256 amount,
        string reason // "no_challenge", "challenge_failed", "challenge_success", "market_invalid"
    );

    // Arbitrator change events
    event ArbitratorAdded(address indexed arbitrator, uint256 timestamp);
    event ArbitratorRemoved(address indexed arbitrator, uint256 timestamp);

    // Parameter update event
    event ParameterUpdated(
        string parameterName,
        uint256 oldValue,
        uint256 newValue,
        uint256 timestamp
    );

    // Bond Token update event
    event BondTokenUpdated(
        address indexed oldToken,
        address indexed newToken,
        uint256 timestamp
    );

    // ==================== Modifiers ====================

    // Only admin can call
    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }
        _;
    }

    // Only arbitrator can call
    modifier onlyArbitrator() {
        if (!arbitrators[msg.sender]) {
            revert OnlyArbitrator();
        }
        _;
    }

    // ==================== Constructor ====================

    constructor(address _bondToken) {
        admin = msg.sender;
        bondToken = IERC20(_bondToken);
        challengeWindow = 3 hours; // Default 3 hours

        // Dynamically get token decimals and set bond
        try IERC20Metadata(_bondToken).decimals() returns (uint8 decimals) {
            // Successfully got decimals
            proposeBond = 200 * 10 ** decimals;
            challengeBond = 200 * 10 ** decimals;
        } catch {
            // Failed to get decimals, use default value 18
            proposeBond = 200 * 1e18;
            challengeBond = 200 * 1e18;
        }
    }

    // ==================== Admin Functions ====================

    /**
     * @dev Add arbitrator
     */
    function addArbitrator(address _arbitrator) external onlyAdmin {
        if (_arbitrator == address(0)) {
            revert InvalidArbitratorAddress();
        }
        if (arbitrators[_arbitrator]) {
            revert InvalidArbitratorAddress();
        }

        arbitrators[_arbitrator] = true;
        arbitratorCount++;
        emit ArbitratorAdded(_arbitrator, block.timestamp);
    }

    /**
     * @dev Remove arbitrator
     */
    function removeArbitrator(address _arbitrator) external onlyAdmin {
        if (!arbitrators[_arbitrator]) {
            revert InvalidArbitratorAddress();
        }

        arbitrators[_arbitrator] = false;
        arbitratorCount--;
        emit ArbitratorRemoved(_arbitrator, block.timestamp);
    }

    /**
     * @dev Add proposer
     */
    function addProposer(
        address _proposer,
        bool _isPlatform
    ) external onlyAdmin {
        proposers[_proposer] = Proposer({
            active: true,
            isPlatform: _isPlatform
        });
    }

    /**
     * @dev Remove proposer
     */
    function removeProposer(address _proposer) external onlyAdmin {
        proposers[_proposer].active = false;
    }

    /**
     * @dev Update proposeBond
     */
    function updateProposeBond(uint256 _newBond) external onlyAdmin {
        uint256 oldBond = proposeBond;
        proposeBond = _newBond;
        emit ParameterUpdated(
            "proposeBond",
            oldBond,
            _newBond,
            block.timestamp
        );
    }

    /**
     * @dev Update challengeBond
     */
    function updateChallengeBond(uint256 _newBond) external onlyAdmin {
        uint256 oldBond = challengeBond;
        challengeBond = _newBond;
        emit ParameterUpdated(
            "challengeBond",
            oldBond,
            _newBond,
            block.timestamp
        );
    }

    /**
     * @dev Update challengeWindow
     */
    function updateChallengeWindow(uint256 _newWindow) external onlyAdmin {
        uint256 oldWindow = challengeWindow;
        challengeWindow = _newWindow;
        emit ParameterUpdated(
            "challengeWindow",
            oldWindow,
            _newWindow,
            block.timestamp
        );
    }

    /**
     * @dev Transfer admin rights
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) {
            revert InvalidArbitratorAddress();
        }
        admin = _newAdmin;
    }

    /**
     * @dev Update Bond Token address
     */
    function updateBondToken(address _newToken) external onlyAdmin {
        if (_newToken == address(0)) {
            revert InvalidArbitratorAddress();
        }
        address oldToken = address(bondToken);
        bondToken = IERC20(_newToken);

        uint8 oldDecimals = IERC20Metadata(oldToken).decimals();
        uint8 newDecimals = IERC20Metadata(_newToken).decimals();
        if (oldDecimals != newDecimals) {
            // After updating address, need to check if decimals match old token
            proposeBond = proposeBond / 10 ** oldDecimals;
            challengeBond = challengeBond / 10 ** oldDecimals;

            proposeBond = proposeBond * 10 ** newDecimals;
            challengeBond = challengeBond * 10 ** newDecimals;
        }

        emit BondTokenUpdated(oldToken, _newToken, block.timestamp);
    }

    // ==================== Core Functions ====================

    /**
     * @dev Pre-create resolution
     * @param marketId Market ID
     * @param resolutionId Resolution ID
     * @param disputeWindowTime Dispute window time (optional, 0 uses default value)
     * @param endTime Resolution time
     */
    function createResolution(
        uint256 marketId,
        uint256 resolutionId,
        uint256 disputeWindowTime,
        uint256 endTime
    ) external {
        // Check proposer permission
        if (!proposers[msg.sender].active) {
            revert InvalidProposer();
        }

        // Check if already exists
        Resolution storage resolution = resolutions[marketId];
        if (resolution.marketId != uint256(0)) {
            revert MarketAlreadyExists();
        }

        // Non-platform accounts need to check and deduct bond
        bool isPlatform = proposers[msg.sender].isPlatform;
        if (!isPlatform) {
            // Check allowance
            uint256 allowance = bondToken.allowance(msg.sender, address(this));
            if (allowance < proposeBond) {
                revert InsufficientBond();
            }

            // Transfer bond to contract
            bool success = bondToken.transferFrom(
                msg.sender,
                address(this),
                proposeBond
            );
            if (!success) {
                revert BondTransferFailed();
            }
        }

        // Set dispute window time
        uint256 window = disputeWindowTime == 0
            ? challengeWindow
            : disputeWindowTime;

        // Create resolution
        resolutions[marketId] = Resolution({
            resolutionId: resolutionId,
            marketId: marketId,
            proposedOutcome: bytes32(0),
            proposer: msg.sender,
            proposeTime: uint256(0),
            disputeWindowTime: window,
            endTime: endTime,
            bondAmount: proposeBond,
            status: ResolutionStatus.Unresolved
        });

        emit ResolutionCreated(
            resolutionId,
            marketId,
            msg.sender,
            proposeBond,
            block.timestamp,
            window,
            endTime
        );
    }

    /**
     * @dev Submit outcome proposal
     * @param marketId Market ID
     * @param outcome Proposal outcome (bytes32 format)
     */
    function proposeOutcome(uint256 marketId, bytes32 outcome) external {
        // Check proposer permission
        if (!proposers[msg.sender].active) {
            revert InvalidProposer();
        }

        // Check if market is resolved
        Resolution storage resolution = resolutions[marketId];

        if (resolution.marketId != marketId) {
            revert MarketNotExists();
        }

        if (resolution.proposer != msg.sender) {
            revert InvalidProposer();
        }

        if (resolution.status != ResolutionStatus.Unresolved) {
            revert MarketAlreadyResolved();
        }

        if (resolution.endTime > block.timestamp) {
            revert MarketNotOver();
        }

        // Update resolution
        resolution.proposedOutcome = outcome;
        resolution.proposeTime = block.timestamp;
        resolution.status = ResolutionStatus.Proposed;

        emit OutcomeProposed(
            resolution.resolutionId,
            marketId,
            outcome,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @dev Submit dispute
     * @param disputeId Dispute ID
     * @param resolutionId Resolution ID
     * @param marketId Market ID
     * @param disputeType Dispute type (0=Outcome, 1=Rule)
     * @param challengedOutcome Challenged outcome (bytes32 format, only valid when disputeType is Outcome)
     * @param reason Dispute description (URL)
     */
    function challenge(
        uint256 disputeId,
        uint256 resolutionId,
        uint256 marketId,
        DisputeType disputeType,
        bytes32 challengedOutcome,
        string calldata reason
    ) external {
        // Check and deduct bond
        uint256 allowance = bondToken.allowance(msg.sender, address(this));
        if (allowance < challengeBond) {
            revert InsufficientBond();
        }

        // Check resolution status
        Resolution storage resolution = resolutions[marketId];
        if (disputeType == DisputeType.Outcome) {
            if (resolution.status != ResolutionStatus.Proposed) {
                revert InvalidStatus();
            }

            // Check if within dispute window
            if (
                block.timestamp >
                resolution.proposeTime + resolution.disputeWindowTime
            ) {
                revert NotWithinChallengeWindow();
            }
        } else {
            if (
                resolution.marketId == marketId &&
                resolution.status != ResolutionStatus.Unresolved
            ) {
                revert InvalidStatus();
            }
        }

        // Transfer bond to contract
        uint256 bondAmount = challengeBond;
        bool success = bondToken.transferFrom(
            msg.sender,
            address(this),
            bondAmount
        );
        if (!success) {
            revert BondTransferFailed();
        }

        // Create dispute
        disputes[disputeId] = Dispute({
            disputeId: disputeId,
            resolutionId: resolutionId,
            marketId: marketId,
            disputeType: disputeType,
            challengedOutcome: challengedOutcome,
            challenger: msg.sender,
            bondAmount: bondAmount,
            disputeTime: block.timestamp,
            resolved: false,
            reason: reason
        });

        // Update resolution status
        resolution.status = ResolutionStatus.Challenged;

        // Create arbitration
        arbitrations[disputeId] = Arbitration({
            disputeId: disputeId,
            resolutionId: resolutionId,
            yesVotes: 0,
            noVotes: 0,
            startTime: block.timestamp,
            finalized: false,
            finalOutcome: bytes32(0),
            invalidate: false
        });

        emit DisputeCreated(
            disputeId,
            resolutionId,
            marketId,
            disputeType,
            challengedOutcome,
            msg.sender,
            bondAmount,
            block.timestamp,
            reason
        );
    }

    /**
     * @dev Arbitration voting
     * @param disputeId Dispute ID
     * @param support Whether to support proposal (true=support proposer, false=support challenger)
     */
    function vote(uint256 disputeId, bool support) external onlyArbitrator {
        // Check if arbitration exists
        Arbitration storage arbitration = arbitrations[disputeId];
        if (arbitration.startTime == 0) {
            revert InvalidDisputeId();
        }

        // Check if already finalized
        if (arbitration.finalized) {
            revert VoteAlreadyFinalized();
        }

        // Check if already voted
        if (arbitrationVotes[disputeId][msg.sender].voted) {
            revert AlreadyVoted();
        }

        // Record vote
        arbitrationVotes[disputeId][msg.sender] = Vote({
            support: support,
            voted: true
        });

        // Update vote count
        if (support) {
            arbitration.yesVotes++;
        } else {
            arbitration.noVotes++;
        }

        emit VoteCast(
            arbitration.resolutionId,
            disputeId,
            msg.sender,
            support,
            block.timestamp
        );

        // Check if can finalize
        _tryFinalizeArbitration(disputeId);
    }

    /**
     * @dev Try to finalize arbitration
     */
    function _tryFinalizeArbitration(uint256 disputeId) internal {
        Arbitration storage arbitration = arbitrations[disputeId];
        uint256 totalVotes = arbitration.yesVotes + arbitration.noVotes;

        // Calculate required votes
        uint256 requiredVotes;
        if (arbitratorCount < 3) {
            // Arbitrator count < 3: Must be unanimous (all arbitrators agree)
            requiredVotes = arbitratorCount;
        } else {
            // Arbitrator count ≥ 3: Need ≥ 2/3 yes votes
            requiredVotes = (arbitratorCount * 2 + 2) / 3; // Round up
        }

        // Check if finalize conditions are met
        bool canFinalize = false;
        bool supportWins = false;

        if (arbitratorCount < 3) {
            // Unanimous: all votes are yes OR all votes are no
            bool allYes = (arbitration.yesVotes == arbitratorCount) &&
                (arbitration.noVotes == 0);
            canFinalize = totalVotes == arbitratorCount;
            // All arbitrators have voted and reached consensus or it's not allNo
            if (allYes || (canFinalize && arbitration.noVotes == 1)) {
                supportWins = true;
            } else {
                supportWins = false;
            }
        } else {
            // 2/3 yes: yesVotes >= requiredVotes
            supportWins = (arbitration.yesVotes >= requiredVotes);
            canFinalize =
                (totalVotes >= requiredVotes) &&
                (supportWins || arbitration.noVotes >= requiredVotes);
        }

        if (canFinalize) {
            _finalizeArbitration(disputeId, supportWins);
        }
    }

    /**
     * @dev Finalize arbitration
     */
    function _finalizeArbitration(
        uint256 disputeId,
        bool supportWins
    ) internal {
        Arbitration storage arbitration = arbitrations[disputeId];
        Dispute storage dispute = disputes[disputeId];
        Resolution storage resolution = resolutions[dispute.marketId];

        arbitration.finalized = true;
        dispute.resolved = true;

        if (supportWins) {
            // Vote supports proposer (challenge failed)
            // Challenge bond to proposer (only has bond when proposer is not platform account)
            if (dispute.bondAmount > 0) {
                if (proposers[resolution.proposer].isPlatform == false) {
                    _distributeBond(
                        dispute.marketId,
                        resolution.proposer,
                        dispute.bondAmount,
                        "challenge_failed"
                    );
                } else {
                    reserveFund += dispute.bondAmount;
                }
            }

            // Final outcome is the proposed outcome
            arbitration.finalOutcome = resolution.proposedOutcome;
            arbitration.invalidate = false;

            if (dispute.disputeType == DisputeType.Outcome) {
                resolution.status = ResolutionStatus.Resolved;
            } else {
                resolution.status = ResolutionStatus.Unresolved;
            }
        } else {
            // Vote supports challenger (challenge succeeded)
            // Proposal bond to challenger (only has bond when proposer is not platform account)
            if (resolution.bondAmount > 0 || dispute.bondAmount > 0) {
                if (proposers[resolution.proposer].isPlatform) {
                    if (reserveFund < resolution.bondAmount) {
                        revert InsufficientBond();
                    }
                    reserveFund -= resolution.bondAmount;
                }
                uint256 totalReward = resolution.bondAmount +
                    dispute.bondAmount;
                _distributeBond(
                    dispute.marketId,
                    dispute.challenger,
                    totalReward,
                    "challenge_success"
                );
            }

            arbitration.finalOutcome = dispute.challengedOutcome;

            // Set final outcome based on dispute type
            if (dispute.disputeType == DisputeType.Outcome) {
                resolution.status = ResolutionStatus.Resolved;
            } else {
                // Rule dispute: market is invalidated
                arbitration.invalidate = true;
                resolution.status = ResolutionStatus.Invalid;
            }
        }

        emit ArbitrationFinalized(
            arbitration.resolutionId,
            disputeId,
            dispute.marketId,
            arbitration.finalOutcome,
            arbitration.invalidate,
            arbitration.yesVotes,
            arbitration.noVotes,
            block.timestamp
        );
    }

    /**
     * @dev Execute resolution (off-chain driver, auto-confirm resolutions without challenge)
     * @param marketId Market ID
     */
    function finalizeResolution(uint256 marketId) external {
        Resolution storage resolution = resolutions[marketId];

        // Check status
        if (resolution.status != ResolutionStatus.Proposed) {
            revert InvalidStatus();
        }

        // Check if dispute window has passed
        if (
            block.timestamp <=
            resolution.proposeTime + resolution.disputeWindowTime
        ) {
            revert NotWithinChallengeWindow();
        }

        // Auto-confirm
        resolution.status = ResolutionStatus.Resolved;

        // Distribute bond to proposer
        if (resolution.bondAmount > 0) {
            if (proposers[resolution.proposer].isPlatform == false) {
                _distributeBond(
                    marketId,
                    resolution.proposer,
                    resolution.bondAmount,
                    "no_challenge"
                );
            }
        }

        emit AutoConfirmed(resolution.resolutionId, marketId, block.timestamp);
    }

    /**
     * @dev Distribute Bond
     */
    function _distributeBond(
        uint256 marketId,
        address recipient,
        uint256 amount,
        string memory reason
    ) internal nonReentrant {
        // If recipient is platform account, do not actually transfer
        bool success = bondToken.transfer(recipient, amount);
        if (!success) {
            revert BondTransferFailed();
        }
        Resolution storage resolution = resolutions[marketId];
        emit BondDistributed(
            resolution.resolutionId,
            recipient,
            marketId,
            amount,
            reason
        );
    }

    /**
     * @dev Get final outcome
     * @param marketId Market ID
     * @return outcome Final outcome (bytes32(0) means not yet resolved)
     * @return resolved Whether resolved
     * @return invalid Whether market is invalidated
     */
    function getFinalOutcome(
        uint256 marketId
    ) external view returns (bytes32 outcome, bool resolved, bool invalid) {
        Resolution storage resolution = resolutions[marketId];

        if (resolution.status == ResolutionStatus.Unresolved) {
            return (bytes32(0), false, false);
        }

        if (resolution.status == ResolutionStatus.Proposed) {
            // Proposed but not yet resolved
            return (resolution.proposedOutcome, false, false);
        }

        if (resolution.status == ResolutionStatus.Resolved) {
            // Auto-confirmed case
            return (resolution.proposedOutcome, true, false);
        }

        // Challenged status needs to be handled through arbitration
        if (resolution.status == ResolutionStatus.Challenged) {
            // Find corresponding arbitration
            // Simplified here, in practice may need to iterate or build mapping
            // Since MVP version doesn't have disputeId -> marketId reverse mapping, cannot implement here
            // Suggest caller query arbitration result through disputeId
            return (bytes32(0), false, false);
        }

        // Invalid status
        if (resolution.status == ResolutionStatus.Invalid) {
            return (bytes32(0), false, true);
        }

        return (bytes32(0), false, false);
    }

    /**
     * @dev Get arbitration final outcome (through disputeId)
     * @param disputeId Dispute ID
     * @return finalOutcome Final outcome
     * @return invalidate Whether market is invalidated
     * @return finalized Whether finalized
     */
    function getArbitrationResult(
        uint256 disputeId
    )
        external
        view
        returns (bytes32 finalOutcome, bool invalidate, bool finalized)
    {
        Arbitration storage arbitration = arbitrations[disputeId];
        return (
            arbitration.finalOutcome,
            arbitration.invalidate,
            arbitration.finalized
        );
    }

    // ==================== Query Functions ====================

    /**
     * @dev Get resolution details
     */
    function getResolution(
        uint256 marketId
    ) external view returns (Resolution memory) {
        return resolutions[marketId];
    }

    /**
     * @dev Get dispute details
     */
    function getDispute(
        uint256 disputeId
    ) external view returns (Dispute memory) {
        return disputes[disputeId];
    }

    /**
     * @dev Get arbitration details
     */
    function getArbitration(
        uint256 disputeId
    ) external view returns (Arbitration memory) {
        return arbitrations[disputeId];
    }

    /**
     * @dev Get arbitrator vote record
     */
    function getVote(
        uint256 disputeId,
        address arbitrator
    ) external view returns (Vote memory) {
        return arbitrationVotes[disputeId][arbitrator];
    }

    /**
     * @dev Get whether arbitrator has voted
     */
    function hasVoted(
        uint256 disputeId,
        address arbitrator
    ) external view returns (bool) {
        return arbitrationVotes[disputeId][arbitrator].voted;
    }

    /**
     * @dev Check if within challenge window
     */
    function isWithinChallengeWindow(
        uint256 marketId
    ) external view returns (bool) {
        Resolution storage resolution = resolutions[marketId];
        if (resolution.status != ResolutionStatus.Proposed) {
            return false;
        }
        return
            block.timestamp <=
            resolution.proposeTime + resolution.disputeWindowTime;
    }

    // ==================== Bond Token Management ====================

    /**
     * @dev Admin add reserve fund
     */
    function addReserveFund(uint256 amount) external onlyAdmin {
        bool success = bondToken.transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert BondTransferFailed();
        }
        reserveFund += amount;
    }

    /**
     * @dev Withdraw excess Bond Token from contract (admin only)
     */
    function withdrawReserveFund(uint256 amount) external onlyAdmin {
        if (reserveFund >= amount) {
            bool success = bondToken.transfer(admin, amount);
            if (!success) {
                revert BondTransferFailed();
            }
            reserveFund -= amount;
        }
    }

    function getBlockTime() external view returns (uint256) {
        return block.timestamp;
    }
}
