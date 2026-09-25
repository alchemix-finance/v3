// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {BaseERC4626DeploymentScript} from "./BaseERC4626Deployment.s.sol";

/// @notice Deploys the Fluid fUSDC lending strategy on Base.
contract DeployFluidUSDCBaseStrategyScript is BaseERC4626DeploymentScript {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant FLUID_USDC_VAULT = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
    address public constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;

    struct FluidUSDCBaseDeployConfig {
        address myt;
        address fluidVault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Fluid USDC Base",
            protocol: "Fluid",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e6,
            globalCap: 0.25e18,
            estimatedYield: 489,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployFluidUSDCBaseStrategy(address targetOwner, FluidUSDCBaseDeployConfig memory config) public returns (address strategyAddr) {
        _validateERC4626Deployment(targetOwner, config.myt, config.fluidVault, config.params.owner);

        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.fluidVault);
        strategyAddr = address(strategy);

        // Keep allocation disabled until curator configuration and smoke tests are complete.
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        FluidUSDCBaseDeployConfig memory config = FluidUSDCBaseDeployConfig({myt: BASE_USDC_MYT, fluidVault: FLUID_USDC_VAULT, params: defaultParams()});

        _validateBaseAsset(newOwner, config.myt, config.fluidVault, config.params.owner, USDC);

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployFluidUSDCBaseStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Fluid USDC Base ERC4626Strategy deployed at:", strategyAddr);
    }
}
