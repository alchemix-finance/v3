// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {DeployYvWETHStrategyScript} from "../../script/DeployYvWETHStrategy.s.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockMYTForYvWETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployYvWETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    uint256 internal constant MAINNET_FORK_BLOCK = 24_980_826;
    uint256 internal constant ALLOCATION_AMOUNT = 100e18;
    uint256 internal constant DEALLOCATION_AMOUNT = ((ALLOCATION_AMOUNT * 95) / 100);

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
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployYvWETHStrategyScript.YvWETHDeployConfig memory config =
            DeployYvWETHStrategyScript.YvWETHDeployConfig({myt: address(myt), yearnVault: address(yearnVault), params: params});

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

    function test_run_fork_allocatorCanAllocateAndDeallocateYvWETH() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);
        // The script performs admin-only curator cap updates, so mirror that authority on the fork.
        vm.store(CURATOR_ADDR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));

        DeployYvWETHStrategyScript forkDeployScript = new DeployYvWETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);
        IVaultV2 vault = IVaultV2(ETH_MYT);

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(address(strategy.mytAsset()), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.vault()), forkDeployScript.YV_WETH_VAULT(), "unexpected Yearn vault");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(vault.isAdapter(strategyAddr), "strategy not registered");
        assertEq(vault.absoluteCap(strategy.adapterId()), 10_000e18, "absolute cap not set");
        assertEq(vault.relativeCap(strategy.adapterId()), 1e18, "relative cap not set");

        uint256 vaultWethBalanceBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 depositAmount = 10e18;
        // Fund the live MYT directly to avoid its preconfigured liquidity adapter on deposit.
        deal(MAINNET_WETH, ETH_MYT, vaultWethBalanceBefore + depositAmount);

        // The deploy script intentionally leaves the strategy paused until governance enables it.
        vm.prank(MAINNET_NEW_OWNER);
        strategy.setKillSwitch(false);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).allocate(strategyAddr, ALLOCATION_AMOUNT);

        assertGt(strategy.realAssets(), 0, "strategy did not receive assets");
        assertGt(vault.allocation(strategy.adapterId()), 0, "vault allocation not updated");

        uint256 vaultWethBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 deallocationAmount = strategy.previewAdjustedWithdraw(DEALLOCATION_AMOUNT);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).deallocate(strategyAddr, deallocationAmount);

        uint256 expectedRemainingAssets = ALLOCATION_AMOUNT - deallocationAmount;
        assertApproxEqAbs(strategy.realAssets(), expectedRemainingAssets, 1e15, "unexpected remaining strategy assets");
        assertGt(IERC20(MAINNET_WETH).balanceOf(ETH_MYT), vaultWethBefore, "vault did not receive WETH back");
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
}
