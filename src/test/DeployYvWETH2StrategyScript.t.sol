// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeployYvWETH2StrategyScript} from "../../script/DeployYvWETH2Strategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

interface IYearnV3DeploymentMetadata {
    function apiVersion() external view returns (string memory);
    function isShutdown() external view returns (bool);
}

contract MockMYTForYvWETH2DeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployYvWETH2StrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant YV_WETH_2_VAULT = 0xAc37729B76db6438CE62042AE1270ee574CA7571;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_970_000;

    DeployYvWETH2StrategyScript internal deployScript;
    TestERC20 internal weth;
    ERC4626Mock internal yearnVault;
    MockMYTForYvWETH2DeployTest internal myt;
    address internal newOwner;

    function setUp() public {
        deployScript = new DeployYvWETH2StrategyScript();

        weth = new TestERC20(1_000_000e18, 18);
        yearnVault = new ERC4626Mock(address(weth));
        myt = new MockMYTForYvWETH2DeployTest(address(weth));

        newOwner = makeAddr("newOwner");
    }

    function test_deployYvWETH2Strategy_setsCoreAddressesAndParams() public {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployYvWETH2StrategyScript.YvWETH2DeployConfig memory config =
            DeployYvWETH2StrategyScript.YvWETH2DeployConfig({myt: address(myt), yearnVault: address(yearnVault), params: params});

        address strategyAddr = deployScript.deployYvWETH2Strategy(newOwner, config);
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(weth), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(yearnVault), "unexpected Yearn vault");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");

        (, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(name, "Yearn Mainnet WETH-2", "unexpected strategy name");
        assertEq(protocol, "Yearn", "unexpected protocol");
        assertEq(uint256(riskClass), uint256(IMYTStrategy.RiskClass.LOW), "unexpected risk class");
    }

    function test_run_fork_deploysAgainstLiveYearnWeth2() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployYvWETH2StrategyScript forkDeployScript = new DeployYvWETH2StrategyScript();
        ERC4626Strategy strategy = ERC4626Strategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(address(strategy.mytAsset()), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.vault()), YV_WETH_2_VAULT, "unexpected Yearn vault");
        assertEq(IERC4626(YV_WETH_2_VAULT).asset(), MAINNET_WETH, "target vault asset mismatch");
        assertEq(IYearnV3DeploymentMetadata(YV_WETH_2_VAULT).apiVersion(), "3.0.2", "unexpected Yearn version");
        assertFalse(IYearnV3DeploymentMetadata(YV_WETH_2_VAULT).isShutdown(), "target vault is shut down");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");
        assertEq(strategy.realAssets(), 0, "new strategy should have no assets");
    }

    function test_run_fork_canServeAsLiquidityAdapter() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), MAINNET_FORK_BLOCK);

        DeployYvWETH2StrategyScript forkDeployScript = new DeployYvWETH2StrategyScript();
        MockMYTVault forkMYT = new MockMYTVault(address(this), MAINNET_WETH);
        address forkOwner = makeAddr("forkOwner");

        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();
        params.owner = address(forkDeployScript);

        DeployYvWETH2StrategyScript.YvWETH2DeployConfig memory config =
            DeployYvWETH2StrategyScript.YvWETH2DeployConfig({myt: address(forkMYT), yearnVault: YV_WETH_2_VAULT, params: params});

        ERC4626Strategy strategy = ERC4626Strategy(forkDeployScript.deployYvWETH2Strategy(forkOwner, config));
        assertEq(address(strategy.vault()), YV_WETH_2_VAULT, "unexpected Yearn vault");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");

        vm.prank(forkOwner);
        strategy.setKillSwitch(false);

        assertEq(IERC4626(YV_WETH_2_VAULT).asset(), forkMYT.asset(), "Yearn vault asset must match MYT");
        assertGt(IERC4626(YV_WETH_2_VAULT).maxDeposit(address(strategy)), 0, "Yearn vault has no deposit capacity");
    }

    function test_defaultParams_usesMainnetYearnWETH2Defaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4, "unexpected curator");
        assertEq(deployScript.ethMYT(), ETH_MYT, "unexpected ETH MYT");
        assertEq(deployScript.YV_WETH_2_VAULT(), YV_WETH_2_VAULT, "unexpected Yearn vault");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "Yearn Mainnet WETH-2", "unexpected name");
        assertEq(params.protocol, "Yearn", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.LOW), "unexpected risk class");
        assertEq(params.cap, 10_000e18, "unexpected cap");
        assertEq(params.globalCap, 1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 700, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }
}
