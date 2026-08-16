// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {EtherfiEETHMYTStrategy} from "../src/strategies/EtherfiEETHStrategy.sol";

/// @notice Reusable deploy helper for the Ether.fi weETH strategy on Ethereum mainnet.
/// @dev Oracle-free pricing; async unwinds (requestExits/claimExits) are keeper-driven.
contract DeployEtherfiEETHStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;

    struct EtherfiEETHDeployConfig {
        address myt;
        address eETH;
        address weETH;
        address depositAdapter;
        address redemptionManager;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Ether.fi Mainnet weETH",
            protocol: "Ether.fi",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 5000e18,
            globalCap: 0.3e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 125
        });
    }

    function deployEtherfiEETHStrategy(
        AlchemistCurator curator,
        address targetOwner,
        EtherfiEETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        EtherfiEETHMYTStrategy strategy = new EtherfiEETHMYTStrategy(
            config.myt,
            config.params,
            config.eETH,
            config.weETH,
            config.depositAdapter,
            config.redemptionManager
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        EtherfiEETHDeployConfig memory config = EtherfiEETHDeployConfig({
            myt: ethMYT,
            eETH: EETH,
            weETH: WEETH,
            depositAdapter: DEPOSIT_ADAPTER,
            redemptionManager: REDEMPTION_MANAGER,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployEtherfiEETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("EtherfiEETHMYTStrategy deployed at:", strategyAddr);
    }
}
