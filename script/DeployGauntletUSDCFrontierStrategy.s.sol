// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {BaseERC4626DeploymentScript} from "./BaseERC4626Deployment.s.sol";

/// @notice Deploys the Gauntlet USDC Frontier Morpho V2 vault strategy on Base.
contract DeployGauntletUSDCFrontierStrategyScript is BaseERC4626DeploymentScript {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant GAUNTLET_USDC_FRONTIER_VAULT = 0x1deEfABEe758AAbdC29a542B24ca3b75aFD56765;

    struct GauntletUSDCFrontierDeployConfig {
        address myt;
        address gauntletVault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Gauntlet USDC Frontier",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 483,
            additionalIncentives: false,
            slippageBPS: 100
        });
    }

    function deployGauntletUSDCFrontierStrategy(address targetOwner, GauntletUSDCFrontierDeployConfig memory config)
        public
        returns (address strategyAddr)
    {
        _validateERC4626Deployment(targetOwner, config.myt, config.gauntletVault, config.params.owner);

        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.gauntletVault);
        strategyAddr = address(strategy);

        // Keep allocation disabled until curator configuration and smoke tests are complete.
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        address targetMYT = vm.envAddress("BASE_USDC_MYT");
        GauntletUSDCFrontierDeployConfig memory config =
            GauntletUSDCFrontierDeployConfig({myt: targetMYT, gauntletVault: GAUNTLET_USDC_FRONTIER_VAULT, params: defaultParams()});

        _validateBaseAsset(newOwner, config.myt, config.gauntletVault, config.params.owner, USDC);

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployGauntletUSDCFrontierStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Gauntlet USDC Frontier ERC4626Strategy deployed at:", strategyAddr);
    }
}
