// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IMarketCore.sol";
import "../interfaces/IMarketViewer.sol";
import "../interfaces/IMarketFactory.sol";
import "../interfaces/IOptimisticOracle.sol";
import "../interfaces/IDLMMEngine.sol";
import "../libraries/FeeHelper.sol";
import "../libraries/Constants.sol";
import "../libraries/ProbabilityMath.sol";
import "../libraries/SwapLib.sol";
import "../libraries/PriceOracle.sol";

/**
 * @title MarketViewer
 * @notice Read-only helper providing swap quotes and computations
 * @dev Separated from MarketCore to reduce its bytecode below EIP-170 limit.
 *      Not upgradeable — just a stateless view helper.
 */
contract MarketViewer is IMarketViewer {
    IMarketCore public immutable marketCore;
    IDLMMEngine public immutable engine;
    IMarketFactory public immutable marketFactory;
    IOptimisticOracle public immutable oracle;

    constructor(address _marketCore, address _engine, address _factory, address _oracle) {
        marketCore = IMarketCore(_marketCore);
        engine = IDLMMEngine(_engine);
        marketFactory = IMarketFactory(_factory);
        oracle = IOptimisticOracle(_oracle);
    }

    /// @inheritdoc IMarketViewer
    function getSwapOut(
        uint256 marketId,
        uint128 amountIn,
        bool swapForNo
    ) external view override returns (uint128 amountOut, uint128 fee) {
        (uint24 va, , , ) = marketCore.volatilityParams(marketId);
        fee = engine.calculateFee(amountIn, va);
        uint128 amountInAfterFee = amountIn - fee;

        IDLMMEngine.BinData[] memory bins = _getBinsAroundActive(marketId, 10);
        IDLMMEngine.SwapResult memory result = engine.calculateSwapOut(
            amountInAfterFee,
            swapForNo,
            marketCore.activeIds(marketId),
            bins
        );
        amountOut = result.amountOut;
    }

    /// @inheritdoc IMarketViewer
    function getSwapIn(
        uint256 marketId,
        uint128 amountOut,
        bool swapForNo
    ) external view override returns (uint128 amountIn, uint128 fee) {
        IDLMMEngine.BinData[] memory bins = _getBinsAroundActive(marketId, 10);
        (amountIn, fee) = engine.calculateSwapIn(
            amountOut,
            swapForNo,
            marketCore.activeIds(marketId),
            bins
        );
    }

    /// @inheritdoc IMarketViewer
    function computeOptimalSellSwap(
        uint256 marketId,
        uint128 totalAmount,
        bool swapForNo
    ) external view override returns (uint128 optimalSwapAmount) {
        // Compute total fee rate
        (uint24 va, , , ) = marketCore.volatilityParams(marketId);
        (uint16 binStep, uint16 baseFactor, , , , uint24 variableFeeControl, , ) = engine.feeParameters();
        uint128 totalFee = FeeHelper.getBaseFee(binStep, baseFactor)
            + FeeHelper.getVariableFee(binStep, variableFeeControl, va);
        if (totalFee > Constants.MAX_FEE) totalFee = Constants.MAX_FEE;

        // Read all bin reserves
        int24 activeId = marketCore.activeIds(marketId);
        (uint128[] memory reservesX, uint128[] memory reservesY) = marketCore.getBatchBinReserves(marketId);
        (, uint256[99] memory slotPrices) = marketCore.getSlotData();

        // Find active slot
        (int24[99] memory slotBinIds, ) = marketCore.getSlotData();
        uint256 activeSlot = _findSlotForBin(activeId, slotBinIds);

        // Convert fixed array to dynamic for SwapLib
        uint256[] memory prices = new uint256[](Constants.TOTAL_PREDICTION_BINS);
        for (uint256 i = 0; i < Constants.TOTAL_PREDICTION_BINS; i++) {
            prices[i] = slotPrices[i];
        }

        optimalSwapAmount = SwapLib.computeOptimalSell(
            totalAmount, swapForNo, activeSlot, reservesX, reservesY, prices, totalFee, Constants.TOTAL_PREDICTION_BINS
        );
    }

    // ============ Price Oracle Views ============

    /// @inheritdoc IMarketViewer
    function getTWAP(uint256 marketId, uint256 window) external view override returns (uint256 twap) {
        uint256 currentPrice = engine.getPriceFromId(marketCore.activeIds(marketId));
        if (window == 0) return currentPrice;

        (uint16 index, uint16 cardinality, uint40[] memory timestamps, uint216[] memory cumulatives)
            = marketCore.getOracleState(marketId);

        if (cardinality <= 1) return currentPrice;

        uint256 targetTime = block.timestamp > window ? block.timestamp - window : 0;

        // Find observation at or before targetTime (search backwards from latest)
        uint256 beforeCumulative;
        uint40 beforeTimestamp;
        bool found;

        uint16 idx = index;
        uint40 afterTimestamp = timestamps[idx];
        uint216 afterCumulative = cumulatives[idx];

        for (uint16 i = 0; i < cardinality; i++) {
            if (timestamps[idx] <= targetTime) {
                beforeTimestamp = timestamps[idx];
                beforeCumulative = uint256(cumulatives[idx]);
                found = true;
                break;
            }
            afterTimestamp = timestamps[idx];
            afterCumulative = cumulatives[idx];
            idx = idx == 0 ? cardinality - 1 : idx - 1;
        }

        if (!found || beforeTimestamp == 0 || beforeTimestamp >= block.timestamp) {
            return currentPrice;
        }

        uint256 timeElapsed = block.timestamp - beforeTimestamp;
        if (timeElapsed == 0) return currentPrice;

        // Interpolate if needed
        if (beforeTimestamp < targetTime && afterTimestamp > beforeTimestamp) {
            uint256 obsTimeDelta = afterTimestamp - beforeTimestamp;
            uint256 tgtTimeDelta = targetTime - beforeTimestamp;
            uint256 cumDelta = uint256(afterCumulative) - beforeCumulative;
            beforeCumulative = beforeCumulative + (cumDelta * tgtTimeDelta / obsTimeDelta);
            timeElapsed = block.timestamp - targetTime;
        }

        // Current cumulative
        uint256 latestCum = uint256(cumulatives[index]);
        uint256 currentCumulative = latestCum + (currentPrice * (block.timestamp - timestamps[index]));

        twap = (currentCumulative - beforeCumulative) / timeElapsed;
    }

    /// @inheritdoc IMarketViewer
    function isPriceManipulated(
        uint256 marketId,
        uint256 longWindow,
        uint256 shortWindow,
        uint256 maxDeviation
    ) external view override returns (bool manipulated) {
        uint256 currentPrice = engine.getPriceFromId(marketCore.activeIds(marketId));
        uint256 longTwap = this.getTWAP(marketId, longWindow);
        uint256 shortTwap = this.getTWAP(marketId, shortWindow);

        uint256 spotDeviation = _calcDeviation(currentPrice, longTwap);
        uint256 trendDeviation = _calcDeviation(shortTwap, longTwap);

        return spotDeviation > maxDeviation && trendDeviation < maxDeviation / 2;
    }

    /// @inheritdoc IMarketViewer
    function getSpotPrice(uint256 marketId) external view override returns (uint256 price) {
        return engine.getPriceFromId(marketCore.activeIds(marketId));
    }

    // ============ Aggregated Market Status ============

    /// @inheritdoc IMarketViewer
    function getMarketStatus(uint256 marketId) external view override returns (MarketStatusInfo memory info) {
        IMarketFactory.MarketConfig memory config = marketFactory.getMarketConfig(marketId);
        info.tradingEndTime = config.tradingEndTime;

        // 1. Fundraising
        if (config.phase == IMarketFactory.MarketPhase.Fundraising) {
            info.status = MarketStatus.Fundraising;
            return info;
        }

        // 2. Check MarketCore resolved
        (, , , bool exists, bool resolved, bool yesWins, ) = marketCore.markets(marketId);
        if (resolved) {
            info.status = MarketStatus.Settled;
            info.yesWins = yesWins;
            return info;
        }

        // 3. Check Oracle state
        IOptimisticOracle.Resolution memory res = oracle.getResolution(marketId);

        if (res.status == IOptimisticOracle.ResolutionStatus.Resolved) {
            info.status = MarketStatus.Resolvable;
            info.yesWins = (res.proposedOutcome == bytes32("YES"));
            return info;
        }
        if (res.status == IOptimisticOracle.ResolutionStatus.Challenged) {
            info.status = MarketStatus.Challenged;
            return info;
        }
        if (res.status == IOptimisticOracle.ResolutionStatus.Proposed) {
            info.status = MarketStatus.Proposed;
            return info;
        }

        // 4. Oracle not involved yet — check trading time
        if (exists && block.timestamp > config.tradingEndTime) {
            info.status = MarketStatus.TradingHalted;
            return info;
        }

        info.status = MarketStatus.Trading;
    }

    // ============ Internal Helpers ============

    function _getBinsAroundActive(uint256 marketId, uint256 count) internal view returns (IDLMMEngine.BinData[] memory bins) {
        int24 activeId = marketCore.activeIds(marketId);
        (int24[99] memory slotBinIds, ) = marketCore.getSlotData();
        uint256 activeSlot = _findSlotForBin(activeId, slotBinIds);

        uint256 startSlot = activeSlot > count ? activeSlot - count : 0;
        uint256 endSlot = activeSlot + count < Constants.TOTAL_PREDICTION_BINS - 1
            ? activeSlot + count
            : Constants.TOTAL_PREDICTION_BINS - 1;
        uint256 numBins = endSlot - startSlot + 1;

        bins = new IDLMMEngine.BinData[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            int24 binId = slotBinIds[startSlot + i];
            (uint128 rx, uint128 ry) = marketCore.getBin(marketId, binId);
            bins[i] = IDLMMEngine.BinData({
                binId: binId,
                reserveX: rx,
                reserveY: ry
            });
        }
    }

    /// @notice Binary search on slot bin IDs (monotonically INCREASING, slot 0 = lowest binId)
    function _findSlotForBin(int24 binId, int24[99] memory slotBinIds) internal pure returns (uint256 slot) {
        uint256 lo = 0;
        uint256 hi = Constants.TOTAL_PREDICTION_BINS;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (slotBinIds[mid] < binId) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= Constants.TOTAL_PREDICTION_BINS) return Constants.TOTAL_PREDICTION_BINS - 1;
        if (lo == 0) return 0;
        int24 diff1 = binId - slotBinIds[lo - 1];
        int24 diff2 = slotBinIds[lo] - binId;
        return diff1 <= diff2 ? lo - 1 : lo;
    }

    function _calcDeviation(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return type(uint256).max;
        if (a > b) {
            return ((a - b) * 1e18) / b;
        } else {
            return ((b - a) * 1e18) / b;
        }
    }
}
