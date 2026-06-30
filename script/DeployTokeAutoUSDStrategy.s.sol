// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";

/// @notice Reusable deploy helper for the Tokemak AutoUSD strategy on Ethereum mainnet.
contract DeployTokeAutoUSDStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public usdcMYT = 0x9B44efCa3e2a707B63Dc00CE79d646E5E5D24bA5;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant TOKE_AUTO_USD_REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    address public constant TOKE_REWARDS_TOKEN = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    address public constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    uint256 public constant DEFAULT_EXEC_TOLERANCE_BPS = 25;

    struct TokeAutoUSDDeployConfig {
        address myt;
        address asset;
        address autoVault;
        address rewarder;
        address tokeRewardsToken;
        address autopilotRouter;
        uint256 execToleranceBps;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "TokeAutoUSD Mainnet",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1000e6,
            globalCap: 0.3e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployTokeAutoUSDStrategy(AlchemistCurator curator, address targetOwner, TokeAutoUSDDeployConfig memory config)
        public
        returns (address strategyAddr)
    {
        curator;
        TokeAutoStrategy strategy = new TokeAutoStrategy(
            config.myt, config.params, config.asset, config.autoVault, config.rewarder, config.tokeRewardsToken, config.autopilotRouter, config.execToleranceBps
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        TokeAutoUSDDeployConfig memory config = TokeAutoUSDDeployConfig({
            myt: usdcMYT,
            asset: USDC,
            autoVault: TOKE_AUTO_USD_VAULT,
            rewarder: TOKE_AUTO_USD_REWARDER,
            tokeRewardsToken: TOKE_REWARDS_TOKEN,
            autopilotRouter: AUTOPILOT_ROUTER,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployTokeAutoUSDStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("TokeAutoStrategy AutoUSD deployed at:", strategyAddr);
    }
}
