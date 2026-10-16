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
import {FluidLiteETHStrategy, IFluidLiteETHVault, ILidoWithdrawalQueue} from "../../strategies/FluidLiteETHStrategy.sol";
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
        strategy = new FluidLiteETHStrategy(address(vault), params, IETH, STETH, LIDO_WITHDRAWAL_QUEUE);
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
        assertEq(strategy.maxPpsDropBps(), 50, "unexpected default PPS-drop bound");
        assertEq(strategy.pendingExitCount(), 0, "no pending exit at deploy");
    }

    function test_constructor_reverts_on_asset_mismatch() public {
        vm.expectRevert(bytes("iETH asset != stETH"));
        new FluidLiteETHStrategy(address(vault), _params(), IETH, WETH, LIDO_WITHDRAWAL_QUEUE);
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
        assertGt(strategy.lastPps(), 0, "allocation should record the PPS");
    }

    function test_allocateWithSwap_reverts_below_par_minOut() public {
        uint256 amountIn = 10e18;
        uint256 shortOut = (amountIn * 9_800) / 10_000;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), shortOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amountIn, shortOut));

        vm.expectRevert();
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);
    }

    function test_realAssets_includesRawStEthBalance() public {
        _dealStETH(address(strategy), 3e18);

        uint256 raw = IERC20(STETH).balanceOf(address(strategy));
        assertApproxEqAbs(IMYTStrategy(address(strategy)).realAssets(), raw, 2, "raw stETH should count at par");
    }

    /* ========== DEALLOCATION ========== */

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

    function test_withdrawFromVault_reverts_on_pps_drop() public {
        _allocateViaSwap(10e18);
        uint256 lastPps = strategy.lastPps();
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        uint256 crashed = (lastPps * 9_000) / 10_000;
        vm.mockCall(IETH, abi.encodeWithSelector(IFluidLiteETHVault.previewRedeem.selector, uint256(1e18)), abi.encode(crashed));

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PpsDropExceeded.selector, lastPps, crashed));
        vm.prank(admin);
        strategy.withdrawFromVault(1e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "PPS drop must not redeem shares");
        assertEq(strategy.pendingExitCount(), 0, "PPS drop must not open a request");
        assertFalse(strategy.killSwitch(), "PPS guard must not touch the kill switch");
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

    /* ========== PREVIEW ========== */

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

    function test_previewAdjustedWithdraw_excludes_pending_queue_request() public {
        _allocateViaSwap(10e18);

        _requestExit(4e18);

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(8e18);
        uint256 idle = IERC20(WETH).balanceOf(address(strategy));
        assertEq(idle, 0, "no idle WETH while the request is pending");
        assertLt(preview, 8e18, "pending request must not inflate instant capacity");
    }

    /* ========== ADMIN / GUARDS ========== */

    function test_setKeeper_onlyOwner() public {
        vm.expectRevert();
        vm.prank(operator);
        strategy.setKeeper(keeper);

        vm.prank(admin);
        strategy.setKeeper(keeper);
        assertEq(strategy.keeper(), keeper, "keeper should update");
    }

    function test_setMaxPpsDropBps_bounds_and_onlyOwner() public {
        vm.expectRevert();
        vm.prank(operator);
        strategy.setMaxPpsDropBps(10);

        vm.expectRevert(bytes("PPS drop bound too high"));
        vm.prank(admin);
        strategy.setMaxPpsDropBps(5001);

        vm.prank(admin);
        strategy.setMaxPpsDropBps(100);
        assertEq(strategy.maxPpsDropBps(), 100, "PPS-drop bound should update");
    }

    function test_ppsGuard_reverts_allocation_on_pps_drop() public {
        _allocateViaSwap(10e18);
        uint256 lastPps = strategy.lastPps();
        assertGt(lastPps, 0, "PPS should be recorded");

        uint256 crashed = (lastPps * 9_000) / 10_000; // 10% drop vs 50 bp bound
        vm.mockCall(IETH, abi.encodeWithSelector(IFluidLiteETHVault.previewRedeem.selector, uint256(1e18)), abi.encode(crashed));

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), 1e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, 1e18, 1e18));

        vm.expectRevert(abi.encodeWithSelector(FluidLiteETHStrategy.PpsDropExceeded.selector, lastPps, crashed));
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 1e18, txData);

        assertFalse(strategy.killSwitch(), "PPS guard must not touch the kill switch");
        assertEq(strategy.lastPps(), lastPps, "failed check must keep the last good PPS");
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

    /* ========== HELPERS ========== */

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

    function _dealStETH(address to, uint256 amount) internal {
        vm.prank(STETH_WHALE);
        require(IERC20(STETH).transfer(to, amount), "stETH deal failed");
    }

    /// @dev Lido only finalizes on an oracle report. Tests impersonate stETH (FINALIZE_ROLE) and
    ///      lock the unfinalized ETH so `claimWithdrawal` can pay the strategy.
    function _finalizeLidoRequest(uint256 requestId) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status =
            ILidoWithdrawalQueue(LIDO_WITHDRAWAL_QUEUE).getWithdrawalStatus(ids)[0];

        uint256 ethToLock = status.amountOfStETH;
        vm.deal(STETH, ethToLock);
        vm.prank(STETH);
        ILidoWithdrawalQueueAdmin(LIDO_WITHDRAWAL_QUEUE).finalize{value: ethToLock}(requestId, type(uint256).max);
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
