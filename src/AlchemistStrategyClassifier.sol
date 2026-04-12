// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategyClassifier} from "./interfaces/IStrategyClassifier.sol";

/**
 * @title AlchemistStrategyClassifier
 * @notice This contract is used to classify strategies based on their risk level and set the respective caps
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 */
contract AlchemistStrategyClassifier is IStrategyClassifier {
    address public admin;
    address public pendingAdmin;

    /**
     * @notice globalCap is the maximum combined allocation for ALL strategies of this risk type, in WAD (1e18 = 100%).
     * @notice localCap is the maximum allocation for a SINGLE strategy in this risk class, in WAD (1e18 = 100%).
     * @dev Example: MEDIUM with globalCap=0.4e18 and localCap=0.25e18 means each MEDIUM strategy is capped at 25%
     *      of totalAssets individually, and all MEDIUM strategies together cannot exceed 40% of totalAssets.
     */
    struct RiskClass {
        uint256 globalCap; // Max combined allocation for all strategies in this class (WAD)
        uint256 localCap; // Max allocation for a single strategy in this class (WAD)
    }

    /// riskLevel => RiskClass data
    mapping(uint8 => RiskClass) public riskClasses;

    /// strategyId => riskLevel
    mapping(uint256 => uint8) public strategyRiskLevel;

    // ===== Constructor =====
    constructor(address _admin) {
        require(_admin != address(0), "IA");
        admin = _admin;

        // Initialize defaults (can be updated by admin later)
        riskClasses[0] = RiskClass(1e18, 1e18); // Low risk
        riskClasses[1] = RiskClass(4e17, 25e16); // Medium risk
        riskClasses[2] = RiskClass(1e17, 1e17); // High risk

        pendingAdmin = address(0);
    }

    // ===== Admin Management =====

    function transferOwnership(address _newAdmin) external {
        require(msg.sender == admin, "PD");
        pendingAdmin = _newAdmin;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingAdmin, "PD");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminChanged(admin);
    }

    // ===== Risk Class Management =====

    function setRiskClass(uint8 classId, uint256 globalCap, uint256 localCap) external {
        require(msg.sender == admin, "PD");
        riskClasses[classId] = RiskClass(globalCap, localCap);
        emit RiskClassModified(classId, globalCap, localCap);
    }

    function assignStrategyRiskLevel(uint256 strategyId, uint8 riskLevel) external {
        require(msg.sender == admin, "PD");
        strategyRiskLevel[strategyId] = riskLevel;
    }

    // ===== IStrategyClassifier Interface Implementation =====

    /// @notice Returns the maximum allowed allocation for a single strategy (WAD percentage)
    function getIndividualCap(uint256 strategyId) external view override returns (uint256) {
        uint8 riskLevel = strategyRiskLevel[strategyId];
        return riskClasses[riskLevel].localCap;
    }

    /// @notice Returns the maximum allowed combined allocation for all strategies in a risk class (WAD percentage)
    function getGlobalCap(uint8 riskLevel) external view override returns (uint256) {
        return riskClasses[riskLevel].globalCap;
    }

    /// @notice Returns the risk level of a given strategy
    function getStrategyRiskLevel(uint256 strategyId) external view override returns (uint8) {
        return strategyRiskLevel[strategyId];
    }
}
