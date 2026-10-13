// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {Re7ETHMidasStrategy} from "../src/strategies/Re7ETHMidasStrategy.sol";

/// @notice Deploys the Re7ETH (Midas tokenized fund) strategy on Optimism.
contract DeployRe7ETHMidasStrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x3Dda174aa9E897e18b8E10e6Ce39c2a52398181d;
    address public ethMYT = 0x91b8657aea26Caa8A0E9D6DD4E24727Ccf32F822;

    address public constant RE7_ETH = 0xEF75DEBD2545C48979Bf09aC55713028808fEf40;
    address public constant RE7_ETH_DEPOSIT_VAULT = 0x3EB163AFe663B2331101725a0a23510C3B1d7E31;
    address public constant RE7_ETH_REDEMPTION_VAULT = 0x06a7Fa6DAA7BC7fD66a7EEFCE54475b456B4B5B4;
    address public constant RE7_ETH_DATA_FEED = 0x7f6136358088c629ef6b6dF5ECf2180074073e84;

    struct Re7ETHMidasDeployConfig {
        address myt;
        address re7ETH;
        address depositVault;
        address redemptionVault;
        address dataFeed;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Re7 ETH Midas",
            protocol: "Midas",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 200,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployRe7ETHMidasStrategy(address targetOwner, Re7ETHMidasDeployConfig memory config) public returns (address strategyAddr) {
        Re7ETHMidasStrategy strategy =
            new Re7ETHMidasStrategy(config.myt, config.params, config.re7ETH, config.depositVault, config.redemptionVault, config.dataFeed);
        strategyAddr = address(strategy);
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        Re7ETHMidasDeployConfig memory config = Re7ETHMidasDeployConfig({
            myt: ethMYT,
            re7ETH: RE7_ETH,
            depositVault: RE7_ETH_DEPOSIT_VAULT,
            redemptionVault: RE7_ETH_REDEMPTION_VAULT,
            dataFeed: RE7_ETH_DATA_FEED,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployRe7ETHMidasStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Re7ETHMidasStrategy deployed at:", strategyAddr);
    }
}
