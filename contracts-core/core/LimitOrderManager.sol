// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ILimitOrderManager.sol";
import "../interfaces/IMarketCore.sol";
import "../interfaces/IDLMMEngine.sol";
import "../interfaces/ISwapHook.sol";
import "../tokens/OutcomeToken.sol";
import "../libraries/ProbabilityMath.sol";
import "../libraries/PriceMath.sol";
import "../libraries/Constants.sol";

/**
 * @title LimitOrderManager
 * @notice Manages limit orders using aggregated LP positions for O(1) trigger complexity
 * @dev Architecture:
 *      - Each (marketId, binId, orderType) has ONE aggregated LP position
 *      - Users add to the aggregated position, tracking their share
 *      - On price crossing: ONE removeLiquidity call per bin per order type (O(1) complexity)
 *      - Users claim their share of proceeds later
 *
 *      This design prevents DoS attacks since triggering is O(1) regardless of
 *      how many individual orders exist in a bin.
 *
 *      Order Types:
 *      - BuyYes: deposit USDC, add NO as LP at higher binId → receive YES when triggered
 *      - BuyNo: deposit USDC, add YES as LP at lower binId → receive NO when triggered
 *      - SellYes: deposit YES, add YES as LP at lower binId → receive USDC when triggered
 *      - SellNo: deposit NO, add NO as LP at higher binId → receive USDC when triggered
 */
