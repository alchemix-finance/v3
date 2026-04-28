// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWstETHL2StrategyScript} from "../../script/DeployWstETHL2Strategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {WstETHL2Strategy} from "../strategies/WstETHL2Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockOracleForWstETHL2DeployTest {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockMYTForWstETHL2DeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployWstETHL2StrategyScriptTest is Test {
    uint256 internal constant MAX_ORACLE_STALENESS = 1 hours;

    DeployWstETHL2StrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForWstETHL2DeployTest internal myt;

    address internal newOwner;
    address internal wstETH;
    MockOracleForWstETHL2DeployTest internal oracle;

    function setUp() public {
        deployScript = new DeployWstETHL2StrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForWstETHL2DeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        wstETH = makeAddr("wstETH");
        oracle = new MockOracleForWstETHL2DeployTest();
    }

    function test_deployWstETHL2Strategy_setsCoreAddressesAndConfig() public {
        address strategyAddr = address(
            deployScript.deployWstEthOptimismStrategy(
                address(myt),
                curator,
                newOwner,
                wstETH,
                address(oracle),
                MAX_ORACLE_STALENESS,
                _buildParams("WstETH Optimism", "WstETH")
            )
        );
        WstETHL2Strategy strategy = WstETHL2Strategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.wsteth()), wstETH, "unexpected wstETH");
        assertEq(address(strategy.pricedTokenOracle()), address(oracle), "unexpected oracle");
        assertEq(strategy.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS, "unexpected max oracle staleness");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(curator.adapterToMYT(strategyAddr), address(myt), "unexpected curator adapter mapping");

        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "WstETH Optimism", "unexpected strategy name");
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
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1_000e18,
            globalCap: 0.3e18,
            estimatedYield: 350,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
