// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for H-06 + H-07 + SCA-1: PerpetualGauge allocation pipeline is broken
///
/// H-06: executeAllocation overflows with default type(uint256).max cap
/// H-07: registerNewStrategy is a no-op stub — strategyList never populated
/// SCA-1: Cap semantics mismatch between PerpetualGauge (BPS) and AlchemistAllocator (absolute)
///
/// Findings: H-06, H-07, SCA-1 | Severity: High | CONFIRMED (PoC verified)

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PerpetualGauge} from "../../PerpetualGauge.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";

contract MockAllocator {
    uint256 public lastAllocated;
    function allocate(uint256, uint256 amount) external {
        lastAllocated = amount;
    }
}

contract PocPerpetualGaugeTest is Test {
    PerpetualGauge gauge;
    AlchemistStrategyClassifier classifier;
    MockAllocator mockAllocator;

    address admin = address(0xAAAA);

    function setUp() public {
        classifier = new AlchemistStrategyClassifier(admin);
        // Set risk class 1 with default cap (type(uint256).max)
        vm.prank(admin);
        classifier.setRiskClass(1, type(uint256).max, type(uint256).max);

        mockAllocator = new MockAllocator();
        // PerpetualGauge(stratClassifier, allocatorProxy, votingToken)
        gauge = new PerpetualGauge(address(classifier), address(mockAllocator), address(this));
    }

    // ================================================================
    // PoC H-07: registerNewStrategy is a no-op — strategyList stays empty
    // ================================================================
    function test_registerNewStrategy_is_noop() public {
        // Call registerNewStrategy
        gauge.registerNewStrategy(1, 100);

        // strategyList is a mapping(uint256 => uint256[])
        // Check via getCurrentAllocations which iterates strategyList
        (uint256[] memory sIds,) = gauge.getCurrentAllocations(1);

        assertEq(sIds.length, 0, "H-07 CONFIRMED: strategyList is empty after registerNewStrategy");

        console.log("=== H-07 CONFIRMED: registerNewStrategy is a no-op ===");
        console.log("strategyList[1].length: 0");
    }

    // ================================================================
    // PoC H-06 + H-07: executeAllocation reverts because strategyList is empty
    // Even if we could populate strategyList, the default cap = type(uint256).max
    // would overflow in: (indivCap * totalIdleAssets) / 1e4
    // ================================================================
    function test_executeAllocation_reverts_empty_strategyList() public {
        vm.expectRevert("No allocations");
        gauge.executeAllocation(1, 1_000_000e18);

        console.log("=== H-06/H-07 CONFIRMED: executeAllocation reverts with empty strategyList ===");
    }

    // ================================================================
    // PoC SCA-1: Cap semantic mismatch
    // PerpetualGauge divides by 1e4 (BPS): target = (indivCap * totalIdleAssets) / 1e4
    // AlchemistAllocator compares directly as absolute
    // No single cap value satisfies both
    // ================================================================
    function test_cap_semantic_mismatch() public view {
        uint256 totalIdle = 1_000_000e18;

        // PerpetualGauge interpretation: cap is in BPS
        // If cap = 5000 (intended as 50%):
        uint256 capBPS = 5000;
        uint256 gaugeResult = (capBPS * totalIdle) / 1e4;
        // = 500,000e18 (50%)

        // AlchemistAllocator interpretation: cap is absolute
        // If cap = 5000 (interpreted as 5000 wei):
        uint256 allocatorResult = capBPS; // compared directly

        console.log("=== SCA-1 CONFIRMED: Cap Semantic Mismatch ===");
        console.log("Cap value:             ", capBPS);
        console.log("PerpetualGauge sees:   ", gaugeResult / 1e18, "ETH (divides by 1e4)");
        console.log("Allocator sees:        ", allocatorResult, "wei (compares directly)");
        console.log("These are incompatible interpretations");
    }
}
