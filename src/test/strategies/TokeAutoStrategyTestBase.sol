// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626Like, TokeAutoStrategy} from "../../strategies/TokeAutoStrategy.sol";
import {IMainRewarder} from "../../strategies/interfaces/ITokemac.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Shared Tokemak strategy coverage.
/// @dev Concrete ETH/USD suites supply vault/rewarder addresses and asset specific setup.
abstract contract TokeAutoStrategyTestBase is BaseStrategyTest {
    function _autoVault() internal view virtual returns (address);
    function _rewarder() internal view virtual returns (address);

    function _units(uint256 n) internal view returns (uint256) {
        return n * 10 ** testConfig.decimals;
    }

    /// @dev USD uses 100 units (100 USDC). ETH overrides to a smaller WETH size so live
    /// AutopoolETH redeems in the shared deallocate tests stay in a liquid range.
    function _navAllocAmount() internal view virtual returns (uint256) {
        return _units(100);
    }

    function _asset() internal view returns (address) {
        return testConfig.vaultAsset;
    }

    function _toke() internal view returns (TokeAutoStrategy) {
        return TokeAutoStrategy(strategy);
    }

    function _beforeTimeShift(uint256 targetTimestamp) internal virtual override {
        _mockFreshDebtReport(targetTimestamp);
    }

    function _mockFreshDebtReport(uint256 timestamp) internal {
        vm.mockCall(
            _autoVault(),
            abi.encodeWithSelector(IERC4626Like.oldestDebtReporting.selector),
            abi.encode(timestamp)
        );
    }

    function _mockStaleDebtReport() internal {
        _mockFreshDebtReport(block.timestamp - _toke().MAX_DEBT_REPORT_AGE() - 1);
    }

    function _mockPurposeNav(uint256 depositNav, uint256 withdrawNav) internal {
        vm.mockCall(
            _autoVault(),
            abi.encodeWithSelector(IERC4626Like.totalAssets.selector, IERC4626Like.TotalAssetPurpose.Deposit),
            abi.encode(depositNav)
        );
        vm.mockCall(
            _autoVault(),
            abi.encodeWithSelector(IERC4626Like.totalAssets.selector, IERC4626Like.TotalAssetPurpose.Withdraw),
            abi.encode(withdrawNav)
        );
    }

    function _applyWidePurposeSpread() internal returns (uint256 lowWithdraw, uint256 highDeposit) {
        uint256 fairWithdraw = IERC4626Like(_autoVault()).totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
        lowWithdraw = fairWithdraw / 2;
        highDeposit = lowWithdraw + (lowWithdraw * 2720) / 10_000;
        _mockPurposeNav(highDeposit, lowWithdraw);
        _mockFreshDebtReport(block.timestamp);
    }

    function _strategyShares() internal view returns (uint256) {
        return IMainRewarder(_rewarder()).balanceOf(strategy) + IERC20(_autoVault()).balanceOf(strategy);
    }

    function _expectedFrozenRealAssets() internal view returns (uint256) {
        uint256 idle = IERC20(_asset()).balanceOf(strategy);
        uint256 shares = _strategyShares();
        if (shares == 0) return idle;
        return idle + Math.mulDiv(shares, _toke().lastGoodSharePrice(), MYTStrategy(strategy).FIXED_POINT_SCALAR());
    }

    function _allocateDirect(uint256 amount) internal {
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(_asset(), strategy, amount);
        IMYTStrategy(strategy).allocate(params, amount, "", address(vault));
        vm.stopPrank();
    }

    /// @notice After a usable allocate, a stale report must not double count idle across deallocate:
    /// realAssets = idle + remainingShares * lastGoodSharePrice.
    function test_unusableReport_deallocate_usesPricePerShareFallback() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = _navAllocAmount();

        _allocateDirect(amountToAllocate);

        uint256 pps = _toke().lastGoodSharePrice();
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        uint256 sharesBefore = _strategyShares();
        assertGt(pps, 0, "usable allocate should snapshot share price");
        assertGt(sharesBefore, 0, "expected staked shares");
        assertApproxEqAbs(realBefore, _expectedFrozenRealAssets(), 10, "snapshot PPS should match live mark");

        _mockStaleDebtReport();

        uint256 amountToDeallocate = amountToAllocate / 2;
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));

        uint256 sharesAfter = _strategyShares();
        uint256 realAfter = IMYTStrategy(strategy).realAssets();
        uint256 expected = _expectedFrozenRealAssets();

        assertLt(sharesAfter, sharesBefore, "deallocate should burn shares");
        assertEq(_toke().lastGoodSharePrice(), pps, "stale path must not refresh PPS");
        assertEq(realAfter, expected, "fallback must track remaining shares * PPS + idle");
        assertLt(realAfter, realBefore, "real assets should decrease after deallocate in unusable window");
    }

    /// @notice A wide Deposit/Withdraw purpose spread freezes realAssets at last-good PPS instead of
    /// following the depressed Withdraw NAV.
    function test_widePurposeSpread_freezesRealAssetsAtLastGoodSharePrice() public {
        _allocateDirect(_navAllocAmount());

        uint256 pps = _toke().lastGoodSharePrice();
        uint256 shares = _strategyShares();
        uint256 fairReal = IMYTStrategy(strategy).realAssets();
        assertGt(pps, 0, "usable allocate should snapshot share price");

        (uint256 lowWithdraw, uint256 highDeposit) = _applyWidePurposeSpread();

        uint256 frozen = _expectedFrozenRealAssets();
        uint256 liveWouldBe = IERC20(_asset()).balanceOf(strategy)
            + IERC4626Like(_autoVault()).convertToAssets(
                shares, lowWithdraw, IERC4626Like(_autoVault()).totalSupply(), IERC4626Like.Rounding.Down
            );
        uint256 realAfter = IMYTStrategy(strategy).realAssets();

        assertEq(realAfter, frozen, "wide spread should use PPS fallback");
        assertApproxEqRel(realAfter, fairReal, 1e12, "frozen mark should stay near pre-attack fair");
        assertLt(liveWouldBe, frozen, "live Withdraw path would have marked lower");
        assertGt(
            (highDeposit - lowWithdraw) * 10_000 / lowWithdraw,
            _toke().maxNavSpreadBps(),
            "fixture spread must exceed maxNavSpreadBps"
        );
    }

    /// @notice Deploy default is 100 bps; only owner may raise it (cap 10_000); widening under a wide
    /// purpose mock restores live Withdraw marking.
    function test_setMaxNavSpreadBps_defaults_and_owner_controls() public {
        TokeAutoStrategy strat = _toke();
        assertEq(strat.maxNavSpreadBps(), strat.DEFAULT_MAX_NAV_SPREAD_BPS(), "deploy default");
        assertEq(strat.maxNavSpreadBps(), 100, "default should be 100 bps");

        vm.prank(address(2));
        vm.expectRevert();
        strat.setMaxNavSpreadBps(500);

        vm.prank(admin);
        vm.expectRevert(bytes("Nav spread too high"));
        strat.setMaxNavSpreadBps(10_001);

        _allocateDirect(_navAllocAmount());

        uint256 shares = _strategyShares();
        (uint256 lowWithdraw,) = _applyWidePurposeSpread();

        uint256 frozen = IMYTStrategy(strategy).realAssets();
        assertEq(frozen, _expectedFrozenRealAssets(), "pre-widen should freeze at last-good");

        vm.expectEmit(true, true, true, true, strategy);
        emit TokeAutoStrategy.MaxNavSpreadBpsUpdated(3_000);
        vm.prank(admin);
        strat.setMaxNavSpreadBps(3_000);
        assertEq(strat.maxNavSpreadBps(), 3_000, "owner should widen spread ceiling");

        uint256 live = IERC20(_asset()).balanceOf(strategy)
            + IERC4626Like(_autoVault()).convertToAssets(
                shares, lowWithdraw, IERC4626Like(_autoVault()).totalSupply(), IERC4626Like.Rounding.Down
            );
        uint256 realAfter = IMYTStrategy(strategy).realAssets();
        assertEq(realAfter, live, "widened ceiling should consume live Withdraw NAV");
        assertLt(realAfter, frozen, "live depressed mark should be below frozen last-good");
    }

    /// @notice Warping past MAX_DEBT_REPORT_AGE without refreshing the age mock freezes at last-good;
    /// remocking a fresh oldestDebtReporting restores live Withdraw NAV.
    function test_staleDebtReport_fallsBackThenRecoversWhenFresh() public {
        _allocateDirect(_navAllocAmount());

        uint256 pps = _toke().lastGoodSharePrice();
        uint256 fairReal = IMYTStrategy(strategy).realAssets();
        assertGt(pps, 0, "usable allocate should snapshot share price");

        // Warp without _beforeTimeShift so the mocked oldestDebtReporting stays pinned in the past.
        vm.warp(block.timestamp + _toke().MAX_DEBT_REPORT_AGE() + 1);

        uint256 frozen = IMYTStrategy(strategy).realAssets();
        assertEq(frozen, _expectedFrozenRealAssets(), "stale report should use PPS fallback");
        assertEq(_toke().lastGoodSharePrice(), pps, "stale window must not refresh PPS");

        _mockFreshDebtReport(block.timestamp);
        uint256 recovered = IMYTStrategy(strategy).realAssets();
        assertApproxEqRel(recovered, fairReal, 1e12, "fresh report should restore live Withdraw mark");
        assertEq(_toke().lastGoodSharePrice(), pps, "recovery read path must not mutate PPS");
    }

    /// @notice Allocate/deallocate while the report is unusable must leave lastGoodSharePrice unchanged.
    function test_unusableAllocateDeallocate_doesNotUpdateLastGoodSharePrice() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = _navAllocAmount();

        _allocateDirect(amountToAllocate);

        uint256 pps = _toke().lastGoodSharePrice();
        assertGt(pps, 0, "usable allocate should snapshot share price");

        _mockStaleDebtReport();

        vm.startPrank(vault);
        deal(_asset(), strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        assertEq(_toke().lastGoodSharePrice(), pps, "unusable allocate must not refresh PPS");

        IMYTStrategy(strategy).deallocate(params, amountToAllocate / 2, "", address(vault));
        vm.stopPrank();

        assertEq(_toke().lastGoodSharePrice(), pps, "unusable deallocate must not refresh PPS");
    }

    /// @notice Owner seed before the first allocate: if that allocate lands in an unusable window,
    /// realAssets must mark the new shares at the seeded PPS instead of collapsing to idle.
    function test_seededSnapshot_unusableFirstAllocate_doesNotCollapseToIdle() public {
        TokeAutoStrategy strat = _toke();
        assertEq(strat.lastGoodSharePrice(), 0, "precondition: cold start");
        assertEq(_strategyShares(), 0, "precondition: no shares before first allocate");

        vm.prank(admin);
        strat.snapshotSharePrice();

        uint256 pps = strat.lastGoodSharePrice();
        assertGt(pps, 0, "owner snapshot should seed PPS before allocate");

        _mockStaleDebtReport();
        _allocateDirect(_navAllocAmount());

        uint256 shares = _strategyShares();
        uint256 idle = IERC20(_asset()).balanceOf(strategy);
        uint256 real = IMYTStrategy(strategy).realAssets();

        assertGt(shares, 0, "allocate should mint shares");
        assertEq(strat.lastGoodSharePrice(), pps, "unusable first allocate must not refresh PPS");
        assertEq(real, _expectedFrozenRealAssets(), "seeded PPS should mark the new shares");
        assertGt(real, idle, "must not collapse share value to idle");
    }

    /// @notice reportUsable() must mirror the internal gate across fresh, stale, and wide-spread states.
    function test_reportUsable_view_reflectsGateStates() public {
        TokeAutoStrategy strat = _toke();
        assertTrue(strat.reportUsable(), "fresh report should be usable");

        _mockStaleDebtReport();
        assertFalse(strat.reportUsable(), "stale report should be unusable");

        _mockFreshDebtReport(block.timestamp);
        assertTrue(strat.reportUsable(), "refreshed report should recover");

        _applyWidePurposeSpread();
        assertFalse(strat.reportUsable(), "wide purpose spread should be unusable");
    }

    /// @notice Every lastGoodSharePrice write path (allocate, deallocate, owner snapshot, forceMarkDown)
    /// must stamp lastSnapshotAt so ops can alert on a stale fallback mark.
    function test_lastSnapshotAt_writtenOnAllUpdatePaths() public {
        TokeAutoStrategy strat = _toke();
        assertEq(strat.lastSnapshotAt(), 0, "precondition: no snapshot yet");

        vm.prank(admin);
        strat.snapshotSharePrice();
        uint256 t1 = strat.lastSnapshotAt();
        assertEq(t1, block.timestamp, "owner snapshot should stamp timestamp");

        vm.warp(block.timestamp + 1 hours);
        _mockFreshDebtReport(block.timestamp);
        _allocateDirect(_navAllocAmount());
        uint256 t2 = strat.lastSnapshotAt();
        assertEq(t2, block.timestamp, "usable allocate should stamp timestamp");
        assertGt(t2, t1, "allocate stamp should advance");

        vm.warp(block.timestamp + 1 hours);
        _mockFreshDebtReport(block.timestamp);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), _navAllocAmount() / 2, "", address(vault));
        uint256 t3 = strat.lastSnapshotAt();
        assertEq(t3, block.timestamp, "usable deallocate should stamp timestamp");

        vm.warp(block.timestamp + 1 hours);
        _mockStaleDebtReport();
        vm.startPrank(vault);
        deal(_asset(), strategy, _navAllocAmount());
        IMYTStrategy(strategy).allocate(getVaultParams(), _navAllocAmount(), "", address(vault));
        vm.stopPrank();
        assertEq(strat.lastSnapshotAt(), t3, "unusable allocate must not stamp timestamp");

        uint256 pps = strat.lastGoodSharePrice();
        vm.prank(admin);
        strat.forceMarkDown(pps - 1);
        assertEq(strat.lastSnapshotAt(), block.timestamp, "forceMarkDown should stamp timestamp");
    }

    /// @notice forceMarkDown lowers the frozen mark during an unusable window and realAssets follows;
    /// it can never raise the mark, set it to zero, or be called by a non-owner.
    function test_forceMarkDown_lowersFrozenMark_and_enforcesMonotonicDecrease() public {
        TokeAutoStrategy strat = _toke();
        _allocateDirect(_navAllocAmount());

        uint256 pps = strat.lastGoodSharePrice();
        assertGt(pps, 0, "usable allocate should snapshot share price");

        _mockStaleDebtReport();
        uint256 frozenBefore = IMYTStrategy(strategy).realAssets();
        assertEq(frozenBefore, _expectedFrozenRealAssets(), "stale report should freeze at last-good");

        vm.prank(address(2));
        vm.expectRevert();
        strat.forceMarkDown(pps / 2);

        vm.prank(admin);
        vm.expectRevert(bytes("Mark can only decrease"));
        strat.forceMarkDown(pps + 1);
        vm.prank(admin);
        vm.expectRevert(bytes("Zero share price"));
        strat.forceMarkDown(0);

        uint256 markedDown = pps / 2;
        vm.expectEmit(true, true, true, true, strategy);
        emit TokeAutoStrategy.LastGoodSharePriceForcedDown(markedDown);
        vm.prank(admin);
        strat.forceMarkDown(markedDown);

        assertEq(strat.lastGoodSharePrice(), markedDown, "mark should be lowered");
        uint256 frozenAfter = IMYTStrategy(strategy).realAssets();
        assertEq(frozenAfter, _expectedFrozenRealAssets(), "realAssets should track the lowered mark");
        assertLt(frozenAfter, frozenBefore, "lowered mark should reduce frozen realAssets");

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(frozenAfter);
        uint256 shares = _strategyShares();
        uint256 sharesNeeded =
            Math.mulDiv(frozenAfter, MYTStrategy(strategy).FIXED_POINT_SCALAR(), markedDown, Math.Rounding.Ceil);
        if (sharesNeeded > shares) sharesNeeded = shares;
        uint256 expectedAssets = Math.mulDiv(sharesNeeded, markedDown, MYTStrategy(strategy).FIXED_POINT_SCALAR());
        assertEq(
            preview,
            expectedAssets - (expectedAssets * strategyConfig.slippageBPS / 10_000),
            "preview must use the lowered mark"
        );
    }

    /// @notice previewAdjustedWithdraw must size off last-good PPS when the report is unusable,
    /// not off a depressed live Withdraw NAV.
    function test_unusableReport_previewAdjustedWithdraw_usesLastGoodSharePrice() public {
        _allocateDirect(_navAllocAmount());

        uint256 pps = _toke().lastGoodSharePrice();
        uint256 shares = _strategyShares();
        uint256 fairReal = IMYTStrategy(strategy).realAssets();
        assertGt(pps, 0, "usable allocate should snapshot share price");
        assertGt(fairReal, 0, "usable mark should be positive");

        (uint256 lowWithdraw,) = _applyWidePurposeSpread();

        uint256 requested = IMYTStrategy(strategy).realAssets();
        uint256 frozenPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(requested);
        uint256 sharesNeeded =
            Math.mulDiv(requested, MYTStrategy(strategy).FIXED_POINT_SCALAR(), pps, Math.Rounding.Ceil);
        if (sharesNeeded > shares) sharesNeeded = shares;
        uint256 expectedAssets = Math.mulDiv(sharesNeeded, pps, MYTStrategy(strategy).FIXED_POINT_SCALAR());
        uint256 expectedPreview = expectedAssets - (expectedAssets * strategyConfig.slippageBPS / 10_000);

        uint256 liveSharesNeeded = IERC4626Like(_autoVault()).convertToShares(
            requested, lowWithdraw, IERC4626Like(_autoVault()).totalSupply(), IERC4626Like.Rounding.Up
        );
        if (liveSharesNeeded > shares) liveSharesNeeded = shares;
        uint256 liveAssets = IERC4626Like(_autoVault()).convertToAssets(
            liveSharesNeeded, lowWithdraw, IERC4626Like(_autoVault()).totalSupply(), IERC4626Like.Rounding.Down
        );
        uint256 livePreview = liveAssets - (liveAssets * strategyConfig.slippageBPS / 10_000);

        assertEq(frozenPreview, expectedPreview, "unusable preview must use last-good PPS");
        assertApproxEqRel(
            frozenPreview,
            fairReal - (fairReal * strategyConfig.slippageBPS / 10_000),
            1e12,
            "frozen preview should stay near pre-attack fair"
        );
        assertLt(livePreview, frozenPreview, "live Withdraw preview would have sized the unwind lower");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        assertFalse(_toke().canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        _toke().setCanForceDeallocate(true);
        assertTrue(_toke().canForceDeallocate(), "force deallocate should be enabled");

        deal(_asset(), strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }
}
