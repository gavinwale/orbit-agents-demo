// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IMarketCore.sol";
import "./ILPManager.sol";

/**
 * @title IMarketFactory
 * @notice Interface for the market factory with fundraising phase
 * @dev Markets go through: Fundraising -> Trading -> Resolution
 */
interface IMarketFactory {
    // ============ Enums ============

    /// @notice Market lifecycle phases
    enum MarketPhase {
        Fundraising,    // LP providers contribute + set target ratios
        Trading,        // Active trading with time-decaying LP
        Resolved        // Market outcome determined
    }

    // ============ Structs ============

    /// @notice Individual contribution entry (supports multiple per address)
    struct ContributionEntry {
        address provider;        // LP provider address
        uint128 amount;          // USDC amount contributed
        uint64 targetYesRatio;   // Target YES ratio in 1e18
        uint40 depositTime;      // Timestamp of contribution
    }

    /// @notice Market configuration
    struct MarketConfig {
        string question;         // Market question
        uint128 fundingThreshold; // Max funding amount before trading starts
        uint40 fundingDeadline;  // Deadline to reach threshold
        uint40 tradingEndTime;   // When trading ends (resolution can happen)
        address creator;
        MarketPhase phase;
    }

    // ============ Events ============

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint128 fundingThreshold,
        uint40 fundingDeadline,
        uint40 tradingEndTime
    );

    event LPContributed(
        uint256 indexed marketId,
        address indexed provider,
        uint128 amount,
        uint64 targetYesRatio
    );

    event FundraisingCompleted(
        uint256 indexed marketId,
        uint128 totalFunds,
        int24 initialActiveId,
        uint256 initialYesPrice
    );

    event TradingStarted(uint256 indexed marketId, uint40 startTime);

    // ============ Market Creation ============

    /// @notice Create a new market in fundraising phase
    /// @param question Market question
    /// @param fundingThreshold Maximum funding amount
    /// @param fundingDuration How long fundraising lasts (seconds)
    /// @param tradingDuration How long trading lasts after fundraising (seconds)
    /// @return marketId The created market ID
    function createMarket(
        string calldata question,
        uint128 fundingThreshold,
        uint40 fundingDuration,
        uint40 tradingDuration
    ) external returns (uint256 marketId);

    // ============ Fundraising Functions ============

    /// @notice Contribute LP during fundraising phase
    /// @dev Target ratio cannot be 0%, 50%, or 100%
    /// @param marketId Market ID
    /// @param amount USDC amount to contribute
    /// @param targetYesRatio Target YES holding ratio (1e18 precision, must be 1-49% or 51-99%)
    function contributeLiquidity(
        uint256 marketId,
        uint128 amount,
        uint64 targetYesRatio
    ) external;

    /// @notice Complete fundraising and start trading
    /// @dev Can be called once funding threshold is reached or deadline passed
    /// @param marketId Market ID
    function completeFundraising(uint256 marketId) external;

    // ============ View Functions ============

    /// @notice Get market configuration
    function getMarketConfig(uint256 marketId) external view returns (MarketConfig memory);

    /// @notice Get all contributions by a specific provider
    function getProviderContributions(uint256 marketId, address provider) external view returns (ContributionEntry[] memory);

    /// @notice Get total funds raised for a market
    function getTotalFundsRaised(uint256 marketId) external view returns (uint128);

    /// @notice Get calculated opening price (weighted average of LP ratios)
    function getOpeningPrice(uint256 marketId) external view returns (uint256 yesPrice, int24 activeId);

    /// @notice Get all LP providers for a market (legacy)
    function getLPProviders(uint256 marketId) external view returns (address[] memory);

    /// @notice Get all contributions for a market
    function getContributions(uint256 marketId) external view returns (ContributionEntry[] memory);

    /// @notice Get contribution count for a market
    function getContributionCount(uint256 marketId) external view returns (uint256);

    /// @notice Get market core contract
    function marketCore() external view returns (IMarketCore);

    /// @notice Get LP manager contract
    function lpManager() external view returns (ILPManager);
}
