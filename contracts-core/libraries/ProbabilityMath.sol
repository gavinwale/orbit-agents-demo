// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";
import "./PriceMath.sol";

/**
 * @title ProbabilityMath
 * @notice Library for prediction market probability calculations
 * @dev Prediction Market Pricing Model (Meteora-style):
 *
 *      Core Concept:
 *      - Pool quote: 1 YES = R NO (R is exchange ratio/price)
 *      - Price R = (1 + binStep/10000)^binId (standard DLMM formula)
 *      - CDT principle: 1 USDC = 1 YES + 1 NO (mint/redeem)
 *      - YES probability: P_yes = R / (1 + R)
 *      - YES odds = (1 + R) / R (e.g., R=2 → odds=1.5 → P_yes=66.67%)
 *
 *      Bin ID Design (Meteora-style, binId 0 = price 1):
 *      - binId = 0  → R = 1     → P_yes = 50%
 *      - binId > 0  → R > 1     → P_yes > 50% (YES more valuable, higher probability)
 *      - binId < 0  → R < 1     → P_yes < 50% (YES less valuable, lower probability)
 *
 *      For 1% probability steps with binStep=10:
 *      - P_yes = 1%   → R ≈ 0.0101 → binId ≈ -4600
 *      - P_yes = 50%  → R = 1      → binId = 0
 *      - P_yes = 99%  → R ≈ 99     → binId ≈ +4600
 */
