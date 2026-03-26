// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/IMarketFactory.sol";
import "../interfaces/IMarketCore.sol";
import "../interfaces/ILPManager.sol";
import "../interfaces/IDLMMEngine.sol";
import "../tokens/OutcomeToken.sol";
import "../libraries/Constants.sol";
import "../libraries/ProbabilityMath.sol";

/**
 * @title MarketFactory
 * @notice Factory contract for creating prediction markets with fundraising phase
 * @dev Markets flow: Fundraising -> Trading -> Resolution
 *      - Fundraising: LPs contribute USDC + set target YES ratio
 *      - Trading: Opening price = weighted average of LP ratios
 *      - Single-sided LP based on user's bias direction
 */
contract MarketFactory is IMarketFactory, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @dev Maximum bins per addLiquidity call (gas optimization)
    uint256 internal constant MAX_BINS_PER_BATCH = 25;

    /// @notice Minimum target ratio (1% = 0.01e18)
    uint64 public constant MIN_TARGET_RATIO = 0.01e18;

    /// @notice Maximum target ratio (99% = 0.99e18)
    uint64 public constant MAX_TARGET_RATIO = 0.99e18;

    /// @notice Forbidden ratio - 50% (must bias one direction)
    uint64 public constant FORBIDDEN_RATIO = 0.5e18;

    /// @notice Precision for ratio calculations
    uint256 private constant PRECISION = 1e18;

    // ============ State ============

    /// @notice MarketCore contract
    IMarketCore public override marketCore;

    /// @notice LPManager contract
    ILPManager public override lpManager;

    /// @notice DLMM Engine
    IDLMMEngine public engine;

    /// @notice Collateral token (USDC)
    IERC20 public collateral;

    /// @notice Outcome token contract
    OutcomeToken public outcomeToken;

    /// @notice Market configurations
    mapping(uint256 => MarketConfig) private _marketConfigs;

    /// @dev Deprecated: was never written to. Kept for UUPS storage layout compatibility.
    /// Original type: mapping(uint256 => mapping(address => LPContribution))
    /// LPContribution was { uint128, uint64, uint40, bool } = 1 slot
    mapping(uint256 => mapping(address => uint256)) private _deprecated_lpContributions;

    /// @dev Deprecated: was never written to. Kept for UUPS storage layout compatibility.
    mapping(uint256 => address[]) private _deprecated_lpProviders;

    /// @notice Total funds raised per market
    mapping(uint256 => uint128) private _totalFundsRaised;

    /// @notice Weighted sum of ratios per market (for opening price calculation)
    mapping(uint256 => uint256) private _weightedRatioSum;

    /// @notice Market count
    uint256 public marketCount;

    /// @notice Contribution entries per market (supports multiple per address)
    mapping(uint256 => ContributionEntry[]) private _contributionList;

    // ============ Storage Gap ============

    uint256[49] private __gap;

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _marketCore,
        address _lpManager,
        address _engine,
        address _collateral,
        address _outcomeToken
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_marketCore != address(0), "MarketFactory: ZERO_MARKET_CORE");
        require(_lpManager != address(0), "MarketFactory: ZERO_LP_MANAGER");
        require(_engine != address(0), "MarketFactory: ZERO_ENGINE");
        require(_collateral != address(0), "MarketFactory: ZERO_COLLATERAL");
        require(_outcomeToken != address(0), "MarketFactory: ZERO_OUTCOME_TOKEN");

        marketCore = IMarketCore(_marketCore);
        lpManager = ILPManager(_lpManager);
        engine = IDLMMEngine(_engine);
        collateral = IERC20(_collateral);
        outcomeToken = OutcomeToken(_outcomeToken);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Admin override for marketCount (emergency fix)
    function setMarketCount(uint256 _count) external onlyOwner {
        marketCount = _count;
    }

    // ============ Market Creation ============

    /// @inheritdoc IMarketFactory
    function createMarket(
        string calldata question,
        uint128 fundingThreshold,
        uint40 fundingDuration,
        uint40 tradingDuration
    ) external override returns (uint256 marketId) {
        require(bytes(question).length > 0, "MarketFactory: EMPTY_QUESTION");
        require(fundingThreshold > 0, "MarketFactory: ZERO_THRESHOLD");
        require(fundingDuration > 0, "MarketFactory: ZERO_FUNDING_DURATION");
        require(tradingDuration > 0, "MarketFactory: ZERO_TRADING_DURATION");

        // Reserve sequential ID from OutcomeToken via MarketCore
        // This ensures IDs are always unique and match across all contracts
        marketId = marketCore.reserveMarketId();
        marketCount = marketId + 1;

        _marketConfigs[marketId] = MarketConfig({
            question: question,
            fundingThreshold: fundingThreshold,
            fundingDeadline: uint40(block.timestamp) + fundingDuration,
            tradingEndTime: uint40(block.timestamp) + fundingDuration + tradingDuration,
            creator: msg.sender,
            phase: MarketPhase.Fundraising
        });

        emit MarketCreated(
            marketId,
            msg.sender,
            question,
            fundingThreshold,
            uint40(block.timestamp) + fundingDuration,
            uint40(block.timestamp) + fundingDuration + tradingDuration
        );
    }

    // ============ Fundraising Functions ============

    /// @inheritdoc IMarketFactory
    function contributeLiquidity(
        uint256 marketId,
        uint128 amount,
        uint64 targetYesRatio
    ) external override nonReentrant {
        MarketConfig storage config = _marketConfigs[marketId];
        require(config.phase == MarketPhase.Fundraising, "MarketFactory: NOT_FUNDRAISING");
        require(block.timestamp <= config.fundingDeadline, "MarketFactory: FUNDING_DEADLINE_PASSED");
        require(amount > 0, "MarketFactory: ZERO_AMOUNT");

        // Validate target ratio (not 0%, 50%, or 100%)
        require(targetYesRatio >= MIN_TARGET_RATIO, "MarketFactory: RATIO_TOO_LOW");
        require(targetYesRatio <= MAX_TARGET_RATIO, "MarketFactory: RATIO_TOO_HIGH");
        require(targetYesRatio != FORBIDDEN_RATIO, "MarketFactory: FORBIDDEN_50_PERCENT");

        // Check if would exceed threshold
        uint128 newTotal = _totalFundsRaised[marketId] + amount;
        if (newTotal > config.fundingThreshold) {
            // Cap at threshold
            amount = config.fundingThreshold - _totalFundsRaised[marketId];
            require(amount > 0, "MarketFactory: FUNDING_COMPLETE");
        }

        // Transfer collateral
        collateral.safeTransferFrom(msg.sender, address(this), amount);

        // Push new contribution entry (each contribution is independent)
        _contributionList[marketId].push(ContributionEntry({
            provider: msg.sender,
            amount: amount,
            targetYesRatio: targetYesRatio,
            depositTime: uint40(block.timestamp)
        }));

        // Update totals
        _totalFundsRaised[marketId] += amount;
        _weightedRatioSum[marketId] += uint256(amount) * uint256(targetYesRatio);

        emit LPContributed(marketId, msg.sender, amount, targetYesRatio);

        // Auto-trigger fundraising completion when threshold is reached
        if (_totalFundsRaised[marketId] >= config.fundingThreshold) {
            _executeFundraising(marketId);
        }
    }

    /// @inheritdoc IMarketFactory
    function completeFundraising(uint256 marketId) external override nonReentrant {
        MarketConfig storage config = _marketConfigs[marketId];
        require(config.phase == MarketPhase.Fundraising, "MarketFactory: NOT_FUNDRAISING");

        uint128 totalFunds = _totalFundsRaised[marketId];
        require(totalFunds > 0, "MarketFactory: NO_FUNDS_RAISED");

        // Only callable when deadline has passed (threshold case is auto-triggered via contributeLiquidity)
        require(block.timestamp > config.fundingDeadline, "MarketFactory: CANNOT_COMPLETE_YET");

        _executeFundraising(marketId);
    }

    /**
     * @dev Execute the fundraising-to-trading transition
     * @param marketId Market ID to transition
     */
    function _executeFundraising(uint256 marketId) internal {
        MarketConfig storage config = _marketConfigs[marketId];
        uint128 totalFunds = _totalFundsRaised[marketId];

        // Calculate opening price (weighted average of LP ratios)
        uint256 weightedAvgRatio = _weightedRatioSum[marketId] / uint256(totalFunds);

        // Convert ratio to bin ID
        int24 initialActiveId = _ratioToBinId(weightedAvgRatio);

        // Activate pre-reserved market in MarketCore (ID was reserved during createMarket)
        marketCore.activateMarket(marketId, config.question, initialActiveId);

        // Approve collateral for MarketCore
        collateral.approve(address(marketCore), totalFunds);

        // Mint outcome tokens (totalFunds USDC -> totalFunds YES + totalFunds NO)
        marketCore.mintOutcomes(marketId, totalFunds, address(this));

        // Initialize LP state in LPManager
        uint40 tradingStartTime = uint40(block.timestamp);
        lpManager.initializeMarketLPState(
            marketId,
            tradingStartTime,
            config.tradingEndTime,
            totalFunds
        );

        // Approve outcome tokens for MarketCore
        outcomeToken.setApprovalForAll(address(marketCore), true);
        // Also approve LPManager to receive tokens
        outcomeToken.setApprovalForAll(address(lpManager), true);

        // Calculate active slot from weighted average ratio
        uint256 activeSlot = (weightedAvgRatio * 100) / PRECISION;
        if (activeSlot == 0) activeSlot = 1;
        if (activeSlot >= 100) activeSlot = 98;
        activeSlot -= 1; // Convert from 1-99 to 0-98

        // Create LP positions using aggregated liquidity (2 addLiquidity calls instead of N)
        _createAggregatedLPPositions(marketId, activeSlot);

        // Update market phase
        config.phase = MarketPhase.Trading;

        emit FundraisingCompleted(
            marketId,
            totalFunds,
            initialActiveId,
            engine.getPriceFromId(initialActiveId)
        );
        emit TradingStarted(marketId, tradingStartTime);
    }

    // ============ View Functions ============

    /// @inheritdoc IMarketFactory
    function getMarketConfig(uint256 marketId) external view override returns (MarketConfig memory) {
        return _marketConfigs[marketId];
    }

    /// @inheritdoc IMarketFactory
    function getProviderContributions(uint256 marketId, address provider) external view override returns (ContributionEntry[] memory) {
        ContributionEntry[] storage entries = _contributionList[marketId];
        // Count matches
        uint256 count = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].provider == provider) count++;
        }
        // Fill result
        ContributionEntry[] memory result = new ContributionEntry[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].provider == provider) {
                result[idx++] = entries[i];
            }
        }
        return result;
    }

    /// @inheritdoc IMarketFactory
    function getTotalFundsRaised(uint256 marketId) external view override returns (uint128) {
        return _totalFundsRaised[marketId];
    }

    /// @inheritdoc IMarketFactory
    function getOpeningPrice(uint256 marketId) external view override returns (uint256 yesPrice, int24 activeId) {
        uint128 totalFunds = _totalFundsRaised[marketId];
        if (totalFunds == 0) {
            return (0, 0);
        }

        uint256 weightedAvgRatio = _weightedRatioSum[marketId] / uint256(totalFunds);
        activeId = _ratioToBinId(weightedAvgRatio);
        yesPrice = engine.getPriceFromId(activeId);
    }

    /// @inheritdoc IMarketFactory
    function getLPProviders(uint256 marketId) external view override returns (address[] memory) {
        ContributionEntry[] storage entries = _contributionList[marketId];
        // Count unique providers
        uint256 count = 0;
        address[] memory temp = new address[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == entries[i].provider) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[count] = entries[i].provider;
                count++;
            }
        }
        // Trim to actual size
        address[] memory providers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            providers[i] = temp[i];
        }
        return providers;
    }

    /// @inheritdoc IMarketFactory
    function getContributions(uint256 marketId) external view override returns (ContributionEntry[] memory) {
        return _contributionList[marketId];
    }

    /// @inheritdoc IMarketFactory
    function getContributionCount(uint256 marketId) external view override returns (uint256) {
        return _contributionList[marketId].length;
    }

    // ============ Internal Functions ============

    /**
     * @dev Convert YES ratio to bin ID
     * @param ratio YES probability in 1e18 precision
     * @return binId Corresponding bin ID
     */
    function _ratioToBinId(uint256 ratio) internal view returns (int24 binId) {
        // Ratio is YES probability (0.01e18 to 0.99e18)
        // Need to find bin where probability matches
        // P_yes = R / (1 + R) where R = (1.001)^binId
        // R = P_yes / (1 - P_yes)
        // binId = log_1.001(R)

        // Find the slot (0-98) that corresponds to this probability
        // slot 0 = 1%, slot 49 = 50%, slot 98 = 99%
        uint256 slot = (ratio * 99) / PRECISION;
        if (slot == 0) slot = 1; // Minimum 1%
        if (slot > 98) slot = 98; // Maximum 99%

        // Adjust slot based on actual probability percentage
        // ratio of 0.60e18 should give slot around 59-60
        slot = (ratio * 100) / PRECISION;
        if (slot == 0) slot = 1;
        if (slot >= 100) slot = 98;
        slot -= 1; // Convert from 1-99 to 0-98

        binId = engine.getBinIdForSlot(slot);
    }

    // ============ Aggregated LP Functions ============

    function _createAggregatedLPPositions(
        uint256 marketId,
        uint256 activeSlot
    ) internal {
        ContributionEntry[] storage contributions = _contributionList[marketId];

        // Aggregate YES-biased and NO-biased contributions separately
        uint128 totalYesBiasedAmount = 0; // Total USDC from YES-biased LPs (will add NO to LP)
        uint128 totalNoBiasedAmount = 0;  // Total USDC from NO-biased LPs (will add YES to LP)

        // First pass: calculate totals for each direction
        for (uint256 i = 0; i < contributions.length; i++) {
            if (contributions[i].targetYesRatio > FORBIDDEN_RATIO) {
                totalYesBiasedAmount += contributions[i].amount;
            } else {
                totalNoBiasedAmount += contributions[i].amount;
            }
        }

        // Initialize arrays (empty by default)
        uint256[] memory yesBiasedShares = new uint256[](0);
        int24[] memory yesBiasedBinIds = new int24[](0);
        uint256[] memory noBiasedShares = new uint256[](0);
        int24[] memory noBiasedBinIds = new int24[](0);

        // Add aggregated liquidity for YES-biased LPs (NO tokens to bins 0 ~ activeSlot)
        // Note: Single-sided liquidity CAN be added to the active bin (same as Meteora DLMM)
        if (totalYesBiasedAmount > 0) {
            (yesBiasedBinIds, yesBiasedShares) = _addAggregatedLiquidity(
                marketId,
                0,                    // startSlot
                activeSlot,           // endSlot (inclusive of opening price)
                0,                    // yesAmount (single-sided NO)
                totalYesBiasedAmount  // noAmount
            );
        }

        // Add aggregated liquidity for NO-biased LPs (YES tokens to bins activeSlot ~ 98)
        // Note: Single-sided liquidity CAN be added to the active bin (same as Meteora DLMM)
        if (totalNoBiasedAmount > 0) {
            (noBiasedBinIds, noBiasedShares) = _addAggregatedLiquidity(
                marketId,
                activeSlot,           // startSlot (inclusive of opening price)
                98,                   // endSlot (max slot)
                totalNoBiasedAmount,  // yesAmount
                0                     // noAmount (single-sided YES)
            );
        }

        // Initialize aggregated pool info in LPManager
        uint128 yesBiasedTotalShares = 0;
        for (uint256 i = 0; i < yesBiasedShares.length; i++) {
            yesBiasedTotalShares += uint128(yesBiasedShares[i]);
        }
        uint128 noBiasedTotalShares = 0;
        for (uint256 i = 0; i < noBiasedShares.length; i++) {
            noBiasedTotalShares += uint128(noBiasedShares[i]);
        }

        // Extract per-pool shares at the overlap bin (activeSlot)
        // YES-biased pool's last bin is activeSlot, NO-biased pool's first bin is activeSlot
        uint256 yesBiasedOverlapShares = yesBiasedShares.length > 0
            ? yesBiasedShares[yesBiasedShares.length - 1]
            : 0;
        uint256 noBiasedOverlapShares = noBiasedShares.length > 0
            ? noBiasedShares[0]
            : 0;

        lpManager.initializeAggregatedPools(
            marketId,
            0,                    // yesBiasedStartSlot
            uint8(activeSlot),    // yesBiasedEndSlot (now includes activeSlot)
            yesBiasedTotalShares,
            uint8(activeSlot),    // noBiasedStartSlot (now includes activeSlot)
            98,                   // noBiasedEndSlot
            noBiasedTotalShares,
            yesBiasedOverlapShares,
            noBiasedOverlapShares
        );

        // Second pass: create virtual LP positions for each contribution
        for (uint256 i = 0; i < contributions.length; i++) {
            _createVirtualLPPosition(
                marketId,
                contributions[i].provider,
                contributions[i].amount,
                contributions[i].targetYesRatio,
                totalYesBiasedAmount,
                totalNoBiasedAmount
            );
        }
    }

    /**
     * @dev Add aggregated liquidity across a range of slots using batched calls
     * @param marketId Market ID
     * @param startSlot Starting slot (inclusive)
     * @param endSlot Ending slot (inclusive)
     * @param yesAmount Total YES tokens to distribute
     * @param noAmount Total NO tokens to distribute
     * @return binIds Array of bin IDs
     * @return shares Array of shares received
     */
    function _addAggregatedLiquidity(
        uint256 marketId,
        uint256 startSlot,
        uint256 endSlot,
        uint128 yesAmount,
        uint128 noAmount
    ) internal returns (int24[] memory binIds, uint256[] memory shares) {
        require(endSlot >= startSlot, "MarketFactory: INVALID_SLOT_RANGE");
        require(endSlot <= 98, "MarketFactory: SLOT_OUT_OF_RANGE");

        uint256 totalBins = endSlot - startSlot + 1;

        // Allocate full arrays for results
        binIds = new int24[](totalBins);
        shares = new uint256[](totalBins);

        // Distribute tokens evenly across all bins
        uint128 yesPerBin = yesAmount > 0 ? yesAmount / uint128(totalBins) : 0;
        uint128 noPerBin = noAmount > 0 ? noAmount / uint128(totalBins) : 0;

        // Handle remainder for even distribution
        uint128 yesRemainder = yesAmount > 0 ? yesAmount % uint128(totalBins) : 0;
        uint128 noRemainder = noAmount > 0 ? noAmount % uint128(totalBins) : 0;

        // Pre-populate binIds and calculate amounts
        uint128[] memory allYesAmounts = new uint128[](totalBins);
        uint128[] memory allNoAmounts = new uint128[](totalBins);

        for (uint256 i = 0; i < totalBins; i++) {
            uint256 slot = startSlot + i;
            binIds[i] = ProbabilityMath.getBinIdForSlot(slot);
            allYesAmounts[i] = yesPerBin + (i < yesRemainder ? 1 : 0);
            allNoAmounts[i] = noPerBin + (i < noRemainder ? 1 : 0);
        }

        // Process in batches to avoid gas limits
        uint256 processedBins = 0;
        while (processedBins < totalBins) {
            uint256 batchSize = totalBins - processedBins;
            if (batchSize > MAX_BINS_PER_BATCH) {
                batchSize = MAX_BINS_PER_BATCH;
            }

            // Create batch arrays
            int24[] memory batchBinIds = new int24[](batchSize);
            uint128[] memory batchYesAmounts = new uint128[](batchSize);
            uint128[] memory batchNoAmounts = new uint128[](batchSize);

            for (uint256 i = 0; i < batchSize; i++) {
                batchBinIds[i] = binIds[processedBins + i];
                batchYesAmounts[i] = allYesAmounts[processedBins + i];
                batchNoAmounts[i] = allNoAmounts[processedBins + i];
            }

            // Execute batch addLiquidity
            uint256[] memory batchShares = marketCore.addLiquidity(
                marketId,
                batchBinIds,
                batchYesAmounts,
                batchNoAmounts,
                address(lpManager)
            );

            // Copy batch results to full shares array
            for (uint256 i = 0; i < batchSize; i++) {
                shares[processedBins + i] = batchShares[i];
            }

            processedBins += batchSize;
        }
    }

    /**
     * @dev Create virtual LP position for a single provider based on their proportional share
     * @param marketId Market ID
     * @param provider LP provider address
     * @param amount Provider's contribution amount
     * @param targetRatio Provider's target YES ratio
     * @param totalYesBiased Total amount from all YES-biased LPs
     * @param totalNoBiased Total amount from all NO-biased LPs
     */
    function _createVirtualLPPosition(
        uint256 marketId,
        address provider,
        uint128 amount,
        uint64 targetRatio,
        uint128 totalYesBiased,
        uint128 totalNoBiased
    ) internal {
        uint128 yesToLP;
        uint128 noToLP;
        uint128 yesToHold;
        uint128 noToHold;
        uint256 poolShareRatio;

        if (targetRatio > FORBIDDEN_RATIO) {
            // YES-biased: holds YES, added NO to LP
            yesToLP = 0;
            noToLP = amount;
            yesToHold = amount;
            noToHold = 0;
            poolShareRatio = totalYesBiased > 0 ? (uint256(amount) * 1e18) / uint256(totalYesBiased) : 0;

            // Transfer held YES tokens to LPManager
            if (yesToHold > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    address(lpManager),
                    outcomeToken.getYesTokenId(marketId),
                    yesToHold,
                    ""
                );
            }
        } else {
            // NO-biased: holds NO, added YES to LP
            yesToLP = amount;
            noToLP = 0;
            yesToHold = 0;
            noToHold = amount;
            poolShareRatio = totalNoBiased > 0 ? (uint256(amount) * 1e18) / uint256(totalNoBiased) : 0;

            // Transfer held NO tokens to LPManager
            if (noToHold > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    address(lpManager),
                    outcomeToken.getNoTokenId(marketId),
                    noToHold,
                    ""
                );
            }
        }

        // Create aggregated LP position with pool share ratio
        lpManager.createAggregatedPosition(
            marketId,
            provider,
            yesToLP,
            noToLP,
            yesToHold,
            noToHold,
            targetRatio,
            poolShareRatio
        );
    }
}
