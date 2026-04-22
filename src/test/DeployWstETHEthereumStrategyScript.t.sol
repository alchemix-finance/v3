// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWstETHEthereumStrategyScript} from "../../script/DeployWstETHEthereumStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {WstETHEthereumStrategy} from "../strategies/WstETHEthereumStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockOracleForWstETHEthereumDeployTest {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockMYTForWstETHEthereumDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployWstETHEthereumStrategyScriptTest is Test {
    DeployWstETHEthereumStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForWstETHEthereumDeployTest internal myt;

    address internal newOwner;
    address internal wstETH;
    MockOracleForWstETHEthereumDeployTest internal oracle;

    function setUp() public {
        deployScript = new DeployWstETHEthereumStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForWstETHEthereumDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        wstETH = makeAddr("wstETH");
        oracle = new MockOracleForWstETHEthereumDeployTest();
    }

    function test_deployWstETHEthereumStrategy_setsCoreAddressesAndConfig() public {
        address strategyAddr = address(
            deployScript.deployWstEthStrategy(
                address(myt), curator, newOwner, wstETH, address(oracle), _buildParams("WstETH Mainnet", "WstETH")
            )
        );
        WstETHEthereumStrategy strategy = WstETHEthereumStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.wsteth()), wstETH, "unexpected wstETH");
        assertEq(address(strategy.pricedTokenEthOracle()), address(oracle), "unexpected oracle");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(curator.adapterToMYT(strategyAddr), address(myt), "unexpected curator adapter mapping");

        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "WstETH Mainnet", "unexpected strategy name");
        assertEq(protocol, "WstETH", "unexpected protocol");
    }

    function _buildParams(string memory name, string memory protocol)
        internal
        view
        returns (IMYTStrategy.StrategyParams memory)
    {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1_000e18,
            globalCap: 0.5e18,
            estimatedYield: 350,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
