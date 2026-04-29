// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {SFraxETHStrategy} from "../src/strategies/SFraxETHStrategy.sol";

/// @notice Reusable deploy helper for Frax sfrxETH strategies.
contract DeploySFraxETHStrategyScript is Script {
    struct SFraxETHDeployConfig {
        address myt;
        address minter;
        address frxETH;
        address sfrxETH;
        address pricedTokenOracle;
        uint256 minFrxEthOutBps;
        uint256 maxOracleStaleness;
        IMYTStrategy.StrategyParams params;
    }

    function deploySFraxETHStrategy(
        AlchemistCurator curator,
        address newOwner,
        SFraxETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        SFraxETHStrategy strategy = new SFraxETHStrategy(
            config.myt,
            config.params,
            config.minter,
            config.frxETH,
            config.sfrxETH,
            config.pricedTokenOracle,
            config.minFrxEthOutBps,
            config.maxOracleStaleness
        );
        strategyAddr = address(strategy);

        curator.submitSetStrategy(strategyAddr, config.myt);
        curator.setStrategy(strategyAddr, config.myt);
        curator.submitIncreaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.increaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.submitIncreaseRelativeCap(strategyAddr, config.params.globalCap);
        curator.increaseRelativeCap(strategyAddr, config.params.globalCap);

        MYTStrategy(strategyAddr).transferOwnership(newOwner);
    }
}
