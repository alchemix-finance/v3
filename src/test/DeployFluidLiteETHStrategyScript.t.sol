// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployFluidLiteETHStrategyScript} from "../../script/DeployFluidLiteETHStrategy.s.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {FluidLiteETHStrategy} from "../strategies/FluidLiteETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockSwapperForFluidLiteETHDeployTest {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract MockMYTForFluidLiteETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployFluidLiteETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant MAINNET_IETH = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78;
    address internal constant MAINNET_LIDO_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    address internal constant ETH_CLASSIFIER = 0xdb7d25b0bfd1585a797f6BF7d7CCBa26E77253cc;
    // Admin of both the live ETH allocator and classifier; also the strategy's post-deploy owner.
    address internal constant MAINNET_ALLOCATOR_ADMIN = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    // Curve stETH/ETH pool, used as a stETH source since `deal` cannot write rebasing balances.
    address internal constant STETH_WHALE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 internal constant MAINNET_FORK_BLOCK = 26_156_774;
    uint256 internal constant ALLOCATION_AMOUNT = 10e18;
    uint256 internal constant DEALLOCATION_TARGET = 4e18;

    DeployFluidLiteETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForFluidLiteETHDeployTest internal myt;

    address internal newOwner;
    address internal iETH;
    address internal stETH;
    address internal withdrawalQueue;

    function setUp() public {
        deployScript = new DeployFluidLiteETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForFluidLiteETHDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        iETH = makeAddr("iETH");
        stETH = makeAddr("stETH");
        withdrawalQueue = makeAddr("withdrawalQueue");

        // Constructor sanity check reads `asset()` from the vault.
        vm.mockCall(iETH, abi.encodeWithSignature("asset()"), abi.encode(stETH));
    }

    function test_deployFluidLiteETHStrategy_setsCoreAddresses() public {
        DeployFluidLiteETHStrategyScript.FluidLiteETHDeployConfig memory config = DeployFluidLiteETHStrategyScript
            .FluidLiteETHDeployConfig({
            myt: address(myt),
            fluidLiteVault: iETH,
            stETH: stETH,
            withdrawalQueue: withdrawalQueue,
            params: _buildParams("Fluid Lite Mainnet ETH", "FluidLite")
        });

        address strategyAddr = deployScript.deployFluidLiteETHStrategy(curator, newOwner, config);
        FluidLiteETHStrategy strategy = FluidLiteETHStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.iETH()), iETH, "unexpected iETH");
        assertEq(address(strategy.stETH()), stETH, "unexpected stETH");
        assertEq(address(strategy.withdrawalQueue()), withdrawalQueue, "unexpected withdrawal queue");
        assertEq(strategy.killSwitch(), true, "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(strategyName, "Fluid Lite Mainnet ETH", "unexpected strategy name");
        assertEq(protocol, "FluidLite", "unexpected protocol");
        assertEq(uint8(riskClass), uint8(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
    }

    function test_defaultParams_matchMainnetConstants() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        assertEq(deployScript.FLUID_LITE_ETH_VAULT(), MAINNET_IETH, "unexpected iETHv2 address");
        assertEq(deployScript.STETH(), MAINNET_STETH, "unexpected stETH address");
        assertEq(deployScript.LIDO_WITHDRAWAL_QUEUE(), MAINNET_LIDO_QUEUE, "unexpected Lido queue address");
        assertEq(deployScript.ethMYT(), ETH_MYT, "unexpected ETH MYT");
        assertEq(params.name, "Fluid Lite Mainnet ETH", "unexpected name");
        assertEq(params.protocol, "FluidLite", "unexpected protocol");
        assertEq(uint8(params.riskClass), uint8(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.globalCap, 0.1e18, "unexpected global cap");
    }

    function test_run_fork_allocatorCanAllocateAndDeallocateFluidLiteETH() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        // Mirror curator admin authority so the test can perform post-deploy registration and cap setup.
        vm.store(CURATOR_ADDR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));

        DeployFluidLiteETHStrategyScript forkDeployScript = new DeployFluidLiteETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        FluidLiteETHStrategy strategy = FluidLiteETHStrategy(payable(strategyAddr));
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
        vm.stopPrank();

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.iETH()), MAINNET_IETH, "unexpected iETHv2");
        assertEq(address(strategy.stETH()), MAINNET_STETH, "unexpected stETH");
        assertEq(address(strategy.withdrawalQueue()), MAINNET_LIDO_QUEUE, "unexpected Lido queue");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertTrue(vault.isAdapter(strategyAddr), "strategy not registered");
        assertEq(vault.absoluteCap(strategy.adapterId()), params.cap, "absolute cap not set");
        assertEq(vault.relativeCap(strategy.adapterId()), params.globalCap, "relative cap not set");

        // Classify as HIGH on the live classifier so the allocator applies the right risk caps.
        uint256 strategyId = uint256(strategy.adapterId());
        vm.prank(MAINNET_ALLOCATOR_ADMIN);
        AlchemistStrategyClassifier(ETH_CLASSIFIER).assignStrategyRiskLevel(strategyId, uint8(params.riskClass));

        uint256 vaultWethBalanceBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        deal(MAINNET_WETH, ETH_MYT, vaultWethBalanceBefore + ALLOCATION_AMOUNT);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setKillSwitch(false);

        // Direct allocation (Lido staking) is not supported; entry is swap-only.
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(MAINNET_ALLOCATOR_ADMIN);
        IAllocator(ETH_ALLOCATOR).allocate(strategyAddr, ALLOCATION_AMOUNT);

        // Allocate through a 1:1 WETH->stETH mock route, as the off-chain router would.
        MockSwapperForFluidLiteETHDeployTest entrySwapper = new MockSwapperForFluidLiteETHDeployTest();
        vm.prank(STETH_WHALE);
        require(IERC20(MAINNET_STETH).transfer(address(entrySwapper), ALLOCATION_AMOUNT), "stETH deal failed");

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setAllowanceHolder(address(entrySwapper));

        bytes memory entryTxData = abi.encodeCall(
            MockSwapperForFluidLiteETHDeployTest.swap, (MAINNET_WETH, MAINNET_STETH, ALLOCATION_AMOUNT, ALLOCATION_AMOUNT)
        );

        vm.prank(MAINNET_ALLOCATOR_ADMIN);
        IAllocator(ETH_ALLOCATOR).allocateWithSwap(strategyAddr, ALLOCATION_AMOUNT, entryTxData);

        uint256 strategyAssetsAfterAllocate = strategy.realAssets();
        assertGt(strategyAssetsAfterAllocate, 0, "strategy did not receive assets");
        assertGt(IERC20(MAINNET_IETH).balanceOf(strategyAddr), 0, "strategy should hold iETHv2");
        assertGt(vault.allocation(strategy.adapterId()), 0, "vault allocation not updated");

        // Mirror the off-chain router: deallocate the preview-adjusted WETH amount and quote a 1:1 stETH->WETH
        // swap for exactly that shortfall. The strategy grosses the vault withdrawal up for the fee internally.
        uint256 deallocationAmount = strategy.previewAdjustedWithdraw(DEALLOCATION_TARGET);
        uint256 stEthToSell = deallocationAmount;

        MockSwapperForFluidLiteETHDeployTest swapper = new MockSwapperForFluidLiteETHDeployTest();
        deal(MAINNET_WETH, address(swapper), deallocationAmount);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(
            MockSwapperForFluidLiteETHDeployTest.swap, (MAINNET_STETH, MAINNET_WETH, stEthToSell, deallocationAmount)
        );

        uint256 vaultWethBeforeDeallocate = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 iEthSharesBeforeDeallocate = IERC20(MAINNET_IETH).balanceOf(strategyAddr);

        vm.prank(MAINNET_ALLOCATOR_ADMIN);
        IAllocator(ETH_ALLOCATOR).deallocateWithUnwrapAndSwap(strategyAddr, deallocationAmount, txData, stEthToSell);

        assertLt(IERC20(MAINNET_IETH).balanceOf(strategyAddr), iEthSharesBeforeDeallocate, "iETHv2 shares should be burned");

        assertLt(strategy.realAssets(), strategyAssetsAfterAllocate, "strategy assets should decrease");
        // Swap path withdraws a slippage-grossed stETH amount and sells `stEthToSell`; the unused buffer stays loose.
        uint256 leftover = IERC20(MAINNET_STETH).balanceOf(strategyAddr);
        uint256 maxStEthIn = (deallocationAmount * 10_000 + (10_000 - params.slippageBPS) - 1) / (10_000 - params.slippageBPS);
        assertApproxEqAbs(leftover, maxStEthIn - stEthToSell, 4, "unused slippage buffer should remain as loose stETH");
        assertGt(IERC20(MAINNET_WETH).balanceOf(ETH_MYT), vaultWethBeforeDeallocate, "vault did not receive WETH back");
    }

    function _buildParams(string memory name, string memory protocol) internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 25e18,
            globalCap: 0.1e18,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
