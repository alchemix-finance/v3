// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Reusable deploy helper for the Yearn WETH-2 ERC4626 vault strategy on Ethereum mainnet.
contract DeployYvWETH2StrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant YV_WETH_2_VAULT = 0xAc37729B76db6438CE62042AE1270ee574CA7571;

    struct YvWETH2DeployConfig {
        address myt;
        address yearnVault;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Yearn Mainnet WETH-2",
            protocol: "Yearn",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 700,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployYvWETH2Strategy(address targetOwner, YvWETH2DeployConfig memory config) public returns (address strategyAddr) {
        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.yearnVault);
        strategyAddr = address(strategy);
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        YvWETH2DeployConfig memory config = YvWETH2DeployConfig({myt: ethMYT, yearnVault: YV_WETH_2_VAULT, params: defaultParams()});

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployYvWETH2Strategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Yearn Mainnet WETH-2 ERC4626Strategy deployed at:", strategyAddr);
    }
}
