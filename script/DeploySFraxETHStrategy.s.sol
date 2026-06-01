// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../src/FrxEthEthDualOracleAggregatorAdapter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {SFraxETHStrategy} from "../src/strategies/SFraxETHStrategy.sol";

/// @notice Reusable deploy helper for the Frax sfrxETH strategy on Ethereum mainnet.
contract DeploySFraxETHStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant FRAX_MINTER_V2 = 0x7Bc6bad540453360F744666D625fec0ee1320cA3;
    address public constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address public constant FRXETH_ETH_DUAL_ORACLE = 0x350a9841956D8B0212EAdF5E14a449CA85FAE1C0;
    uint256 public constant MIN_FRXETH_OUT_BPS = 9000;
    uint256 public constant MAX_ORACLE_STALENESS = 24 hours;

    struct SFraxETHDeployConfig {
        address myt;
        address minter;
        address frxETH;
        address sfrxETH;
        address frxEthEthDualOracle;
        uint256 minFrxEthOutBps;
        uint256 maxOracleStaleness;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "sfrxETH Mainnet",
            protocol: "Frax",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 5000e18,
            globalCap: 1e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deploySFraxETHStrategy(
        AlchemistCurator curator,
        address targetOwner,
        SFraxETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        FrxEthEthDualOracleAggregatorAdapter oracleAdapter =
            new FrxEthEthDualOracleAggregatorAdapter(config.frxEthEthDualOracle);

        SFraxETHStrategy strategy = new SFraxETHStrategy(
            config.myt,
            config.params,
            config.minter,
            config.frxETH,
            config.sfrxETH,
            address(oracleAdapter),
            config.minFrxEthOutBps,
            config.maxOracleStaleness
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        SFraxETHDeployConfig memory config = SFraxETHDeployConfig({
            myt: ethMYT,
            minter: FRAX_MINTER_V2,
            frxETH: FRXETH,
            sfrxETH: SFRXETH,
            frxEthEthDualOracle: FRXETH_ETH_DUAL_ORACLE,
            minFrxEthOutBps: MIN_FRXETH_OUT_BPS,
            maxOracleStaleness: MAX_ORACLE_STALENESS,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deploySFraxETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("SFraxETHStrategy deployed at:", strategyAddr);
    }
}
