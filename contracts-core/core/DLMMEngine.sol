// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/IDLMMEngine.sol";
import "../libraries/Constants.sol";
import "../libraries/PriceMath.sol";
import "../libraries/ProbabilityMath.sol";
import "../libraries/FeeHelper.sol";

/**
 * @title DLMMEngine
 * @notice Singleton trading engine for prediction markets (UUPS upgradeable)
 * @dev Contains all price/probability calculations and fee logic
 *      Deployed once and shared by all markets
 */
contract DLMMEngine is IDLMMEngine, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ============ Constants ============

    /// @notice Fixed bin step for all markets (10 basis points = 0.1%)
    uint16 public constant BIN_STEP = 10;

    // ============ State Variables ============

    /// @notice Global fee parameters
    FeeHelper.FeeParameters public feeParameters;

    /// @notice Protocol fee recipient
    address public feeRecipient;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the engine
    function initialize(
        uint16 _baseFactor,
        uint16 _filterPeriod,
        uint16 _decayPeriod,
        uint16 _reductionFactor,
        uint24 _variableFeeControl,
        uint16 _protocolShare,
        uint24 _maxVolatilityAccumulator,
        address _feeRecipient
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_feeRecipient != address(0), "Engine: ZERO_ADDRESS");
        require(_protocolShare <= Constants.MAX_PROTOCOL_SHARE, "Engine: INVALID_PROTOCOL_SHARE");

        feeParameters = FeeHelper.FeeParameters({
            binStep: BIN_STEP,
            baseFactor: _baseFactor,
            filterPeriod: _filterPeriod,
            decayPeriod: _decayPeriod,
            reductionFactor: _reductionFactor,
            variableFeeControl: _variableFeeControl,
            protocolShare: _protocolShare,
            maxVolatilityAccumulator: _maxVolatilityAccumulator
        });

        feeRecipient = _feeRecipient;
    }

    // ============ UUPS Upgrade ============

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Price/Probability Functions (Pure) ============

    /// @inheritdoc IDLMMEngine
    function getPriceFromId(int24 id) external pure override returns (uint256 price) {
        return PriceMath.getPriceFromId(BIN_STEP, id);
    }

    /// @inheritdoc IDLMMEngine
    function getProbabilityFromId(int24 id) external pure override returns (uint256 probability) {
        return ProbabilityMath.getProbabilityFromBin(BIN_STEP, id);
    }

    /// @inheritdoc IDLMMEngine
    function getBinIdForSlot(uint256 slot) external pure override returns (int24 binId) {
        return ProbabilityMath.getBinIdForSlot(slot);
    }

    /// @inheritdoc IDLMMEngine
    function isValidBinId(int24 id) external pure override returns (bool valid) {
        return ProbabilityMath.isValidPredictionBin(id);
    }

    /// @inheritdoc IDLMMEngine
    function getIdFromPrice(uint256 price) external pure override returns (int24 id) {
        return PriceMath.getIdFromPrice(BIN_STEP, price);
    }

    // ============ Fee Functions ============

    /// @inheritdoc IDLMMEngine
    function getTotalFee(uint24 volatilityAccumulator) external view override returns (uint128 totalFee) {
        return FeeHelper.getTotalFee(feeParameters, volatilityAccumulator);
    }

    /// @inheritdoc IDLMMEngine
    function calculateFee(uint128 amountIn, uint24 volatilityAccumulator) external view override returns (uint128 fee) {
        uint128 totalFee = FeeHelper.getTotalFee(feeParameters, volatilityAccumulator);
        return FeeHelper.getFeeAmount(amountIn, totalFee);
    }

    /// @inheritdoc IDLMMEngine
    function getProtocolFee(uint128 fee) external view override returns (uint128 protocolFee) {
        return FeeHelper.getProtocolFee(fee, feeParameters.protocolShare);
    }

    // ============ Swap Calculation Functions ============

    /// @inheritdoc IDLMMEngine
    function calculateSwapOut(
        uint128 amountIn,
        bool swapForY,
        int24 currentActiveId,
        BinData[] calldata bins
    ) external view override returns (SwapResult memory result) {
        result.binUpdates = new BinUpdate[](bins.length);

        uint128 amountInLeft = amountIn;
        int24 activeId = currentActiveId;
        uint256 binIndex = _findBinIndex(bins, activeId);

        uint256 updateCount = 0;

        while (amountInLeft > 0 && binIndex < bins.length) {
            BinData memory bin = bins[binIndex];

            if (!ProbabilityMath.isValidPredictionBin(bin.binId)) break;

            uint256 price = PriceMath.getPriceFromId(BIN_STEP, bin.binId);

            (uint128 binAmountOut, uint128 binAmountIn) = ProbabilityMath.getSwapAmount(
                price,
                bin.reserveX,
                bin.reserveY,
                amountInLeft,
                swapForY
            );

            if (binAmountOut > 0) {
                // Record bin update
                result.binUpdates[updateCount] = BinUpdate({
                    binId: bin.binId,
                    deltaX: swapForY ? int128(binAmountIn) : -int128(binAmountOut),
                    deltaY: swapForY ? -int128(binAmountOut) : int128(binAmountIn)
                });
                updateCount++;

                result.amountOut += binAmountOut;
                result.amountInUsed += binAmountIn;
                amountInLeft -= binAmountIn;
                activeId = bin.binId;
            }

            // Move to next bin if needed
            if (amountInLeft > 0) {
                binIndex++;
            }
        }

        result.newActiveId = activeId;

        // Resize binUpdates array
        assembly {
            mstore(mload(add(result, 128)), updateCount) // result.binUpdates.length = updateCount
        }
    }

    /// @inheritdoc IDLMMEngine
    function calculateSwapIn(
        uint128 amountOut,
        bool swapForY,
        int24 currentActiveId,
        BinData[] calldata bins
    ) external view override returns (uint128 amountIn, uint128 fee) {
        uint128 amountOutLeft = amountOut;
        uint256 binIndex = _findBinIndex(bins, currentActiveId);

        while (amountOutLeft > 0 && binIndex < bins.length) {
            BinData memory bin = bins[binIndex];

            if (!ProbabilityMath.isValidPredictionBin(bin.binId)) break;

            uint256 price = PriceMath.getPriceFromId(BIN_STEP, bin.binId);

            // Calculate available output
            uint128 availableOut = swapForY ? bin.reserveY : bin.reserveX;
            uint128 binAmountOut = amountOutLeft > availableOut ? availableOut : amountOutLeft;

            if (binAmountOut > 0) {
                // Calculate required input
                uint128 binAmountIn;
                if (swapForY) {
                    // YES -> NO: amountIn = amountOut / price
                    binAmountIn = uint128(PriceMath._mulDiv(uint256(binAmountOut), Constants.SCALE, price) + 1);
                } else {
                    // NO -> YES: amountIn = amountOut * price
                    binAmountIn = uint128(PriceMath._mulDiv(uint256(binAmountOut), price, Constants.SCALE) + 1);
                }

                amountIn += binAmountIn;
                amountOutLeft -= binAmountOut;
            }

            if (amountOutLeft > 0) {
                binIndex++;
            }
        }

        // Add fee
        uint128 totalFee = FeeHelper.getTotalFee(feeParameters, 0);
        fee = FeeHelper.getFeeAmountWithComposition(amountIn, totalFee);
        amountIn += fee;
    }

    // ============ Volatility Functions ============

    /// @inheritdoc IDLMMEngine
    function calculateVolatilityUpdate(
        FeeHelper.VolatilityParameters calldata currentParams,
        int24 activeId
    ) external view override returns (uint24 newVolatilityAccumulator, uint24 newVolatilityReference) {
        uint24 unsignedActiveId = uint24(uint256(int256(activeId) + 8388608));
        (newVolatilityAccumulator, newVolatilityReference) = FeeHelper.updateVolatilityAccumulator(
            feeParameters,
            currentParams,
            unsignedActiveId
        );
    }

    // ============ Admin Functions ============

    /// @inheritdoc IDLMMEngine
    function setFeeParameters(
        uint16 _baseFactor,
        uint16 _filterPeriod,
        uint16 _decayPeriod,
        uint16 _reductionFactor,
        uint24 _variableFeeControl,
        uint16 _protocolShare,
        uint24 _maxVolatilityAccumulator
    ) external override onlyOwner {
        require(_protocolShare <= Constants.MAX_PROTOCOL_SHARE, "Engine: INVALID_PROTOCOL_SHARE");

        feeParameters.baseFactor = _baseFactor;
        feeParameters.filterPeriod = _filterPeriod;
        feeParameters.decayPeriod = _decayPeriod;
        feeParameters.reductionFactor = _reductionFactor;
        feeParameters.variableFeeControl = _variableFeeControl;
        feeParameters.protocolShare = _protocolShare;
        feeParameters.maxVolatilityAccumulator = _maxVolatilityAccumulator;

        emit FeeParametersSet(
            msg.sender,
            _baseFactor,
            _filterPeriod,
            _decayPeriod,
            _reductionFactor,
            _variableFeeControl,
            _protocolShare,
            _maxVolatilityAccumulator
        );
    }

    /// @inheritdoc IDLMMEngine
    function setFeeRecipient(address newRecipient) external override onlyOwner {
        require(newRecipient != address(0), "Engine: ZERO_ADDRESS");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientSet(oldRecipient, newRecipient);
    }

    // ============ Internal Functions ============

    /// @dev Find the index of bin with given binId in sorted array
    function _findBinIndex(BinData[] calldata bins, int24 targetBinId) internal pure returns (uint256) {
        for (uint256 i = 0; i < bins.length; i++) {
            if (bins[i].binId == targetBinId) {
                return i;
            }
        }
        return 0;
    }
}
