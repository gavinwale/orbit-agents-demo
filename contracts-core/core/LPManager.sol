// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/ILPManager.sol";
import "../interfaces/ISwapHook.sol";
import "../interfaces/ILPFeeCollector.sol";
import "../interfaces/IMarketCore.sol";
import "../interfaces/IMarketViewer.sol";
import "../interfaces/IDLMMEngine.sol";
import "../tokens/OutcomeToken.sol";
import "../tokens/LPPositionNFT.sol";
import "../libraries/Constants.sol";
import "../libraries/ProbabilityMath.sol";
import "../libraries/LPMathLib.sol";

/**
 * @title LPManager
 * @notice Manages LP positions as NFTs with time-based liquidity decay and rebalancing
 * @dev Each LP position is an NFT with its own bins and shares
 *      Implements pm-amm style decay: L(t) = L0 * sqrt((T-t)/T)
 */
contract LPManager is ILPManager, ISwapHook, ILPFeeCollector, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Minimum withdrawal interval (1 hour)
    uint40 public constant override MIN_WITHDRAWAL_INTERVAL = 1 hours;

    /// @notice Minimum liquidity ratio at expiry (10% = 0.1e18)
    uint64 public constant override MIN_LIQUIDITY_RATIO = 0;

    /// @notice Precision for calculations
    uint256 private constant PRECISION = 1e18;

    // ============ Core References ============

    /// @notice MarketCore contract
    IMarketCore public marketCore;

    /// @notice DLMM Engine
    IDLMMEngine public engine;

    /// @notice MarketViewer contract (for price manipulation checks)
    IMarketViewer public marketViewer;

    /// @notice Collateral token (USDC)
    IERC20 public collateral;

    /// @notice Outcome token contract
    OutcomeToken public outcomeToken;

    /// @notice LP Position NFT contract
    LPPositionNFT public override positionNFT;

    /// @notice MarketFactory address (authorized to create positions)
    address public factory;

    /// @notice Authorized callers for afterSwap (e.g., SwapHookRouter)
    mapping(address => bool) public authorizedCallers;

    // ============ State ============

    /// @notice Market LP state: marketId => state
    mapping(uint256 => MarketLPState) private _marketLPStates;

    /// @notice Last decay factor calculated per market
    mapping(uint256 => uint256) private _lastDecayFactor;

    /// @notice Position token IDs per market: marketId => tokenId[]
    mapping(uint256 => uint256[]) private _marketPositions;

    /// @notice Aggregated pool info for Stage1 LP positions
    struct AggregatedPoolInfo {
        uint8 startSlot;        // Start slot (inclusive)
        uint8 endSlot;          // End slot (inclusive)
        uint128 totalShares;    // Total shares in this pool (sum of all bin shares)
        bool exists;            // Whether this pool exists
    }

    /// @notice YES-biased aggregated pool per market (liquidity in slots 0 ~ activeSlot-1)
    mapping(uint256 => AggregatedPoolInfo) public yesBiasedPools;

    /// @notice NO-biased aggregated pool per market (liquidity in slots activeSlot+1 ~ 98)
    mapping(uint256 => AggregatedPoolInfo) public noBiasedPools;

    /// @notice Token ID to pool share ratio (how much of the aggregated pool this position owns)
    /// @dev 1e18 = 100% of the pool
    mapping(uint256 => uint256) public positionPoolShareRatio;

    /// @notice Shares in the overlap bin (activeSlot) belonging to YES-biased pool
    /// @dev When both pools include activeSlot, getUserBinShares returns combined shares.
    ///      We store per-pool shares separately to correctly split removal amounts.
    mapping(uint256 => uint256) private _yesBiasedOverlapShares;

    /// @notice Shares in the overlap bin (activeSlot) belonging to NO-biased pool
    mapping(uint256 => uint256) private _noBiasedOverlapShares;

    /// @notice Flag indicating we're inside the afterSwap hook callback
    bool private _inHookContext;

    /// @notice Flag indicating we're executing a rebalance swap
    /// @dev When true, afterSwap hook should skip LPManager logic to prevent recursion
    bool private _inRebalanceContext;

    /// @notice Cached bin IDs for each slot (0-98), precomputed to avoid expensive math
    int24[99] private _slotBinIds;

    // ============ TWAP Configuration ============

    /// @notice TWAP long window for manipulation detection (default: 1 hour)
    uint256 public twapLongWindow;

    /// @notice TWAP short window for manipulation detection (default: 10 minutes)
    uint256 public twapShortWindow;

    /// @notice Maximum price deviation allowed before rebalance is blocked (default: 3% = 0.03e18)
    /// @dev Should be slightly higher than swap fee to make manipulation unprofitable
    uint256 public maxPriceDeviation;

    // ============ Storage Gap ============

    uint256[50] private __gap;

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _marketCore,
        address _engine,
        address _collateral,
        address _outcomeToken,
        address _positionNFT,
        address _factory
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_marketCore != address(0), "LP:0");
        require(_engine != address(0), "LP:0");
        require(_collateral != address(0), "LP:0");
        require(_outcomeToken != address(0), "LP:0");
        require(_positionNFT != address(0), "LP:0");

        marketCore = IMarketCore(_marketCore);
        engine = IDLMMEngine(_engine);
        collateral = IERC20(_collateral);
        outcomeToken = OutcomeToken(_outcomeToken);
        positionNFT = LPPositionNFT(_positionNFT);
        factory = _factory;

        // Initialize TWAP parameters with defaults
        twapLongWindow = 1 hours;
        twapShortWindow = 10 minutes;
        maxPriceDeviation = 0.03e18; // 3%

        // Precompute and cache all 99 slot → binId mappings
        for (uint256 slot = 0; slot < Constants.TOTAL_PREDICTION_BINS; slot++) {
            _slotBinIds[slot] = ProbabilityMath.getBinIdForSlot(slot);
        }
    }

    /// @notice Reinitialize slot data after probability formula fix (P_yes = R/(1+R))
    function reinitializeV2() external reinitializer(2) {
        for (uint256 slot = 0; slot < Constants.TOTAL_PREDICTION_BINS; slot++) {
            _slotBinIds[slot] = ProbabilityMath.getBinIdForSlot(slot);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============ Modifiers ============

    modifier onlyFactory() {
        require(msg.sender == factory, "LP:FACTORY");
        _;
    }

    // ============ Admin Functions ============

    /// @notice Set factory address (can only be set once if initially zero)
    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "LP:0");
        require(factory == address(0) || factory == _factory, "LP:SET");
        factory = _factory;
    }

    /// @notice Set market viewer address
    function setMarketViewer(address _viewer) external onlyOwner {
        marketViewer = IMarketViewer(_viewer);
    }

    /// @notice Set authorized caller for afterSwap (e.g., SwapHookRouter)
    /// @param caller Address to authorize/deauthorize
    /// @param authorized Whether the address is authorized
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }

    /// @notice Set TWAP parameters for manipulation detection
    function setTwapParams(uint256 _longWindow, uint256 _shortWindow, uint256 _maxDeviation) external onlyOwner {
        require(_shortWindow > 0 && _shortWindow < _longWindow && _longWindow <= 24 hours, "LP:TWAP");
        require(_maxDeviation >= 0.01e18 && _maxDeviation <= 0.2e18, "LP:DEV");
        emit TwapLongWindowUpdated(twapLongWindow, _longWindow);
        emit TwapShortWindowUpdated(twapShortWindow, _shortWindow);
        emit MaxPriceDeviationUpdated(maxPriceDeviation, _maxDeviation);
        twapLongWindow = _longWindow;
        twapShortWindow = _shortWindow;
        maxPriceDeviation = _maxDeviation;
    }

    // ============ Position Management ============

    /// @inheritdoc ILPManager
    function createPosition(
        uint256 marketId,
        address provider,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld,
        uint64 targetYesRatio,
        int24[] calldata binIds,
        uint256[] calldata shares
    ) external override onlyFactory returns (uint256 tokenId) {
        // Mint NFT position
        tokenId = positionNFT.mint(
            provider,
            marketId,
            yesInLP,
            noInLP,
            yesHeld,
            noHeld,
            targetYesRatio,
            binIds,
            shares
        );

        // Track position for this market
        _marketPositions[marketId].push(tokenId);

        emit LPPositionCreated(tokenId, marketId, provider, yesInLP, noInLP, targetYesRatio);
    }

    /// @notice Create an aggregated LP position (no bin data stored, uses pool share ratio)
    /// @param marketId Market ID
    /// @param provider LP provider address
    /// @param yesInLP YES tokens in LP
    /// @param noInLP NO tokens in LP
    /// @param yesHeld YES tokens held
    /// @param noHeld NO tokens held
    /// @param targetYesRatio Target YES ratio
    /// @param poolShareRatio Share of the aggregated pool (1e18 = 100%)
    /// @return tokenId The minted position NFT token ID
    function createAggregatedPosition(
        uint256 marketId,
        address provider,
        uint128 yesInLP,
        uint128 noInLP,
        uint128 yesHeld,
        uint128 noHeld,
        uint64 targetYesRatio,
        uint256 poolShareRatio
    ) external onlyFactory returns (uint256 tokenId) {
        // Mint NFT position with empty bin data
        int24[] memory emptyBinIds = new int24[](0);
        uint256[] memory emptyShares = new uint256[](0);

        tokenId = positionNFT.mint(
            provider,
            marketId,
            yesInLP,
            noInLP,
            yesHeld,
            noHeld,
            targetYesRatio,
            emptyBinIds,
            emptyShares
        );

        // Set pool share ratio for aggregated position
        positionPoolShareRatio[tokenId] = poolShareRatio;

        // Track position for this market
        _marketPositions[marketId].push(tokenId);

        emit LPPositionCreated(tokenId, marketId, provider, yesInLP, noInLP, targetYesRatio);
    }

    /// @inheritdoc ILPManager
    function initializeMarketLPState(
        uint256 marketId,
        uint40 tradingStartTime,
        uint40 tradingEndTime,
        uint128 totalLiquidity
    ) external override onlyFactory {
        require(_marketLPStates[marketId].totalInitialLiquidity == 0, "LP:INIT");

        _marketLPStates[marketId] = MarketLPState({
            totalInitialLiquidity: totalLiquidity,
            tradingStartTime: tradingStartTime,
            tradingEndTime: tradingEndTime,
            lastGlobalWithdrawTime: tradingStartTime,
            accumulatedFees: 0
        });

        _lastDecayFactor[marketId] = PRECISION; // Start at 100%
    }

    /// @notice Initialize aggregated pool info for a market
    /// @dev Called by MarketFactory after completeFundraising to set up pool ranges
    /// @param marketId Market ID
    /// @param yesBiasedStartSlot Start slot for YES-biased pool (0 if no YES-biased LPs)
    /// @param yesBiasedEndSlot End slot for YES-biased pool
    /// @param yesBiasedTotalShares Total shares in YES-biased pool
    /// @param noBiasedStartSlot Start slot for NO-biased pool
    /// @param noBiasedEndSlot End slot for NO-biased pool (98 if no NO-biased LPs)
    /// @param noBiasedTotalShares Total shares in NO-biased pool
    /// @param yesBiasedOverlapSharesInit YES-biased pool's shares at the overlap bin (activeSlot)
    /// @param noBiasedOverlapSharesInit NO-biased pool's shares at the overlap bin (activeSlot)
    function initializeAggregatedPools(
        uint256 marketId,
        uint8 yesBiasedStartSlot,
        uint8 yesBiasedEndSlot,
        uint128 yesBiasedTotalShares,
        uint8 noBiasedStartSlot,
        uint8 noBiasedEndSlot,
        uint128 noBiasedTotalShares,
        uint256 yesBiasedOverlapSharesInit,
        uint256 noBiasedOverlapSharesInit
    ) external onlyFactory {
        if (yesBiasedTotalShares > 0) {
            yesBiasedPools[marketId] = AggregatedPoolInfo({
                startSlot: yesBiasedStartSlot,
                endSlot: yesBiasedEndSlot,
                totalShares: yesBiasedTotalShares,
                exists: true
            });
        }

        if (noBiasedTotalShares > 0) {
            noBiasedPools[marketId] = AggregatedPoolInfo({
                startSlot: noBiasedStartSlot,
                endSlot: noBiasedEndSlot,
                totalShares: noBiasedTotalShares,
                exists: true
            });
        }

        // Store per-pool shares at the overlap bin (where both pools meet at activeSlot)
        _yesBiasedOverlapShares[marketId] = yesBiasedOverlapSharesInit;
        _noBiasedOverlapShares[marketId] = noBiasedOverlapSharesInit;
    }

    // ============ Time Decay Functions ============

    /// @inheritdoc ILPManager
    function getDecayFactor(uint256 marketId) public view override returns (uint256 decayFactor) {
        MarketLPState memory state = _marketLPStates[marketId];

        if (state.totalInitialLiquidity == 0) {
            return PRECISION;
        }

        uint256 currentTime = block.timestamp;

        // Before trading starts
        if (currentTime <= state.tradingStartTime) {
            return PRECISION;
        }

        // After trading ends
        if (currentTime >= state.tradingEndTime) {
            return MIN_LIQUIDITY_RATIO;
        }

        // Calculate decay: L(t) = L0 * sqrt((T-t)/T)
        uint256 totalDuration = state.tradingEndTime - state.tradingStartTime;
        uint256 timeRemaining = state.tradingEndTime - currentTime;

        // timeRatio = (T - t) / T
        uint256 timeRatio = (timeRemaining * PRECISION) / totalDuration;

        // decayFactor = sqrt(timeRatio) = timeRatio^0.5
        decayFactor = LPMathLib.sqrt(timeRatio * PRECISION);

        // Ensure minimum
        if (decayFactor < MIN_LIQUIDITY_RATIO) {
            decayFactor = MIN_LIQUIDITY_RATIO;
        }
    }

    // ============ LP Withdrawal ============

    /// @inheritdoc ILPManager
    function canTriggerWithdrawal(uint256 marketId) public view override returns (bool canTrigger) {
        MarketLPState memory state = _marketLPStates[marketId];
        return block.timestamp >= state.lastGlobalWithdrawTime + MIN_WITHDRAWAL_INTERVAL;
    }


    /// @inheritdoc ILPManager
    function triggerPositionWithdrawal(uint256 tokenId) external override nonReentrant returns (uint128 yesWithdrawn, uint128 noWithdrawn) {
        LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        uint256 marketId = pos.marketId;

        require(canTriggerWithdrawal(marketId), "LP:SOON");

        MarketLPState storage state = _marketLPStates[marketId];

        uint256 currentDecay = getDecayFactor(marketId);
        uint256 lastDecay = _lastDecayFactor[marketId];

        if (currentDecay >= lastDecay) {
            return (0, 0);
        }

        // Calculate removal ratio
        uint256 removalRatio = ((lastDecay - currentDecay) * PRECISION) / lastDecay;

        // Update global state
        state.lastGlobalWithdrawTime = uint40(block.timestamp);
        _lastDecayFactor[marketId] = currentDecay;

        // Use the unified withdrawal logic
        (yesWithdrawn, noWithdrawn) = _withdrawFromPosition(tokenId, removalRatio);

        emit LPWithdrawalTriggered(marketId, uint40(block.timestamp), currentDecay);
    }

    // ============ Swap Hook ============

    /// @inheritdoc ISwapHook
    /// @dev Called by SwapHookRouter after every swap that changes the active bin.
    ///      Performs decay-based withdrawal and collective rebalance when conditions are met.
    ///      Uses _inRebalanceContext to prevent recursion when rebalance swaps trigger this hook again.
    function afterSwap(
        uint256 marketId,
        int24 /* oldActiveId */,
        int24 /* newActiveId */
    ) external override returns (bool success) {
        // Prevent recursion: rebalance swaps also trigger afterSwap via SwapHookRouter
        if (_inRebalanceContext) {
            return true;
        }

        // Access control: only authorized callers (e.g., SwapHookRouter)
        require(authorizedCallers[msg.sender], "LP:AUTH");

        // Check if minimum withdrawal interval has passed; skip silently if not
        if (!canTriggerWithdrawal(marketId)) {
            return true;
        }

        // Skip if price manipulation detected (don't revert — other hooks should still run)
        if (_isPriceManipulated(marketId)) {
            return true;
        }

        uint256[] memory positions = _marketPositions[marketId];
        if (positions.length == 0) {
            return true;
        }

        MarketLPState storage state = _marketLPStates[marketId];
        uint256 currentDecay = getDecayFactor(marketId);
        uint256 lastDecay = _lastDecayFactor[marketId];

        // Update global state
        state.lastGlobalWithdrawTime = uint40(block.timestamp);
        _lastDecayFactor[marketId] = currentDecay;

        // Set hook context so internal calls route to *FromHook variants
        _inHookContext = true;

        // Withdraw if decay has decreased
        if (currentDecay < lastDecay) {
            uint256 removalRatio = ((lastDecay - currentDecay) * PRECISION) / lastDecay;

            // Pool-level withdrawal for aggregated positions
            _withdrawFromAggregatedPools(marketId, removalRatio, positions);

            // Per-position withdrawal for traditional (non-aggregated) positions
            for (uint256 i = 0; i < positions.length; i++) {
                if (positionPoolShareRatio[positions[i]] > 0) continue;
                _withdrawFromPosition(positions[i], removalRatio);
            }
        }

        // Collective rebalance (internal matching + external swap)
        _executeCollectiveRebalance(marketId, positions);

        _inHookContext = false;

        emit LPWithdrawalTriggered(marketId, uint40(block.timestamp), currentDecay);
        return true;
    }


    // ============ Rebalancing ============

    /// @inheritdoc ILPManager
    function calculateRebalance(
        uint256 tokenId
    ) public view override returns (bool needsSwap, bool swapYesToNo, uint128 swapAmount) {
        LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        return LPMathLib.calculateRebalance(
            pos.currentYesInLP, pos.currentNoInLP,
            pos.currentYesHeld, pos.currentNoHeld,
            pos.targetYesRatio, pos.settled
        );
    }

    /// @inheritdoc ILPManager
    function executeRebalance(uint256 tokenId) external override nonReentrant returns (uint128 amountSwapped) {
        LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        require(!pos.settled, "LP:SETTLED");

        (bool needsSwap, bool swapYesToNo, uint128 swapAmount) = calculateRebalance(tokenId);

        if (!needsSwap || swapAmount == 0) {
            return 0;
        }

        // Approve MarketCore
        outcomeToken.setApprovalForAll(address(marketCore), true);

        // Set rebalance context to prevent afterSwap recursion
        _inRebalanceContext = true;

        uint128 received;
        if (swapYesToNo) {
            // Swap YES for NO
            received = marketCore.swap(pos.marketId, swapAmount, true, address(this));

            // Update position: decrease YES held, increase NO held
            positionNFT.updateHeldBalances(
                tokenId,
                pos.currentYesHeld - swapAmount,
                pos.currentNoHeld + received
            );

            emit RebalanceExecuted(tokenId, -int128(swapAmount), int128(received));
        } else {
            // Swap NO for YES
            received = marketCore.swap(pos.marketId, swapAmount, false, address(this));

            // Update position: decrease NO held, increase YES held
            positionNFT.updateHeldBalances(
                tokenId,
                pos.currentYesHeld + received,
                pos.currentNoHeld - swapAmount
            );

            emit RebalanceExecuted(tokenId, int128(received), -int128(swapAmount));
        }

        _inRebalanceContext = false;
        amountSwapped = swapAmount;
    }

    // ============ Collective Withdrawal and Rebalance ============

    /// @inheritdoc ILPManager
    function triggerMarketWithdrawalAndRebalance(uint256 marketId)
        external
        override
        nonReentrant
        returns (uint128 totalWithdrawnYes, uint128 totalWithdrawnNo, uint128 netSwapAmount)
    {
        require(authorizedCallers[msg.sender], "LP:AUTH");
        require(canTriggerWithdrawal(marketId), "LP:SOON");

        // Check for price manipulation before executing rebalance
        // This prevents sandwich attacks on LP rebalancing
        require(!_isPriceManipulated(marketId), "LP:MANIP");

        MarketLPState storage state = _marketLPStates[marketId];
        uint256[] memory positions = _marketPositions[marketId];

        if (positions.length == 0) {
            return (0, 0, 0);
        }

        uint256 currentDecay = getDecayFactor(marketId);
        uint256 lastDecay = _lastDecayFactor[marketId];

        // Update global state
        state.lastGlobalWithdrawTime = uint40(block.timestamp);
        _lastDecayFactor[marketId] = currentDecay;

        // Only withdraw if decay has decreased
        if (currentDecay < lastDecay) {
            uint256 removalRatio = ((lastDecay - currentDecay) * PRECISION) / lastDecay;

            // Step 1a: Pool-level withdrawal for aggregated positions
            // All aggregated positions in the same pool share the same bins,
            // so we do ONE removeLiquidity per pool and distribute proportionally.
            (uint128 poolYes, uint128 poolNo) = _withdrawFromAggregatedPools(marketId, removalRatio, positions);
            totalWithdrawnYes += poolYes;
            totalWithdrawnNo += poolNo;

            // Step 1b: Per-position withdrawal for traditional (non-aggregated) positions only
            for (uint256 i = 0; i < positions.length; i++) {
                if (positionPoolShareRatio[positions[i]] > 0) continue; // Already handled by pool withdrawal
                (uint128 yesWithdrawn, uint128 noWithdrawn) = _withdrawFromPosition(positions[i], removalRatio);
                totalWithdrawnYes += yesWithdrawn;
                totalWithdrawnNo += noWithdrawn;
            }
        }

        // Steps 2-4: Collective rebalance (internal matching + external swap)
        netSwapAmount = _executeCollectiveRebalance(marketId, positions);

        emit LPWithdrawalTriggered(marketId, uint40(block.timestamp), currentDecay);
    }

    /// @notice Execute collective rebalance: internal matching + external swap
    /// @dev Extracted from triggerMarketWithdrawalAndRebalance to avoid stack-too-deep
    function _executeCollectiveRebalance(
        uint256 marketId,
        uint256[] memory positions
    ) internal returns (uint128 netSwapAmount) {
        // Step 2: Collect rebalance needs from all positions
        uint128 totalYesToSell = 0;
        uint128 totalNoToSell = 0;
        uint128[] memory yesToSell = new uint128[](positions.length);
        uint128[] memory noToSell = new uint128[](positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            (bool needsSwap, bool swapYesToNo, uint128 swapAmount) = calculateRebalance(positions[i]);

            if (needsSwap && swapAmount > 0) {
                if (swapYesToNo) {
                    yesToSell[i] = swapAmount;
                    totalYesToSell += swapAmount;
                } else {
                    noToSell[i] = swapAmount;
                    totalNoToSell += swapAmount;
                }
            }
        }

        // Step 3: Internal exchange at current market price
        uint256 currentPrice = engine.getPriceFromId(marketCore.activeIds(marketId));

        uint256 yesSellerWantNo = (uint256(totalYesToSell) * currentPrice) / PRECISION;
        uint256 noSellerOfferNo = uint256(totalNoToSell);
        uint256 internalMatchNo = yesSellerWantNo < noSellerOfferNo ? yesSellerWantNo : noSellerOfferNo;

        if (internalMatchNo > 0 && totalYesToSell > 0 && totalNoToSell > 0) {
            uint256 internalMatchYes = (internalMatchNo * PRECISION) / currentPrice;

            _executeInternalExchange(
                positions,
                yesToSell,
                noToSell,
                totalYesToSell,
                totalNoToSell,
                uint128(internalMatchYes),
                uint128(internalMatchNo)
            );

            if (yesSellerWantNo <= noSellerOfferNo) {
                for (uint256 i = 0; i < positions.length; i++) {
                    yesToSell[i] = 0;
                }
                uint256 remainingRatio = ((noSellerOfferNo - internalMatchNo) * PRECISION) / noSellerOfferNo;
                for (uint256 i = 0; i < positions.length; i++) {
                    noToSell[i] = uint128((uint256(noToSell[i]) * remainingRatio) / PRECISION);
                }
                totalYesToSell = 0;
                totalNoToSell = uint128(noSellerOfferNo - internalMatchNo);
            } else {
                for (uint256 i = 0; i < positions.length; i++) {
                    noToSell[i] = 0;
                }
                uint256 remainingYes = (yesSellerWantNo - internalMatchNo) * PRECISION / currentPrice;
                uint256 remainingRatio = (remainingYes * PRECISION) / uint256(totalYesToSell);
                for (uint256 i = 0; i < positions.length; i++) {
                    yesToSell[i] = uint128((uint256(yesToSell[i]) * remainingRatio) / PRECISION);
                }
                totalNoToSell = 0;
                totalYesToSell = uint128(remainingYes);
            }
        }

        // Step 4: Execute external swap for net deficit only
        if (totalYesToSell > 0 || totalNoToSell > 0) {
            _inRebalanceContext = true;
            outcomeToken.setApprovalForAll(address(marketCore), true);

            if (totalYesToSell > 0) {
                uint128 received = _callSwap(marketId, totalYesToSell, true);
                _distributeExternalSwapResult(positions, yesToSell, totalYesToSell, received, true);
                netSwapAmount = totalYesToSell;
                emit CollectiveRebalanceExecuted(marketId, int128(totalYesToSell), totalYesToSell);
            } else if (totalNoToSell > 0) {
                uint128 received = _callSwap(marketId, totalNoToSell, false);
                _distributeExternalSwapResult(positions, noToSell, totalNoToSell, received, false);
                netSwapAmount = totalNoToSell;
                emit CollectiveRebalanceExecuted(marketId, -int128(totalNoToSell), totalNoToSell);
            }

            _inRebalanceContext = false;
        }
    }

    /// @notice Pool-level withdrawal for all aggregated positions in a market
    /// @dev Instead of N separate removeLiquidity calls (one per position),
    ///      we do 1 call per pool and distribute proportionally. This fixes the bug
    ///      where sequential per-position removals would skew subsequent share calculations.
    function _withdrawFromAggregatedPools(
        uint256 marketId,
        uint256 removalRatio,
        uint256[] memory positions
    ) internal returns (uint128 totalYesWithdrawn, uint128 totalNoWithdrawn) {
        // Process YES-biased pool
        AggregatedPoolInfo memory yesPool = yesBiasedPools[marketId];
        if (yesPool.exists) {
            (uint128 yesW, uint128 noW) = _removeLiquidityFromPool(marketId, yesPool, removalRatio, true);
            if (yesW > 0 || noW > 0) {
                _distributePoolWithdrawal(positions, true, yesW, noW);
                totalYesWithdrawn += yesW;
                totalNoWithdrawn += noW;
            }
        }

        // Process NO-biased pool
        AggregatedPoolInfo memory noPool = noBiasedPools[marketId];
        if (noPool.exists) {
            (uint128 yesW, uint128 noW) = _removeLiquidityFromPool(marketId, noPool, removalRatio, false);
            if (yesW > 0 || noW > 0) {
                _distributePoolWithdrawal(positions, false, yesW, noW);
                totalYesWithdrawn += yesW;
                totalNoWithdrawn += noW;
            }
        }
    }

    /// @notice Remove liquidity from an entire aggregated pool at once
    function _removeLiquidityFromPool(
        uint256 marketId,
        AggregatedPoolInfo memory poolInfo,
        uint256 removalRatio,
        bool isYesBiased
    ) internal returns (uint128 yesWithdrawn, uint128 noWithdrawn) {
        uint256 numBins = uint256(poolInfo.endSlot) - uint256(poolInfo.startSlot) + 1;

        int24[] memory binIds = new int24[](numBins);
        uint256[] memory sharesToRemove = new uint256[](numBins);

        for (uint256 i = 0; i < numBins; i++) {
            binIds[i] = _slotBinIds[uint256(poolInfo.startSlot) + i];
        }

        uint256[] memory allShares = marketCore.getBatchUserBinShares(marketId, binIds, address(this));

        AggregatedPoolInfo memory otherPool = isYesBiased
            ? noBiasedPools[marketId]
            : yesBiasedPools[marketId];
        bool hasOverlap = otherPool.exists && (
            isYesBiased
                ? poolInfo.endSlot == otherPool.startSlot
                : poolInfo.startSlot == otherPool.endSlot
        );

        for (uint256 i = 0; i < numBins; i++) {
            uint256 totalBinShares;
            bool isOverlap = hasOverlap && (
                (isYesBiased && i == numBins - 1) ||
                (!isYesBiased && i == 0)
            );

            if (isOverlap) {
                totalBinShares = isYesBiased
                    ? _yesBiasedOverlapShares[marketId]
                    : _noBiasedOverlapShares[marketId];
            } else {
                totalBinShares = allShares[i];
            }

            sharesToRemove[i] = (totalBinShares * removalRatio) / PRECISION;
        }

        (yesWithdrawn, noWithdrawn) = _callRemoveLiquidity(marketId, binIds, sharesToRemove);

        if (hasOverlap) {
            uint256 overlapIdx = isYesBiased ? numBins - 1 : 0;
            if (isYesBiased) {
                _yesBiasedOverlapShares[marketId] -= sharesToRemove[overlapIdx];
            } else {
                _noBiasedOverlapShares[marketId] -= sharesToRemove[overlapIdx];
            }
        }
    }

    /// @notice Distribute pool-level withdrawal proceeds to individual positions by poolShareRatio
    function _distributePoolWithdrawal(
        uint256[] memory positions,
        bool isYesBiased,
        uint128 yesWithdrawn,
        uint128 noWithdrawn
    ) internal {
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i];
            uint256 shareRatio = positionPoolShareRatio[tokenId];
            if (shareRatio == 0) continue; // Skip traditional positions

            LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);

            // Only distribute to positions belonging to this pool
            bool posIsYesBiased = pos.targetYesRatio > 0.5e18;
            if (posIsYesBiased != isYesBiased) continue;

            // Calculate this position's share of the withdrawn tokens
            uint128 posYes = uint128((uint256(yesWithdrawn) * shareRatio) / PRECISION);
            uint128 posNo = uint128((uint256(noWithdrawn) * shareRatio) / PRECISION);

            // Move from LP to held
            uint128 newYesInLP = pos.currentYesInLP > posYes ? pos.currentYesInLP - posYes : 0;
            uint128 newNoInLP = pos.currentNoInLP > posNo ? pos.currentNoInLP - posNo : 0;

            positionNFT.updatePosition(tokenId, newYesInLP, newNoInLP, pos.currentYesHeld + posYes, pos.currentNoHeld + posNo);

            emit PositionWithdrawn(tokenId, posYes, posNo);
        }
    }

    /// @notice Internal function to withdraw from a single position
    function _withdrawFromPosition(uint256 tokenId, uint256 removalRatio)
        internal
        returns (uint128 yesWithdrawn, uint128 noWithdrawn)
    {
        LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);

        if (pos.settled) {
            return (0, 0);
        }

        uint256 poolShareRatio = positionPoolShareRatio[tokenId];

        // Check if this is an aggregated LP position (has pool share ratio set)
        if (poolShareRatio > 0) {
            // Use aggregated pool withdrawal logic
            (yesWithdrawn, noWithdrawn) = _withdrawFromAggregatedPosition(
                tokenId,
                pos,
                poolShareRatio,
                removalRatio
            );
        } else {
            // Use traditional per-bin withdrawal logic (for non-aggregated positions)
            (yesWithdrawn, noWithdrawn) = _withdrawFromTraditionalPosition(
                tokenId,
                pos,
                removalRatio
            );
        }

        emit PositionWithdrawn(tokenId, yesWithdrawn, noWithdrawn);
    }

    /// @notice Withdraw from an aggregated LP position using pool share ratio
    function _withdrawFromAggregatedPosition(
        uint256 tokenId,
        LPPositionNFT.Position memory pos,
        uint256 poolShareRatio,
        uint256 removalRatio
    ) internal returns (uint128 yesWithdrawn, uint128 noWithdrawn) {
        uint256 marketId = pos.marketId;
        bool isYesBiased = pos.targetYesRatio > 0.5e18;

        AggregatedPoolInfo memory poolInfo = isYesBiased
            ? yesBiasedPools[marketId]
            : noBiasedPools[marketId];

        if (!poolInfo.exists) {
            return (0, 0);
        }

        uint256 numBins = uint256(poolInfo.endSlot) - uint256(poolInfo.startSlot) + 1;

        AggregatedPoolInfo memory otherPool = isYesBiased
            ? noBiasedPools[marketId]
            : yesBiasedPools[marketId];
        bool hasOverlap = otherPool.exists && (
            isYesBiased
                ? poolInfo.endSlot == otherPool.startSlot
                : poolInfo.startSlot == otherPool.endSlot
        );

        int24[] memory binIds = new int24[](numBins);
        uint256[] memory sharesToRemove = new uint256[](numBins);

        for (uint256 i = 0; i < numBins; i++) {
            binIds[i] = _slotBinIds[uint256(poolInfo.startSlot) + i];
        }

        uint256[] memory allShares = marketCore.getBatchUserBinShares(marketId, binIds, address(this));

        for (uint256 i = 0; i < numBins; i++) {
            uint256 actualBinShares;
            bool isOverlap = hasOverlap && (
                (isYesBiased && i == numBins - 1) ||
                (!isYesBiased && i == 0)
            );

            if (isOverlap) {
                actualBinShares = isYesBiased
                    ? _yesBiasedOverlapShares[marketId]
                    : _noBiasedOverlapShares[marketId];
            } else {
                actualBinShares = allShares[i];
            }

            uint256 positionBinShares = (actualBinShares * poolShareRatio) / PRECISION;
            sharesToRemove[i] = (positionBinShares * removalRatio) / PRECISION;
        }

        (yesWithdrawn, noWithdrawn) = _callRemoveLiquidity(marketId, binIds, sharesToRemove);

        if (hasOverlap) {
            uint256 overlapIdx = isYesBiased ? numBins - 1 : 0;
            if (isYesBiased) {
                _yesBiasedOverlapShares[marketId] -= sharesToRemove[overlapIdx];
            } else {
                _noBiasedOverlapShares[marketId] -= sharesToRemove[overlapIdx];
            }
        }

        uint128 newYesInLP = pos.currentYesInLP > yesWithdrawn ? pos.currentYesInLP - yesWithdrawn : 0;
        uint128 newNoInLP = pos.currentNoInLP > noWithdrawn ? pos.currentNoInLP - noWithdrawn : 0;

        positionNFT.updatePosition(tokenId, newYesInLP, newNoInLP, pos.currentYesHeld + yesWithdrawn, pos.currentNoHeld + noWithdrawn);
    }

    /// @notice Withdraw from a traditional (non-aggregated) LP position using stored bin data
    function _withdrawFromTraditionalPosition(
        uint256 tokenId,
        LPPositionNFT.Position memory pos,
        uint256 removalRatio
    ) internal returns (uint128 yesWithdrawn, uint128 noWithdrawn) {
        // Get bin data for this position
        (int24[] memory binIds, uint256[] memory shares) = positionNFT.getBinData(tokenId);

        if (binIds.length == 0) {
            return (0, 0);
        }

        // Calculate shares to remove from each bin
        uint256[] memory sharesToRemove = new uint256[](binIds.length);
        uint256[] memory newShares = new uint256[](binIds.length);

        for (uint256 i = 0; i < binIds.length; i++) {
            sharesToRemove[i] = (shares[i] * removalRatio) / PRECISION;
            newShares[i] = shares[i] - sharesToRemove[i];
        }

        // Remove liquidity from MarketCore
        (yesWithdrawn, noWithdrawn) = _callRemoveLiquidity(pos.marketId, binIds, sharesToRemove);

        // Update position NFT
        uint128 newYesInLP = pos.currentYesInLP > yesWithdrawn ? pos.currentYesInLP - yesWithdrawn : 0;
        uint128 newNoInLP = pos.currentNoInLP > noWithdrawn ? pos.currentNoInLP - noWithdrawn : 0;
        uint128 newYesHeld = pos.currentYesHeld + yesWithdrawn;
        uint128 newNoHeld = pos.currentNoHeld + noWithdrawn;

        positionNFT.updatePosition(tokenId, newYesInLP, newNoInLP, newYesHeld, newNoHeld);
        positionNFT.updateShares(tokenId, newShares);
    }

    /// @notice Execute internal exchange between YES sellers and NO sellers
    /// @dev Transfers tokens between positions at current market price without going through DLMM
    function _executeInternalExchange(
        uint256[] memory positions,
        uint128[] memory yesToSell,
        uint128[] memory noToSell,
        uint128 totalYesToSell,
        uint128 totalNoToSell,
        uint128 matchedYes,
        uint128 matchedNo
    ) internal {
        // Distribute proportionally to each side
        // YES sellers give YES, receive NO
        // NO sellers give NO, receive YES

        for (uint256 i = 0; i < positions.length; i++) {
            LPPositionNFT.Position memory pos = positionNFT.getPosition(positions[i]);

            if (yesToSell[i] > 0) {
                // This position is selling YES
                uint128 yesGiven = uint128((uint256(yesToSell[i]) * matchedYes) / totalYesToSell);
                uint128 noReceived = uint128((uint256(yesToSell[i]) * matchedNo) / totalYesToSell);

                // Clamp to actual balance
                if (yesGiven > pos.currentYesHeld) {
                    yesGiven = pos.currentYesHeld;
                }

                positionNFT.updateHeldBalances(
                    positions[i],
                    pos.currentYesHeld - yesGiven,
                    pos.currentNoHeld + noReceived
                );

                emit RebalanceExecuted(positions[i], -int128(yesGiven), int128(noReceived));
            }

            if (noToSell[i] > 0) {
                // This position is selling NO
                // Re-read position in case it was updated above (same position could have both)
                pos = positionNFT.getPosition(positions[i]);

                uint128 noGiven = uint128((uint256(noToSell[i]) * matchedNo) / totalNoToSell);
                uint128 yesReceived = uint128((uint256(noToSell[i]) * matchedYes) / totalNoToSell);

                // Clamp to actual balance
                if (noGiven > pos.currentNoHeld) {
                    noGiven = pos.currentNoHeld;
                }

                positionNFT.updateHeldBalances(
                    positions[i],
                    pos.currentYesHeld + yesReceived,
                    pos.currentNoHeld - noGiven
                );

                emit RebalanceExecuted(positions[i], int128(yesReceived), -int128(noGiven));
            }
        }
    }

    /// @notice Distribute external swap results to positions that contributed
    /// @param positions Array of position token IDs
    /// @param contributions Each position's contribution to the swap
    /// @param totalContribution Sum of all contributions
    /// @param received Amount received from external swap
    /// @param swapYesToNo True if we swapped YES for NO
    function _distributeExternalSwapResult(
        uint256[] memory positions,
        uint128[] memory contributions,
        uint128 totalContribution,
        uint128 received,
        bool swapYesToNo
    ) internal {
        if (totalContribution == 0) {
            return;
        }

        for (uint256 i = 0; i < positions.length; i++) {
            if (contributions[i] == 0) {
                continue;
            }

            LPPositionNFT.Position memory pos = positionNFT.getPosition(positions[i]);

            // Calculate this position's share
            uint128 posContribution = contributions[i];
            uint128 posReceived = uint128((uint256(posContribution) * received) / totalContribution);

            if (swapYesToNo) {
                // We sold YES externally, distribute NO received
                // Position already had YES deducted during internal exchange or needs deduction now
                uint128 yesToDeduct = posContribution > pos.currentYesHeld ? pos.currentYesHeld : posContribution;

                positionNFT.updateHeldBalances(
                    positions[i],
                    pos.currentYesHeld - yesToDeduct,
                    pos.currentNoHeld + posReceived
                );

                emit RebalanceExecuted(positions[i], -int128(yesToDeduct), int128(posReceived));
            } else {
                // We sold NO externally, distribute YES received
                uint128 noToDeduct = posContribution > pos.currentNoHeld ? pos.currentNoHeld : posContribution;

                positionNFT.updateHeldBalances(
                    positions[i],
                    pos.currentYesHeld + posReceived,
                    pos.currentNoHeld - noToDeduct
                );

                emit RebalanceExecuted(positions[i], int128(posReceived), -int128(noToDeduct));
            }
        }
    }

    // ============ Settlement ============

    /// @inheritdoc ILPManager
    function settlePosition(uint256 tokenId) external override nonReentrant returns (uint128 payout) {
        LPPositionNFT.Position memory pos = positionNFT.getPosition(tokenId);
        require(!pos.settled, "LP:SETTLED");

        // Check market is resolved
        (, , , , bool resolved, bool yesWins, ) = marketCore.markets(pos.marketId);
        require(resolved, "LP:RESOLVED");

        address owner = positionNFT.ownerOf(tokenId);

        // Get total position
        uint128 totalYes = pos.currentYesInLP + pos.currentYesHeld;
        uint128 totalNo = pos.currentNoInLP + pos.currentNoHeld;

        // Mark as settled
        positionNFT.markSettled(tokenId);

        // Transfer tokens to owner
        if (totalYes > 0) {
            outcomeToken.safeTransferFrom(
                address(this),
                owner,
                outcomeToken.getYesTokenId(pos.marketId),
                totalYes,
                ""
            );
        }
        if (totalNo > 0) {
            outcomeToken.safeTransferFrom(
                address(this),
                owner,
                outcomeToken.getNoTokenId(pos.marketId),
                totalNo,
                ""
            );
        }

        // Payout is the winning token amount
        if (yesWins) {
            payout = totalYes;
        } else {
            payout = totalNo;
        }

        emit LPSettled(tokenId, owner, payout);
    }

    // ============ View Functions ============

    /// @inheritdoc ILPManager
    function getMarketLPState(uint256 marketId) external view override returns (MarketLPState memory) {
        return _marketLPStates[marketId];
    }


    /// @notice Get all position token IDs for a market
    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory) {
        return _marketPositions[marketId];
    }

    // ============ Fee Tracking ============

    /// @inheritdoc ILPFeeCollector
    function recordLPFee(uint256 marketId, uint128 lpFee) external override {
        require(msg.sender == address(marketCore), "LP:MC");
        _marketLPStates[marketId].accumulatedFees += lpFee;
    }

    // ============ Internal Functions ============



    function _callRemoveLiquidity(
        uint256 marketId,
        int24[] memory binIds,
        uint256[] memory sharesToRemove
    ) internal returns (uint128 actualYes, uint128 actualNo) {
        if (_inHookContext) {
            (actualYes, actualNo) = marketCore.removeLiquidityFromHook(marketId, binIds, sharesToRemove, address(this));
        } else {
            (actualYes, actualNo) = marketCore.removeLiquidity(marketId, binIds, sharesToRemove, address(this));
        }
    }

    /// @notice Route swap call based on context
    /// @dev When called from within afterSwap hook, uses swapFromHook (bypasses nonReentrant).
    ///      Otherwise uses normal swap.
    function _callSwap(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo
    ) internal returns (uint128 amountOut) {
        if (_inHookContext) {
            amountOut = marketCore.swapFromHook(marketId, amountIn, swapForNo, address(this));
        } else {
            amountOut = marketCore.swap(marketId, amountIn, swapForNo, address(this));
        }
    }

    /// @notice Check if current price appears manipulated using TWAP comparison
    /// @dev Price is considered manipulated if:
    ///      1. Spot price deviates significantly from long TWAP, AND
    ///      2. Short TWAP hasn't moved much (indicating it's not a real trend)
    function _isPriceManipulated(uint256 marketId) internal view returns (bool) {
        if (address(marketViewer) == address(0)) return false;
        return marketViewer.isPriceManipulated(
            marketId,
            twapLongWindow,
            twapShortWindow,
            maxPriceDeviation
        );
    }

}
