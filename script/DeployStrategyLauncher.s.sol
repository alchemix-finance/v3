// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StrategyLauncher} from "../src/utils/StrategyLauncher.sol";

/// @notice Deploys the launcher and points it at the probe and clip allocator
///         already serving `myt`. The probe owner still has to call
///         `setPoker(launcher, true)`. This script does not touch a strategy.
contract DeployStrategyLauncherScript is Script {
    /// @dev `safe` receives the ownership handover. Keeper addresses may be zero.
    function deploy(
        address myt,
        address probe,
        address clip,
        address safe,
        address probeKeeper,
        address clipKeeper
    ) public returns (StrategyLauncher launcher) {
        launcher = new StrategyLauncher();
        launcher.setVenue(myt, probe, clip);
        if (probeKeeper != address(0)) launcher.setProbeKeeper(probeKeeper, true);
        if (clipKeeper != address(0)) launcher.setClipKeeper(clipKeeper, true);
        if (safe != address(0)) launcher.transferOwnership(safe);
    }

    /// @notice Reads MYT, PROBE, CLIP, SAFE, and DEPLOYER from the environment.
    ///         PROBE_KEEPER and CLIP_KEEPER are optional.
    function run() public returns (StrategyLauncher launcher) {
        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);
        launcher = deploy(
            vm.envAddress("MYT"),
            vm.envAddress("PROBE"),
            vm.envAddress("CLIP"),
            vm.envAddress("SAFE"),
            vm.envOr("PROBE_KEEPER", address(0)),
            vm.envOr("CLIP_KEEPER", address(0))
        );
        vm.stopBroadcast();

        console.log("StrategyLauncher", address(launcher));
        console.log("pending owner", vm.envAddress("SAFE"));
    }
}