contract LimitOrderManager is ILimitOrderManager, ISwapHook, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant PRECISION = 1e18;

    /// @notice Minimum order amount (10 USDC with 18 decimals)
    uint128 public constant override MIN_ORDER_AMOUNT = 10e18;

    // ============ State ============

    /// @notice MarketCore contract
    IMarketCore public marketCore;

    /// @notice DLMMEngine contract
    IDLMMEngine public engine;

    /// @notice Collateral token (USDC)
    IERC20 public collateral;

    /// @notice Outcome token contract
    OutcomeToken public outcomeToken;

    // ============ State ============

    /// @notice All orders by ID
    mapping(uint256 => UserOrder) private _orders;

    /// @notice User orders per market: marketId => user => orderIds
    mapping(uint256 => mapping(address => uint256[])) private _userOrders;

    /// @notice Aggregated positions: marketId => binId => orderType => position
    /// @dev Each OrderType gets its own position to avoid cross-contamination between
    ///      BuyYes/SellNo (both high bin) or BuyNo/SellYes (both low bin)
    mapping(uint256 => mapping(int24 => mapping(OrderType => AggregatedPosition))) private _positions;

    /// @notice Track order IDs in each aggregated position: positionKey => orderIds
    mapping(bytes32 => uint256[]) private _positionOrders;

    /// @notice Cycle snapshots for claim calculations: positionKey => cycle => snapshot
    /// @dev Stores totalShares, held amounts and settled amounts at the time of trigger for each cycle
    struct CycleSnapshot {
        uint256 totalShares;
        uint128 heldYes;      // YES tokens held (for SellYes orders)
        uint128 heldNo;       // NO tokens held (for SellNo orders)
        uint128 settledYes;   // YES tokens from removeLiquidity
        uint128 settledNo;    // NO tokens from removeLiquidity
        uint128 settledUsdc;  // USDC from burning pairs (for sell orders)
    }
    mapping(bytes32 => mapping(uint64 => CycleSnapshot)) private _cycleSnapshots;

    /// @notice Total order count
    uint256 public override orderCount;

    /// @notice Authorized callers for afterSwap (SwapHookRouter)
    mapping(address => bool) public authorizedCallers;

    /// @notice Cached bin IDs for each slot (0-98), precomputed to avoid expensive math per swap
    /// @dev getBinIdForSlot involves exponentiation + logarithm (~47K gas per call).
    ///      Caching avoids 99 * 47K = 4.65M gas overhead on every swap.
    int24[99] private _slotBinIds;

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
        address _outcomeToken
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_marketCore != address(0), "LimitOrderManager: ZERO_MARKET_CORE");
        require(_engine != address(0), "LimitOrderManager: ZERO_ENGINE");
        require(_collateral != address(0), "LimitOrderManager: ZERO_COLLATERAL");
        require(_outcomeToken != address(0), "LimitOrderManager: ZERO_OUTCOME_TOKEN");

        marketCore = IMarketCore(_marketCore);
        engine = IDLMMEngine(_engine);
        collateral = IERC20(_collateral);
        outcomeToken = OutcomeToken(_outcomeToken);

        // Authorize MarketCore to call afterSwap (for direct hook calls)
        authorizedCallers[_marketCore] = true;

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

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "LimitOrderManager: NOT_AUTHORIZED");
        _;
    }

    // ============ Admin Functions ============

    /// @notice Set authorized caller
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }

    // ============ Order Management ============

    /// @inheritdoc ILimitOrderManager
    function placeLimitOrder(
        uint256 marketId,
        OrderType orderType,
        int24 targetBinId,
        uint128 amount,
        address onBehalfOf
    ) external override nonReentrant returns (uint256 orderId) {
        require(amount >= MIN_ORDER_AMOUNT, "LimitOrderManager: AMOUNT_TOO_SMALL");
        require(ProbabilityMath.isValidPredictionBin(targetBinId), "LimitOrderManager: INVALID_BIN_ID");
        require(onBehalfOf != address(0), "LimitOrderManager: ZERO_BENEFICIARY");

        // Get current active bin
        int24 currentActiveId = marketCore.activeIds(marketId);

        // Validate order placement
        _validateDirection(orderType, targetBinId, currentActiveId);

        // Get or create aggregated position (keyed by orderType for isolation)
        bytes32 posKey = _getPositionKey(marketId, targetBinId, orderType);
        AggregatedPosition storage pos = _positions[marketId][targetBinId][orderType];

        // If position was previously triggered, reset it for new orders
        // Previous users can still claim using cycle snapshots
        if (pos.status == PositionStatus.Triggered) {
            // Increment cycle for new orders
            pos.cycle++;
            // Reset for new cycle
            pos.totalShares = 0;
            pos.lpShares = 0;
            pos.totalDeposited = 0;
            pos.heldYes = 0;
            pos.heldNo = 0;
            pos.settledYes = 0;
            pos.settledNo = 0;
            pos.settledUsdc = 0;
            pos.status = PositionStatus.Empty;
        }

        // Calculate shares and add liquidity
        uint128 shares;
        if (orderType == OrderType.BuyYes || orderType == OrderType.BuyNo) {
            shares = _addBuyOrder(marketId, orderType, targetBinId, amount, pos);
        } else {
            shares = _addSellOrder(marketId, orderType, targetBinId, amount, pos);
        }

        // Update position status
        if (pos.status == PositionStatus.Empty) {
            pos.status = PositionStatus.Active;
        }

        // Create order
        orderId = orderCount++;
        _orders[orderId] = UserOrder({
            marketId: marketId,
            owner: msg.sender,
            orderType: orderType,
            targetBinId: targetBinId,
            depositAmount: amount,
            shares: shares,
            status: OrderStatus.Active,
            createdAt: uint40(block.timestamp),
            cycle: pos.cycle,
            beneficiary: onBehalfOf
        });

        // Track order by beneficiary (real user)
        _userOrders[marketId][onBehalfOf].push(orderId);
        _positionOrders[posKey].push(orderId);

        emit LimitOrderCreated(orderId, marketId, onBehalfOf, orderType, targetBinId, amount, shares);
    }

    /**
     * @dev Validate order placement direction
     */
    function _validateDirection(
        OrderType orderType,
        int24 targetBinId,
        int24 currentActiveId
    ) internal pure {
        if (orderType == OrderType.BuyYes) {
            // Buy YES when it's cheap (lower probability = lower binId)
            require(targetBinId < currentActiveId, "LimitOrderManager: INVALID_TARGET_BIN_YES");
        } else if (orderType == OrderType.BuyNo) {
            // Buy NO when it's cheap (higher YES probability = higher binId)
            require(targetBinId > currentActiveId, "LimitOrderManager: INVALID_TARGET_BIN_NO");
        } else if (orderType == OrderType.SellYes) {
            // Sell YES when it's expensive (higher probability = higher binId)
            require(targetBinId > currentActiveId, "LimitOrderManager: INVALID_TARGET_BIN_SELL_YES");
        } else {
            // Sell NO when it's expensive (lower YES probability = lower binId)
            require(targetBinId < currentActiveId, "LimitOrderManager: INVALID_TARGET_BIN_SELL_NO");
        }
    }

    /**
     * @dev Add a buy order to the aggregated position
     */
    function _addBuyOrder(
        uint256 marketId,
        OrderType orderType,
        int24 targetBinId,
        uint128 amount,
        AggregatedPosition storage pos
    ) internal returns (uint128 shares) {
        // Transfer USDC from user
        collateral.safeTransferFrom(msg.sender, address(this), amount);

        // Approve and mint YES+NO tokens via MarketCore
        collateral.approve(address(marketCore), amount);
        marketCore.mintOutcomes(marketId, amount, address(this));

        // Prepare liquidity parameters
        int24[] memory binIds = new int24[](1);
        uint128[] memory amountsYes = new uint128[](1);
        uint128[] memory amountsNo = new uint128[](1);
        binIds[0] = targetBinId;

        if (orderType == OrderType.BuyYes) {
            // Add NO tokens as liquidity (will be swapped for YES when price drops)
            amountsYes[0] = 0;
            amountsNo[0] = amount;
        } else {
            // Add YES tokens as liquidity (will be swapped for NO when price rises)
            amountsYes[0] = amount;
            amountsNo[0] = 0;
        }

        // Add liquidity
        outcomeToken.setApprovalForAll(address(marketCore), true);
        uint256[] memory lpSharesArray = marketCore.addLiquidity(marketId, binIds, amountsYes, amountsNo, address(this));

        // Calculate user's shares proportionally
        // Shares are 1:1 with deposit for simplicity
        shares = amount;
        pos.totalShares += shares;
        pos.lpShares += lpSharesArray[0];
        pos.totalDeposited += amount;

        // Hold the opposite token (YES for BuyYes, NO for BuyNo)
        // These are already in the contract from minting
    }

    /**
     * @dev Add a sell order to the aggregated position
     * @notice For sell orders, we split the deposit: part goes to LP, part is held in contract
     *         SellYes at bin with YES probability p:
     *           - lpAmount = amount * (1-p)  // goes to LP as YES
     *           - heldAmount = amount * p    // held in contract
     *           - On trigger: lpAmount YES swaps to lpAmount * p/(1-p) NO
     *           - On claim: pair min(heldAmount, settledNo) and burn for USDC
     *         SellNo at bin with YES probability p (NO probability = 1-p):
     *           - lpAmount = amount * p      // goes to LP as NO
     *           - heldAmount = amount * (1-p) // held in contract
     *           - On trigger: lpAmount NO swaps to lpAmount * (1-p)/p YES
     *           - On claim: pair min(heldAmount, settledYes) and burn for USDC
     */
    function _addSellOrder(
        uint256 marketId,
        OrderType orderType,
        int24 targetBinId,
        uint128 amount,
        AggregatedPosition storage pos
    ) internal returns (uint128 shares) {
        // Get YES probability at target bin
        uint256 yesProbability = engine.getProbabilityFromId(targetBinId);

        // Calculate lpAmount and heldAmount based on probability
        uint128 lpAmount;
        uint128 heldAmount;

        if (orderType == OrderType.SellYes) {
            // SellYes: lpAmount = amount * (1-p), heldAmount = amount * p
            lpAmount = uint128((uint256(amount) * (PRECISION - yesProbability)) / PRECISION);
            heldAmount = amount - lpAmount;

            // Transfer YES tokens from user
            outcomeToken.safeTransferFrom(
                msg.sender,
                address(this),
                outcomeToken.getYesTokenId(marketId),
                amount,
                ""
            );

            // Track held YES tokens
            pos.heldYes += heldAmount;
        } else {
            // SellNo: lpAmount = amount * p, heldAmount = amount * (1-p)
            lpAmount = uint128((uint256(amount) * yesProbability) / PRECISION);
            heldAmount = amount - lpAmount;

            // Transfer NO tokens from user
            outcomeToken.safeTransferFrom(
                msg.sender,
                address(this),
                outcomeToken.getNoTokenId(marketId),
                amount,
                ""
            );

            // Track held NO tokens
            pos.heldNo += heldAmount;
        }

        // Only add liquidity if lpAmount > 0
        if (lpAmount > 0) {
            // Prepare liquidity parameters
            int24[] memory binIds = new int24[](1);
            uint128[] memory amountsYes = new uint128[](1);
            uint128[] memory amountsNo = new uint128[](1);
            binIds[0] = targetBinId;

            if (orderType == OrderType.SellYes) {
                amountsYes[0] = lpAmount;
                amountsNo[0] = 0;
            } else {
                amountsYes[0] = 0;
                amountsNo[0] = lpAmount;
            }

            // Add liquidity
            outcomeToken.setApprovalForAll(address(marketCore), true);
            uint256[] memory lpSharesArray = marketCore.addLiquidity(marketId, binIds, amountsYes, amountsNo, address(this));
            pos.lpShares += lpSharesArray[0];
        }

        // Calculate user's shares (1:1 with total deposit)
        shares = amount;
        pos.totalShares += shares;
        pos.totalDeposited += amount;
    }

    /// @inheritdoc ILimitOrderManager
    function withdrawOrder(uint256 orderId) external override nonReentrant returns (uint128 refundAmount) {
        UserOrder storage order = _orders[orderId];
        require(order.owner == msg.sender, "LimitOrderManager: NOT_OWNER");
        require(order.status == OrderStatus.Active, "LimitOrderManager: NOT_ACTIVE");

        uint256 marketId = order.marketId;
        int24 targetBinId = order.targetBinId;
        OrderType orderType = order.orderType;

        AggregatedPosition storage pos = _positions[marketId][targetBinId][orderType];
        require(pos.status == PositionStatus.Active, "LimitOrderManager: POSITION_NOT_ACTIVE");

        // Check that order's cycle matches current position's cycle
        // If position was triggered and reset, order should claim from old cycle instead of withdraw
        require(order.cycle == pos.cycle, "LimitOrderManager: CYCLE_MISMATCH");

        // Calculate proportional LP shares to remove
        uint256 userLpShares = (pos.lpShares * order.shares) / pos.totalShares;

        // Remove liquidity (only if there are LP shares)
        uint128 yesReceived;
        uint128 noReceived;
        if (userLpShares > 0) {
            int24[] memory binIds = new int24[](1);
            uint256[] memory sharesToRemove = new uint256[](1);
            binIds[0] = targetBinId;
            sharesToRemove[0] = userLpShares;

            (yesReceived, noReceived) = marketCore.removeLiquidity(
                marketId,
                binIds,
                sharesToRemove,
                address(this)
            );
        }

        // Calculate user's proportional held tokens for sell orders
        uint128 userHeldYes;
        uint128 userHeldNo;
        if (orderType == OrderType.SellYes && pos.heldYes > 0) {
            userHeldYes = uint128((uint256(pos.heldYes) * order.shares) / pos.totalShares);
            pos.heldYes -= userHeldYes;
        } else if (orderType == OrderType.SellNo && pos.heldNo > 0) {
            userHeldNo = uint128((uint256(pos.heldNo) * order.shares) / pos.totalShares);
            pos.heldNo -= userHeldNo;
        }

        // Update position
        pos.totalShares -= order.shares;
        pos.lpShares -= userLpShares;
        pos.totalDeposited -= order.depositAmount;

        // If position is empty, reset status
        if (pos.totalShares == 0) {
            pos.status = PositionStatus.Empty;
        }

        // Refund to caller (owner) — Router forwards to beneficiary
        if (orderType == OrderType.BuyYes || orderType == OrderType.BuyNo) {
            // For buy orders: burn pairs to get USDC back, return any excess tokens
            refundAmount = _refundBuyOrder(marketId, orderType, order.depositAmount, yesReceived, noReceived, msg.sender);
        } else {
            // For sell orders: return LP tokens + held tokens
            refundAmount = _refundSellOrder(marketId, orderType, yesReceived + userHeldYes, noReceived + userHeldNo, msg.sender);
        }

        // Update order status
        order.status = OrderStatus.Withdrawn;

        emit LimitOrderWithdrawn(orderId, marketId, order.beneficiary, refundAmount);
    }

    /**
     * @dev Refund a buy order withdrawal
     * @notice Includes tokens from both held balance AND LP removal to prevent token loss
     *         when the bin has been partially traded before cancellation
     */
    function _refundBuyOrder(
        uint256 marketId,
        OrderType orderType,
        uint128 depositAmount,
        uint128 yesReceived,
        uint128 noReceived,
        address recipient
    ) internal returns (uint128 refundAmount) {
        uint128 totalYes;
        uint128 totalNo;

        if (orderType == OrderType.BuyYes) {
            // Held YES (from mint) + YES returned from LP (partial fill)
            totalYes = depositAmount + yesReceived;
            totalNo = noReceived;
        } else {
            // YES returned from LP (partial fill)
            totalYes = yesReceived;
            // Held NO (from mint) + NO returned from LP (partial fill)
            totalNo = depositAmount + noReceived;
        }

        // Burn the minimum to get USDC
        refundAmount = totalYes < totalNo ? totalYes : totalNo;

        if (refundAmount > 0) {
            outcomeToken.setApprovalForAll(address(marketCore), true);
            marketCore.burnOutcomes(marketId, refundAmount, recipient);
        }

        // Transfer any remaining tokens to recipient
        uint128 remainingYes = totalYes - refundAmount;
        uint128 remainingNo = totalNo - refundAmount;

        if (remainingYes > 0) {
            outcomeToken.safeTransferFrom(
                address(this),
                recipient,
                outcomeToken.getYesTokenId(marketId),
                remainingYes,
                ""
            );
        }
        if (remainingNo > 0) {
            outcomeToken.safeTransferFrom(
                address(this),
                recipient,
                outcomeToken.getNoTokenId(marketId),
                remainingNo,
                ""
            );
        }
    }

    /**
     * @dev Refund a sell order withdrawal
     */
    function _refundSellOrder(
        uint256 marketId,
        OrderType orderType,
        uint128 yesReceived,
        uint128 noReceived,
        address recipient
    ) internal returns (uint128 refundAmount) {
        if (orderType == OrderType.SellYes) {
            // Return YES tokens
            refundAmount = yesReceived;
            if (yesReceived > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    recipient,
                    outcomeToken.getYesTokenId(marketId),
                    yesReceived,
                    ""
                );
            }
            // Also return any NO received (from partial swaps)
            if (noReceived > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    recipient,
                    outcomeToken.getNoTokenId(marketId),
                    noReceived,
                    ""
                );
            }
        } else {
            // Return NO tokens
            refundAmount = noReceived;
            if (noReceived > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    recipient,
                    outcomeToken.getNoTokenId(marketId),
                    noReceived,
                    ""
                );
            }
            // Also return any YES received (from partial swaps)
            if (yesReceived > 0) {
                outcomeToken.safeTransferFrom(
                    address(this),
                    recipient,
                    outcomeToken.getYesTokenId(marketId),
                    yesReceived,
                    ""
                );
            }
        }
    }

    /// @inheritdoc ILimitOrderManager
    function claimOrder(uint256 orderId) external override nonReentrant returns (uint128 claimedAmount) {
        UserOrder storage order = _orders[orderId];
        require(order.owner == msg.sender, "LimitOrderManager: NOT_OWNER");
        require(order.status == OrderStatus.Active, "LimitOrderManager: NOT_ACTIVE");

        uint256 marketId = order.marketId;
        OrderType orderType = order.orderType;

        // Get cycle snapshot for this order's cycle
        bytes32 posKey = _getPositionKey(marketId, order.targetBinId, orderType);
        CycleSnapshot storage snapshot = _cycleSnapshots[posKey][order.cycle];
        require(snapshot.totalShares > 0, "LimitOrderManager: NOT_TRIGGERED");

        // Calculate user's share of settled amounts using snapshot
        uint256 userShare = order.shares;
        uint256 totalShares = snapshot.totalShares;

        if (orderType == OrderType.BuyYes) {
            // User gets YES tokens: held YES + settled YES from LP
            uint128 settledYes = uint128((uint256(snapshot.settledYes) * userShare) / totalShares);
            // Plus the held YES (depositAmount)
            claimedAmount = order.depositAmount + settledYes;

            outcomeToken.safeTransferFrom(
                address(this),
                msg.sender,
                outcomeToken.getYesTokenId(marketId),
                claimedAmount,
                ""
            );
        } else if (orderType == OrderType.BuyNo) {
            // User gets NO tokens: held NO + settled NO from LP
            uint128 settledNo = uint128((uint256(snapshot.settledNo) * userShare) / totalShares);
            claimedAmount = order.depositAmount + settledNo;

            outcomeToken.safeTransferFrom(
                address(this),
                msg.sender,
                outcomeToken.getNoTokenId(marketId),
                claimedAmount,
                ""
            );
        } else {
            // Sell orders get USDC
            claimedAmount = uint128((uint256(snapshot.settledUsdc) * userShare) / totalShares);

            if (claimedAmount > 0) {
                collateral.safeTransfer(msg.sender, claimedAmount);
            }
        }

        order.status = OrderStatus.Claimed;

        emit LimitOrderClaimed(orderId, marketId, order.beneficiary, claimedAmount);
    }

    // ============ Swap Hook ============

    /// @inheritdoc ISwapHook
    function afterSwap(
        uint256 marketId,
        int24 oldActiveId,
        int24 newActiveId
    ) external override(ILimitOrderManager, ISwapHook) onlyAuthorized returns (bool success) {
        if (oldActiveId == newActiveId) return true;

        uint256 positionsTriggered = _processTriggeredPositions(marketId, oldActiveId, newActiveId);

        if (positionsTriggered > 0) {
            emit BinCrossed(marketId, oldActiveId, newActiveId, positionsTriggered);
        }

        return true;
    }

    /**
     * @dev Process aggregated positions when price crosses bins
     * @notice O(99) worst case - iterates through valid prediction bins only.
     *         Checks 2 order types per bin (buy + sell for the relevant direction).
     */
    function _processTriggeredPositions(
        uint256 marketId,
        int24 oldActiveId,
        int24 newActiveId
    ) internal returns (uint256 positionsTriggered) {
        bool binIdIncreased = newActiveId > oldActiveId;

        int24 startBin;
        int24 endBin;

        if (binIdIncreased) {
            // YES probability rose: trigger high-bin positions (BuyNo, SellYes)
            startBin = oldActiveId + 1;
            endBin = newActiveId;
        } else {
            // YES probability fell: trigger low-bin positions (BuyYes, SellNo)
            startBin = newActiveId;
            endBin = oldActiveId - 1;
        }

        // Binary search on sorted _slotBinIds (monotonically INCREASING: slot 0 = lowest binId)
        // to find only the slots within [startBin, endBin], instead of iterating all 99.
        (uint256 firstSlot, uint256 lastSlot) = _findSlotRange(startBin, endBin);

        for (uint256 slot = firstSlot; slot <= lastSlot; slot++) {
            int24 binId = _slotBinIds[slot];

            // Double-check range (edge slots from binary search may be slightly off)
            if (binId < startBin || binId > endBin) continue;

            if (binIdIncreased) {
                // YES probability rose: trigger BuyNo and SellYes at high bins
                positionsTriggered += _tryTriggerPosition(marketId, binId, OrderType.BuyNo);
                positionsTriggered += _tryTriggerPosition(marketId, binId, OrderType.SellYes);
            } else {
                // YES probability fell: trigger BuyYes and SellNo at low bins
                positionsTriggered += _tryTriggerPosition(marketId, binId, OrderType.BuyYes);
                positionsTriggered += _tryTriggerPosition(marketId, binId, OrderType.SellNo);
            }
        }
    }

    /// @dev Binary search on _slotBinIds (monotonically INCREASING) to find
    ///      the range of slots whose binId falls within [startBin, endBin].
    /// @return firstSlot Lowest slot index in range (lowest binId end)
    /// @return lastSlot Highest slot index in range (highest binId end)
    function _findSlotRange(int24 startBin, int24 endBin) internal view returns (uint256 firstSlot, uint256 lastSlot) {
        uint256 n = Constants.TOTAL_PREDICTION_BINS; // 99

        // _slotBinIds is INCREASING: [0]=lowest, [98]=highest
        // Find firstSlot: first slot where binId >= startBin
        // All slots before firstSlot have binId < startBin (too low)
        {
            uint256 lo = 0;
            uint256 hi = n;
            while (lo < hi) {
                uint256 mid = (lo + hi) / 2;
                if (_slotBinIds[mid] < startBin) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            firstSlot = lo;
        }

        // Find lastSlot: last slot where binId <= endBin
        // All slots after lastSlot have binId > endBin (too high)
        {
            uint256 lo = firstSlot;
            uint256 hi = n;
            while (lo < hi) {
                uint256 mid = (lo + hi) / 2;
                if (_slotBinIds[mid] <= endBin) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            // lo is now first slot where binId > endBin, so lastSlot = lo - 1
            if (lo == 0) {
                // No slots in range — set lastSlot < firstSlot so the loop doesn't execute
                lastSlot = 0;
                firstSlot = 1;
                return (firstSlot, lastSlot);
            }
            lastSlot = lo - 1;
        }
    }

    /**
     * @dev Try to trigger a position if it's active
     * @return 1 if triggered, 0 otherwise
     */
    function _tryTriggerPosition(
        uint256 marketId,
        int24 binId,
        OrderType orderType
    ) internal returns (uint256) {
        AggregatedPosition storage pos = _positions[marketId][binId][orderType];
        if (pos.status == PositionStatus.Active && pos.totalShares > 0) {
            _triggerPosition(marketId, binId, orderType, pos);
            return 1;
        }
        return 0;
    }

    /**
     * @dev Trigger a single aggregated position - O(1) operation
     * @notice With positions separated by OrderType, each position is homogeneous:
     *         - BuyYes: LP had NO, swapped to YES → user claims YES
     *         - BuyNo: LP had YES, swapped to NO → user claims NO
     *         - SellYes: LP had YES, swapped to NO → pair heldYes with settledNo → burn for USDC
     *         - SellNo: LP had NO, swapped to YES → pair heldNo with settledYes → burn for USDC
     */
    function _triggerPosition(
        uint256 marketId,
        int24 binId,
        OrderType orderType,
        AggregatedPosition storage pos
    ) internal {
        uint128 yesReceived;
        uint128 noReceived;

        // Remove all liquidity from the position (only if there's LP)
        if (pos.lpShares > 0) {
            int24[] memory binIds = new int24[](1);
            uint256[] memory sharesToRemove = new uint256[](1);
            binIds[0] = binId;
            sharesToRemove[0] = pos.lpShares;

            (yesReceived, noReceived) = marketCore.removeLiquidityFromHook(
                marketId,
                binIds,
                sharesToRemove,
                address(this)
            );
        }

        // Store tokens received from LP
        pos.settledYes = yesReceived;
        pos.settledNo = noReceived;

        // Process sell orders: pair held tokens with settled tokens and burn for USDC
        uint128 burnAmount;

        if (orderType == OrderType.SellYes && pos.heldYes > 0) {
            // SellYes position: pair heldYes with settledNo
            burnAmount = pos.heldYes < pos.settledNo ? pos.heldYes : pos.settledNo;
        } else if (orderType == OrderType.SellNo && pos.heldNo > 0) {
            // SellNo position: pair heldNo with settledYes
            burnAmount = pos.heldNo < pos.settledYes ? pos.heldNo : pos.settledYes;
        }

        if (burnAmount > 0) {
            outcomeToken.setApprovalForAll(address(marketCore), true);
            marketCore.burnOutcomesFromHook(marketId, burnAmount, address(this));
            pos.settledUsdc = burnAmount;

            // Adjust token amounts after burning
            if (orderType == OrderType.SellYes) {
                pos.heldYes -= burnAmount;
                pos.settledNo -= burnAmount;
            } else if (orderType == OrderType.SellNo) {
                pos.heldNo -= burnAmount;
                pos.settledYes -= burnAmount;
            }
        }

        pos.lpShares = 0;
        pos.status = PositionStatus.Triggered;

        // Save cycle snapshot for claim calculations
        bytes32 posKey = _getPositionKey(marketId, binId, orderType);
        _cycleSnapshots[posKey][pos.cycle] = CycleSnapshot({
            totalShares: pos.totalShares,
            heldYes: pos.heldYes,
            heldNo: pos.heldNo,
            settledYes: pos.settledYes,
            settledNo: pos.settledNo,
            settledUsdc: pos.settledUsdc
        });

        bool isHighBin = (orderType == OrderType.BuyYes || orderType == OrderType.SellNo);
        emit AggregatedPositionTriggered(marketId, binId, isHighBin, yesReceived, noReceived);
    }

    // ============ View Functions ============

    /// @inheritdoc ILimitOrderManager
    function getOrder(uint256 orderId) external view override returns (UserOrder memory order) {
        return _orders[orderId];
    }

    /// @inheritdoc ILimitOrderManager
    function getUserOrders(uint256 marketId, address user) external view override returns (uint256[] memory orderIds) {
        return _userOrders[marketId][user];
    }

    /// @inheritdoc ILimitOrderManager
    function getAggregatedPosition(
        uint256 marketId,
        int24 binId,
        OrderType orderType
    ) external view override returns (AggregatedPosition memory position) {
        return _positions[marketId][binId][orderType];
    }

    /// @inheritdoc ILimitOrderManager
    function binHasPosition(uint256 marketId, int24 binId) external view override returns (bool hasPosition) {
        return _positions[marketId][binId][OrderType.BuyYes].status == PositionStatus.Active ||
               _positions[marketId][binId][OrderType.BuyNo].status == PositionStatus.Active ||
               _positions[marketId][binId][OrderType.SellYes].status == PositionStatus.Active ||
               _positions[marketId][binId][OrderType.SellNo].status == PositionStatus.Active;
    }

    /// @inheritdoc ILimitOrderManager
    function getBinIdForProbability(uint256 targetProbability) external view override returns (int24 binId) {
        require(targetProbability >= 0.01e18 && targetProbability <= 0.99e18, "LimitOrderManager: INVALID_PROBABILITY");

        uint256 slot = ((targetProbability - 0.01e18) * 98) / (0.98e18);
        return engine.getBinIdForSlot(slot);
    }

    /// @inheritdoc ILimitOrderManager
    function getClaimableAmount(uint256 orderId) external view override returns (uint128 amount) {
        UserOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.Active) return 0;

        OrderType orderType = order.orderType;

        // Use cycle snapshot to check claimability (order might be from a previous cycle)
        bytes32 posKey = _getPositionKey(order.marketId, order.targetBinId, orderType);
        CycleSnapshot storage snapshot = _cycleSnapshots[posKey][order.cycle];

        // If no snapshot exists for this cycle, the position hasn't been triggered yet
        if (snapshot.totalShares == 0) return 0;

        uint256 userShare = order.shares;
        uint256 totalShares = snapshot.totalShares;

        if (orderType == OrderType.BuyYes) {
            uint128 settledYes = uint128((uint256(snapshot.settledYes) * userShare) / totalShares);
            return order.depositAmount + settledYes;
        } else if (orderType == OrderType.BuyNo) {
            uint128 settledNo = uint128((uint256(snapshot.settledNo) * userShare) / totalShares);
            return order.depositAmount + settledNo;
        } else {
            return uint128((uint256(snapshot.settledUsdc) * userShare) / totalShares);
        }
    }

    // ============ Internal Functions ============

    function _getPositionKey(uint256 marketId, int24 binId, OrderType orderType) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(marketId, binId, orderType));
    }

    // ============ ERC1155 Receiver ============

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
