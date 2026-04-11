// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySFraxETHStrategyScript} from "../../script/DeploySFraxETHStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {SFraxETHStrategy} from "../strategies/SFraxETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockOracleForSFraxETHDeployTest {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockMYTForSFraxETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeploySFraxETHStrategyScriptTest is Test {
    DeploySFraxETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForSFraxETHDeployTest internal myt;

    address internal newOwner;
    address internal minter;
    address internal frxETH;
    address internal sfrxETH;
    MockOracleForSFraxETHDeployTest internal oracle;

    uint256 internal constant MIN_FRXETH_OUT_BPS = 9000;

    function setUp() public {
        deployScript = new DeploySFraxETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForSFraxETHDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        minter = makeAddr("minter");
        frxETH = makeAddr("frxETH");
        sfrxETH = makeAddr("sfrxETH");
        oracle = new MockOracleForSFraxETHDeployTest();
    }

    function test_deploySFraxETHStrategy_setsCoreAddressesAndFloor() public {
        DeploySFraxETHStrategyScript.SFraxETHDeployConfig memory config = DeploySFraxETHStrategyScript
            .SFraxETHDeployConfig({
            myt: address(myt),
            minter: minter,
            frxETH: frxETH,
            sfrxETH: sfrxETH,
            pricedTokenEthOracle: address(oracle),
            minFrxEthOutBps: MIN_FRXETH_OUT_BPS,
            params: _buildParams("sfrxETH Mainnet", "Frax")
        });

        address strategyAddr = deployScript.deploySFraxETHStrategy(curator, newOwner, config);
        SFraxETHStrategy strategy = SFraxETHStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.minter()), minter, "unexpected minter");
        assertEq(address(strategy.frxETH()), frxETH, "unexpected frxETH");
        assertEq(address(strategy.sfrxETH()), sfrxETH, "unexpected sfrxETH");
        assertEq(address(strategy.pricedTokenEthOracle()), address(oracle), "unexpected oracle");
        assertEq(strategy.minFrxEthOutBps(), MIN_FRXETH_OUT_BPS, "unexpected minFrxEthOutBps");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(myt), "unexpected curator adapter mapping");
        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "sfrxETH Mainnet", "unexpected strategy name");
        assertEq(protocol, "Frax", "unexpected protocol");
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
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
