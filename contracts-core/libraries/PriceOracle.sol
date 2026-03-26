// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PriceOracle
 * @notice Library for TWAP (Time-Weighted Average Price) calculations
 * @dev Uses a ring buffer of price observations similar to Uniswap V3
 */
library PriceOracle {
    /// @notice Maximum number of observations stored per market
    uint16 public constant MAX_OBSERVATIONS = 64;

    /// @notice Single price observation
    struct Observation {
        uint40 timestamp;           // Block timestamp
        uint216 priceCumulative;    // Cumulative price * time
    }

    /// @notice Oracle state for a market
    struct OracleState {
        uint16 index;               // Current observation index
        uint16 cardinality;         // Number of populated observations
        Observation[64] observations; // Ring buffer (MAX_OBSERVATIONS)
    }

    /// @notice Initialize oracle state with first observation
    /// @param state Oracle state to initialize
    /// @param price Initial price (1e18 precision)
    function initialize(OracleState storage state, uint256 price) internal {
        state.observations[0] = Observation({
            timestamp: uint40(block.timestamp),
            priceCumulative: 0
        });
        state.index = 0;
        state.cardinality = 1;
    }

    /// @notice Record a new price observation
    /// @param state Oracle state
    /// @param price Current price (1e18 precision)
    function record(OracleState storage state, uint256 price) internal {
        Observation memory last = state.observations[state.index];

        // Don't record if same block
        if (last.timestamp == block.timestamp) {
            return;
        }

        // Calculate time elapsed since last observation
        uint256 timeElapsed = block.timestamp - last.timestamp;

        // Calculate new cumulative price
        // priceCumulative += price * timeElapsed
        uint256 newCumulative = uint256(last.priceCumulative) + (price * timeElapsed);

        // Cap at uint216 max
        if (newCumulative > type(uint216).max) {
            newCumulative = type(uint216).max;
        }

        // Move to next index in ring buffer
        uint16 newIndex = (state.index + 1) % MAX_OBSERVATIONS;

        state.observations[newIndex] = Observation({
            timestamp: uint40(block.timestamp),
            priceCumulative: uint216(newCumulative)
        });

        state.index = newIndex;

        // Increase cardinality up to max
        if (state.cardinality < MAX_OBSERVATIONS) {
            state.cardinality++;
        }
    }

    /// @notice Get TWAP over a specified time window
    /// @param state Oracle state
    /// @param window Time window in seconds
    /// @param currentPrice Current spot price (fallback if insufficient data)
    /// @return twap Time-weighted average price (1e18 precision)
    function getTWAP(
        OracleState storage state,
        uint256 window,
        uint256 currentPrice
    ) internal view returns (uint256 twap) {
        if (state.cardinality == 0) {
            return currentPrice;
        }

        Observation memory latest = state.observations[state.index];

        // If window is 0 or only one observation, return current price
        if (window == 0 || state.cardinality == 1) {
            return currentPrice;
        }

        uint256 targetTime = block.timestamp > window ? block.timestamp - window : 0;

        // Find the observation at or before targetTime
        (Observation memory beforeObs, Observation memory afterObs) = _getSurroundingObservations(
            state,
            targetTime
        );

        // If we don't have enough history, use what we have
        if (beforeObs.timestamp == 0 || beforeObs.timestamp >= block.timestamp) {
            return currentPrice;
        }

        // Calculate TWAP
        // TWAP = (cumulativeNow - cumulativeBefore) / (timeNow - timeBefore)
        uint256 timeElapsed = block.timestamp - beforeObs.timestamp;
        if (timeElapsed == 0) {
            return currentPrice;
        }

        // Get current cumulative (latest + time since latest * current price)
        uint256 currentCumulative = uint256(latest.priceCumulative) +
            (currentPrice * (block.timestamp - latest.timestamp));

        // Get before cumulative (interpolate if needed)
        uint256 beforeCumulative;
        if (beforeObs.timestamp == afterObs.timestamp || beforeObs.timestamp >= targetTime) {
            beforeCumulative = uint256(beforeObs.priceCumulative);
        } else {
            // Interpolate between before and after
            uint256 observationTimeDelta = afterObs.timestamp - beforeObs.timestamp;
            uint256 targetTimeDelta = targetTime - beforeObs.timestamp;
            uint256 cumulativeDelta = uint256(afterObs.priceCumulative) - uint256(beforeObs.priceCumulative);
            beforeCumulative = uint256(beforeObs.priceCumulative) +
                (cumulativeDelta * targetTimeDelta / observationTimeDelta);
        }

        twap = (currentCumulative - beforeCumulative) / timeElapsed;
    }

    /// @notice Find observations surrounding a target timestamp
    function _getSurroundingObservations(
        OracleState storage state,
        uint256 targetTime
    ) private view returns (Observation memory beforeObs, Observation memory afterObs) {
        // Start from latest and go backwards
        uint16 idx = state.index;

        beforeObs = state.observations[idx];
        afterObs = beforeObs;

        for (uint16 i = 0; i < state.cardinality; i++) {
            Observation memory obs = state.observations[idx];

            if (obs.timestamp <= targetTime) {
                beforeObs = obs;
                break;
            }

            afterObs = obs;

            // Move backwards in ring buffer
            if (idx == 0) {
                idx = state.cardinality - 1;
            } else {
                idx--;
            }
        }
    }

    /// @notice Check if current price deviates significantly from TWAP
    /// @param state Oracle state
    /// @param currentPrice Current spot price
    /// @param longWindow Long TWAP window (e.g., 1 hour)
    /// @param shortWindow Short TWAP window (e.g., 10 minutes)
    /// @param maxDeviation Maximum allowed deviation (1e18 = 100%)
    /// @return manipulated True if price appears manipulated
    function isManipulated(
        OracleState storage state,
        uint256 currentPrice,
        uint256 longWindow,
        uint256 shortWindow,
        uint256 maxDeviation
    ) internal view returns (bool manipulated) {
        uint256 longTwap = getTWAP(state, longWindow, currentPrice);
        uint256 shortTwap = getTWAP(state, shortWindow, currentPrice);

        // Calculate deviation of spot from long TWAP
        uint256 spotDeviation = _calcDeviation(currentPrice, longTwap);

        // Calculate deviation of short TWAP from long TWAP (trend indicator)
        uint256 trendDeviation = _calcDeviation(shortTwap, longTwap);

        // Price is considered manipulated if:
        // 1. Spot deviates significantly from long TWAP, AND
        // 2. Short TWAP hasn't moved much (not a real trend)
        //
        // If it's a real market move, short TWAP will follow spot
        // If it's manipulation, short TWAP won't have time to adjust
        return spotDeviation > maxDeviation && trendDeviation < maxDeviation / 2;
    }

    /// @notice Calculate percentage deviation between two prices
    function _calcDeviation(uint256 a, uint256 b) private pure returns (uint256) {
        if (b == 0) return type(uint256).max;
        if (a > b) {
            return ((a - b) * 1e18) / b;
        } else {
            return ((b - a) * 1e18) / b;
        }
    }
}
