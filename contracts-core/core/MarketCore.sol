// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/IDLMMEngine.sol";
import "../interfaces/IMarketCore.sol";
import "../interfaces/ISwapHook.sol";
import "../interfaces/IOptimisticOracle.sol";
import "../interfaces/ILPFeeCollector.sol";
import "../tokens/OutcomeToken.sol";
import "../libraries/Constants.sol";
import "../libraries/PriceMath.sol";
import "../libraries/ProbabilityMath.sol";
import "../libraries/FeeHelper.sol";
import "../libraries/PriceOracle.sol";
import "../libraries/SwapExecutor.sol";

/**
 * @title MarketCore
 * @notice Singleton contract managing all prediction markets
 * @dev All market state is stored in mappings keyed by marketId.
 *      Uses OutcomeToken (ERC-1155) for YES/NO tokens.
 *      LP shares are managed via internal accounting (no ERC-1155 token).
 *      Creating a new market only registers a marketId - no contract deployment required.
 */
contract MarketCore is IMarketCore, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @dev Offset for encoding int24 to uint256
    uint256 private constant BIN_ID_OFFSET = 8388608;

    // ============ State ============

    /// @notice Trading engine address
    IDLMMEngine public engine;

    /// @notice Outcome token contract (ERC-1155 for YES/NO)
    OutcomeToken public outcomeToken;

    /// @notice Collateral token (e.g., USDC)
    IERC20 public collateral;

    // ============ Market State (per marketId) ============

    /// @notice Market metadata
    mapping(uint256 => MarketInfo) public markets;

    /// @notice Current active bin ID per market
    mapping(uint256 => int24) public activeIds;

    /// @notice Bin reserves per market: marketId => binId => Bin
    mapping(uint256 => mapping(int24 => Bin)) private _bins;

    /// @notice Volatility parameters per market
    mapping(uint256 => FeeHelper.VolatilityParameters) public volatilityParams;

    /// @notice Accumulated protocol fees per market (collateral)
    mapping(uint256 => uint128) public protocolFees;

    /// @notice Total collateral held per market
    mapping(uint256 => uint256) public totalCollateral;

    /// @notice Swap hook address (for limit orders, LP withdrawals, etc.)
    address public swapHook;

    /// @notice LP fee collector (for fee accounting)
    address public lpFeeCollector;

    /// @notice Swap hook depth counter (replaces bool _inSwapHook)
    /// @dev Incremented before calling afterSwap, decremented after. Allows hook
    ///      contracts to call removeLiquidityFromHook/swapFromHook/etc.
    ///      Using a counter instead of bool supports nested hook calls
    ///      (e.g., rebalance swap triggers another afterSwap from within a hook).
    uint256 private _swapHookDepth;

    /// @notice Authorized addresses that can call swap()
    mapping(address => bool) public authorizedSwapCallers;

    /// @notice Authorized addresses that can call *FromHook functions during swap hooks
    /// @dev Should include LimitOrderManager, LPManager, and any other registered hook contracts
    mapping(address => bool) public authorizedHookCallers;

    // ============ LP State (internal accounting) ============

    /// @notice User LP shares per bin: marketId => binId => user => shares
    mapping(uint256 => mapping(int24 => mapping(address => uint256))) public userBinShares;

    /// @notice Total LP shares per bin: marketId => binId => totalShares
    mapping(uint256 => mapping(int24 => uint256)) public binTotalShares;

    // ============ Price Oracle State ============

    /// @notice Price oracle state per market for TWAP calculations
    mapping(uint256 => PriceOracle.OracleState) private _priceOracles;

    /// @notice Cached bin IDs for each slot (0-98), precomputed to avoid expensive math
    int24[99] private _slotBinIds;

    /// @notice Cached prices for each slot (0-98), precomputed to avoid expensive pow()
    uint256[99] private _slotPrices;

    // ============ Market Creation Access Control ============

    /// @notice Authorized market creator (MarketFactory)
    address public authorizedMarketCreator;

    /// @notice Optimistic Oracle address for lazy resolution
    address private _oracle;

    // ============ Storage Gap ============

    uint256[48] private __gap;

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _engine,
        address _outcomeToken,
        address _collateral
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_engine != address(0), "MC:0");
        require(_outcomeToken != address(0), "MC:0");
        require(_collateral != address(0), "MC:0");

        engine = IDLMMEngine(_engine);
        outcomeToken = OutcomeToken(_outcomeToken);
        collateral = IERC20(_collateral);

        // Precompute and cache all 99 slot → binId and slot → price mappings
        for (uint256 slot = 0; slot < Constants.TOTAL_PREDICTION_BINS; slot++) {
            int24 binId = ProbabilityMath.getBinIdForSlot(slot);
            _slotBinIds[slot] = binId;
            _slotPrices[slot] = PriceMath.getPriceFromId(10, binId);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============ Modifiers ============

    modifier validMarket(uint256 marketId) {
        require(markets[marketId].exists, "MC:MKT");
        _;
    }

    modifier notPaused(uint256 marketId) {
        require(!markets[marketId].paused, "MC:PAUSED");
        _;
    }

    modifier notResolved(uint256 marketId) {
        require(!markets[marketId].resolved, "MC:RESOLVED");
        _;
    }

    modifier duringSwapHook() {
        require(_swapHookDepth > 0, "MC:HOOK");
        require(authorizedHookCallers[msg.sender], "MC:!HOOK");
        _;
    }

    modifier onlyAuthorizedSwap() {
        require(authorizedSwapCallers[msg.sender], "MC:!SWAP");
        _;
    }

    // ============ Market Creation ============

    /// @inheritdoc IMarketCore
    function reserveMarketId() external returns (uint256 marketId) {
        require(msg.sender == authorizedMarketCreator || msg.sender == owner(), "MC:AUTH");
        marketId = outcomeToken.registerMarket();
    }

    /// @inheritdoc IMarketCore
    function activateMarket(
        uint256 marketId,
        string calldata question,
        int24 initialActiveId
    ) external {
        require(msg.sender == authorizedMarketCreator, "MC:AUTH");
        require(!markets[marketId].exists, "MC:EXISTS");
        require(ProbabilityMath.isValidPredictionBin(initialActiveId), "MC:BIN");

        markets[marketId] = MarketInfo({
            question: question,
            creator: msg.sender,
            createdAt: uint40(block.timestamp),
            exists: true,
            resolved: false,
            yesWins: false,
            paused: false
        });

        activeIds[marketId] = initialActiveId;

        volatilityParams[marketId] = FeeHelper.VolatilityParameters({
            volatilityAccumulator: 0,
            volatilityReference: 0,
            idReference: uint24(uint256(int256(initialActiveId) + int256(BIN_ID_OFFSET))),
            timeOfLastUpdate: uint40(block.timestamp)
        });

        _initializePriceOracle(marketId);

        emit MarketCreated(marketId, msg.sender, question, initialActiveId);
    }

    // ============ Token Minting/Burning ============

    /// @inheritdoc IMarketCore
    function mintOutcomes(
        uint256 marketId,
        uint256 amount,
        address to
    ) external validMarket(marketId) notResolved(marketId) nonReentrant {
        require(amount > 0, "MC:AMT");
        require(to != address(0), "MC:ADDR");

        // Transfer collateral from user
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        totalCollateral[marketId] += amount;

        // Mint equal amounts of YES and NO tokens
        outcomeToken.mintPair(marketId, to, amount);

        emit OutcomesMinted(marketId, msg.sender, to, amount);
    }

    /// @inheritdoc IMarketCore
    function burnOutcomes(
        uint256 marketId,
        uint256 amount,
        address to
    ) external validMarket(marketId) nonReentrant {
        require(amount > 0, "MC:AMT");
        require(to != address(0), "MC:ADDR");

        // Burn equal amounts of YES and NO tokens from user
        outcomeToken.burnPair(marketId, msg.sender, amount);

        // Return collateral
        totalCollateral[marketId] -= amount;
        collateral.safeTransfer(to, amount);

        emit OutcomesBurned(marketId, msg.sender, to, amount);
    }

    /// @notice Burn outcomes callable during swap hook (no reentrancy guard)
    /// @dev Only callable when _inSwapHook is true
    function burnOutcomesFromHook(
        uint256 marketId,
        uint256 amount,
        address to
    ) external validMarket(marketId) duringSwapHook {
        require(amount > 0, "MC:AMT");
        require(to != address(0), "MC:ADDR");

        outcomeToken.burnPair(marketId, msg.sender, amount);

        totalCollateral[marketId] -= amount;
        collateral.safeTransfer(to, amount);

        emit OutcomesBurned(marketId, msg.sender, to, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IMarketCore
    function getBin(uint256 marketId, int24 binId) external view returns (uint128 reserveX, uint128 reserveY) {
        Bin memory bin = _bins[marketId][binId];
        return (bin.reserveX, bin.reserveY);
    }

    /// @inheritdoc IMarketCore
    function getCurrentProbability(uint256 marketId) external view validMarket(marketId) returns (uint256) {
        return engine.getProbabilityFromId(activeIds[marketId]);
    }

    /// @inheritdoc IMarketCore
    function getCurrentPrice(uint256 marketId) external view validMarket(marketId) returns (uint256) {
        return engine.getPriceFromId(activeIds[marketId]);
    }

    /// @inheritdoc IMarketCore
    function getProtocolFees(uint256 marketId) external view returns (uint128) {
        return protocolFees[marketId];
    }

    /// @notice Get user's LP shares in a specific bin
    function getUserBinShares(uint256 marketId, int24 binId, address user) external view returns (uint256) {
        return userBinShares[marketId][binId][user];
    }

    /// @inheritdoc IMarketCore
    function getBatchUserBinShares(uint256 marketId, int24[] calldata binIds, address user) external view returns (uint256[] memory shares) {
        shares = new uint256[](binIds.length);
        for (uint256 i = 0; i < binIds.length; i++) {
            shares[i] = userBinShares[marketId][binIds[i]][user];
        }
    }

    /// @notice Get total LP shares in a specific bin
    function getBinTotalShares(uint256 marketId, int24 binId) external view returns (uint256) {
        return binTotalShares[marketId][binId];
    }

    // ============ Swap Functions ============

    /// @inheritdoc IMarketCore
    function swap(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo,
        address to
    ) external validMarket(marketId) notPaused(marketId) notResolved(marketId) onlyAuthorizedSwap nonReentrant returns (uint128 amountOut) {
        return _swapInternal(marketId, amountIn, swapForNo, to);
    }

    /// @inheritdoc IMarketCore
    /// @dev Allows hook contracts (e.g., LPManager) to execute swaps during afterSwap callbacks
    ///      without hitting the nonReentrant guard. Protected by duringSwapHook modifier
    ///      which checks _swapHookDepth > 0 AND authorizedHookCallers[msg.sender].
    function swapFromHook(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo,
        address to
    ) external validMarket(marketId) notPaused(marketId) notResolved(marketId) duringSwapHook returns (uint128 amountOut) {
        return _swapInternal(marketId, amountIn, swapForNo, to);
    }

    /// @dev Shared swap implementation used by both swap() and swapFromHook()
    function _swapInternal(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo,
        address to
    ) internal returns (uint128 amountOut) {
        require(to != address(0), "MC:ADDR");
        require(amountIn > 0, "MC:AMT");

        // Transfer input tokens from caller to this contract
        if (swapForNo) {
            outcomeToken.safeTransferFrom(msg.sender, address(this), outcomeToken.getYesTokenId(marketId), amountIn, "");
        } else {
            outcomeToken.safeTransferFrom(msg.sender, address(this), outcomeToken.getNoTokenId(marketId), amountIn, "");
        }

        // Update volatility
        _updateVolatility(marketId);

        // Calculate fee
        FeeHelper.VolatilityParameters memory volParams = volatilityParams[marketId];
        uint128 fee = engine.calculateFee(amountIn, volParams.volatilityAccumulator);
        uint128 amountInAfterFee = amountIn - fee;

        // Execute swap
        int24 currentActiveId = activeIds[marketId];
        int24 newActiveId = currentActiveId;
        int24[] memory touchedBins;
        (amountOut, newActiveId, touchedBins) = SwapExecutor.executeSwap(
            _bins[marketId], _slotBinIds, _slotPrices, amountInAfterFee, swapForNo, newActiveId
        );

        require(amountOut > 0, "MC:OUT");

        // Update active bin if needed
        if (newActiveId != currentActiveId) {
            emit ActiveIdUpdated(marketId, currentActiveId, newActiveId);
            activeIds[marketId] = newActiveId;
        }

        // Handle protocol fees
        uint128 protocolFee = engine.getProtocolFee(fee);
        uint128 lpFee = fee - protocolFee;

        protocolFees[marketId] += protocolFee;

        // Add LP fee to active bin
        if (swapForNo) {
            _bins[marketId][newActiveId].reserveX += lpFee;
        } else {
            _bins[marketId][newActiveId].reserveY += lpFee;
        }

        // Track LP fee for accounting
        if (lpFeeCollector != address(0) && lpFee > 0) {
            ILPFeeCollector(lpFeeCollector).recordLPFee(marketId, lpFee);
        }

        // Transfer output tokens from this contract to recipient
        if (swapForNo) {
            outcomeToken.safeTransferFrom(address(this), to, outcomeToken.getNoTokenId(marketId), amountOut, "");
        } else {
            outcomeToken.safeTransferFrom(address(this), to, outcomeToken.getYesTokenId(marketId), amountOut, "");
        }

        emit Swap(marketId, msg.sender, to, activeIds[marketId], amountIn, amountOut, fee, swapForNo);

        // Record price observation for TWAP oracle
        _recordPriceObservation(marketId);

        // Call swap hook AFTER all state updates are complete
        // Hook may call back into removeLiquidityFromHook/swapFromHook
        // The _swapHookDepth counter allows these calls to bypass nonReentrant
        // Called on every swap (not just bin changes) so LPManager can process
        // time-based decay even when small swaps don't cross bin boundaries.
        // LimitOrderManager handles oldActiveId==newActiveId by returning early.
        if (swapHook != address(0)) {
            _swapHookDepth++;
            ISwapHook(swapHook).afterSwap(marketId, currentActiveId, newActiveId);
            _swapHookDepth--;
        }

        // Emit BinsUpdated AFTER hook so reserves reflect final state
        // (hook may modify bins via removeLiquidityFromHook/addLiquidityFromHook)
        if (touchedBins.length > 0) {
            _emitBinsUpdated(marketId, touchedBins);
        }
    }

    // ============ Liquidity Functions ============

    /// @inheritdoc IMarketCore
    function addLiquidity(
        uint256 marketId,
        int24[] calldata binIds,
        uint128[] calldata amountsYes,
        uint128[] calldata amountsNo,
        address to
    ) external validMarket(marketId) notPaused(marketId) notResolved(marketId) nonReentrant returns (uint256[] memory shares) {
        return _addLiquidityCore(marketId, binIds, amountsYes, amountsNo, to, true);
    }

    /// @inheritdoc IMarketCore
    function removeLiquidity(
        uint256 marketId,
        int24[] calldata binIds,
        uint256[] calldata sharesToBurn,
        address to
    ) external validMarket(marketId) nonReentrant returns (uint128 totalAmountYes, uint128 totalAmountNo) {
        return _removeLiquidityCore(marketId, binIds, sharesToBurn, to, true, true);
    }

    /// @notice Remove liquidity callable by swap hook (no reentrancy guard)
    /// @dev Only callable by the registered swapHook during afterSwap callback
    function removeLiquidityFromHook(
        uint256 marketId,
        int24[] calldata binIds,
        uint256[] calldata sharesToBurn,
        address to
    ) external validMarket(marketId) duringSwapHook returns (uint128 totalAmountYes, uint128 totalAmountNo) {
        return _removeLiquidityCore(marketId, binIds, sharesToBurn, to, false, false);
    }

    /// @notice Add liquidity callable by swap hook (no reentrancy guard)
    /// @dev Only callable by the registered swapHook during afterSwap callback
    function addLiquidityFromHook(
        uint256 marketId,
        int24[] calldata binIds,
        uint128[] calldata amountsYes,
        uint128[] calldata amountsNo,
        address to
    ) external validMarket(marketId) duringSwapHook returns (uint256[] memory shares) {
        return _addLiquidityCore(marketId, binIds, amountsYes, amountsNo, to, false);
    }

    // ============ Protocol Fee Functions ============

    /// @inheritdoc IMarketCore
    function collectProtocolFees(uint256 marketId) external validMarket(marketId) returns (uint128 fees) {
        address recipient = engine.feeRecipient();
        require(msg.sender == recipient || msg.sender == owner(), "MC:AUTH");

        fees = protocolFees[marketId];
        protocolFees[marketId] = 0;

        if (fees > 0) {
            emit ProtocolFeesCollected(marketId, recipient, fees);
        }
    }

    // ============ Market Resolution ============

    /// @dev Lazy resolution: read Oracle if not yet resolved, write result to storage
    function _ensureResolved(uint256 marketId) internal {
        if (markets[marketId].resolved) return;
        (bytes32 o, bool r, bool inv) = IOptimisticOracle(_oracle).getFinalOutcome(marketId);
        require(r, "MC:!R");
        require(!inv, "MC:INV");
        bool w = o == bytes32("YES");
        markets[marketId].resolved = true;
        markets[marketId].yesWins = w;
        emit MarketResolved(marketId, w);
    }

    /// @inheritdoc IMarketCore
    function resolveMarket(uint256 marketId) external validMarket(marketId) {
        _ensureResolved(marketId);
    }

    /// @inheritdoc IMarketCore
    function redeem(uint256 marketId, address to) external validMarket(marketId) nonReentrant returns (uint256 payout) {
        _ensureResolved(marketId);
        require(to != address(0), "MC:ADDR");

        MarketInfo memory info = markets[marketId];
        uint256 yesBalance = outcomeToken.yesBalance(marketId, msg.sender);
        uint256 noBalance = outcomeToken.noBalance(marketId, msg.sender);

        if (info.yesWins) {
            payout = yesBalance;
            if (yesBalance > 0) {
                outcomeToken.burnYes(marketId, msg.sender, yesBalance);
            }
        } else {
            payout = noBalance;
            if (noBalance > 0) {
                outcomeToken.burnNo(marketId, msg.sender, noBalance);
            }
        }

        if (payout > 0) {
            totalCollateral[marketId] -= payout;
            collateral.safeTransfer(to, payout);
        }

        emit Redeemed(marketId, msg.sender, to, payout);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IMarketCore
    function setPaused(uint256 marketId, bool _paused) external validMarket(marketId) onlyOwner {
        markets[marketId].paused = _paused;
    }

    /// @inheritdoc IMarketCore
    function setSwapHook(address hook) external onlyOwner {
        swapHook = hook;
    }

    /// @notice Set the LP fee collector address
    /// @param collector Address of the ILPFeeCollector contract
    function setLPFeeCollector(address collector) external onlyOwner {
        lpFeeCollector = collector;
    }

    /// @inheritdoc IMarketCore
    function setAuthorizedSwapCaller(address caller, bool authorized) external onlyOwner {
        authorizedSwapCallers[caller] = authorized;
        emit AuthorizedSwapCallerUpdated(caller, authorized);
    }

    /// @inheritdoc IMarketCore
    function setAuthorizedHookCaller(address caller, bool authorized) external onlyOwner {
        authorizedHookCallers[caller] = authorized;
        emit AuthorizedHookCallerUpdated(caller, authorized);
    }

    /// @notice Set the authorized market creator (MarketFactory)
    /// @param _creator Address of the MarketFactory contract
    function setAuthorizedMarketCreator(address _creator) external onlyOwner {
        authorizedMarketCreator = _creator;
    }

    function setOracle(address o) external onlyOwner {
        _oracle = o;
    }

    /// @inheritdoc IMarketCore
    function forceDecay(uint256 marketId) external validMarket(marketId) {
        FeeHelper.VolatilityParameters storage volParams = volatilityParams[marketId];
        (uint24 newVa, uint24 newVr) = engine.calculateVolatilityUpdate(volParams, activeIds[marketId]);
        volParams.volatilityAccumulator = newVa;
        volParams.volatilityReference = newVr;
        volParams.timeOfLastUpdate = uint40(block.timestamp);
    }

    // ============ Internal Functions ============

    /// @dev Shared add liquidity logic for both addLiquidity and addLiquidityFromHook
    function _addLiquidityCore(
        uint256 marketId,
        int24[] calldata binIds,
        uint128[] calldata amountsYes,
        uint128[] calldata amountsNo,
        address to,
        bool trackModifiedBins
    ) internal returns (uint256[] memory shares) {
        require(to != address(0), "MC:ADDR");
        require(binIds.length == amountsYes.length && binIds.length == amountsNo.length, "MC:LEN");

        shares = new uint256[](binIds.length);
        uint128 totalYes;
        uint128 totalNo;

        int24[] memory modifiedBinIds;
        uint256 modifiedCount;
        if (trackModifiedBins) {
            modifiedBinIds = new int24[](binIds.length);
        }

        for (uint256 i = 0; i < binIds.length; i++) {
            uint128 amountYes = amountsYes[i];
            uint128 amountNo = amountsNo[i];

            if (amountYes == 0 && amountNo == 0) continue;

            shares[i] = _addLiquidityToBin(marketId, binIds[i], amountYes, amountNo, to);
            totalYes += amountYes;
            totalNo += amountNo;

            if (trackModifiedBins) {
                modifiedBinIds[modifiedCount] = binIds[i];
                modifiedCount++;
            }
        }

        if (totalYes > 0) {
            outcomeToken.safeTransferFrom(msg.sender, address(this), outcomeToken.getYesTokenId(marketId), totalYes, "");
        }
        if (totalNo > 0) {
            outcomeToken.safeTransferFrom(msg.sender, address(this), outcomeToken.getNoTokenId(marketId), totalNo, "");
        }

        if (trackModifiedBins && modifiedCount > 0) {
            assembly { mstore(modifiedBinIds, modifiedCount) }
            _emitBinsUpdated(marketId, modifiedBinIds);
        }

        emit LiquidityAdded(marketId, msg.sender, to, binIds, amountsYes, amountsNo, shares);
    }

    /// @dev Shared remove liquidity logic for both removeLiquidity and removeLiquidityFromHook
    function _removeLiquidityCore(
        uint256 marketId,
        int24[] calldata binIds,
        uint256[] calldata sharesToBurn,
        address to,
        bool validateBins,
        bool trackModifiedBins
    ) internal returns (uint128 totalAmountYes, uint128 totalAmountNo) {
        require(to != address(0), "MC:ADDR");
        require(binIds.length == sharesToBurn.length, "MC:LEN");

        int24[] memory modifiedBinIds;
        uint256 modifiedCount;
        if (trackModifiedBins) {
            modifiedBinIds = new int24[](binIds.length);
        }

        for (uint256 i = 0; i < binIds.length; i++) {
            int24 binId = binIds[i];
            uint256 shares = sharesToBurn[i];

            if (validateBins) {
                require(_isValidBinId(binId), "MC:BIN");
            }

            if (shares == 0) continue;

            require(userBinShares[marketId][binId][msg.sender] >= shares, "MC:SHARES");

            Bin storage bin = _bins[marketId][binId];
            uint256 totalSharesInBin = binTotalShares[marketId][binId];
            uint256 shareFraction = (shares * Constants.PRECISION) / totalSharesInBin;

            (uint128 amountYes, uint128 amountNo) = ProbabilityMath.getAmountsFromShares(
                bin.reserveX, bin.reserveY, shareFraction
            );

            bin.reserveX -= amountYes;
            bin.reserveY -= amountNo;
            userBinShares[marketId][binId][msg.sender] -= shares;
            binTotalShares[marketId][binId] -= shares;

            totalAmountYes += amountYes;
            totalAmountNo += amountNo;

            if (trackModifiedBins) {
                modifiedBinIds[modifiedCount] = binId;
                modifiedCount++;
            }
        }

        if (totalAmountYes > 0) {
            outcomeToken.safeTransferFrom(address(this), to, outcomeToken.getYesTokenId(marketId), totalAmountYes, "");
        }
        if (totalAmountNo > 0) {
            outcomeToken.safeTransferFrom(address(this), to, outcomeToken.getNoTokenId(marketId), totalAmountNo, "");
        }

        if (trackModifiedBins && modifiedCount > 0) {
            assembly { mstore(modifiedBinIds, modifiedCount) }
            _emitBinsUpdated(marketId, modifiedBinIds);
        }

        emit LiquidityRemoved(marketId, msg.sender, to, binIds, sharesToBurn, totalAmountYes, totalAmountNo);
    }

    function _addLiquidityToBin(
        uint256 marketId,
        int24 binId,
        uint128 amountYes,
        uint128 amountNo,
        address to
    ) internal returns (uint256 mintShares) {
        // Use lightweight validation: just check binId is within valid range
        // Full validation (isValidPredictionBin) is too expensive for batch operations
        require(
            binId >= Constants.MIN_PREDICTION_BIN_ID && binId <= Constants.MAX_PREDICTION_BIN_ID,
            "MC:BIN"
        );

        // Get price for this bin
        uint256 price = engine.getPriceFromId(binId);

        // Calculate liquidity
        uint256 addedLiquidity = ProbabilityMath.getLiquidity(price, amountYes, amountNo);

        // Get current bin state
        Bin storage bin = _bins[marketId][binId];
        uint256 currentLiquidity = ProbabilityMath.getLiquidity(price, bin.reserveX, bin.reserveY);

        // Get total shares for this bin
        uint256 totalSharesInBin = binTotalShares[marketId][binId];

        // Calculate shares to mint
        if (totalSharesInBin == 0) {
            mintShares = addedLiquidity;
        } else {
            mintShares = (addedLiquidity * totalSharesInBin) / currentLiquidity;
        }

        // Update bin reserves
        bin.reserveX += amountYes;
        bin.reserveY += amountNo;

        // Update LP shares (internal accounting)
        userBinShares[marketId][binId][to] += mintShares;
        binTotalShares[marketId][binId] += mintShares;
    }

    function _emitBinsUpdated(uint256 marketId, int24[] memory binIds) internal {
        uint128[] memory reservesYes = new uint128[](binIds.length);
        uint128[] memory reservesNo = new uint128[](binIds.length);
        for (uint256 i = 0; i < binIds.length; i++) {
            Bin memory bin = _bins[marketId][binIds[i]];
            reservesYes[i] = bin.reserveX;
            reservesNo[i] = bin.reserveY;
        }
        emit BinsUpdated(marketId, binIds, reservesYes, reservesNo);
    }

    function _updateVolatility(uint256 marketId) internal {
        FeeHelper.VolatilityParameters storage volParams = volatilityParams[marketId];
        (uint24 newVa, uint24 newVr) = engine.calculateVolatilityUpdate(volParams, activeIds[marketId]);
        volParams.volatilityAccumulator = newVa;
        volParams.volatilityReference = newVr;
        volParams.idReference = uint24(uint256(int256(activeIds[marketId]) + int256(BIN_ID_OFFSET)));
        volParams.timeOfLastUpdate = uint40(block.timestamp);
    }

    // ============ Batch Getters (for MarketViewer) ============

    /// @inheritdoc IMarketCore
    function getBatchBinReserves(uint256 marketId) external view returns (uint128[] memory reservesX, uint128[] memory reservesY) {
        reservesX = new uint128[](Constants.TOTAL_PREDICTION_BINS);
        reservesY = new uint128[](Constants.TOTAL_PREDICTION_BINS);
        for (uint256 i = 0; i < Constants.TOTAL_PREDICTION_BINS; i++) {
            Bin memory b = _bins[marketId][_slotBinIds[i]];
            reservesX[i] = b.reserveX;
            reservesY[i] = b.reserveY;
        }
    }

    /// @inheritdoc IMarketCore
    function getSlotData() external view returns (int24[99] memory binIds, uint256[99] memory prices) {
        binIds = _slotBinIds;
        prices = _slotPrices;
    }

    /// @notice Fast bin ID validation using cached slot array
    /// @dev Binary search via SwapExecutor library + exact match check. O(log 99) storage reads.
    function _isValidBinId(int24 binId) internal view returns (bool) {
        if (binId < Constants.MIN_PREDICTION_BIN_ID || binId > Constants.MAX_PREDICTION_BIN_ID) {
            return false;
        }
        uint256 slot = SwapExecutor.findSlotForBin(_slotBinIds, binId);
        return _slotBinIds[slot] == binId;
    }

    // ============ Price Oracle Functions ============

    /// @notice Record a price observation for TWAP calculation
    /// @dev Called automatically after each swap
    function _recordPriceObservation(uint256 marketId) internal {
        uint256 currentPrice = engine.getPriceFromId(activeIds[marketId]);
        PriceOracle.record(_priceOracles[marketId], currentPrice);
    }

    /// @notice Initialize price oracle for a market
    /// @dev Called when market is created
    function _initializePriceOracle(uint256 marketId) internal {
        uint256 initialPrice = engine.getPriceFromId(activeIds[marketId]);
        PriceOracle.initialize(_priceOracles[marketId], initialPrice);
    }

    /// @notice Get oracle state for off-chain/viewer consumption
    function getOracleState(uint256 marketId) external view returns (
        uint16 index,
        uint16 cardinality,
        uint40[] memory timestamps,
        uint216[] memory cumulatives
    ) {
        PriceOracle.OracleState storage state = _priceOracles[marketId];
        index = state.index;
        cardinality = state.cardinality;
        timestamps = new uint40[](cardinality);
        cumulatives = new uint216[](cardinality);
        for (uint16 i = 0; i < cardinality; i++) {
            timestamps[i] = state.observations[i].timestamp;
            cumulatives[i] = state.observations[i].priceCumulative;
        }
    }
}
