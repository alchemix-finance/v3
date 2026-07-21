// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {StakeDAOWETHStrategy} from "../src/strategies/StakeDAOWETHStrategy.sol";

/// @notice Reusable deploy helper for the Stake DAO ETH+/WETH RewardVault strategy on Ethereum mainnet.
contract DeployStakeDAOWETHStrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant REWARD_VAULT = 0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C;
    address public constant ETH_PLUS_WETH_POOL = 0x2c683fAd51da2cd17793219CC86439C1875c353e;
    address public constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;
    uint256 public constant WITHDRAW_BUFFER_BPS = 125;
    uint256 public constant MIN_WETH_PER_CURVE_LP = 1e18;
    uint256 public constant MIN_CURVE_LP_PER_WETH = 0.95e18;

    struct StakeDAOWETHDeployConfig {
        address myt;
        address rewardVault;
        address curvePool;
        address ensoRouter;
        uint256 withdrawBufferBps;
        uint256 minWethPerCurveLp;
        uint256 minCurveLpPerWeth;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "StakeDAO Mainnet ETH+/WETH",
            protocol: "StakeDAO",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 5000e18,
            globalCap: 0.3e18,
            estimatedYield: 500,
            additionalIncentives: true,
            slippageBPS: 125
        });
    }

    function deployStakeDAOWETHStrategy(AlchemistCurator curator, address targetOwner, StakeDAOWETHDeployConfig memory config)
        public
        returns (address strategyAddr)
    {
        StakeDAOWETHStrategy strategy = new StakeDAOWETHStrategy(
            config.myt,
            config.params,
            config.rewardVault,
            config.curvePool,
            config.ensoRouter,
            config.withdrawBufferBps,
            config.minWethPerCurveLp,
            config.minCurveLpPerWeth
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        StakeDAOWETHDeployConfig memory config = StakeDAOWETHDeployConfig({
            myt: ethMYT,
            rewardVault: REWARD_VAULT,
            curvePool: ETH_PLUS_WETH_POOL,
            ensoRouter: ENSO_ROUTER,
            withdrawBufferBps: WITHDRAW_BUFFER_BPS,
            minWethPerCurveLp: MIN_WETH_PER_CURVE_LP,
            minCurveLpPerWeth: MIN_CURVE_LP_PER_WETH,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployStakeDAOWETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("StakeDAOWETHStrategy deployed at:", strategyAddr);
    }
}
