// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Deploys the Re7 WETH Morpho V2 strategy on Optimism.
contract DeployRe7WETHStrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x3Dda174aa9E897e18b8E10e6Ce39c2a52398181d;
    address public ethMYT = 0x91b8657aea26Caa8A0E9D6DD4E24727Ccf32F822;

    address public constant RE7_WETH_VAULT = 0x3d63934715b6D4c4DFbBC1a00Fe2A2145079DD76;

    struct Re7WETHDeployConfig {
        address myt;
        address re7Vault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Re7 WETH Morpho V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployRe7WETHStrategy(address targetOwner, Re7WETHDeployConfig memory config) public returns (address strategyAddr) {
        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.re7Vault);
        strategyAddr = address(strategy);
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        Re7WETHDeployConfig memory config = Re7WETHDeployConfig({myt: ethMYT, re7Vault: RE7_WETH_VAULT, params: defaultParams()});

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployRe7WETHStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Re7 WETH ERC4626Strategy deployed at:", strategyAddr);
    }
}
