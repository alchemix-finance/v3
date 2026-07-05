// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployStakeDAOWETHStrategyScript} from "../../script/DeployStakeDAOWETHStrategy.s.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {StakeDAOWETHStrategy} from "../strategies/StakeDAOWETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockMYTForStakeDAOWETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract MockCurvePoolForStakeDAOWETHDeploy {}

contract MockRewardVaultForStakeDAOWETHDeploy {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract DeployStakeDAOWETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_REWARD_VAULT = 0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C;
    address internal constant MAINNET_ETH_PLUS_WETH_POOL = 0x2c683fAd51da2cd17793219CC86439C1875c353e;
    address internal constant MAINNET_ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_454_018;
    uint256 internal constant ALLOCATION_AMOUNT = 1e18;
    uint256 internal constant DEALLOCATION_TARGET = 0.5e18;

    DeployStakeDAOWETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal weth;
    MockMYTForStakeDAOWETHDeployTest internal myt;

    address internal newOwner;
    address internal rewardVault;
    address internal curvePool;
    address internal ensoRouter;

    function setUp() public {
        deployScript = new DeployStakeDAOWETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        weth = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForStakeDAOWETHDeployTest(address(weth));

        newOwner = makeAddr("newOwner");
        curvePool = address(new MockCurvePoolForStakeDAOWETHDeploy());
        rewardVault = address(new MockRewardVaultForStakeDAOWETHDeploy(curvePool));
        ensoRouter = makeAddr("ensoRouter");
    }

    function test_deployStakeDAOWETHStrategy_setsCoreAddressesAndDefaults() public {
        DeployStakeDAOWETHStrategyScript.StakeDAOWETHDeployConfig memory config =
            DeployStakeDAOWETHStrategyScript.StakeDAOWETHDeployConfig({
                myt: address(myt),
                rewardVault: rewardVault,
                curvePool: curvePool,
                ensoRouter: ensoRouter,
                wethCoinIndex: deployScript.WETH_COIN_INDEX(),
                params: _buildParams("StakeDAO Mainnet ETH+/WETH", "StakeDAO")
            });

        address strategyAddr = deployScript.deployStakeDAOWETHStrategy(curator, newOwner, config);
        StakeDAOWETHStrategy strategy = StakeDAOWETHStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.weth()), address(weth), "unexpected WETH");
        assertEq(address(strategy.rewardVault()), rewardVault, "unexpected reward vault");
        assertEq(address(strategy.curvePool()), curvePool, "unexpected curve pool");
        assertEq(strategy.ensoRouter(), ensoRouter, "unexpected enso router");
        assertEq(strategy.wethCoinIndex(), deployScript.WETH_COIN_INDEX(), "unexpected WETH coin index");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "StakeDAO Mainnet ETH+/WETH", "unexpected strategy name");
        assertEq(protocol, "StakeDAO", "unexpected protocol");
    }

    function test_deployStakeDAOWETHStrategy_blocksForceDeallocateSwap() public {
        DeployStakeDAOWETHStrategyScript.StakeDAOWETHDeployConfig memory config =
            DeployStakeDAOWETHStrategyScript.StakeDAOWETHDeployConfig({
                myt: address(myt),
                rewardVault: rewardVault,
                curvePool: curvePool,
                ensoRouter: ensoRouter,
                wethCoinIndex: deployScript.WETH_COIN_INDEX(),
                params: _buildParams("StakeDAO Mainnet ETH+/WETH", "StakeDAO")
            });

        address strategyAddr = deployScript.deployStakeDAOWETHStrategy(curator, newOwner, config);
        StakeDAOWETHStrategy strategy = StakeDAOWETHStrategy(strategyAddr);

        IMYTStrategy.VaultAdapterParams memory swapParams;
        swapParams.action = IMYTStrategy.ActionType.swap;
        swapParams.swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(address(myt));
        strategy.deallocate(abi.encode(swapParams), 1, IVaultV2.forceDeallocate.selector, address(myt));
    }

    function test_run_fork_deploysStakeDAOWETHWithMainnetDefaults() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployStakeDAOWETHStrategyScript forkDeployScript = new DeployStakeDAOWETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        StakeDAOWETHStrategy strategy = StakeDAOWETHStrategy(strategyAddr);
        IVaultV2 vault = IVaultV2(ETH_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.weth()), MAINNET_WETH, "unexpected WETH");
        assertEq(address(strategy.rewardVault()), MAINNET_REWARD_VAULT, "unexpected reward vault");
        assertEq(address(strategy.curvePool()), MAINNET_ETH_PLUS_WETH_POOL, "unexpected curve pool");
        assertEq(strategy.ensoRouter(), MAINNET_ENSO_ROUTER, "unexpected enso router");
        assertEq(strategy.wethCoinIndex(), forkDeployScript.WETH_COIN_INDEX(), "unexpected WETH coin index");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(vault.isAdapter(strategyAddr), "deploy script should not register strategy");
        assertEq(params.name, "StakeDAO Mainnet ETH+/WETH", "unexpected name");
        assertEq(params.protocol, "StakeDAO", "unexpected protocol");
    }

    function test_run_fork_allocatorCanAllocateAndDeallocateStakeDAOWETHDirect() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        vm.store(CURATOR_ADDR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));
        vm.store(ETH_ALLOCATOR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));

        DeployStakeDAOWETHStrategyScript forkDeployScript = new DeployStakeDAOWETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        StakeDAOWETHStrategy strategy = StakeDAOWETHStrategy(strategyAddr);
        AlchemistCurator liveCurator = AlchemistCurator(CURATOR_ADDR);
        IVaultV2 vault = IVaultV2(ETH_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        vm.startPrank(DEPLOYER);
        liveCurator.setOperator(DEPLOYER, true);
        liveCurator.submitSetStrategy(strategyAddr, ETH_MYT);
        liveCurator.setStrategy(strategyAddr, ETH_MYT);
        liveCurator.submitIncreaseAbsoluteCap(strategyAddr, params.cap);
        liveCurator.increaseAbsoluteCap(strategyAddr, params.cap);
        liveCurator.submitIncreaseRelativeCap(strategyAddr, params.globalCap);
        liveCurator.increaseRelativeCap(strategyAddr, params.globalCap);
        AlchemistAllocator(ETH_ALLOCATOR).setOperator(DEPLOYER, true);
        vm.stopPrank();

        assertTrue(vault.isAdapter(strategyAddr), "strategy not registered");
        assertEq(vault.absoluteCap(strategy.adapterId()), params.cap, "absolute cap not set");
        assertEq(vault.relativeCap(strategy.adapterId()), params.globalCap, "relative cap not set");

        uint256 vaultWethBalanceBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        deal(MAINNET_WETH, ETH_MYT, vaultWethBalanceBefore + ALLOCATION_AMOUNT);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setKillSwitch(false);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).allocate(strategyAddr, ALLOCATION_AMOUNT);

        uint256 strategyAssetsAfterAllocate = strategy.realAssets();
        assertGt(strategyAssetsAfterAllocate, 0, "strategy did not receive assets");
        assertGt(IERC20(MAINNET_REWARD_VAULT).balanceOf(strategyAddr), 0, "strategy should hold RewardVault shares");
        assertGt(vault.allocation(strategy.adapterId()), 0, "vault allocation not updated");

        uint256 vaultWethBeforeDeallocate = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 deallocationAmount = strategy.previewAdjustedWithdraw(DEALLOCATION_TARGET);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).deallocate(strategyAddr, deallocationAmount);

        assertLt(strategy.realAssets(), strategyAssetsAfterAllocate, "strategy assets should decrease");
        assertGt(IERC20(MAINNET_WETH).balanceOf(ETH_MYT), vaultWethBeforeDeallocate, "vault did not receive WETH back");
    }

    function test_defaultParams_usesMainnetStakeDAODefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), CURATOR_ADDR, "unexpected curator");
        assertEq(deployScript.ethMYT(), ETH_MYT, "unexpected ETH MYT");
        assertEq(deployScript.REWARD_VAULT(), MAINNET_REWARD_VAULT, "unexpected reward vault");
        assertEq(deployScript.ETH_PLUS_WETH_POOL(), MAINNET_ETH_PLUS_WETH_POOL, "unexpected curve pool");
        assertEq(deployScript.ENSO_ROUTER(), MAINNET_ENSO_ROUTER, "unexpected enso router");
        assertEq(deployScript.WETH_COIN_INDEX(), 1, "unexpected WETH coin index");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "StakeDAO Mainnet ETH+/WETH", "unexpected name");
        assertEq(params.protocol, "StakeDAO", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 5000e18, "unexpected cap");
        assertEq(params.globalCap, 0.3e18, "unexpected global cap");
        assertEq(params.estimatedYield, 500, "unexpected estimated yield");
        assertTrue(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 125, "unexpected slippage");
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
            cap: 5000e18,
            globalCap: 0.3e18,
            estimatedYield: 500,
            additionalIncentives: true,
            slippageBPS: 125
        });
    }
}
