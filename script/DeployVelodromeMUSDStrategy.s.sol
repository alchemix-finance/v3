// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {VelodromeMUSDStrategy} from "../src/strategies/VelodromeMUSDStrategy.sol";

/// @notice Deploy helper for the Velodrome USDC/msUSD LP + gauge strategy on Optimism.
contract DeployVelodromeMUSDStrategyScript is Script {
    // Replace with your own deployer address.
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    // Existing deployed core contracts on Optimism.
    address public usdcMYT = 0xAf510a560744880410f0f65e3341A020FBC2cA41;
    address public newOwner = 0x3Dda174aa9E897e18b8E10e6Ce39c2a52398181d;

    // Velodrome V2 USDC/msUSD stable pool + gauge (Optimism).
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant MUSD = 0x9dAbAE7274D28A45F0B65Bf8ED201A5731492ca0;
    address public constant POOL = 0xe07388b2a7bb29d3Ad8989e1074Bd00Bd0d3C43d;
    address public constant GAUGE = 0x7b3f9Ae95D8852078E49168505d6C897E4B11B6E;
    address public constant ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address public constant FACTORY = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;

    struct VelodromeMUSDDeployConfig {
        address myt;
        address usdc;
        address musd;
        address pool;
        address gauge;
        address router;
        address factory;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Velodrome USDC/msUSD",
            protocol: "Velodrome",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 100_000e6,
            globalCap: 1e18,
            estimatedYield: 0,
            additionalIncentives: true,
            slippageBPS: 300
        });
    }

    function deployVelodromeMUSDStrategy(address targetOwner, VelodromeMUSDDeployConfig memory config)
        public
        returns (address strategyAddr)
    {
        VelodromeMUSDStrategy strategy = new VelodromeMUSDStrategy(
            config.myt, config.params, config.usdc, config.musd, config.pool, config.gauge, config.router, config.factory
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        require(usdcMYT != address(0), "Set usdcMYT");

        VelodromeMUSDDeployConfig memory config = VelodromeMUSDDeployConfig({
            myt: usdcMYT,
            usdc: USDC,
            musd: MUSD,
            pool: POOL,
            gauge: GAUGE,
            router: ROUTER,
            factory: FACTORY,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployVelodromeMUSDStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("VelodromeMUSDStrategy deployed at:", strategyAddr);
    }
}
