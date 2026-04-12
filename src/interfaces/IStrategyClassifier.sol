// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

/// @notice Simple interface for DAO-defined percentage-based caps storage (WAD: 1e18 = 100%)
interface IStrategyClassifier {
    function getIndividualCap(uint256 strategyId) external view returns (uint256); // WAD percentage of totalAssets
    function getGlobalCap(uint8 riskLevel) external view returns (uint256); // WAD percentage of totalAssets
    function getStrategyRiskLevel(uint256 strategyId) external view returns (uint8);
    event AdminChanged(address indexed admin);
    event RiskClassModified(uint256 indexed class, uint256 indexed globalCap, uint256 indexed localCap);
}
