// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reproduction of H-06, H-07, H-08: PerpetualGauge bugs
/// H-06: executeAllocation overflows with default type(uint256).max cap
/// H-07: registerNewStrategy is a no-op — strategyList never populated
/// H-08: Cap semantics mismatch (BPS vs absolute)

contract SimStrategyClassifier {
    mapping(uint256 => uint256) public individualCap;
    mapping(uint8 => uint256) public globalCap;
    mapping(uint256 => uint8) public riskLevel;

    constructor() {
        // Default caps = type(uint256).max, matching AlchemistStrategyClassifier
        individualCap[1] = type(uint256).max;
        globalCap[1] = type(uint256).max;
        riskLevel[1] = 1;
    }

    function setRiskClass(uint256 stratId, uint256 indivCap, uint256 globCap) external {
        individualCap[stratId] = indivCap;
        globalCap[riskLevel[stratId]] = globCap;
    }

    function getIndividualCap(uint256 stratId) external view returns (uint256) {
        return individualCap[stratId];
    }
    function getGlobalCap(uint8 risk) external view returns (uint256) {
        return globalCap[risk];
    }
    function getStrategyRiskLevel(uint256 stratId) external view returns (uint8) {
        return riskLevel[stratId];
    }
}

contract SimPerpetualGauge {
    SimStrategyClassifier public classifier;
    mapping(uint256 => uint256[]) public strategyList;

    uint256 public lastStrategyAddedAt;

    constructor(address _classifier) {
        classifier = SimStrategyClassifier(_classifier);
    }

    function registerNewStrategy(uint256 ytId, uint256 strategyId) external {
        lastStrategyAddedAt = block.timestamp;
        // TODO — bug: strategyList is never populated
    }

    function getStrategyListLength(uint256 ytId) external view returns (uint256) {
        return strategyList[ytId].length;
    }

    /// @notice Demonstrates the overflow: (indivCap * totalIdleAssets) / 1e4
    function testOverflow(uint256 totalIdleAssets) external view returns (uint256) {
        uint256 indivCap = classifier.getIndividualCap(1);
        // This will revert with checked arithmetic overflow when indivCap = type(uint256).max
        return (indivCap * totalIdleAssets) / 1e4;
    }

    /// @notice Shows the cap semantic mismatch
    function capAsBPS(uint256 capValue, uint256 totalAssets) external pure returns (uint256) {
        return (capValue * totalAssets) / 1e4; // PerpetualGauge interpretation
    }

    function capAsAbsolute(uint256 capValue) external pure returns (uint256) {
        return capValue; // AlchemistAllocator interpretation
    }
}
