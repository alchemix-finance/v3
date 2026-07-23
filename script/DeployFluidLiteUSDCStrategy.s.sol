// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Reusable deploy helper for the Fluid Lite fLiteUSD strategy on Ethereum mainnet.
contract DeployFluidLiteUSDCStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public usdcMYT = 0x9B44efCa3e2a707B63Dc00CE79d646E5E5D24bA5;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant FLUID_LITE_USDC_VAULT = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;

    struct FluidLiteUSDCDeployConfig {
        address myt;
        address fluidLiteVault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Fluid Lite Mainnet USDC",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 1000e6,
            globalCap: 0.1e18,
            estimatedYield: 680,
            additionalIncentives: false,
            slippageBPS: 100
        });
    }

    function deployFluidLiteUSDCStrategy(
        AlchemistCurator curator,
        address targetOwner,
        FluidLiteUSDCDeployConfig memory config
    ) public returns (address strategyAddr) {
        curator;
        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.fluidLiteVault);
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        FluidLiteUSDCDeployConfig memory config = FluidLiteUSDCDeployConfig({
            myt: usdcMYT,
            fluidLiteVault: FLUID_LITE_USDC_VAULT,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployFluidLiteUSDCStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("Fluid Lite USDC Strategy deployed at:", strategyAddr);
    }
}
