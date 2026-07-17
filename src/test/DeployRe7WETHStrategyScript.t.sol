// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {DeployRe7WETHStrategyScript} from "../../script/DeployRe7WETHStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForRe7WETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract DeployRe7WETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant OPTIMISM_WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant OPTIMISM_FORK_BLOCK = 154_316_176;

    DeployRe7WETHStrategyScript internal deployScript;
    TestERC20 internal weth;
    ERC4626Mock internal re7Vault;
    MockMYTForRe7WETHDeployTest internal myt;
    address internal newOwner;

    function setUp() public {
        deployScript = new DeployRe7WETHStrategyScript();
        weth = new TestERC20(1_000_000e18, 18);
        re7Vault = new ERC4626Mock(address(weth));
        myt = new MockMYTForRe7WETHDeployTest(address(weth));
        newOwner = makeAddr("newOwner");
    }

    function test_deployRe7WETHStrategy_setsCoreAddressesAndDefaults() public {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployRe7WETHStrategyScript.Re7WETHDeployConfig memory config =
            DeployRe7WETHStrategyScript.Re7WETHDeployConfig({myt: address(myt), re7Vault: address(re7Vault), params: params});

        ERC4626Strategy strategy = ERC4626Strategy(deployScript.deployRe7WETHStrategy(newOwner, config));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), address(weth), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(re7Vault), "unexpected Re7 vault");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");

        (, string memory name, string memory protocol,,,,,,) = strategy.params();
        assertEq(name, "Re7 WETH Morpho V2", "unexpected strategy name");
        assertEq(protocol, "Morpho V2", "unexpected protocol");
    }

    function test_run_fork_deploysRe7WETHWithOptimismDefaults() public {
        vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), OPTIMISM_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployRe7WETHStrategyScript forkDeployScript = new DeployRe7WETHStrategyScript();
        ERC4626Strategy strategy = ERC4626Strategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), forkDeployScript.ethMYT(), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), OPTIMISM_WETH, "unexpected MYT asset");
        assertEq(address(strategy.vault()), forkDeployScript.RE7_WETH_VAULT(), "unexpected Re7 vault");
        assertEq(strategy.owner(), forkDeployScript.newOwner(), "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
    }

    function test_defaultParams_usesRe7OptimismDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(params.owner, deployScript.deployerAddr(), "unexpected owner");
        assertEq(params.name, "Re7 WETH Morpho V2", "unexpected name");
        assertEq(params.protocol, "Morpho V2", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 20e18, "unexpected cap");
        assertEq(params.globalCap, 0.25e18, "unexpected global cap");
        assertEq(params.estimatedYield, 500, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }
}