library ProbabilityMath {
    /// @notice Get YES probability from price (exchange ratio)
    /// @dev P_yes = R / (1 + R) = price / (SCALE + price)
    /// @param price Price/exchange ratio in 128.128 fixed point (1 YES = R NO)
    /// @return probability YES probability in 1e18 precision
    function getProbabilityFromPrice(uint256 price) internal pure returns (uint256 probability) {
        // P_yes = R / (1 + R) = price / (SCALE + price)
        // In 1e18 precision: P_yes = price * 1e18 / (SCALE + price)
        probability = PriceMath._mulDiv(price, Constants.PRECISION, Constants.SCALE + price);
    }

    /// @notice Get price (exchange ratio) from YES probability
    /// @dev R = P_yes / (1 - P_yes)
    /// @param probability YES probability in 1e18 precision
    /// @return price Price in 128.128 fixed point
    function getPriceFromProbability(uint256 probability) internal pure returns (uint256 price) {
        require(probability > 0 && probability < Constants.PRECISION, "ProbMath: INVALID_PROB");
        // R = P_yes / (1 - P_yes)
        // price = probability * SCALE / (PRECISION - probability)
        price = PriceMath._mulDiv(probability, Constants.SCALE, Constants.PRECISION - probability);
    }

    /// @notice Get YES probability from bin ID
    /// @param binStep Bin step in basis points
    /// @param binId Bin ID (can be negative)
    /// @return probability YES probability in 1e18 precision
    function getProbabilityFromBin(uint16 binStep, int24 binId) internal pure returns (uint256 probability) {
        uint256 price = PriceMath.getPriceFromId(binStep, binId);
        probability = getProbabilityFromPrice(price);
    }

    /// @notice Get bin ID from YES probability
    /// @param binStep Bin step in basis points
    /// @param probability YES probability in 1e18 precision
    /// @return binId Bin ID
    function getBinFromProbability(uint16 binStep, uint256 probability) internal pure returns (int24 binId) {
        uint256 price = getPriceFromProbability(probability);
        binId = PriceMath.getIdFromPrice(binStep, price);
    }

    /// @notice Get bin ID from YES odds
    /// @dev YES odds O = (1+R)/R, so P_yes = 1/O = R/(1+R)
    /// @param binStep Bin step in basis points
    /// @param odds YES odds in 1e18 precision (e.g., 1.5e18 for 1.5x odds means 66.67% YES probability)
    /// @return binId Bin ID
    function getBinFromOdds(uint16 binStep, uint256 odds) internal pure returns (int24 binId) {
        require(odds > Constants.PRECISION, "ProbMath: ODDS_TOO_LOW"); // odds must be > 1
        // P_yes = 1/O
        uint256 probability = Constants.PRECISION * Constants.PRECISION / odds;
        return getBinFromProbability(binStep, probability);
    }

    /// @notice Calculate swap output amount within a single bin
    /// @dev At price R (1 YES = R NO):
    ///      - Swapping YES for NO: amountOut = amountIn * R
    ///      - Swapping NO for YES: amountOut = amountIn / R
    /// @param price Current price in 128.128 fixed point
    /// @param reserveYes Reserve of YES tokens
    /// @param reserveNo Reserve of NO tokens
    /// @param amountIn Amount of input token
    /// @param swapYesForNo True if swapping YES for NO
    /// @return amountOut Output amount
    /// @return amountInUsed Amount of input actually used
    function getSwapAmount(
        uint256 price,
        uint128 reserveYes,
        uint128 reserveNo,
        uint128 amountIn,
        bool swapYesForNo
    ) internal pure returns (uint128 amountOut, uint128 amountInUsed) {
        if (amountIn == 0) return (0, 0);

        if (swapYesForNo) {
            // YES -> NO: amountOut = amountIn * R
            if (reserveNo == 0) return (0, 0);

            uint256 theoreticalOut = PriceMath._mulDiv(uint256(amountIn), price, Constants.SCALE);

            if (theoreticalOut > reserveNo) {
                // Not enough NO reserve, consume what we can
                amountOut = reserveNo;
                // How much YES needed for this NO? = NO / R
                amountInUsed = uint128(PriceMath._mulDiv(uint256(reserveNo), Constants.SCALE, price) + 1);
                if (amountInUsed > amountIn) amountInUsed = amountIn;
            } else {
                amountOut = uint128(theoreticalOut);
                amountInUsed = amountIn;
            }
        } else {
            // NO -> YES: amountOut = amountIn / R
            if (reserveYes == 0) return (0, 0);

            uint256 theoreticalOut = PriceMath._mulDiv(uint256(amountIn), Constants.SCALE, price);

            if (theoreticalOut > reserveYes) {
                // Not enough YES reserve
                amountOut = reserveYes;
                // How much NO needed for this YES? = YES * R
                amountInUsed = uint128(PriceMath._mulDiv(uint256(reserveYes), price, Constants.SCALE) + 1);
                if (amountInUsed > amountIn) amountInUsed = amountIn;
            } else {
                amountOut = uint128(theoreticalOut);
                amountInUsed = amountIn;
            }
        }
    }

    /// @notice Calculate liquidity from reserves
    /// @dev L = reserveYes + reserveNo / R = reserveYes + reserveNo * SCALE / price
    /// @param price Current price in 128.128 fixed point
    /// @param reserveYes Reserve of YES tokens
    /// @param reserveNo Reserve of NO tokens
    /// @return liquidity Total liquidity (normalized to YES terms)
    function getLiquidity(
        uint256 price,
        uint128 reserveYes,
        uint128 reserveNo
    ) internal pure returns (uint256 liquidity) {
        // L = reserveYes + reserveNo / R
        uint256 noInYesTerms = PriceMath._mulDiv(uint256(reserveNo), Constants.SCALE, price);
        liquidity = uint256(reserveYes) + noInYesTerms;
    }

    /// @notice Calculate how much output corresponds to given share fraction
    /// @param reserveYes YES token reserve
    /// @param reserveNo NO token reserve
    /// @param shareFraction User's share fraction in 1e18 precision
    /// @return amountYes YES tokens to return
    /// @return amountNo NO tokens to return
    function getAmountsFromShares(
        uint128 reserveYes,
        uint128 reserveNo,
        uint256 shareFraction
    ) internal pure returns (uint128 amountYes, uint128 amountNo) {
        if (shareFraction == 0) {
            return (0, 0);
        }

        // Proportional withdrawal
        amountYes = uint128((uint256(reserveYes) * shareFraction) / Constants.PRECISION);
        amountNo = uint128((uint256(reserveNo) * shareFraction) / Constants.PRECISION);
    }

    /// @notice Check if bin ID is a valid discrete probability bin
    /// @dev Valid bins are those that map to a 1% probability step (1%, 2%, ..., 99%)
    ///      A binId is valid if it equals the canonical binId for some probability slot
    /// @param binId Bin ID to check
    /// @return valid True if bin ID corresponds to a valid 1% probability step
    function isValidPredictionBin(int24 binId) internal pure returns (bool valid) {
        // First check basic range
        if (binId < Constants.MIN_PREDICTION_BIN_ID || binId > Constants.MAX_PREDICTION_BIN_ID) {
            return false;
        }

        // Get the probability for this binId
        uint256 price = PriceMath.getPriceFromId(Constants.DEFAULT_BIN_STEP, binId);
        uint256 probability = getProbabilityFromPrice(price);

        // Check if probability is within valid range (1% to 99%)
        if (probability < Constants.MIN_PROBABILITY || probability > Constants.MAX_PROBABILITY) {
            return false;
        }

        // Find the nearest slot for this probability
        // Use rounding to find nearest slot
        uint256 slot;
        if (probability >= Constants.MIN_PROBABILITY) {
            slot = (probability - Constants.MIN_PROBABILITY + Constants.PROB_STEP / 2) / Constants.PROB_STEP;
        }

        // Clamp to valid range
        if (slot >= Constants.TOTAL_PREDICTION_BINS) {
            slot = Constants.TOTAL_PREDICTION_BINS - 1;
        }

        // Get the canonical binId for this slot
        uint256 slotProb = Constants.MIN_PROBABILITY + slot * Constants.PROB_STEP;
        int24 canonicalBinId = getBinFromProbability(Constants.DEFAULT_BIN_STEP, slotProb);

        // The binId is valid if it matches the canonical binId for its slot
        return binId == canonicalBinId;
    }

    /// @notice Get the valid bin ID for a given YES probability slot (0-98)
    /// @param slot YES probability slot (0 = 1% YES, 1 = 2% YES, ..., 49 = 50% YES, ..., 98 = 99% YES)
    /// @return binId The valid bin ID for this slot
    function getBinIdForSlot(uint256 slot) internal pure returns (int24 binId) {
        require(slot < Constants.TOTAL_PREDICTION_BINS, "ProbMath: INVALID_SLOT");
        uint256 probability = Constants.MIN_PROBABILITY + slot * Constants.PROB_STEP;
        return getBinFromProbability(Constants.DEFAULT_BIN_STEP, probability);
    }

    /// @notice Get the YES probability slot for a bin ID
    /// @param binId Bin ID
    /// @return slot YES probability slot (0-98)
    function getSlotForBinId(int24 binId) internal pure returns (uint256 slot) {
        uint256 price = PriceMath.getPriceFromId(Constants.DEFAULT_BIN_STEP, binId);
        uint256 probability = getProbabilityFromPrice(price);
        require(probability >= Constants.MIN_PROBABILITY && probability <= Constants.MAX_PROBABILITY, "ProbMath: OUT_OF_RANGE");
        slot = (probability - Constants.MIN_PROBABILITY + Constants.PROB_STEP / 2) / Constants.PROB_STEP;
        if (slot >= Constants.TOTAL_PREDICTION_BINS) {
            slot = Constants.TOTAL_PREDICTION_BINS - 1;
        }
    }
}
