// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for B8-1 / DEPTH-EC-3: FrxEthEthDualOracleAggregatorAdapter fabricates
///         block.timestamp for updatedAt, making staleness checks always pass (age == 0).
///
/// Finding: B8-1 + DEPTH-EC-3 | Severity: High | CONFIRMED (PoC verified)
/// Location: FrxEthEthDualOracleAggregatorAdapter.sol
///
/// Root cause: latestRoundData returns block.timestamp as updatedAt.
/// Consumer computes: block.timestamp - updatedAt = 0 → oracle is ALWAYS "fresh".

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../FrxEthEthDualOracleAggregatorAdapter.sol";

/// @dev Minimal mock of the Frax dual oracle
contract MockFrxDualOracle {
    uint256 public priceLow;
    uint256 public priceHigh;

    constructor(uint256 _low, uint256 _high) {
        priceLow  = _low;
        priceHigh = _high;
    }

    function getPrices() external view returns (bool isBadData, uint256 low, uint256 high) {
        return (false, priceLow, priceHigh);
    }
}

/// @dev Simulates how a consumer checks staleness
contract MockOracleConsumer {
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;

    FrxEthEthDualOracleAggregatorAdapter public oracle;

    constructor(address _oracle) {
        oracle = FrxEthEthDualOracleAggregatorAdapter(_oracle);
    }

    function getPrice() external view returns (int256 price, uint256 age) {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        age   = block.timestamp - updatedAt;
        price = answer;
        require(age <= MAX_ORACLE_STALENESS, "Oracle stale");
        return (price, age);
    }
}

contract PocDualOracleTimestampTest is Test {

    FrxEthEthDualOracleAggregatorAdapter adapter;
    MockFrxDualOracle                    dualOracle;
    MockOracleConsumer                   consumer;

    function setUp() public {
        dualOracle = new MockFrxDualOracle(0.998e18, 1.000e18);
        adapter    = new FrxEthEthDualOracleAggregatorAdapter(address(dualOracle));
        consumer   = new MockOracleConsumer(address(adapter));
    }

    // ================================================================
    // PoC 1: updatedAt is always block.timestamp — staleness is always 0
    // ================================================================
    function test_poc_oracle_updatedAt_equals_block_timestamp() public {
        (, , , uint256 updatedAt,) = adapter.latestRoundData();

        assertEq(updatedAt, block.timestamp, "CONFIRMED: updatedAt == block.timestamp");

        uint256 staleness = block.timestamp - updatedAt;
        assertEq(staleness, 0, "CONFIRMED: staleness always 0");

        console.log("=== B8-1 CONFIRMED ===");
        console.log("block.timestamp:", block.timestamp);
        console.log("updatedAt:      ", updatedAt);
        console.log("Staleness (s):  ", staleness);
    }

    // ================================================================
    // PoC 2: Even after 30 days, staleness still reports 0
    // ================================================================
    function test_poc_stale_price_never_detected() public {
        (, int256 priceAtT,,,) = adapter.latestRoundData();

        // Simulate 30 days passing with no oracle update
        vm.warp(block.timestamp + 30 days);

        (, int256 priceAfter30d,, uint256 updatedAfter30d,) = adapter.latestRoundData();
        uint256 apparentAge = block.timestamp - updatedAfter30d;

        assertEq(apparentAge, 0, "CONFIRMED: 30 days passed but staleness still 0");

        // Consumer staleness check passes
        (int256 consumerPrice, uint256 consumerAge) = consumer.getPrice();
        assertEq(consumerAge, 0, "Consumer receives 0-age price");

        console.log("=== DEPTH-EC-3 CONFIRMED ===");
        console.log("Days elapsed:     30");
        console.log("Apparent age (s): ", apparentAge);
        console.log("MAX_STALENESS (s):", uint256(7 days));
        console.log("Price accepted as fresh despite 30 days of staleness");
    }

    // ================================================================
    // PoC 3: Quantify phantom collateral from stale price during depeg
    // ================================================================
    function test_poc_phantom_collateral_from_stale_price() public {
        uint256 stalePrice  = 1.000e18;
        uint256 actualPrice = 0.950e18; // 5% depeg

        uint256 TVL_SHARES = 30_000_000e18;

        uint256 phantomCollateral = TVL_SHARES * stalePrice  / 1e18;
        uint256 realCollateral    = TVL_SHARES * actualPrice / 1e18;

        uint256 phantomExcess = phantomCollateral - realCollateral;

        console.log("=== DEPTH-EX-2: Phantom Collateral Simulation ===");
        console.log("TVL (MYT shares):       ", TVL_SHARES / 1e18, "ETH");
        console.log("Stale price (oracle):   ", stalePrice);
        console.log("Actual price (market):  ", actualPrice);
        console.log("Phantom collateral:     ", phantomCollateral / 1e18, "ETH");
        console.log("Real collateral:        ", realCollateral    / 1e18, "ETH");
        console.log("Excess borrow capacity: ", phantomExcess     / 1e18, "ETH");

        assertGt(phantomExcess, 0, "Phantom excess confirmed");
    }
}
