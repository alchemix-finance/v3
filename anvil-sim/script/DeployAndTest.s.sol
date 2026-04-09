// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SimPhantomSynthetics} from "../src/SimH01_PhantomSynthetics.sol";
import {SimDualOracle, SimFrxAdapter, SimOracleConsumer} from "../src/SimH02_OracleTimestamp.sol";
import {SimStrategyClassifier, SimPerpetualGauge} from "../src/SimH06H07_PerpetualGauge.sol";
import {SimRetroactiveParams} from "../src/SimH05_RetroactiveParams.sol";

contract DeployAndTest is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy H-01 sim
        SimPhantomSynthetics h01 = new SimPhantomSynthetics();
        console.log("H01 deployed at:", address(h01));

        // Deploy H-02 sim
        SimDualOracle dual = new SimDualOracle(0.998e18, 1.000e18);
        SimFrxAdapter adapter = new SimFrxAdapter(address(dual));
        SimOracleConsumer consumer = new SimOracleConsumer(address(adapter));
        console.log("H02 DualOracle:", address(dual));
        console.log("H02 Adapter:   ", address(adapter));
        console.log("H02 Consumer:  ", address(consumer));

        // Deploy H-06/H-07 sim
        SimStrategyClassifier classifier = new SimStrategyClassifier();
        SimPerpetualGauge gauge = new SimPerpetualGauge(address(classifier));
        console.log("H06 Classifier:", address(classifier));
        console.log("H06 Gauge:     ", address(gauge));

        // Deploy H-05 sim
        SimRetroactiveParams h05 = new SimRetroactiveParams(1.05e18, 1.11e18);
        console.log("H05 deployed at:", address(h05));

        vm.stopBroadcast();
    }
}
