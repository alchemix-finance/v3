// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {Re7ETHMidasStrategy, IMidasDataFeed, IMidasDepositVault, IMidasRedemptionVault} from "../../strategies/Re7ETHMidasStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

interface IAggregatorV3Tiny {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

library Re7ETHMidasAddresses {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant RE7_ETH = 0xEF75DEBD2545C48979Bf09aC55713028808fEf40;
    address internal constant DEPOSIT_VAULT = 0x3EB163AFe663B2331101725a0a23510C3B1d7E31;
    address internal constant REDEMPTION_VAULT = 0x06a7Fa6DAA7BC7fD66a7EEFCE54475b456B4B5B4;
    address internal constant DATA_FEED = 0x7f6136358088c629ef6b6dF5ECf2180074073e84;
    address internal constant AGGREGATOR = 0x7b1047B1563fFbF7361c881b6f7EDB1521e5C238;
    uint256 internal constant FORK_BLOCK = 158_100_000;
    uint256 internal constant REDEMPTION_LIQUIDITY = 100_000e18;
}

contract Re7ETHMidasStrategyTest is BaseStrategyTest {
    uint80 internal feedRoundId;
    int256 internal feedAnswer;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Re7 ETH Midas",
            protocol: "Midas",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 200,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: Re7ETHMidasAddresses.WETH, vaultInitialDeposit: 20e18, absoluteCap: 20e18, relativeCap: 0.25e18, decimals: 18});
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new Re7ETHMidasStrategy(
                vault_,
                params,
                Re7ETHMidasAddresses.RE7_ETH,
                Re7ETHMidasAddresses.DEPOSIT_VAULT,
                Re7ETHMidasAddresses.REDEMPTION_VAULT,
                Re7ETHMidasAddresses.DATA_FEED
            )
        );
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return Re7ETHMidasAddresses.FORK_BLOCK;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function setUp() public override {
        super.setUp();
        (feedRoundId, feedAnswer,,,) = IAggregatorV3Tiny(Re7ETHMidasAddresses.AGGREGATOR).latestRoundData();
        // Midas serves instant redemptions from the redemption vault's own balance, which is empty on-chain.
        _fundRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_LIQUIDITY);
    }

    /// @dev The Midas feed is marked unhealthy after 30 days without an update; keep it fresh across warps.
    function _beforeTimeShift(uint256 targetTimestamp) internal override {
        _refreshFeed(targetTimestamp);
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedAssets);
        return preview < requestedAssets ? preview : requestedAssets;
    }

    function _refreshFeed(uint256 timestamp) internal {
        vm.mockCall(
            Re7ETHMidasAddresses.AGGREGATOR,
            abi.encodeWithSelector(IAggregatorV3Tiny.latestRoundData.selector),
            abi.encode(feedRoundId, feedAnswer, timestamp, timestamp, feedRoundId)
        );
    }

    function _fundRedemptionVault(uint256 amount) internal {
        deal(Re7ETHMidasAddresses.WETH, Re7ETHMidasAddresses.REDEMPTION_VAULT, amount);
    }

    function _nav() internal view returns (uint256) {
        return IMidasDataFeed(Re7ETHMidasAddresses.DATA_FEED).getDataInBase18();
    }

    function _redeemFeeBps() internal view returns (uint256) {
        IMidasRedemptionVault rv = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        (, uint256 tokenFee,,) = rv.tokensConfig(Re7ETHMidasAddresses.WETH);
        return tokenFee + rv.instantFee();
    }

    function _allocateDirect(uint256 amount) internal {
        deal(Re7ETHMidasAddresses.WETH, strategy, amount);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(getVaultParams(), amount, "", address(vault));
    }

    function test_wiring() public view {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        assertEq(s.weth(), Re7ETHMidasAddresses.WETH, "unexpected weth");
        assertEq(s.re7ETH(), Re7ETHMidasAddresses.RE7_ETH, "unexpected re7ETH");
        assertEq(address(s.depositVault()), Re7ETHMidasAddresses.DEPOSIT_VAULT, "unexpected deposit vault");
        assertEq(address(s.redemptionVault()), Re7ETHMidasAddresses.REDEMPTION_VAULT, "unexpected redemption vault");
        assertEq(address(s.dataFeed()), Re7ETHMidasAddresses.DATA_FEED, "unexpected data feed");
        assertFalse(s.canForceDeallocate(), "force deallocate should default disabled");
    }

    function test_constructor_revertsOnZeroAddresses() public {
        IMYTStrategy.StrategyParams memory params = getStrategyConfig();
        vm.expectRevert("Zero Re7ETH address");
        new Re7ETHMidasStrategy(
            vault, params, address(0), Re7ETHMidasAddresses.DEPOSIT_VAULT, Re7ETHMidasAddresses.REDEMPTION_VAULT, Re7ETHMidasAddresses.DATA_FEED
        );
        vm.expectRevert("Zero deposit vault address");
        new Re7ETHMidasStrategy(vault, params, Re7ETHMidasAddresses.RE7_ETH, address(0), Re7ETHMidasAddresses.REDEMPTION_VAULT, Re7ETHMidasAddresses.DATA_FEED);
        vm.expectRevert("Zero redemption vault address");
        new Re7ETHMidasStrategy(vault, params, Re7ETHMidasAddresses.RE7_ETH, Re7ETHMidasAddresses.DEPOSIT_VAULT, address(0), Re7ETHMidasAddresses.DATA_FEED);
        vm.expectRevert("Zero data feed address");
        new Re7ETHMidasStrategy(
            vault, params, Re7ETHMidasAddresses.RE7_ETH, Re7ETHMidasAddresses.DEPOSIT_VAULT, Re7ETHMidasAddresses.REDEMPTION_VAULT, address(0)
        );
    }

    function test_allocate_mintsRe7ETHAtNav() public {
        uint256 amount = 2e18;
        uint256 nav = _nav();

        _allocateDirect(amount);

        uint256 mTokens = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        uint256 expectedMTokens = (amount * 1e18) / nav;
        assertApproxEqRel(mTokens, expectedMTokens, 1e14, "minted Re7ETH should match NAV");
        assertEq(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), 0, "all WETH should be deposited");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), amount, 1e9, "realAssets should track deposit at NAV");
    }

    function test_allocate_belowMidasMinimumStaysIdle() public {
        uint256 minAmount = IMidasDepositVault(Re7ETHMidasAddresses.DEPOSIT_VAULT).minAmount();
        uint256 dust = (minAmount * _nav()) / 1e18 / 2;

        _allocateDirect(dust);

        assertEq(IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy), 0, "dust should not be deposited");
        assertEq(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), dust, "dust should stay idle");
        assertEq(IMYTStrategy(strategy).realAssets(), dust, "idle dust should be valued");
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(dust), dust, "idle dust should be fully withdrawable");
    }

    function test_allocate_swapActionReverts() public {
        deal(Re7ETHMidasAddresses.WETH, strategy, 1e18);
        IMYTStrategy.VaultAdapterParams memory p;
        p.action = IMYTStrategy.ActionType.swap;
        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(strategy).allocate(abi.encode(p), 1e18, "", address(vault));
    }

    function test_deallocate_redeemsWithInstantFee() public {
        uint256 allocAmount = 4e18;
        _allocateDirect(allocAmount);

        uint256 target = 1e18;
        uint256 mBefore = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), target, "", address(vault));

        uint256 mAfter = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        uint256 idle = IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy);
        assertGe(idle, target, "idle WETH must cover deallocation");
        assertEq(IERC20(Re7ETHMidasAddresses.WETH).allowance(strategy, vault), target, "vault allowance should equal amount");

        // Gross mTokens burned should exceed the net amount by the Midas instant fee.
        uint256 burned = mBefore - mAfter;
        uint256 netMTokens = (target * 1e18 + _nav() - 1) / _nav();
        uint256 feeBps = _redeemFeeBps();
        uint256 expectedBurned = (netMTokens * 10_000 + (10_000 - feeBps) - 1) / (10_000 - feeBps);
        assertApproxEqRel(burned, expectedBurned, 1e12, "burned mTokens should include instant fee");

        // Position value drops by roughly target / (1 - fee).
        uint256 valueAfter = IMYTStrategy(strategy).realAssets();
        uint256 expectedCost = (target * 10_000) / (10_000 - feeBps);
        assertApproxEqRel(valueBefore - valueAfter + idle, expectedCost, 1e14, "fee should be reflected in value change");
    }

    function test_deallocate_tinyShortfallRoundsUpToMinAmount() public {
        _allocateDirect(2e18);
        uint256 minAmount = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT).minAmount();

        uint256 mBefore = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, "", address(vault));
        uint256 burned = mBefore - IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);

        assertEq(burned, minAmount, "should redeem exactly the Midas minimum");
        assertGe(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), 1, "idle should cover request");
    }

    function test_deallocate_revertsWhenRedemptionVaultUnfunded() public {
        _allocateDirect(2e18);
        _fundRedemptionVault(0);

        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "preview should report nothing withdrawable");

        vm.prank(vault);
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));
    }

    function test_deallocate_servesFromIdleWithoutTouchingPosition() public {
        _allocateDirect(2e18);
        deal(Re7ETHMidasAddresses.WETH, strategy, 0.5e18);
        uint256 mBefore = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);

        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 0.5e18, "", address(vault));

        assertEq(IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy), mBefore, "position should be untouched");
    }

    function test_deallocate_swapActionsRevert() public {
        _allocateDirect(1e18);
        IMYTStrategy.VaultAdapterParams memory p;
        p.action = IMYTStrategy.ActionType.swap;
        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(strategy).deallocate(abi.encode(p), 1e17, "", address(vault));

        p.action = IMYTStrategy.ActionType.unwrapAndSwap;
        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(strategy).deallocate(abi.encode(p), 1e17, "", address(vault));
    }

    // ---------------------------------------------------------------------------------------------
    // Preview
    // ---------------------------------------------------------------------------------------------

    function test_previewAdjustedWithdraw_appliesFeeAndSlippage() public {
        _allocateDirect(3e18);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets);
        uint256 feeBps = _redeemFeeBps();
        uint256 expected = (realAssets * (10_000 - feeBps)) / 10_000;
        expected = (expected * (10_000 - 50)) / 10_000;
        assertApproxEqRel(preview, expected, 1e12, "preview should net out fee and slippage");
        assertLt(preview, realAssets, "preview must be below gross value");

        // Preview amount must actually be withdrawable.
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), preview, "", address(vault));
        assertGe(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), preview, "preview should be honoured");
    }

    function test_previewAdjustedWithdraw_cappedByRedemptionLiquidity() public {
        _allocateDirect(3e18);
        _fundRedemptionVault(1e18);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(3e18);
        assertApproxEqRel(preview, (1e18 * (10_000 - 50)) / 10_000, 1e12, "preview should cap at vault liquidity");
    }

    function test_previewAdjustedWithdraw_cappedByDailyLimit() public {
        _allocateDirect(3e18);
        IMidasRedemptionVault rv = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        uint256 limit = rv.instantDailyLimit();
        if (limit == type(uint256).max) return;

        // Exhaust the daily limit by writing the current-day usage slot via the strategy's own view of it.
        uint256 day = block.timestamp / 1 days;
        vm.mockCall(Re7ETHMidasAddresses.REDEMPTION_VAULT, abi.encodeWithSelector(IMidasRedemptionVault.dailyLimits.selector, day), abi.encode(limit));
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "exhausted daily limit should zero the preview");

        // Headroom smaller than the Midas minimum redeem is equally unusable.
        uint256 minRedeem = rv.minAmount();
        vm.mockCall(
            Re7ETHMidasAddresses.REDEMPTION_VAULT, abi.encodeWithSelector(IMidasRedemptionVault.dailyLimits.selector, day), abi.encode(limit - minRedeem + 1)
        );
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "sub-minimum headroom should zero the preview");

        // Headroom of exactly one minimum redeem is withdrawable and must actually execute.
        vm.mockCall(
            Re7ETHMidasAddresses.REDEMPTION_VAULT, abi.encodeWithSelector(IMidasRedemptionVault.dailyLimits.selector, day), abi.encode(limit - minRedeem)
        );
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(1e18);
        assertGt(preview, 0, "one minimum redeem of headroom should be previewable");
        assertLe(preview, (minRedeem * _nav()) / 1e18, "preview should not exceed headroom value");
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------------------------------------
    // Oracle health
    // ---------------------------------------------------------------------------------------------

    function test_realAssets_revertsWhenFeedStale() public {
        _allocateDirect(1e18);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert("DF: feed is unhealthy");
        IMYTStrategy(strategy).realAssets();
    }

    function test_realAssets_tracksNavIncrease() public {
        _allocateDirect(1e18);
        uint256 before = IMYTStrategy(strategy).realAssets();

        // Bump NAV by 1%.
        feedAnswer = (feedAnswer * 101) / 100;
        _refreshFeed(block.timestamp);

        uint256 after_ = IMYTStrategy(strategy).realAssets();
        assertApproxEqRel(after_, (before * 101) / 100, 1e12, "realAssets should follow NAV");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        assertFalse(s.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        s.setCanForceDeallocate(true);
        assertTrue(s.canForceDeallocate(), "force deallocate should be enabled");

        deal(Re7ETHMidasAddresses.WETH, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }

    function test_setCanForceDeallocate_onlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        Re7ETHMidasStrategy(strategy).setCanForceDeallocate(true);
    }

    function test_rescueTokens_protectsWethAndRe7ETH() public {
        _allocateDirect(1e18);
        vm.startPrank(admin);
        vm.expectRevert("Protected token");
        Re7ETHMidasStrategy(strategy).rescueTokens(Re7ETHMidasAddresses.RE7_ETH, admin, 1);
        vm.expectRevert("Protected token");
        Re7ETHMidasStrategy(strategy).rescueTokens(Re7ETHMidasAddresses.WETH, admin, 1);
        vm.stopPrank();
    }
     
    function test_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint256 alloc1 = 2e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e15, "allocation should track first deposit");
        vm.stopPrank();

        _warpWithHook(7 days);

        vm.startPrank(allocator);
        uint256 alloc2 = 1e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2, 1e15, "allocation should track both deposits");
        vm.stopPrank();

        _warpWithHook(14 days);

        vm.startPrank(allocator);
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(1e18);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), preview);
        assertLt(IMYTStrategy(strategy).realAssets(), realBefore, "real assets should decrease after deallocation");

        uint256 vaultWethBefore = IERC20(Re7ETHMidasAddresses.WETH).balanceOf(vault);
        uint256 finalReal = IMYTStrategy(strategy).realAssets();
        uint256 finalPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalReal);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), finalPreview);
        assertGt(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(vault), vaultWethBefore, "vault WETH should increase");
        assertLt(IMYTStrategy(strategy).realAssets(), finalReal / 50, "position should be nearly fully exited");
        vm.stopPrank();
    }
}

