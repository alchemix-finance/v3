// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {SiUSDStrategy} from "../src/strategies/SiUSDStrategy.sol";

/// @notice Reusable deploy helper for InfiniFi siUSD strategies.
contract DeploySiUSDStrategiesScript is Script {
    struct SiUSDDeployConfig {
        address myt;
        address usdc;
        address iUSD;
        address siUSD;
        address gateway;
        address mintController;
        address redeemController;
        address iUsdUsdcOracle;
        uint256 maxOracleStaleness;
        IMYTStrategy.StrategyParams params;
    }

    function deploySiUSDStrategy(
        AlchemistCurator curator,
        address newOwner,
        SiUSDDeployConfig memory config
    ) public returns (address strategyAddr) {
        SiUSDStrategy strategy = new SiUSDStrategy(
            config.myt,
            config.params,
            config.usdc,
            config.iUSD,
            config.siUSD,
            config.gateway,
            config.mintController,
            config.redeemController,
            config.iUsdUsdcOracle,
            config.maxOracleStaleness
        );
        strategyAddr = address(strategy);

        curator.submitSetStrategy(strategyAddr, config.myt);
        curator.setStrategy(strategyAddr, config.myt);
        curator.submitIncreaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.increaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.submitIncreaseRelativeCap(strategyAddr, config.params.globalCap);
        curator.increaseRelativeCap(strategyAddr, config.params.globalCap);

        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(newOwner);
    }

    function deployBatch(
        AlchemistCurator curator,
        address newOwner,
        SiUSDDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deploySiUSDStrategy(curator, newOwner, configs[i]);
        }
    }
}
