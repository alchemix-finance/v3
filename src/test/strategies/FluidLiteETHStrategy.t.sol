// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {FluidLiteETHStrategy, IFluidLiteETHVault, ILidoWithdrawalQueue, IStETH} from "../../strategies/FluidLiteETHStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";

interface ILidoWithdrawalQueueAdmin {
    function finalize(uint256 lastRequestIdToBeFinalized, uint256 maxShareRate) external payable;
    function unfinalizedStETH() external view returns (uint256);
}

contract MockSwapperForFluidLiteETH {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract FluidLiteETHStrategyTest is Test {
    uint256 internal constant ABSOLUTE_CAP = 1_000_000e18;
    uint256 internal constant RELATIVE_CAP = 1e18;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant FEE_SCALE = 1e6;
    uint256 internal constant BASE_BPS = 50;
    uint256 internal constant UP_BPS_PER_DAY = 10;
    uint256 internal constant DOWN_BPS_PER_DAY = 2;
    uint256 internal constant MAX_UP_BPS = 200;
    uint256 internal constant MAX_DOWN_BPS = 100;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant IETH = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78;
    address public constant LIDO_WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    // Curve stETH/ETH pool, used as a stETH source since `deal` cannot write rebasing balances.
    address public constant STETH_WHALE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    MockMYTVault internal vault;
    AlchemistAllocator internal allocator;
    AlchemistStrategyClassifier internal classifier;
    FluidLiteETHStrategy internal strategy;

    address internal admin = address(0xA11CE);
    address internal operator = address(0xB0B);
    address internal keeper = address(0xBEEF);
    uint256 private _forkId;

    function setUp() public {
        _forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"), getForkBlockNumber());
        vm.selectFork(_forkId);

        vault = new MockMYTVault(admin, WETH);
        classifier = new AlchemistStrategyClassifier(admin);

        vm.startPrank(admin);
        vault.setCurator(operator);
        classifier.setRiskClass(0, 1e18, 1e18);
        classifier.setRiskClass(1, 0.4e18, 0.25e18);
        classifier.setRiskClass(2, 1e18, 1e18); // HIGH widened so the test can exercise the full cap.
        allocator = new AlchemistAllocator(address(vault), admin, operator, address(classifier));
        vm.stopPrank();

        vm.startPrank(operator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (admin)));
        vault.setPerformanceFeeRecipient(admin);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (15e16)));
        vault.setPerformanceFee(15e16);
        vm.stopPrank();

        vm.startPrank(admin);
        IMYTStrategy.StrategyParams memory params = _params();
        strategy = new FluidLiteETHStrategy(address(vault), params, IETH, STETH, LIDO_WITHDRAWAL_QUEUE, _guard());
        classifier.assignStrategyRiskLevel(uint256(IMYTStrategy(address(strategy)).adapterId()), uint8(params.riskClass));
        vm.stopPrank();

        _setUpMYT();
        _depositToVault(ABSOLUTE_CAP);
    }

    function test_constructor_wires_vault_and_queue() public view {
        assertEq(address(strategy.iETH()), IETH, "unexpected iETH");
        assertEq(address(strategy.stETH()), STETH, "unexpected stETH");
        assertEq(IFluidLiteETHVault(IETH).asset(), STETH, "iETHv2 asset should be stETH");
        assertEq(address(strategy.withdrawalQueue()), LIDO_WITHDRAWAL_QUEUE, "unexpected queue");
        assertEq(strategy.shareUnit(), 1e18, "iETHv2 has 18 decimals");
        assertEq(strategy.anchorPps(), IFluidLiteETHVault(IETH).previewRedeem(1e18), "anchor should start at the live price");
        assertGt(strategy.anchorPps(), 1e18, "iETHv2 PPS should be above 1 at the fork block");
        assertEq(strategy.baseBps(), BASE_BPS, "unexpected baseBps");
        assertEq(strategy.pendingExitCount(), 0, "no pending exit at deploy");
    }

    function test_constructor_reverts_on_asset_mismatch() public {
        vm.expectRevert(bytes("iETH asset != stETH"));
        new FluidLiteETHStrategy(address(vault), _params(), IETH, WETH, LIDO_WITHDRAWAL_QUEUE, _guard());
    }

    function test_allocate_direct_reverts_noLidoStaking() public {
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).allocate(address(strategy), 1e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), 0, "no shares should be minted");
        assertEq(IERC20(STETH).balanceOf(address(strategy)), 0, "no stETH should be held");
    }

    function test_allocateWithSwap_depositsReceivedStEthIntoIETH(uint256 amount) public {
        amount = bound(amount, 1e18, 500e18);

        _allocateViaSwap(amount);

        uint256 shares = IERC20(IETH).balanceOf(address(strategy));
        assertGt(shares, 0, "strategy should hold iETHv2 shares after swap allocation");
        assertLe(IERC20(STETH).balanceOf(address(strategy)), 2, "stETH should be deposited, not retained");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "no idle WETH after swap allocation");

        // Mock swap is 1:1 and iETHv2 has no deposit fee; valuation is par-marked.
        uint256 positionStETH = IFluidLiteETHVault(IETH).previewRedeem(shares);
        assertApproxEqRel(positionStETH, amount, 1e14, "position should track deposit 1:1");
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), positionStETH, 1e15);
    }

    function test_allocateWithSwap_reverts_below_par_minOut() public {
        uint256 amountIn = 10e18;
        uint256 shortOut = (amountIn * 9_800) / 10_000;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), shortOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amountIn, shortOut));

        vm.expectPartialRevert(IMYTStrategy.InvalidAmount.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);
    }

    function test_allocateWithSwap_accepts_stEth_at_slippage_floor() public {
        uint256 amountIn = 10e18;
        uint256 floorOut = (amountIn * (10_000 - SLIPPAGE_BPS)) / 10_000;
        // stETH transfers can land 1-2 wei short of the requested amount.
        uint256 swapOut = floorOut + 2;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), swapOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amountIn, swapOut));

        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);

        uint256 shares = IERC20(IETH).balanceOf(address(strategy));
        assertGt(shares, 0, "allocation at the floor should land");
        assertApproxEqAbs(IFluidLiteETHVault(IETH).previewRedeem(shares), floorOut, 4, "position should reflect the discounted fill");
        assertLt(IMYTStrategy(address(strategy)).realAssets(), amountIn, "swap loss must show up in NAV");
    }

    function test_allocateWithSwap_reverts_one_wei_below_slippage_floor() public {
        uint256 amountIn = 10e18;
        uint256 floorOut = (amountIn * (10_000 - SLIPPAGE_BPS)) / 10_000;
        uint256 swapOut = floorOut - 1;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), swapOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amountIn, swapOut));

        vm.expectPartialRevert(IMYTStrategy.InvalidAmount.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), 0, "failed allocation must not mint shares");
    }

    function test_realAssets_includesRawStEthBalance() public {
        _dealStETH(address(strategy), 3e18);

        uint256 raw = IERC20(STETH).balanceOf(address(strategy));
        assertApproxEqAbs(IMYTStrategy(address(strategy)).realAssets(), raw, 2, "raw stETH should count at par");
    }

    function test_deallocateWithUnwrapAndSwap_grossesUpVaultFee() public {
        _allocateViaSwap(10e18);

        uint256 minStETHOut = 4e18;
        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        uint256 positionBefore = IFluidLiteETHVault(IETH).previewRedeem(sharesBefore);
        uint256 allocationBefore = IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId());

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, minStETHOut, 4e18));

        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, minStETHOut);

        uint256 sharesAfter = IERC20(IETH).balanceOf(address(strategy));
        uint256 positionAfter = IFluidLiteETHVault(IETH).previewRedeem(sharesAfter);
        uint256 withdrawnFromVault = positionBefore - positionAfter;

        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore + 4e18, "vault should receive WETH");
        assertLt(sharesAfter, sharesBefore, "iETHv2 shares should be burned");
        assertLt(
            IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId()),
            allocationBefore,
            "allocation should decrease"
        );

        // The swap path withdraws a slippage-grossed stETH target, then sells `minStETHOut`.
        uint256 maxStEthIn = (4e18 * 10_000 + (10_000 - SLIPPAGE_BPS) - 1) / (10_000 - SLIPPAGE_BPS);
        uint256 feePct = IFluidLiteETHVault(IETH).withdrawalFeePercentage();
        uint256 expectedGross = (maxStEthIn * FEE_SCALE + (FEE_SCALE - feePct) - 1) / (FEE_SCALE - feePct) + 2;
        assertGt(withdrawnFromVault, minStETHOut, "gross withdrawal must exceed net target");
        assertApproxEqAbs(withdrawnFromVault, expectedGross, 4, "gross withdrawal should match fee math");

        uint256 leftover = IERC20(STETH).balanceOf(address(strategy));
        assertApproxEqAbs(leftover, maxStEthIn - minStETHOut, 4, "unused slippage buffer should remain as loose stETH");
    }

    function test_deallocateWithUnwrapAndSwap_sellsRawStEthBeforeTouchingVault() public {
        _allocateViaSwap(10e18);
        _dealStETH(address(strategy), 5e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 4e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "vault shares untouched when raw stETH suffices");
    }

    function test_deallocateWithUnwrapAndSwap_reverts_when_vault_idle_liquidity_too_low() public {
        _allocateViaSwap(10e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        vm.mockCall(STETH, abi.encodeWithSelector(IERC20.balanceOf.selector, IETH), abi.encode(uint256(1e18)));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        vm.expectRevert(bytes("Insufficient intermediate out"));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 4e18);
    }

    function test_deallocateWithUnwrapAndSwap_reverts_when_minOut_exceeds_slippage_bound() public {
        _allocateViaSwap(10e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        vm.expectRevert(bytes("Intermediate exceeds max stETH in"));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 8e18);
    }

    function test_deallocateWithUnwrapAndSwap_accepts_stEth_discount_within_slippage() public {
        _allocateViaSwap(10e18);

        uint256 wethOut = 4e18;
        uint256 maxStEthIn = (wethOut * 10_000 + (10_000 - SLIPPAGE_BPS) - 1) / (10_000 - SLIPPAGE_BPS);
        // Sell the whole slippage budget for exactly the shortfall: stETH fills at ~0.99 WETH.
        uint256 stEthIn = maxStEthIn - 4;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), wethOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 realBefore = IMYTStrategy(address(strategy)).realAssets();
        uint256 positionBefore = IFluidLiteETHVault(IETH).previewRedeem(IERC20(IETH).balanceOf(address(strategy)));
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, stEthIn, wethOut));

        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), wethOut, txData, stEthIn);

        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore + wethOut, "vault should receive the full amount");
        assertLe(IERC20(STETH).balanceOf(address(strategy)), 8, "whole stETH budget should be sold");

        // NAV drops by the WETH paid out, the dex discount on the stETH sold, and iETHv2's withdraw fee on the gross pull.
        uint256 grossWithdrawn = positionBefore - IFluidLiteETHVault(IETH).previewRedeem(IERC20(IETH).balanceOf(address(strategy)));
        uint256 vaultFee = IFluidLiteETHVault(IETH).getWithdrawFee(grossWithdrawn);
        uint256 realAfter = IMYTStrategy(address(strategy)).realAssets();
        assertGt(realBefore - realAfter, wethOut, "exit must cost more than the WETH paid out");
        assertApproxEqAbs(realBefore - realAfter, wethOut + (stEthIn - wethOut) + vaultFee, 1e12, "discount and fee should be realized in NAV");
    }

    function test_deallocateWithUnwrapAndSwap_reverts_when_swap_returns_below_shortfall() public {
        _allocateViaSwap(10e18);

        uint256 wethOut = 4e18;
        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), wethOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, wethOut, wethOut - 1));

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, wethOut, wethOut - 1));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), wethOut, txData, wethOut);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "failed exit must roll back the vault withdrawal");
        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore, "vault must not receive a partial fill");
    }

    function test_deallocateWithSwap_reverts_useUnwrapPath() public {
        _allocateViaSwap(10e18);

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithSwap(address(strategy), 1e18, hex"01");
    }

    function test_deallocate_direct_reverts_without_idle_weth() public {
        _allocateViaSwap(10e18);

        vm.expectRevert(bytes("Insufficient WETH available"));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocate(address(strategy), 1e18);
    }

    function test_deallocate_direct_serves_idle_weth() public {
        _allocateViaSwap(10e18);
        deal(WETH, address(strategy), 2e18);

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));

        vm.prank(admin);
        IAllocator(address(allocator)).deallocate(address(strategy), 2e18);

        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore + 2e18, "vault should receive idle WETH");
        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "direct path must not touch iETHv2");
    }

    function test_withdrawFromVault_redeemsStEthWithoutQueueing() public {
        _allocateViaSwap(10e18);
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));

        vm.prank(admin);
        uint256 received = strategy.withdrawFromVault(4e18);

        assertGe(received, 4e18, "full net stETH should land");
        assertEq(strategy.pendingExitCount(), 0, "vault withdraw must not open a Lido request");
        assertLt(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "shares should be redeemed");
        assertGe(IERC20(STETH).balanceOf(address(strategy)), 4e18, "stETH should sit on the strategy");
    }

    function test_withdrawFromVault_reverts_for_non_keeper() public {
        _allocateViaSwap(10e18);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.NotKeeper.selector, operator));
        vm.prank(operator);
        strategy.withdrawFromVault(1e18);
    }

    function test_withdrawFromVault_reverts_below_price_floor() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        (uint256 lower, uint256 upper) = strategy.priceBounds();
        uint256 crashed = (strategy.anchorPps() * 9_000) / 10_000;
        _mockPps(crashed);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideRoom.selector, crashed, lower, upper));
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "price drop must roll back the redeem");
        assertEq(strategy.pendingExitCount(), 0, "price drop must not open a request");
        assertFalse(strategy.killSwitch(), "price guard must not touch the kill switch");
        vm.clearMockedCalls();
    }

    function test_withdrawFromVault_reverts_when_amount_exceeds_position() public {
        _allocateViaSwap(10e18);
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));

        vm.expectRevert(bytes("Insufficient stETH withdrawn"));
        vm.prank(admin);
        strategy.withdrawFromVault(100e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "short withdraw must roll back");
    }

    function test_requestExits_queuesLooseStEthAndTracksPending() public {
        _allocateViaSwap(10e18);

        vm.prank(admin);
        strategy.withdrawFromVault(4e18);

        uint256 realBefore = IMYTStrategy(address(strategy)).realAssets();
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));

        vm.prank(admin);
        uint256 tokenId = strategy.requestExits(4e18);

        assertGt(tokenId, 0, "queue should mint a request id");
        assertTrue(strategy.isPendingExit(tokenId), "request should be tracked");
        assertEq(strategy.pendingExitCount(), 1, "one exit in flight");
        assertEq(strategy.claimableExits(), 0, "unfinalized request is not claimable");
        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "queue step must not touch iETHv2");
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), realBefore, 5e14, "NAV should hold the pending request at redemption value");
    }

    function test_requestExits_reverts_without_loose_stEth() public {
        _allocateViaSwap(10e18);
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));

        vm.expectRevert(bytes("Insufficient stETH"));
        vm.prank(admin);
        strategy.requestExits(1e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "failed queue must not redeem shares");
        assertEq(strategy.pendingExitCount(), 0, "no request opened");
    }

    function test_requestExits_reverts_for_non_keeper() public {
        _allocateViaSwap(10e18);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.NotKeeper.selector, operator));
        vm.prank(operator);
        strategy.requestExits(1e18);
    }

    function test_requestExits_allows_keeper() public {
        _allocateViaSwap(10e18);

        vm.prank(admin);
        strategy.setKeeper(keeper);

        vm.prank(keeper);
        strategy.withdrawFromVault(2e18);
        vm.prank(keeper);
        uint256 tokenId = strategy.requestExits(2e18);
        assertTrue(strategy.isPendingExit(tokenId), "keeper should be able to request");
    }

    function test_requestExits_reverts_when_exit_already_pending() public {
        _allocateViaSwap(10e18);

        uint256 tokenId = _requestExit(2e18);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.ExitPending.selector, tokenId));
        vm.prank(admin);
        strategy.requestExits(1e18);
    }

    function test_claimExits_reverts_before_finalization() public {
        _allocateViaSwap(10e18);

        _requestExit(2e18);

        vm.expectRevert();
        strategy.claimExits();
    }

    function test_claimExits_wrapsFinalizedRequestIntoIdleWeth() public {
        _allocateViaSwap(10e18);

        uint256 realBefore = IMYTStrategy(address(strategy)).realAssets();

        uint256 tokenId = _requestExit(4e18);
        _finalizeLidoRequest(tokenId);

        uint256 claimable = strategy.claimableExits();
        assertGt(claimable, 0, "finalized request should be claimable");
        assertApproxEqAbs(claimable, 4e18, 0.02e18, "claimable ETH should track the queued stETH");

        uint256 ethClaimed = strategy.claimExits();
        assertEq(ethClaimed, claimable, "claimed ETH should match claimable");
        assertEq(strategy.pendingExitCount(), 0, "pending exit should clear");
        assertEq(strategy.claimableExits(), 0, "nothing left to claim");
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(strategy)), ethClaimed, 1, "claimed ETH should be wrapped as idle WETH");
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), realBefore, 5e14, "NAV should be unchanged across request/finalize/claim");
    }

    function test_claimExits_finalized_below_face_marks_nav_down_at_finalization() public {
        _allocateViaSwap(10e18);

        uint256 tokenId = _requestExit(4e18);
        uint256 face = _status(tokenId).amountOfStETH;
        uint256 realPending = IMYTStrategy(address(strategy)).realAssets();

        // Lido finalizes the batch at 98% of the request's share rate (slashing / negative rebase).
        _finalizeLidoRequestAtRateBps(tokenId, 9_800);

        uint256 claimable = strategy.claimableExits();
        assertLt(claimable, face, "below-face finalization must pay less than face");
        assertApproxEqRel(claimable, (face * 9_800) / 10_000, 1e13, "claimable should follow the finalized share rate");

        uint256 realFinalized = IMYTStrategy(address(strategy)).realAssets();
        assertApproxEqAbs(realPending - realFinalized, face - claimable, 1e9, "NAV should drop by the haircut at finalization");

        uint256 ethClaimed = strategy.claimExits();
        assertEq(ethClaimed, claimable, "claim should pay the finalized amount");
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(strategy)), ethClaimed, 1, "claimed ETH should be wrapped");
        assertApproxEqAbs(IMYTStrategy(address(strategy)).realAssets(), realFinalized, 1e9, "claim itself must not move NAV");
    }

    function test_pendingExitValue_caps_at_face_and_marks_down_on_negative_rebase() public {
        _allocateViaSwap(10e18);

        uint256 tokenId = _requestExit(4e18);
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _status(tokenId);
        uint256 face = status.amountOfStETH;
        uint256 realAtFace = IMYTStrategy(address(strategy)).realAssets();

        // Positive rebase while pending: Lido pays at most face, so NAV must not inflate.
        vm.mockCall(
            STETH, abi.encodeWithSelector(IStETH.getPooledEthByShares.selector, status.amountOfShares), abi.encode((face * 103) / 100)
        );
        assertApproxEqAbs(IMYTStrategy(address(strategy)).realAssets(), realAtFace, 2, "pending value must cap at face");

        // Negative rebase while pending: the request is now worth less than face.
        uint256 marked = (face * 97) / 100;
        vm.mockCall(STETH, abi.encodeWithSelector(IStETH.getPooledEthByShares.selector, status.amountOfShares), abi.encode(marked));
        assertApproxEqAbs(
            IMYTStrategy(address(strategy)).realAssets(), realAtFace - (face - marked), 2, "pending value must follow the share rate down"
        );
        assertEq(strategy.claimableExits(), 0, "unfinalized request is still not claimable");
        vm.clearMockedCalls();
    }

    function test_deallocate_direct_autoClaims_finalized_exit() public {
        _allocateViaSwap(10e18);

        uint256 tokenId = _requestExit(4e18);
        _finalizeLidoRequest(tokenId);

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));

        vm.prank(admin);
        IAllocator(address(allocator)).deallocate(address(strategy), 4e18);

        assertEq(strategy.pendingExitCount(), 0, "deallocate should settle the matured exit");
        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore + 4e18, "vault should receive claimed WETH");
    }

    function test_claimWithdrawalQueue_reverts_unknown_exit() public {
        _allocateViaSwap(10e18);

        _requestExit(2e18);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.UnknownExit.selector, 99));
        vm.prank(admin);
        strategy.claimWithdrawalQueue(99);
    }

    function test_previewAdjustedWithdraw_is_conservative_and_accounts_for_fee() public {
        _allocateViaSwap(10e18);

        uint256 requested = 4e18;
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(requested);

        assertGt(preview, 0, "preview should be positive");
        assertLt(preview, requested, "preview should be below requested");
        assertGe(preview, (requested * (10_000 - SLIPPAGE_BPS)) / 10_000 - 1, "preview too pessimistic");
    }

    function test_previewAdjustedWithdraw_clamps_to_vault_idle_liquidity() public {
        _allocateViaSwap(10e18);

        uint256 liquidity = 2e18;
        vm.mockCall(STETH, abi.encodeWithSelector(IERC20.balanceOf.selector, IETH), abi.encode(liquidity));

        uint256 fee = IFluidLiteETHVault(IETH).getWithdrawFee(liquidity);
        uint256 expectedCap = ((liquidity - fee) * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(8e18);
        assertApproxEqAbs(preview, expectedCap, 2, "preview should clamp to net idle liquidity");
    }

    function test_previewAdjustedWithdraw_returns_full_amount_from_idle() public {
        deal(WETH, address(strategy), 5e18);
        assertEq(IMYTStrategy(address(strategy)).previewAdjustedWithdraw(5e18), 5e18, "idle covers request");
    }

    function test_previewAdjustedWithdraw_clamps_fee_above_deliverable() public {
        _allocateViaSwap(10e18);

        // Simulates a Fluid vault with a non-zero withdrawFeeAbsoluteMin (zero on mainnet today):
        // fee exceeding the deliverable stETH must clamp to zero, not underflow (Panic 0x11).
        vm.mockCall(IETH, IFluidLiteETHVault.getWithdrawFee.selector, abi.encode(1e30));

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(8e18);
        assertEq(preview, 0, "fee above deliverable must clamp position value to zero");
    }

    function test_previewAdjustedWithdraw_excludes_pending_queue_request() public {
        _allocateViaSwap(10e18);

        _requestExit(4e18);

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(8e18);
        uint256 idle = IERC20(WETH).balanceOf(address(strategy));
        assertEq(idle, 0, "no idle WETH while the request is pending");
        assertLt(preview, 8e18, "pending request must not inflate instant capacity");
    }

    function test_setKeeper_onlyOwner() public {
        vm.expectRevert();
        vm.prank(operator);
        strategy.setKeeper(keeper);

        vm.prank(admin);
        strategy.setKeeper(keeper);
        assertEq(strategy.keeper(), keeper, "keeper should update");
    }

    function test_setPriceGuard_bounds_and_onlyOwner() public {
        FluidLiteETHStrategy.PriceGuardParams memory guard = _guard();

        vm.expectRevert();
        vm.prank(operator);
        strategy.setPriceGuard(guard);

        guard.maxDownBps = 10_000;
        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.InvalidBps.selector, 10_000));
        vm.prank(admin);
        strategy.setPriceGuard(guard);

        guard.maxDownBps = 300;
        vm.prank(admin);
        strategy.setPriceGuard(guard);
        assertEq(strategy.maxDownBps(), 300, "guard should update");
    }

    function test_priceGuard_reverts_allocation_outside_band_both_sides() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 anchor = strategy.anchorPps();
        (uint256 lower, uint256 upper) = strategy.priceBounds();

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), 2e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, 1e18, 1e18));

        uint256 crashed = (anchor * 9_000) / 10_000;
        _mockPps(crashed);
        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideRoom.selector, crashed, lower, upper));
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);

        uint256 pumped = (anchor * 11_000) / 10_000;
        _mockPps(pumped);
        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideRoom.selector, pumped, lower, upper));
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);

        assertEq(strategy.anchorPps(), anchor, "rejected prices must not move the anchor");
        assertFalse(strategy.killSwitch(), "price guard must not touch the kill switch");
        vm.clearMockedCalls();
    }

    function test_priceGuard_floor_boundary_on_vault_withdraw() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 anchor = strategy.anchorPps();
        (uint256 lower, uint256 upper) = strategy.priceBounds();
        assertEq(lower, (anchor * (10_000 - BASE_BPS)) / 10_000, "floor should be baseBps below the anchor at zero elapsed");

        _mockPps(lower - 1);
        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideRoom.selector, lower - 1, lower, upper));
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);

        _mockPps(lower);
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);
        // baseBps room is excluded from anchor travel, so a pass at the floor does not drag the anchor down.
        assertEq(strategy.anchorPps(), anchor, "anchor must not move by the base room");
        vm.clearMockedCalls();
    }

    function test_priceGuard_slowBleed_trips_against_anchor() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 anchor = strategy.anchorPps();
        (uint256 lower, uint256 upper) = strategy.priceBounds();

        // 40 bp down is inside the 50 bp base room.
        uint256 step1 = (anchor * (10_000 - 40)) / 10_000;
        _mockPps(step1);
        vm.prank(admin);
        strategy.withdrawFromVault(0.5e18);
        assertEq(strategy.anchorPps(), anchor, "anchor must stay put with no elapsed budget");

        // Another 40 bp is measured against the same anchor, so the cumulative 80 bp trips.
        uint256 step2 = (step1 * (10_000 - 40)) / 10_000;
        _mockPps(step2);
        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideRoom.selector, step2, lower, upper));
        vm.prank(admin);
        strategy.withdrawFromVault(0.5e18);
        vm.clearMockedCalls();
    }

    /// @dev Replays the worst moves in ~360 days of iETHv2 `exchangePrice` history (see
    ///      `defaultPriceGuard` in the deploy script) and checks none of them trip the guard or
    ///      exhaust the anchor budget.
    function test_priceGuard_absorbs_worst_realized_iETHv2_moves() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 anchor = strategy.anchorPps();

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), 3e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, 1e18, 1e18));

        // Worst 30-day drift (+54 bp) with nobody poking: allocation passes and one touch re-anchors.
        vm.warp(block.timestamp + 30 days);
        uint256 after30d = (anchor * (10_000 + 54)) / 10_000;
        _mockPps(after30d);
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);
        assertEq(strategy.anchorPps(), after30d, "30 days of up budget should fully absorb a 54 bp lag");

        // Worst single rebalancer update (+4.8 bp) landing right after, with zero elapsed budget.
        uint256 afterStep = (after30d * (10_000 + 5)) / 10_000;
        _mockPps(afterStep);
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);
        assertEq(strategy.anchorPps(), after30d, "zero elapsed: step is absorbed by baseBps, anchor stays");

        // Worst peak-to-trough drawdown (-2.2 bp, rounded up to 3) from the live mark: exits stay open.
        uint256 afterDraw = (afterStep * (10_000 - 3)) / 10_000;
        _mockPps(afterDraw);
        vm.prank(admin);
        strategy.withdrawFromVault(0.5e18);
        assertEq(strategy.anchorPps(), after30d, "a drawdown well inside baseBps leaves the anchor alone");

        // A year of realized drift (+336 bp) between touches tops out the per-touch budget, but
        // allocation still passes once the anchor has been poked back within range.
        vm.warp(block.timestamp + 365 days);
        uint256 afterYear = (after30d * (10_000 + 336)) / 10_000;
        _mockPps(afterYear);
        strategy.poke();
        assertEq(strategy.anchorPps(), (after30d * (10_000 + MAX_UP_BPS)) / 10_000, "single poke is capped at maxUpBps");
        vm.warp(block.timestamp + 14 days);
        strategy.poke();
        assertEq(strategy.anchorPps(), afterYear, "two weeks of budget closes the remaining 136 bp");
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);
        vm.clearMockedCalls();
    }

    function test_acceptPrice_onlyOwner_and_bounds() public {
        _allocateViaSwap(10e18);
        uint256 live = strategy.liveSharePrice();

        vm.expectRevert();
        vm.prank(operator);
        strategy.acceptPrice(0, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PriceOutsideAcceptBounds.selector, live, live + 1, live + 2));
        vm.prank(admin);
        strategy.acceptPrice(live + 1, live + 2);

        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        strategy.acceptPrice(live, live);
        assertEq(strategy.anchorPps(), live, "anchor should be set to live");
        assertEq(strategy.anchorTimestamp(), block.timestamp, "anchor timestamp should reset");
    }

    function test_acceptPrice_unblocks_after_crash_and_books_loss() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 realBefore = IMYTStrategy(address(strategy)).realAssets();
        uint256 crashed = (strategy.anchorPps() * 9_000) / 10_000;
        _mockPpsRatio(9_000);

        vm.expectPartialRevert(FluidLiteETHStrategy.PriceOutsideRoom.selector);
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);

        vm.prank(admin);
        strategy.acceptPrice(crashed, crashed);
        assertEq(strategy.anchorPps(), crashed, "owner acceptance should re-anchor at the crashed price");

        // Loss is now fully reported and the vault is usable again.
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), (realBefore * 9_000) / 10_000, 1e12, "loss should be booked on accept");
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);
        vm.clearMockedCalls();
    }

    function test_poke_drifts_anchor_within_time_budget() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 anchor = strategy.anchorPps();

        // Live 2% below. Zero elapsed: nothing moves.
        _mockPps((anchor * 9_800) / 10_000);
        strategy.poke();
        assertEq(strategy.anchorPps(), anchor, "no budget at zero elapsed");

        // One day: anchor may fall by downBpsPerDay.
        vm.warp(block.timestamp + 1 days);
        strategy.poke();
        uint256 afterDown = (anchor * (10_000 - DOWN_BPS_PER_DAY)) / 10_000;
        assertEq(strategy.anchorPps(), afterDown, "anchor should fall by one day of down budget");
        assertEq(strategy.anchorTimestamp(), block.timestamp, "move should reset the clock");

        // Live 2% above. One day: anchor may rise by upBpsPerDay.
        _mockPps((afterDown * 10_200) / 10_000);
        vm.warp(block.timestamp + 1 days);
        strategy.poke();
        assertEq(strategy.anchorPps(), (afterDown * (10_000 + UP_BPS_PER_DAY)) / 10_000, "anchor should rise by one day of up budget");

        // Long idle: travel is capped at maxDownBps regardless of elapsed time.
        uint256 before = strategy.anchorPps();
        _mockPps(before / 2);
        vm.warp(block.timestamp + 365 days);
        strategy.poke();
        assertEq(strategy.anchorPps(), (before * (10_000 - MAX_DOWN_BPS)) / 10_000, "single update capped at maxDownBps");
        vm.clearMockedCalls();
    }

    function test_totalValue_clamps_vault_leg_to_band() public {
        _allocateViaSwap(10e18);
        _resetAnchor();
        uint256 realBefore = IMYTStrategy(address(strategy)).realAssets();

        // 10% crash: NAV reports the floor (baseBps below anchor), not the live mark.
        _mockPpsRatio(9_000);
        uint256 expectedFloor = (realBefore * (10_000 - BASE_BPS)) / 10_000;
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), expectedFloor, 1e12, "crash should be clamped to the floor");

        // 10% pump: NAV reports the ceiling.
        _mockPpsRatio(11_000);
        uint256 expectedCeil = (realBefore * (10_000 + BASE_BPS)) / 10_000;
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), expectedCeil, 1e12, "pump should be clamped to the ceiling");

        // Inside the band: live mark passes through unchanged.
        _mockPpsRatio(9_970);
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), (realBefore * 9_970) / 10_000, 1e12, "in-band move reports live");
        vm.clearMockedCalls();
    }

    function test_rescue_reverts_for_protected_tokens() public {
        address[4] memory protectedTokens = [WETH, STETH, IETH, LIDO_WITHDRAWAL_QUEUE];
        for (uint256 i; i < protectedTokens.length; i++) {
            vm.expectRevert();
            vm.prank(admin);
            MYTStrategy(address(strategy)).rescueTokens(protectedTokens[i], admin, 1);
        }
    }

    function test_onERC721Received_reverts_for_unexpected_sender() public {
        vm.expectRevert(bytes("Unexpected NFT sender"));
        strategy.onERC721Received(admin, admin, 1, "");
    }

    function test_setCanForceDeallocate_onlyOwner() public {
        assertFalse(strategy.canForceDeallocate(), "force deallocate defaults off");

        vm.expectRevert();
        vm.prank(operator);
        strategy.setCanForceDeallocate(true);

        vm.prank(admin);
        strategy.setCanForceDeallocate(true);
        assertTrue(strategy.canForceDeallocate(), "owner can enable force deallocate");
    }

    function _params() internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: admin,
            name: "FluidLiteETH",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: SLIPPAGE_BPS
        });
    }

    function _guard() internal pure returns (FluidLiteETHStrategy.PriceGuardParams memory) {
        return FluidLiteETHStrategy.PriceGuardParams({
            baseBps: BASE_BPS,
            upBpsPerDay: UP_BPS_PER_DAY,
            downBpsPerDay: DOWN_BPS_PER_DAY,
            maxUpBps: MAX_UP_BPS,
            maxDownBps: MAX_DOWN_BPS
        });
    }

    /// @dev Re-anchor at the live price now, so band tests start with zero elapsed budget.
    function _resetAnchor() internal {
        vm.prank(admin);
        strategy.acceptPrice(0, type(uint256).max);
    }

    /// @dev Redeem iETHv2 to stETH, then queue that stETH. Mirrors the keeper sequence.
    function _requestExit(uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(admin);
        strategy.withdrawFromVault(amount);
        vm.prank(admin);
        tokenId = strategy.requestExits(amount);
    }

    /// @dev Enter the position through the only supported path: a 1:1 WETH->stETH mock swap.
    function _allocateViaSwap(uint256 amount) internal {
        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), amount);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amount, amount));

        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amount, txData);
    }

    /// @dev Pin the iETHv2 PPS the guard reads. Only `previewRedeem(1e18)` is mocked, so
    ///      position valuation and real withdrawals keep using the live vault.
    function _mockPps(uint256 pps) internal {
        vm.mockCall(IETH, abi.encodeWithSelector(IFluidLiteETHVault.previewRedeem.selector, uint256(1e18)), abi.encode(pps));
    }

    /// @dev Scale both the unit PPS and the strategy's position preview by `ratioBps`, so the
    ///      live mark and the raw share value move together as they would on a real repricing.
    function _mockPpsRatio(uint256 ratioBps) internal {
        vm.clearMockedCalls();
        uint256 shares = IERC20(IETH).balanceOf(address(strategy));
        uint256 unit = IFluidLiteETHVault(IETH).previewRedeem(1e18);
        uint256 raw = IFluidLiteETHVault(IETH).previewRedeem(shares);
        _mockPps((unit * ratioBps) / 10_000);
        vm.mockCall(IETH, abi.encodeWithSelector(IFluidLiteETHVault.previewRedeem.selector, shares), abi.encode((raw * ratioBps) / 10_000));
    }

    function _dealStETH(address to, uint256 amount) internal {
        vm.prank(STETH_WHALE);
        require(IERC20(STETH).transfer(to, amount), "stETH deal failed");
    }

    function _status(uint256 requestId) internal view returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        return ILidoWithdrawalQueue(LIDO_WITHDRAWAL_QUEUE).getWithdrawalStatus(ids)[0];
    }

    /// @dev Lido only finalizes on an oracle report. Tests impersonate stETH (FINALIZE_ROLE) and
    ///      lock the unfinalized ETH so `claimWithdrawal` can pay the strategy.
    function _finalizeLidoRequest(uint256 requestId) internal {
        _finalizeLidoRequestAtShareRate(requestId, type(uint256).max);
    }

    /// @dev Finalize at a fraction of the request's own share rate. Lido caps the payout at
    ///      `shares * maxShareRate`, so anything below 10_000 bps pays less than face.
    function _finalizeLidoRequestAtRateBps(uint256 requestId, uint256 rateBps) internal {
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _status(requestId);
        uint256 requestShareRate = (status.amountOfStETH * 1e27) / status.amountOfShares;
        _finalizeLidoRequestAtShareRate(requestId, (requestShareRate * rateBps) / 10_000);
    }

    function _finalizeLidoRequestAtShareRate(uint256 requestId, uint256 maxShareRate) internal {
        uint256 ethToLock = _status(requestId).amountOfStETH;
        vm.deal(STETH, ethToLock);
        vm.prank(STETH);
        ILidoWithdrawalQueueAdmin(LIDO_WITHDRAWAL_QUEUE).finalize{value: ethToLock}(requestId, maxShareRate);
    }

    function _setUpMYT() internal {
        vm.startPrank(operator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        IVaultV2(address(vault)).setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(strategy)));
        IVaultV2(address(vault)).addAdapter(address(strategy));

        bytes memory idData = IMYTStrategy(address(strategy)).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, ABSOLUTE_CAP)));
        IVaultV2(address(vault)).increaseAbsoluteCap(idData, ABSOLUTE_CAP);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        IVaultV2(address(vault)).increaseRelativeCap(idData, RELATIVE_CAP);
        vm.stopPrank();
    }

    function _depositToVault(uint256 amount) internal {
        deal(WETH, admin, amount);
        vm.startPrank(admin);
        TokenUtils.safeApprove(WETH, address(vault), amount);
        IVaultV2(address(vault)).deposit(amount, admin);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(address(vault)).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(address(vault)).timelock(selector));
    }

    function getForkBlockNumber() internal pure returns (uint256) {
        return 26_156_774;
    }
}
