// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SimPhantomSynthetics} from "../src/SimH01_PhantomSynthetics.sol";
import {SimDualOracle, SimFrxAdapter, SimOracleConsumer} from "../src/SimH02_OracleTimestamp.sol";
import {SimMYTStrategy, SimEtherfiStrategy, SimEtherfiStrategyFixed} from "../src/SimH04_EtherfiProtectedToken.sol";
import {SimStrategyClassifier, SimPerpetualGauge} from "../src/SimH06H07_PerpetualGauge.sol";
import {SimRetroactiveParams} from "../src/SimH05_RetroactiveParams.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _sym) { name = _name; symbol = _sym; }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AnvilReconciliationTest is Test {

    // ================================================================
    //  H-01: PHANTOM totalSyntheticsIssued - THE KEY DISPUTE
    //  Plamen: Bug. Codex: REFUTED. Gemini: PARTIALLY CONFIRMED.
    // ================================================================

    function test_H01_phantom_synthetics_accounting_divergence() public {
        SimPhantomSynthetics sim = new SimPhantomSynthetics();

        // User deposits 100 MYT and mints 90 synthetic debt
        sim.deposit(100e18);
        sim.mint(90e18);

        assertEq(sim.totalDebt(), 90e18);
        assertEq(sim.totalSyntheticsIssued(), 90e18);
        assertEq(sim.alchemistMYTBalance(), 100e18);

        console.log("=== H-01: Before selfLiquidate ===");
        console.log("totalDebt:            ", sim.totalDebt());
        console.log("totalSyntheticsIssued:", sim.totalSyntheticsIssued());
        console.log("alchemist MYT:        ", sim.alchemistMYTBalance());
        console.log("transmuter MYT:       ", sim.transmuterMYTBalance());

        // selfLiquidate: debt cleared, MYT moves to transmuter
        sim.selfLiquidate(90e18);

        console.log("\n=== H-01: After selfLiquidate ===");
        console.log("totalDebt:            ", sim.totalDebt());
        console.log("totalSyntheticsIssued:", sim.totalSyntheticsIssued());
        console.log("alchemist MYT:        ", sim.alchemistMYTBalance());
        console.log("transmuter MYT:       ", sim.transmuterMYTBalance());

        // FACT 1: totalDebt = 0, totalSyntheticsIssued = 90e18 (Plamen is RIGHT about the divergence)
        assertEq(sim.totalDebt(), 0, "totalDebt should be 0");
        assertEq(sim.totalSyntheticsIssued(), 90e18, "totalSyntheticsIssued unchanged - DIVERGENCE CONFIRMED");

        // FACT 2: Plamen's bad debt check (ignoring Transmuter) -> TRUE = bricked
        bool plamenBadDebt = sim.isProtocolInBadDebt_plamenVersion();
        console.log("\nPlamen bad debt (ignoring Transmuter):", plamenBadDebt);
        assertTrue(plamenBadDebt, "Plamen version says bad debt (ignoring transmuter MYT)");

        // FACT 3: Actual code bad debt check (includes Transmuter) -> FALSE = NOT bricked
        bool actualBadDebt = sim.isProtocolInBadDebt_actualCode();
        console.log("Actual bad debt (with Transmuter):    ", actualBadDebt);
        assertFalse(actualBadDebt, "Actual code: NOT bad debt because transmuter MYT counted as backing");

        console.log("\n=== H-01 RECONCILIATION ===");
        console.log("Code fact (divergence): CONFIRMED - Plamen is right that _subDebt does not touch totalSyntheticsIssued");
        console.log("Impact claim (brick):   REFUTED  - Codex is right that _isProtocolInBadDebt includes transmuter backing");
        console.log("VERDICT: PARTIALLY CONFIRMED. Accounting hygiene issue, NOT a protocol brick.");
    }

    function test_H01_edge_case_transmuter_drains_then_brick() public {
        SimPhantomSynthetics sim = new SimPhantomSynthetics();

        sim.deposit(100e18);
        sim.mint(90e18);
        sim.selfLiquidate(90e18);

        // Now simulate: transmuter processes redemptions, MYT leaves transmuter
        // (users claim their underlying from transmuter)
        sim.transmuterMYTBalance; // 90e18 in transmuter
        // We can't modify transmuterMYTBalance directly, but in the real protocol:
        // If transmuter processes redemptions and sends MYT out, transmuterMYTBalance drops.
        // In that case, backingDebt drops and isProtocolInBadDebt would return true.

        console.log("=== H-01 EDGE CASE: Post-Transmuter Redemption ===");
        console.log("If Transmuter redeems all MYT -> backing = 0 -> totalSyntheticsIssued=90 > 0 -> BAD DEBT");
        console.log("This means: the accounting divergence DOES matter over the Transmuter lifecycle.");
        console.log("But the immediate 'brick after liquidation' claim is wrong.");
        console.log("The real risk is: after Transmuter cycle completes, phantom issuance persists.");
    }

    // ================================================================
    //  H-02: DUAL ORACLE TIMESTAMP FABRICATION - ALL THREE AGREE
    // ================================================================

    function test_H02_oracle_timestamp_fabrication() public {
        SimDualOracle dual = new SimDualOracle(0.998e18, 1.000e18);
        SimFrxAdapter adapter = new SimFrxAdapter(address(dual));
        SimOracleConsumer consumer = new SimOracleConsumer(address(adapter));

        // At current block: staleness = 0
        (, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
        uint256 staleness = block.timestamp - updatedAt;

        console.log("=== H-02: Oracle Timestamp Fabrication ===");
        console.log("block.timestamp:", block.timestamp);
        console.log("updatedAt:      ", updatedAt);
        console.log("staleness:      ", staleness);

        assertEq(updatedAt, block.timestamp, "CONFIRMED: updatedAt fabricated as block.timestamp");
        assertEq(staleness, 0, "CONFIRMED: staleness always 0");

        // Warp 30 days - oracle should be stale, but still reports fresh
        vm.warp(block.timestamp + 30 days);

        (int256 price30d, uint256 age30d, bool staleDetected) = consumer.checkPrice();

        console.log("\nAfter 30 days:");
        console.log("Age reported:   ", age30d);
        console.log("Stale detected: ", staleDetected);

        assertEq(age30d, 0, "CONFIRMED: 30 days later, still reports 0 age");
        assertFalse(staleDetected, "CONFIRMED: stale price NEVER detected");

        console.log("\n=== H-02 VERDICT: CONFIRMED by all three reports. Real High. ===");
    }

    function test_H02_spread_validation_missing_H09() public {
        // Extreme spread: one oracle says 0.5e18, other says 1.5e18
        SimDualOracle dual = new SimDualOracle(0.5e18, 1.5e18);
        SimFrxAdapter adapter = new SimFrxAdapter(address(dual));

        (, int256 answer,,,) = adapter.latestRoundData();
        uint256 avgPrice = uint256(answer);

        console.log("=== H-09/M-26: Spread Validation Missing ===");
        console.log("priceLow:     %d", uint256(0.5e18));
        console.log("priceHigh:    %d", uint256(1.5e18));
        console.log("Spread:       200 percent");
        console.log("Average used: %d", avgPrice);

        assertEq(avgPrice, 1e18, "Average of wildly divergent prices used without spread check");
        console.log("CONFIRMED: No spread validation - 200% divergence accepted silently");
    }

    // ================================================================
    //  H-04: ETHERFI MISSING _isProtectedToken - ALL THREE AGREE
    // ================================================================

    function test_H04_etherfi_missing_protected_token() public {
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockERC20 weETH = new MockERC20("weETH", "weETH");

        address owner = address(0xAD);
        address attacker = address(0xBAD);

        SimEtherfiStrategy strategy = new SimEtherfiStrategy(owner, address(weth), address(weETH));

        // Simulate strategy holding 100 weETH
        weETH.mint(address(strategy), 100e18);

        console.log("=== H-04: EtherFi Missing _isProtectedToken ===");
        console.log("Strategy weETH balance:", weETH.balanceOf(address(strategy)));

        // Owner rescues weETH - should fail but does not
        vm.prank(owner);
        strategy.rescueTokens(address(weETH), attacker, 100e18);

        console.log("After rescue:");
        console.log("Strategy weETH:", weETH.balanceOf(address(strategy)));
        console.log("Attacker weETH:", weETH.balanceOf(attacker));

        assertEq(weETH.balanceOf(address(strategy)), 0, "CONFIRMED: weETH fully drained");
        assertEq(weETH.balanceOf(attacker), 100e18, "CONFIRMED: attacker got all weETH");

        // Contrast: WETH IS protected
        weth.mint(address(strategy), 50e18);
        vm.prank(owner);
        vm.expectRevert("Protected token");
        strategy.rescueTokens(address(weth), attacker, 50e18);

        console.log("WETH rescue: REVERTED (correctly protected)");

        // Test the fix
        SimEtherfiStrategyFixed fixedStrategy = new SimEtherfiStrategyFixed(owner, address(weth), address(weETH));
        weETH.mint(address(fixedStrategy), 100e18);

        vm.prank(owner);
        vm.expectRevert("Protected token");
        fixedStrategy.rescueTokens(address(weETH), attacker, 100e18);

        console.log("Fixed strategy weETH rescue: REVERTED (correctly protected)");
        console.log("\n=== H-04 VERDICT: CONFIRMED. All three reports agree. ===");
    }

    // ================================================================
    //  H-05: RETROACTIVE PARAM CHANGES - Dispute on severity
    // ================================================================

    function test_H05_retroactive_collateralization() public {
        SimRetroactiveParams sim = new SimRetroactiveParams(
            1.05e18,  // collateralizationLowerBound = 105%
            1.11e18   // minimumCollateralization = 111%
        );

        // Alice creates position: 111 collateral, 100 debt -> ratio = 111%
        uint256 posId = sim.createPosition(111e18, 100e18);

        bool healthyBefore = sim.isHealthy(posId);
        uint256 ratioBefore = sim.getRatio(posId);

        console.log("=== H-05: Retroactive Collateralization ===");
        console.log("Position ratio:   ", ratioBefore);
        console.log("Lower bound:      ", sim.collateralizationLowerBound());
        console.log("Healthy before:   ", healthyBefore);

        assertTrue(healthyBefore, "Position is healthy before param change");

        // Admin instantly raises lower bound to 130% - no timelock!
        sim.setCollateralizationLowerBound(1.30e18);

        bool healthyAfter = sim.isHealthy(posId);
        console.log("\nAfter admin raises lowerBound to 130%:");
        console.log("New lower bound:  ", sim.collateralizationLowerBound());
        console.log("Position ratio:   ", sim.getRatio(posId)); // still 111%
        console.log("Healthy after:    ", healthyAfter);

        assertFalse(healthyAfter, "CONFIRMED: Position instantly unhealthy after param change");

        console.log("\n=== H-05 RECONCILIATION ===");
        console.log("Retroactive param change: CONFIRMED - no timelock, no grace period");
        console.log("Mass liquidation risk:    CONFIRMED");
        console.log("Protocol brick via H-01:  DISPUTED - Codex says Transmuter backing prevents brick");
        console.log("VERDICT: Medium (admin abuse/centralization), not High (protocol brick)");
    }

    // ================================================================
    //  H-06/H-07: PERPETUAL GAUGE - ALL THREE AGREE ON CODE FACTS
    // ================================================================

    function test_H06_gauge_overflow() public {
        SimStrategyClassifier classifier = new SimStrategyClassifier();
        SimPerpetualGauge gauge = new SimPerpetualGauge(address(classifier));

        console.log("=== H-06: executeAllocation Overflow ===");
        console.log("Default indivCap:", classifier.getIndividualCap(1));

        // type(uint256).max * any_nonzero_value overflows in Solidity 0.8
        vm.expectRevert();
        gauge.testOverflow(1_000_000e18);

        console.log("CONFIRMED: Overflow reverts with default cap");
        console.log("Codex/Gemini note: NOT permanent - admin can set finite caps");
    }

    function test_H07_registerNewStrategy_noop() public {
        SimStrategyClassifier classifier = new SimStrategyClassifier();
        SimPerpetualGauge gauge = new SimPerpetualGauge(address(classifier));

        gauge.registerNewStrategy(1, 100);

        uint256 listLen = gauge.getStrategyListLength(1);
        assertEq(listLen, 0, "CONFIRMED: strategyList empty after registerNewStrategy");

        console.log("=== H-07: registerNewStrategy is a no-op ===");
        console.log("strategyList length after register:", listLen);
        console.log("CONFIRMED: TODO comment, never populates list");
    }

    function test_H08_cap_semantic_mismatch() public {
        SimStrategyClassifier classifier = new SimStrategyClassifier();
        SimPerpetualGauge gauge = new SimPerpetualGauge(address(classifier));

        uint256 capValue = 5000; // Intended as 50% BPS
        uint256 totalAssets = 1_000_000e18;

        uint256 gaugeInterpretation = gauge.capAsBPS(capValue, totalAssets);
        uint256 allocatorInterpretation = gauge.capAsAbsolute(capValue);

        console.log("=== H-08: Cap Semantic Mismatch ===");
        console.log("Cap value:          ", capValue);
        console.log("Gauge (BPS):        ", gaugeInterpretation);
        console.log("Allocator (absolute):", allocatorInterpretation);
        console.log("Gauge sees 500K ETH, Allocator sees 5000 wei - INCOMPATIBLE");

        assertTrue(gaugeInterpretation != allocatorInterpretation, "CONFIRMED: Incompatible interpretations");
    }
}