contract Re7ETHMidasInvariantTest is E2EInvariantStrategyTest {
    uint256 internal navSnapshot;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return Re7ETHMidasAddresses.FORK_BLOCK;
    }

    function getAsset() internal pure override returns (address) {
        return Re7ETHMidasAddresses.WETH;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
            name: "Re7 ETH Midas",
            protocol: "Midas",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 200,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new Re7ETHMidasStrategy(
                vault_,
                params,
                Re7ETHMidasAddresses.RE7_ETH,
                Re7ETHMidasAddresses.DEPOSIT_VAULT,
                Re7ETHMidasAddresses.REDEMPTION_VAULT,
                Re7ETHMidasAddresses.DATA_FEED
            )
        );
    }

    /// @dev The handler's force-deallocate path sizes by gross `realAssets` and ignores `previewAdjustedWithdraw`,
    ///      so it cannot respect the Midas instant fee, minimum redeem size or daily limit. Force deallocation is
    ///      owner-gated and disabled by default on this strategy; the unit suite covers enabling it.
    function _realStrategySupportsForceDeallocate() internal pure override returns (bool) {
        return false;
    }

    function _postCreateStrategy(address) internal override {
        // The handler warps up to a year at a time; pin the NAV so the Midas feed never trips its 30-day health check.
        navSnapshot = IMidasDataFeed(Re7ETHMidasAddresses.DATA_FEED).getDataInBase18();
        vm.mockCall(Re7ETHMidasAddresses.DATA_FEED, abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector), abi.encode(navSnapshot));
        deal(Re7ETHMidasAddresses.WETH, Re7ETHMidasAddresses.REDEMPTION_VAULT, Re7ETHMidasAddresses.REDEMPTION_LIQUIDITY);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 mTokens = (amount * 1e18) / navSnapshot;
        uint256 bal = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        mTokens = mTokens > bal ? bal : mTokens;
        if (mTokens == 0) return;
        vm.prank(strategy);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(address(0xdead), mTokens);
    }
}
