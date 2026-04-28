// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {DeployYvWETHStrategyScript} from "../../script/DeployYvWETHStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForYvWETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployYvWETHStrategyScriptTest is Test {
    DeployYvWETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal weth;
    ERC4626Mock internal yearnVault;
    MockMYTForYvWETHDeployTest internal myt;

    address internal newOwner;

    function setUp() public {
        deployScript = new DeployYvWETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        weth = new TestERC20(1_000_000e18, 18);
        yearnVault = new ERC4626Mock(address(weth));
        myt = new MockMYTForYvWETHDeployTest(address(weth));

        newOwner = makeAddr("newOwner");
    }

    function test_deployYvWETHStrategy_setsCoreAddressesAndParams() public {
        DeployYvWETHStrategyScript.YvWETHDeployConfig memory config = DeployYvWETHStrategyScript.YvWETHDeployConfig({
            myt: address(myt), yearnVault: address(yearnVault), params: _buildParams("Yearn Mainnet WETH-1", "Yearn")
        });

        address strategyAddr = deployScript.deployYvWETHStrategy(curator, newOwner, config);
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(weth), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(yearnVault), "unexpected Yearn vault");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertEq(curator.adapterToMYT(strategyAddr), address(myt), "unexpected curator adapter mapping");

        (, string memory name, string memory protocol,,,,,,) = strategy.params();
        assertEq(name, "Yearn Mainnet WETH-1", "unexpected strategy name");
        assertEq(protocol, "Yearn", "unexpected protocol");
    }

    function test_defaultParams_usesMainnetYearnWETHDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4, "unexpected curator");
        assertEq(deployScript.ethMYT(), 0x29bcfeD246ce37319d94eBa107db90C453D4c43D, "unexpected ETH MYT");
        assertEq(params.owner, 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2, "unexpected owner");
        assertEq(params.name, "Yearn Mainnet WETH-1", "unexpected name");
        assertEq(params.protocol, "Yearn", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.LOW), "unexpected risk class");
        assertEq(params.cap, 10_000e18, "unexpected cap");
        assertEq(params.globalCap, 1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 500, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 1, "unexpected slippage");
    }

    function _buildParams(string memory name, string memory protocol) internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1000e18,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
