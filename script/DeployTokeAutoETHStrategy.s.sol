// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";

/// @notice Reusable deploy helper for the Tokemak AutoETH strategy on Ethereum mainnet.
contract DeployTokeAutoETHStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant TOKE_AUTO_ETH_VAULT = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant TOKE_AUTO_ETH_REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public constant TOKE_REWARDS_TOKEN = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    address public constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    uint256 public constant DEFAULT_EXEC_TOLERANCE_BPS = 25;

    struct TokeAutoETHDeployConfig {
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
            name: "TokeAutoEth Mainnet",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 0.7e18,
            globalCap: 0.3e18,
            estimatedYield: 800,
            additionalIncentives: false,
            slippageBPS: 600
        });
    }

    function deployTokeAutoETHStrategy(
        AlchemistCurator curator,
        address targetOwner,
        TokeAutoETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        curator;
        TokeAutoStrategy strategy = new TokeAutoStrategy(
            config.myt,
            config.params,
            config.asset,
            config.autoVault,
            config.rewarder,
            config.tokeRewardsToken,
            config.autopilotRouter,
            config.execToleranceBps
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        TokeAutoETHDeployConfig memory config = TokeAutoETHDeployConfig({
            myt: ethMYT,
            asset: WETH,
            autoVault: TOKE_AUTO_ETH_VAULT,
            rewarder: TOKE_AUTO_ETH_REWARDER,
            tokeRewardsToken: TOKE_REWARDS_TOKEN,
            autopilotRouter: AUTOPILOT_ROUTER,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployTokeAutoETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("TokeAutoStrategy AutoETH deployed at:", strategyAddr);
    }
}
