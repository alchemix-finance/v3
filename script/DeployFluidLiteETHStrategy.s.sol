// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {FluidLiteETHStrategy} from "../src/strategies/FluidLiteETHStrategy.sol";

/// @notice Reusable deploy helper for the Fluid Lite iETHv2 (leveraged stETH) strategy on Ethereum mainnet.
contract DeployFluidLiteETHStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant FLUID_LITE_ETH_VAULT = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78; // iETHv2
    address public constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812; // Chainlink stETH/ETH
    uint256 public constant MAX_ORACLE_STALENESS = 24 hours;

    struct FluidLiteETHDeployConfig {
        address myt;
        address fluidLiteVault;
        address stETH;
        address stEthEthOracle;
        uint256 maxOracleStaleness;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Fluid Lite Mainnet ETH",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 25e18,
            globalCap: 0.1e18,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployFluidLiteETHStrategy(
        AlchemistCurator curator,
        address targetOwner,
        FluidLiteETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        curator;
        FluidLiteETHStrategy strategy = new FluidLiteETHStrategy(
            config.myt,
            config.params,
            config.fluidLiteVault,
            config.stETH,
            config.stEthEthOracle,
            config.maxOracleStaleness
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        FluidLiteETHDeployConfig memory config = FluidLiteETHDeployConfig({
            myt: ethMYT,
            fluidLiteVault: FLUID_LITE_ETH_VAULT,
            stETH: STETH,
            stEthEthOracle: STETH_ETH_ORACLE,
            maxOracleStaleness: MAX_ORACLE_STALENESS,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployFluidLiteETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("Fluid Lite ETH Strategy deployed at:", strategyAddr);
    }
}
