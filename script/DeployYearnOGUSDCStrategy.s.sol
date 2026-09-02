// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Deploys the Yearn OG USDC V2 Morpho vault strategy on Base.
contract DeployYearnOGUSDCStrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant YEARN_OG_USDC_V2_VAULT = 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42;

    struct YearnOGUSDCDeployConfig {
        address myt;
        address yearnOGVault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Yearn OG USDC V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e6,
            globalCap: 0.25e18,
            estimatedYield: 531,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployYearnOGUSDCStrategy(address targetOwner, YearnOGUSDCDeployConfig memory config) public returns (address strategyAddr) {
        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.yearnOGVault);
        strategyAddr = address(strategy);

        // Keep allocation disabled until curator configuration and smoke tests are complete.
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        address targetMYT = vm.envAddress("BASE_USDC_MYT");
        YearnOGUSDCDeployConfig memory config = YearnOGUSDCDeployConfig({myt: targetMYT, yearnOGVault: YEARN_OG_USDC_V2_VAULT, params: defaultParams()});

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployYearnOGUSDCStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Yearn OG USDC V2 ERC4626Strategy deployed at:", strategyAddr);
    }
}
