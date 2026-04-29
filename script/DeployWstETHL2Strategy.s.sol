// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {WstETHL2Strategy} from "../src/strategies/WstETHL2Strategy.sol";

contract DeployWstETHL2StrategyScript is Script {
    address public deployerAddr = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Existing deployed core contracts on Optimism.
    address public myt = 0x91b8657aea26Caa8A0E9D6DD4E24727Ccf32F822;
    AlchemistCurator public curator = AlchemistCurator(0xC8a2bdE198d21e9AbB0b306b4aD27F0711aEF20d);
    address public newOwner = 0x3Dda174aa9E897e18b8E10e6Ce39c2a52398181d;

    // Strategy-specific addresses.
    address public wstETHOptimism = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address public wstEthEthOracleOptimism = 0x524299Ab0987a7c4B3c8022a35669DdcdC715a10;
    uint256 public maxOracleStaleness = 1 hours;

    IMYTStrategy.StrategyParams public wstEthParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "WstETH Optimism",
        protocol: "WstETH",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 0.7 * 1e18,
        globalCap: 0.3e18,
        estimatedYield: 350,
        additionalIncentives: false,
        slippageBPS: 50
    });

    function deployWstEthOptimismStrategy(address _myt) public returns (WstETHL2Strategy) {
        return deployWstEthOptimismStrategy(
            _myt, curator, newOwner, wstETHOptimism, wstEthEthOracleOptimism, maxOracleStaleness, wstEthParams
        );
    }

    function deployWstEthOptimismStrategy(
        address _myt,
        AlchemistCurator _curator,
        address _newOwner,
        address _wstETH,
        address _wstEthEthOracle,
        uint256 _maxOracleStaleness,
        IMYTStrategy.StrategyParams memory _params
    )
        public
        returns (WstETHL2Strategy)
    {
        WstETHL2Strategy strategy =
            new WstETHL2Strategy(_myt, _params, _wstETH, _wstEthEthOracle, _maxOracleStaleness);

        strategy.setKillSwitch(true);
        // _curator.submitSetStrategy(address(strategy), address(_myt));
        // _curator.setStrategy(address(strategy), address(_myt));
        // _curator.submitIncreaseAbsoluteCap(address(strategy), _params.cap);
        // _curator.increaseAbsoluteCap(address(strategy), _params.cap);
        // _curator.submitIncreaseRelativeCap(address(strategy), _params.globalCap);
        // _curator.increaseRelativeCap(address(strategy), _params.globalCap);

        strategy.transferOwnership(_newOwner);
        return strategy;
    }

    function run() public {
        vm.startBroadcast(deployerAddr);
        WstETHL2Strategy strategy = deployWstEthOptimismStrategy(myt);
        vm.stopBroadcast();

        console.log("WstETHL2Strategy deployed at:", address(strategy));
    }
}
