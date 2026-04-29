// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {WstETHEthereumStrategy} from "../src/strategies/WstETHEthereumStrategy.sol";

contract DeployWstETHEthereumStrategyScript is Script {
    address public deployerAddr = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Existing deployed core contracts on Ethereum mainnet.
    address public myt = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    AlchemistCurator public curator = AlchemistCurator(0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4);
    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;

    // Strategy-specific addresses.
    address public wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public stEthEthOracle = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    uint256 public maxOracleStaleness = 24 hours;

    IMYTStrategy.StrategyParams public wstEthParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "WstETH Mainnet",
        protocol: "WstETH",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0.7 * 1e18,
        globalCap: 1e18,
        estimatedYield: 350,
        additionalIncentives: false,
        slippageBPS: 50
    });

    function deployWstEthStrategy(address _myt) public returns (WstETHEthereumStrategy) {
        return deployWstEthStrategy(_myt, curator, newOwner, wstETH, stEthEthOracle, maxOracleStaleness, wstEthParams);
    }

    function deployWstEthStrategy(
        address _myt,
        AlchemistCurator _curator,
        address _newOwner,
        address _wstETH,
        address _stEthEthOracle,
        uint256 _maxOracleStaleness,
        IMYTStrategy.StrategyParams memory _params
    )
        public
        returns (WstETHEthereumStrategy)
    {
        WstETHEthereumStrategy strategy =
            new WstETHEthereumStrategy(_myt, _params, _wstETH, _stEthEthOracle, _maxOracleStaleness);
        strategy.setKillSwitch(true);
        //_curator.submitSetStrategy(address(strategy), address(_myt));
        //_curator.setStrategy(address(strategy), address(_myt));
        //_curator.submitIncreaseAbsoluteCap(address(strategy), _params.cap);
        //_curator.increaseAbsoluteCap(address(strategy), _params.cap);
        //_curator.submitIncreaseRelativeCap(address(strategy), _params.globalCap);
        //_curator.increaseRelativeCap(address(strategy), _params.globalCap);

        strategy.transferOwnership(_newOwner);
        return strategy;
    }

    function run() public {
        vm.startBroadcast(deployerAddr);
        WstETHEthereumStrategy strategy = deployWstEthStrategy(myt);
        vm.stopBroadcast();

        console.log("WstETHEthereumStrategy deployed at:", address(strategy));
    }
}
