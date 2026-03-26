// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/IMarketCore.sol";
import "../interfaces/IMarketViewer.sol";
import "../interfaces/ILimitOrderManager.sol";
import "../interfaces/IMarketFactory.sol";
import "../tokens/OutcomeToken.sol";

/**
 * @title MarketRouter
 * @notice Convenience router that combines multi-step operations into single transactions
 * @dev User approves Router once for USDC + OutcomeToken, then calls buy/sell in one tx.
 *      Router never holds user funds between transactions.
 *
 *      Buy flow:  USDC → mintOutcomes → swap unwanted side → deliver wanted tokens
 *      Sell flow: pull tokens → swap portion to pair → burnOutcomes → deliver USDC
 */
contract MarketRouter is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ============ State ============

    IMarketCore public marketCore;
    ILimitOrderManager public limitOrderManager;
    IERC20 public usdc;
    OutcomeToken public outcomeToken;

    /// @dev Deprecated - beneficiary now tracked in LimitOrderManager.UserOrder.beneficiary
    mapping(uint256 => address) public orderOwners;

    /// @notice Swap fee in basis points (e.g., 30 = 0.3%)
    uint256 public swapFeeBps;

    /// @notice Address that receives collected fees
    address public feeRecipient;

    /// @notice Accumulated fees held in Router (USDC)
    uint256 public accumulatedFees;

    /// @notice MarketViewer for swap quotes (separated from MarketCore for EIP-170)
    IMarketViewer public marketViewer;

    // ============ LP Fee Sharing ============

    /// @notice Share of swap fee allocated to Stage 1 LPs (basis points of fee, e.g., 5000 = 50%)
    uint256 public lpFeeShareBps;

    /// @notice MarketFactory for looking up LP contributions
    IMarketFactory public marketFactory;

    /// @notice Accumulated LP fees per market (USDC)
    mapping(uint256 => uint256) public accumulatedLPFees;

    /// @notice Already claimed LP fees: marketId => user => claimed amount
    mapping(uint256 => mapping(address => uint256)) public claimedLPFees;

    // ============ Constants ============

    /// @notice Maximum swap fee: 5%
    uint256 public constant MAX_SWAP_FEE_BPS = 500;

    // ============ Storage Gap ============

    uint256[45] private __gap;

    // ============ Errors ============

    error SlippageExceeded(uint256 received, uint256 minimum);
    error NotOrderOwner();
    error ZeroAmount();
    error FeeTooHigh();
    error ZeroAddress();
    error NoFeesToCollect();
    error NotLP();
    error TradingEnded();

    // ============ Enums ============

    enum TradeType { BuyYes, BuyNo, SellYes, SellNo }

    // ============ Events ============

    event Trade(
        uint256 indexed marketId,
        address indexed trader,
        TradeType tradeType,
        uint256 usdcAmount,
        uint256 tokenAmount
    );

    event SwapFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesCollected(address indexed recipient, uint256 amount);
    event LPFeeShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event LPFeeClaimed(uint256 indexed marketId, address indexed provider, uint256 amount);

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _marketCore,
        address _limitOrderManager,
        address _usdc,
        address _outcomeToken
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        marketCore = IMarketCore(_marketCore);
        limitOrderManager = ILimitOrderManager(_limitOrderManager);
        usdc = IERC20(_usdc);
        outcomeToken = OutcomeToken(_outcomeToken);

        // Infinite approvals so Router can call marketCore.mintOutcomes / burnOutcomes
        IERC20(_usdc).approve(_marketCore, type(uint256).max);
        IERC20(_usdc).approve(_limitOrderManager, type(uint256).max);
        OutcomeToken(_outcomeToken).setApprovalForAll(_marketCore, true);
        OutcomeToken(_outcomeToken).setApprovalForAll(_limitOrderManager, true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Set MarketViewer address (for swap quotes separated from MarketCore)
    function setMarketViewer(address _viewer) external onlyOwner {
        marketViewer = IMarketViewer(_viewer);
    }

    // ============ Fee Splitting ============

    /// @dev Split a fee into protocol share and LP share for the given market
    function _splitFee(uint256 marketId, uint256 fee) internal {
        if (fee == 0) return;
        uint256 lpShare = fee * lpFeeShareBps / 10000;
        if (lpShare > 0) {
            accumulatedLPFees[marketId] += lpShare;
        }
        accumulatedFees += fee - lpShare;
    }

    /// @dev Sum a provider's total contribution amount across all entries
    function _getProviderTotalAmount(uint256 marketId, address provider) internal view returns (uint128 total) {
        IMarketFactory.ContributionEntry[] memory entries = marketFactory.getProviderContributions(marketId, provider);
        for (uint256 i = 0; i < entries.length; i++) {
            total += entries[i].amount;
        }
    }

    /// @dev Revert if market trading period has ended
    function _requireTradingActive(uint256 marketId) internal view {
        if (address(marketFactory) == address(0)) return;
        IMarketFactory.MarketConfig memory config = marketFactory.getMarketConfig(marketId);
        if (config.tradingEndTime != 0 && block.timestamp > config.tradingEndTime) revert TradingEnded();
    }

    // ============ Market Buy ============

    /**
     * @notice Buy YES tokens with USDC in a single transaction
     * @dev Flow: pull USDC → mintOutcomes(YES+NO to Router) → swap NO→YES to user → transfer minted YES to user
     * @param marketId Market ID
     * @param usdcAmount Amount of USDC to spend
     * @param minYesOut Minimum total YES tokens to receive (slippage protection)
     * @param to Recipient address
     * @return totalYesOut Total YES tokens delivered
     */
    function buyYes(
        uint256 marketId,
        uint256 usdcAmount,
        uint128 minYesOut,
        address to
    ) external nonReentrant returns (uint256 totalYesOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);

        // 1. Pull USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Deduct swap fee
        uint256 fee = usdcAmount * swapFeeBps / 10000;
        uint256 netAmount = usdcAmount - fee;
        _splitFee(marketId, fee);

        // 3. Mint YES+NO pairs to Router
        marketCore.mintOutcomes(marketId, netAmount, address(this));

        // 4. Swap all NO → YES, send directly to recipient
        // swapForNo=false means: sell NO, get YES
        uint128 swapOut = marketCore.swap(
            marketId,
            uint128(netAmount),
            false, // sell NO → get YES
            to
        );

        // 5. Transfer minted YES tokens to recipient
        uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
        outcomeToken.safeTransferFrom(address(this), to, yesTokenId, netAmount, "");

        // 6. Total = minted YES + swapped YES
        totalYesOut = netAmount + swapOut;
        if (totalYesOut < minYesOut) revert SlippageExceeded(totalYesOut, minYesOut);

        emit Trade(marketId, msg.sender, TradeType.BuyYes, usdcAmount, totalYesOut);
    }

    /**
     * @notice Buy NO tokens with USDC in a single transaction
     * @dev Flow: pull USDC → mintOutcomes(YES+NO to Router) → swap YES→NO to user → transfer minted NO to user
     * @param marketId Market ID
     * @param usdcAmount Amount of USDC to spend
     * @param minNoOut Minimum total NO tokens to receive (slippage protection)
     * @param to Recipient address
     * @return totalNoOut Total NO tokens delivered
     */
    function buyNo(
        uint256 marketId,
        uint256 usdcAmount,
        uint128 minNoOut,
        address to
    ) external nonReentrant returns (uint256 totalNoOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);

        // 1. Pull USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Deduct swap fee
        uint256 fee = usdcAmount * swapFeeBps / 10000;
        uint256 netAmount = usdcAmount - fee;
        _splitFee(marketId, fee);

        // 3. Mint YES+NO pairs to Router
        marketCore.mintOutcomes(marketId, netAmount, address(this));

        // 4. Swap all YES → NO, send directly to recipient
        // swapForNo=true means: sell YES, get NO
        uint128 swapOut = marketCore.swap(
            marketId,
            uint128(netAmount),
            true, // sell YES → get NO
            to
        );

        // 5. Transfer minted NO tokens to recipient
        uint256 noTokenId = outcomeToken.getNoTokenId(marketId);
        outcomeToken.safeTransferFrom(address(this), to, noTokenId, netAmount, "");

        // 6. Total = minted NO + swapped NO
        totalNoOut = netAmount + swapOut;
        if (totalNoOut < minNoOut) revert SlippageExceeded(totalNoOut, minNoOut);

        emit Trade(marketId, msg.sender, TradeType.BuyNo, usdcAmount, totalNoOut);
    }

    // ============ Market Sell ============

    /**
     * @notice Sell YES tokens for USDC in a single transaction
     * @dev Flow: pull YES → binary-search optimal swap amount → swap YES→NO → burnOutcomes(pairs) → deliver USDC + leftover
     * @param marketId Market ID
     * @param yesAmount Total YES tokens to sell
     * @param minUsdcOut Minimum USDC to receive (slippage protection)
     * @param to Recipient address
     * @return usdcOut USDC delivered to recipient
     */
    function sellYes(
        uint256 marketId,
        uint128 yesAmount,
        uint128 minUsdcOut,
        address to
    ) external nonReentrant returns (uint128 usdcOut) {
        if (yesAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);

        uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
        uint256 noTokenId = outcomeToken.getNoTokenId(marketId);

        // 1. Pull YES tokens from user
        outcomeToken.safeTransferFrom(msg.sender, address(this), yesTokenId, yesAmount, "");

        // 2. Compute optimal swap amount on-chain (binary search inside MarketCore)
        uint128 swapAmount = marketViewer.computeOptimalSellSwap(marketId, yesAmount, true);

        // 3. Swap portion of YES → NO
        uint128 noOut = 0;
        if (swapAmount > 0) {
            noOut = marketCore.swap(marketId, swapAmount, true, address(this));
        }

        // 4. Burn matching pairs for USDC (to Router for fee deduction)
        uint128 remainingYes = yesAmount - swapAmount;
        uint128 pairAmount = remainingYes < noOut ? remainingYes : noOut;
        if (pairAmount > 0) {
            marketCore.burnOutcomes(marketId, pairAmount, address(this));
        }

        // 5. Deduct swap fee from USDC proceeds
        uint256 fee = uint256(pairAmount) * swapFeeBps / 10000;
        _splitFee(marketId, fee);
        uint128 netUsdc = pairAmount - uint128(fee);

        // 6. Transfer net USDC to recipient
        if (netUsdc > 0) {
            usdc.safeTransfer(to, netUsdc);
        }
        usdcOut = netUsdc;

        // 7. Send leftover dust to feeRecipient (binary search rounding)
        uint128 leftoverYes = remainingYes - pairAmount;
        uint128 leftoverNo = noOut - pairAmount;
        address dustRecipient = feeRecipient != address(0) ? feeRecipient : address(this);

        if (leftoverYes > 0) {
            outcomeToken.safeTransferFrom(address(this), dustRecipient, yesTokenId, leftoverYes, "");
        }
        if (leftoverNo > 0) {
            outcomeToken.safeTransferFrom(address(this), dustRecipient, noTokenId, leftoverNo, "");
        }

        if (usdcOut < minUsdcOut) revert SlippageExceeded(usdcOut, minUsdcOut);

        emit Trade(marketId, msg.sender, TradeType.SellYes, usdcOut, yesAmount);
    }

    /**
     * @notice Sell NO tokens for USDC in a single transaction
     * @dev Flow: pull NO → binary-search optimal swap amount → swap NO→YES → burnOutcomes(pairs) → deliver USDC + leftover
     * @param marketId Market ID
     * @param noAmount Total NO tokens to sell
     * @param minUsdcOut Minimum USDC to receive (slippage protection)
     * @param to Recipient address
     * @return usdcOut USDC delivered to recipient
     */
    function sellNo(
        uint256 marketId,
        uint128 noAmount,
        uint128 minUsdcOut,
        address to
    ) external nonReentrant returns (uint128 usdcOut) {
        if (noAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);

        uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
        uint256 noTokenId = outcomeToken.getNoTokenId(marketId);

        // 1. Pull NO tokens from user
        outcomeToken.safeTransferFrom(msg.sender, address(this), noTokenId, noAmount, "");

        // 2. Compute optimal swap amount on-chain (binary search inside MarketCore)
        uint128 swapAmount = marketViewer.computeOptimalSellSwap(marketId, noAmount, false);

        // 3. Swap portion of NO → YES
        uint128 yesOut = 0;
        if (swapAmount > 0) {
            yesOut = marketCore.swap(marketId, swapAmount, false, address(this));
        }

        // 4. Burn matching pairs for USDC (to Router for fee deduction)
        uint128 remainingNo = noAmount - swapAmount;
        uint128 pairAmount = remainingNo < yesOut ? remainingNo : yesOut;
        if (pairAmount > 0) {
            marketCore.burnOutcomes(marketId, pairAmount, address(this));
        }

        // 5. Deduct swap fee from USDC proceeds
        uint256 fee = uint256(pairAmount) * swapFeeBps / 10000;
        _splitFee(marketId, fee);
        uint128 netUsdc = pairAmount - uint128(fee);

        // 6. Transfer net USDC to recipient
        if (netUsdc > 0) {
            usdc.safeTransfer(to, netUsdc);
        }
        usdcOut = netUsdc;

        // 7. Send leftover dust to feeRecipient (binary search rounding)
        uint128 leftoverNo = remainingNo - pairAmount;
        uint128 leftoverYes = yesOut - pairAmount;
        address dustRecipient = feeRecipient != address(0) ? feeRecipient : address(this);

        if (leftoverNo > 0) {
            outcomeToken.safeTransferFrom(address(this), dustRecipient, noTokenId, leftoverNo, "");
        }
        if (leftoverYes > 0) {
            outcomeToken.safeTransferFrom(address(this), dustRecipient, yesTokenId, leftoverYes, "");
        }

        if (usdcOut < minUsdcOut) revert SlippageExceeded(usdcOut, minUsdcOut);

        emit Trade(marketId, msg.sender, TradeType.SellNo, usdcOut, noAmount);
    }

    // ============ Quote Functions ============

    /**
     * @notice Quote how many YES tokens you get for a given USDC amount
     * @param marketId Market ID
     * @param usdcAmount USDC to spend
     * @return totalYesOut Total YES tokens (minted + swapped)
     */
    function quoteBuyYes(uint256 marketId, uint256 usdcAmount) external view returns (uint256 totalYesOut) {
        uint256 netAmount = usdcAmount - (usdcAmount * swapFeeBps / 10000);
        (uint128 swapOut,) = marketViewer.getSwapOut(marketId, uint128(netAmount), false);
        totalYesOut = netAmount + swapOut;
    }

    /**
     * @notice Quote how many NO tokens you get for a given USDC amount
     * @param marketId Market ID
     * @param usdcAmount USDC to spend
     * @return totalNoOut Total NO tokens (minted + swapped)
     */
    function quoteBuyNo(uint256 marketId, uint256 usdcAmount) external view returns (uint256 totalNoOut) {
        uint256 netAmount = usdcAmount - (usdcAmount * swapFeeBps / 10000);
        (uint128 swapOut,) = marketViewer.getSwapOut(marketId, uint128(netAmount), true);
        totalNoOut = netAmount + swapOut;
    }

    /**
     * @notice Quote USDC output for selling YES tokens (after fee deduction)
     * @param marketId Market ID
     * @param yesAmount YES tokens to sell
     * @return usdcOut Estimated USDC output after fee
     */
    function quoteSellYes(
        uint256 marketId,
        uint128 yesAmount
    ) external view returns (uint128 usdcOut) {
        uint128 swapAmount = marketViewer.computeOptimalSellSwap(marketId, yesAmount, true);
        (uint128 noOut,) = marketViewer.getSwapOut(marketId, swapAmount, true);
        uint128 remaining = yesAmount - swapAmount;
        uint128 grossUsdc = remaining < noOut ? remaining : noOut;
        uint128 fee = uint128(uint256(grossUsdc) * swapFeeBps / 10000);
        usdcOut = grossUsdc - fee;
    }

    /**
     * @notice Quote USDC output for selling NO tokens (after fee deduction)
     * @param marketId Market ID
     * @param noAmount NO tokens to sell
     * @return usdcOut Estimated USDC output after fee
     */
    function quoteSellNo(
        uint256 marketId,
        uint128 noAmount
    ) external view returns (uint128 usdcOut) {
        uint128 swapAmount = marketViewer.computeOptimalSellSwap(marketId, noAmount, false);
        (uint128 yesOut,) = marketViewer.getSwapOut(marketId, swapAmount, false);
        uint128 remaining = noAmount - swapAmount;
        uint128 grossUsdc = remaining < yesOut ? remaining : yesOut;
        uint128 fee = uint128(uint256(grossUsdc) * swapFeeBps / 10000);
        usdcOut = grossUsdc - fee;
    }

    // ============ Internal ============

    /**
     * @notice Binary search to find optimal swap amount for selling tokens
     * @dev Finds swapAmount where getSwapOut(swapAmount) ≈ totalAmount - swapAmount
     * @param marketId Market ID
     * @param totalAmount Total tokens to sell
     * @param swapForNo True if swapping YES→NO, false if NO→YES
     * @return optimalSwapAmount The amount to swap for maximum USDC pairing
     */
    function _findOptimalSwapAmount(
        uint256 marketId,
        uint128 totalAmount,
        bool swapForNo
    ) internal view returns (uint128 optimalSwapAmount) {
        uint128 lo = 0;
        uint128 hi = totalAmount;
        // Tolerance: stop when range is within 0.001% of totalAmount (negligible dust)
        uint128 tolerance = totalAmount / 100000;
        if (tolerance == 0) tolerance = 1;

        for (uint256 i = 0; i < 30; i++) {
            if (hi - lo <= tolerance) break;
            uint128 mid = lo + (hi - lo) / 2;
            (uint128 midOut,) = marketViewer.getSwapOut(marketId, mid, swapForNo);
            uint128 midRemaining = totalAmount - mid;
            if (midOut > midRemaining) {
                hi = mid;
            } else {
                lo = mid;
            }
        }

        optimalSwapAmount = lo;
    }

    // ============ Limit Order Functions ============

    /**
     * @notice Place a limit buy YES order (deposit USDC, get YES when price drops)
     * @param marketId Market ID
     * @param targetBinId Target bin ID
     * @param usdcAmount USDC amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitBuyYes(
        uint256 marketId,
        int24 targetBinId,
        uint128 usdcAmount
    ) external nonReentrant returns (uint256 orderId) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.BuyYes,
            targetBinId,
            usdcAmount,
            msg.sender
        );
    }

    /**
     * @notice Place a limit buy NO order (deposit USDC, get NO when price rises)
     * @param marketId Market ID
     * @param targetBinId Target bin ID
     * @param usdcAmount USDC amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitBuyNo(
        uint256 marketId,
        int24 targetBinId,
        uint128 usdcAmount
    ) external nonReentrant returns (uint256 orderId) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.BuyNo,
            targetBinId,
            usdcAmount,
            msg.sender
        );
    }

    /**
     * @notice Place a limit sell YES order (deposit YES, get USDC when price rises)
     * @param marketId Market ID
     * @param targetBinId Target bin ID
     * @param amount YES token amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitSellYes(
        uint256 marketId,
        int24 targetBinId,
        uint128 amount
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
        outcomeToken.safeTransferFrom(msg.sender, address(this), yesTokenId, amount, "");
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.SellYes,
            targetBinId,
            amount,
            msg.sender
        );
    }

    /**
     * @notice Place a limit sell NO order (deposit NO, get USDC when price drops)
     * @param marketId Market ID
     * @param targetBinId Target bin ID
     * @param amount NO token amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitSellNo(
        uint256 marketId,
        int24 targetBinId,
        uint128 amount
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        uint256 noTokenId = outcomeToken.getNoTokenId(marketId);
        outcomeToken.safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.SellNo,
            targetBinId,
            amount,
            msg.sender
        );
    }

    /**
     * @notice Place a limit buy YES order by target probability
     * @param marketId Market ID
     * @param targetProbability Target YES probability (1e18 precision, e.g., 0.25e18 for 25%)
     * @param usdcAmount USDC amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitBuyYesByProb(
        uint256 marketId,
        uint256 targetProbability,
        uint128 usdcAmount
    ) external nonReentrant returns (uint256 orderId) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        int24 targetBinId = limitOrderManager.getBinIdForProbability(targetProbability);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.BuyYes,
            targetBinId,
            usdcAmount,
            msg.sender
        );
    }

    /**
     * @notice Place a limit buy NO order by target probability
     * @param marketId Market ID
     * @param targetProbability Target YES probability (1e18 precision)
     * @param usdcAmount USDC amount to deposit
     * @return orderId Created order ID
     */
    function placeLimitBuyNoByProb(
        uint256 marketId,
        uint256 targetProbability,
        uint128 usdcAmount
    ) external nonReentrant returns (uint256 orderId) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireTradingActive(marketId);
        int24 targetBinId = limitOrderManager.getBinIdForProbability(targetProbability);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        orderId = limitOrderManager.placeLimitOrder(
            marketId,
            ILimitOrderManager.OrderType.BuyNo,
            targetBinId,
            usdcAmount,
            msg.sender
        );
    }

    /**
     * @notice Withdraw a limit order placed through this Router
     * @dev Router is order.owner, so LimitOrderManager sends tokens to Router.
     *      Router then forwards everything to the real user (beneficiary).
     * @param orderId Order ID to withdraw
     * @return refundAmount Amount refunded
     */
    function withdrawLimitOrder(uint256 orderId) external nonReentrant returns (uint128 refundAmount) {
        ILimitOrderManager.UserOrder memory order = limitOrderManager.getOrder(orderId);
        if (order.beneficiary != msg.sender) revert NotOrderOwner();

        uint256 marketId = order.marketId;

        // Withdraw - tokens/USDC come to Router (since Router is order.owner)
        uint256 usdcBefore = usdc.balanceOf(address(this));
        refundAmount = limitOrderManager.withdrawOrder(orderId);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        // Forward USDC to beneficiary (only the delta, not accumulated fees)
        uint256 usdcRefund = usdcAfter - usdcBefore;
        if (usdcRefund > 0) {
            usdc.safeTransfer(msg.sender, usdcRefund);
        }

        // Forward any outcome tokens to beneficiary
        uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
        uint256 noTokenId = outcomeToken.getNoTokenId(marketId);
        uint256 yesBalance = outcomeToken.balanceOf(address(this), yesTokenId);
        uint256 noBalance = outcomeToken.balanceOf(address(this), noTokenId);

        if (yesBalance > 0) {
            outcomeToken.safeTransferFrom(address(this), msg.sender, yesTokenId, yesBalance, "");
        }
        if (noBalance > 0) {
            outcomeToken.safeTransferFrom(address(this), msg.sender, noTokenId, noBalance, "");
        }
    }

    /**
     * @notice Claim a triggered limit order placed through this Router
     * @dev Router is order.owner, so LimitOrderManager sends tokens to Router.
     *      Router then forwards to the real user (beneficiary).
     * @param orderId Order ID to claim
     * @return claimedAmount Amount claimed
     */
    function claimLimitOrder(uint256 orderId) external nonReentrant returns (uint128 claimedAmount) {
        ILimitOrderManager.UserOrder memory order = limitOrderManager.getOrder(orderId);
        if (order.beneficiary != msg.sender) revert NotOrderOwner();

        uint256 marketId = order.marketId;
        ILimitOrderManager.OrderType orderType = order.orderType;

        // Claim - tokens/USDC come to Router (since Router is order.owner)
        claimedAmount = limitOrderManager.claimOrder(orderId);

        // Forward to beneficiary based on order type
        if (orderType == ILimitOrderManager.OrderType.BuyYes) {
            uint256 yesTokenId = outcomeToken.getYesTokenId(marketId);
            outcomeToken.safeTransferFrom(address(this), msg.sender, yesTokenId, claimedAmount, "");
        } else if (orderType == ILimitOrderManager.OrderType.BuyNo) {
            uint256 noTokenId = outcomeToken.getNoTokenId(marketId);
            outcomeToken.safeTransferFrom(address(this), msg.sender, noTokenId, claimedAmount, "");
        } else {
            // Sell orders: claimedAmount is USDC
            usdc.safeTransfer(msg.sender, claimedAmount);
        }
    }

    // ============ LP Fee Claiming ============

    /**
     * @notice Claim accumulated LP fees for a market
     * @dev Stage 1 LPs receive fees proportional to their contribution amount.
     *      Uses accumulated-minus-claimed pattern to handle continuous fee accrual.
     * @param marketId Market ID
     * @return amount USDC amount claimed
     */
    function claimLPFees(uint256 marketId) external nonReentrant returns (uint256 amount) {
        uint128 userAmount = _getProviderTotalAmount(marketId, msg.sender);
        if (userAmount == 0) revert NotLP();

        uint128 totalFunds = marketFactory.getTotalFundsRaised(marketId);
        uint256 totalLPFees = accumulatedLPFees[marketId];

        uint256 userTotal = (totalLPFees * userAmount) / totalFunds;
        uint256 claimed = claimedLPFees[marketId][msg.sender];
        amount = userTotal - claimed;

        if (amount == 0) revert NoFeesToCollect();

        claimedLPFees[marketId][msg.sender] = userTotal;
        usdc.safeTransfer(msg.sender, amount);

        emit LPFeeClaimed(marketId, msg.sender, amount);
    }

    /**
     * @notice Get claimable LP fees for a user in a market
     * @param marketId Market ID
     * @param user LP provider address
     * @return claimable Amount of USDC claimable
     */
    function getClaimableLPFees(uint256 marketId, address user) external view returns (uint256 claimable) {
        uint128 userAmount = _getProviderTotalAmount(marketId, user);
        if (userAmount == 0) return 0;

        uint128 totalFunds = marketFactory.getTotalFundsRaised(marketId);
        if (totalFunds == 0) return 0;

        uint256 userTotal = (accumulatedLPFees[marketId] * userAmount) / totalFunds;
        uint256 claimed = claimedLPFees[marketId][user];

        claimable = userTotal > claimed ? userTotal - claimed : 0;
    }

    // ============ Admin Functions ============

    /// @notice Set the swap fee in basis points
    /// @param _feeBps Fee in basis points (e.g., 30 = 0.3%)
    function setSwapFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_SWAP_FEE_BPS) revert FeeTooHigh();
        emit SwapFeeUpdated(swapFeeBps, _feeBps);
        swapFeeBps = _feeBps;
    }

    /// @notice Set the fee recipient address
    /// @param _recipient Address to receive collected fees
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, _recipient);
        feeRecipient = _recipient;
    }

    /// @notice Collect accumulated protocol fees and send to feeRecipient
    /// @dev Only collects protocol share. LP share is claimed via claimLPFees().
    /// @return amount Amount of USDC collected
    function collectFees() external returns (uint256 amount) {
        amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        if (feeRecipient == address(0)) revert ZeroAddress();
        accumulatedFees = 0;
        usdc.safeTransfer(feeRecipient, amount);
        emit FeesCollected(feeRecipient, amount);
    }

    /// @notice Set LP fee share percentage (of total swap fee)
    /// @param _shareBps Basis points (e.g., 5000 = 50% of fee goes to LPs)
    function setLPFeeShare(uint256 _shareBps) external onlyOwner {
        require(_shareBps <= 10000, "MAX_100_PERCENT");
        emit LPFeeShareUpdated(lpFeeShareBps, _shareBps);
        lpFeeShareBps = _shareBps;
    }

    /// @notice Set MarketFactory address (for LP contribution lookups)
    function setMarketFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        marketFactory = IMarketFactory(_factory);
    }

    /**
     * @notice Check if this contract supports a given interface
     * @dev Overrides ERC1155Holder to maintain ERC165 support
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
