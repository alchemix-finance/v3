// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {Re7ETHMidasStrategy, IMidasDataFeed, IMidasDepositVault, IMidasRedemptionVault, MidasRequestStatus} from "../../strategies/Re7ETHMidasStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

interface IAggregatorV3Tiny {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IMidasRedemptionVaultAdmin {
    function accessControl() external view returns (address);
    function vaultRole() external view returns (bytes32);
    function requestRedeemer() external view returns (address);
    function approveRequest(uint256 requestId, uint256 newMTokenRate) external;
    function rejectRequest(uint256 requestId) external;
}

interface IMidasAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

library Re7ETHMidasAddresses {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant RE7_ETH = 0xEF75DEBD2545C48979Bf09aC55713028808fEf40;
    address internal constant DEPOSIT_VAULT = 0x3EB163AFe663B2331101725a0a23510C3B1d7E31;
    address internal constant REDEMPTION_VAULT = 0x06a7Fa6DAA7BC7fD66a7EEFCE54475b456B4B5B4;
    address internal constant DATA_FEED = 0x7f6136358088c629ef6b6dF5ECf2180074073e84;
    address internal constant AGGREGATOR = 0x7b1047B1563fFbF7361c881b6f7EDB1521e5C238;
    address internal constant MIDAS_ADMIN = address(0xAD3115);
    uint256 internal constant FORK_BLOCK = 158_100_000;
    uint256 internal constant REDEMPTION_LIQUIDITY = 100_000e18;
}

contract MockReplacementAggregator {
    int256 internal immutable answer;

    constructor(int256 _answer) {
        answer = _answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
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

    /// @dev Midas settles requests by pulling WETH from `requestRedeemer`; the vault admin role is mocked onto MIDAS_ADMIN.
    function _setupMidasAdmin() internal {
        IMidasRedemptionVaultAdmin rv = IMidasRedemptionVaultAdmin(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        vm.mockCall(
            rv.accessControl(), abi.encodeWithSelector(IMidasAccessControl.hasRole.selector, rv.vaultRole(), Re7ETHMidasAddresses.MIDAS_ADMIN), abi.encode(true)
        );
        deal(Re7ETHMidasAddresses.WETH, rv.requestRedeemer(), Re7ETHMidasAddresses.REDEMPTION_LIQUIDITY);
    }

    function _approveExit(uint256 requestId) internal {
        uint256 rate = _nav();
        vm.prank(Re7ETHMidasAddresses.MIDAS_ADMIN);
        IMidasRedemptionVaultAdmin(Re7ETHMidasAddresses.REDEMPTION_VAULT).approveRequest(requestId, rate);
    }

    function _rejectExit(uint256 requestId) internal {
        vm.prank(Re7ETHMidasAddresses.MIDAS_ADMIN);
        IMidasRedemptionVaultAdmin(Re7ETHMidasAddresses.REDEMPTION_VAULT).rejectRequest(requestId);
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
        assertEq(address(s.aggregator()), Re7ETHMidasAddresses.AGGREGATOR, "unexpected aggregator");
        assertEq(s.aggregatorDecimals(), 8, "unexpected aggregator decimals");
        assertEq(s.maxNavStaleness(), 7 days, "unexpected staleness default");
        assertEq(s.maxNavDeviationBPS(), 500, "unexpected deviation default");
        assertEq(s.lastNav(), _nav(), "lastNav should be seeded from the live feed");
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

    function test_allocate_belowMidasMinimumReverts() public {
        uint256 minAmount = IMidasDepositVault(Re7ETHMidasAddresses.DEPOSIT_VAULT).minAmount();
        uint256 dust = (minAmount * _nav()) / 1e18 / 2;

        deal(Re7ETHMidasAddresses.WETH, strategy, dust);
        vm.prank(vault);
        vm.expectRevert("DV: mToken amount < min");
        IMYTStrategy(strategy).allocate(getVaultParams(), dust, "", address(vault));
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

    function test_staleNav_failsSoftInValuation_failsHardInExecution() public {
        _allocateDirect(1e18);
        uint256 healthyValue = IMYTStrategy(strategy).realAssets();

        // Exceed our 7-day staleness window (Midas's own 30-day check would still pass).
        vm.warp(block.timestamp + 8 days);

        // Valuation holds cached lastNav flat instead of reverting or dipping.
        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "stale value should hold lastNav");

        // Only idle is reported withdrawable.
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "no idle, nothing withdrawable");
        deal(Re7ETHMidasAddresses.WETH, strategy, 0.3e18);
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0.3e18, "only idle should be withdrawable");

        // Execution fails hard: minting and position redemptions require a healthy NAV.
        vm.prank(vault);
        vm.expectRevert("NAV unhealthy");
        IMYTStrategy(strategy).allocate(getVaultParams(), 0.3e18, "", address(vault));

        vm.prank(vault);
        vm.expectRevert("NAV unhealthy");
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));

        // But idle-covered deallocations still work without a NAV.
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 0.3e18, "", address(vault));

        // A fresh print restores full valuation (idle 0.3e18 was approved to the vault but never pulled).
        _refreshFeed(block.timestamp);
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), healthyValue + 0.3e18, 1e12, "fresh print should restore value");
    }

    function test_navDeviationGuard_rejectsOutlierPrint() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 healthyValue = IMYTStrategy(strategy).realAssets();

        // A fresh print that jumps +6% (beyond the 5% spread guard) is treated as unhealthy.
        int256 originalAnswer = feedAnswer;
        feedAnswer = (feedAnswer * 106) / 100;
        _refreshFeed(block.timestamp);

        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "outlier print should hold lastNav");

        vm.expectRevert("NAV unhealthy");
        s.pokeNav();

        // Same for a -6% print.
        feedAnswer = (originalAnswer * 94) / 100;
        _refreshFeed(block.timestamp);
        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "outlier drop should hold lastNav");

        // A print within the spread is accepted again.
        feedAnswer = (originalAnswer * 104) / 100;
        _refreshFeed(block.timestamp);
        s.pokeNav();
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), (healthyValue * 104) / 100, 1e12, "value should follow accepted print");
    }

    function test_acceptNav_ownerAcceptsOutOfBandPrint() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 healthyValue = IMYTStrategy(strategy).realAssets();
        uint256 navBefore = s.lastNav();

        feedAnswer = (feedAnswer * 80) / 100;
        uint256 expectedNav = (uint256(feedAnswer) * 1e18) / 10 ** s.aggregatorDecimals();
        _refreshFeed(block.timestamp);
        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "rejected print should hold lastNav");

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        s.acceptNav();

        // A stale print cannot be accepted either.
        vm.warp(block.timestamp + 8 days);
        vm.prank(admin);
        vm.expectRevert("Stale NAV");
        s.acceptNav();

        _refreshFeed(block.timestamp);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.NavAccepted(navBefore, expectedNav);
        s.acceptNav();

        assertEq(s.lastNav(), expectedNav, "lastNav should take the accepted print");
        assertEq(s.lastNavUpdatedAt(), block.timestamp, "lastNavUpdatedAt should be refreshed");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), (healthyValue * 80) / 100, 1e12, "value should follow accepted print");

        // Execution is healthy again at the new reference.
        s.pokeNav();
    }

    function test_pokeNav_updatesCache() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        uint256 navBefore = s.lastNav();

        feedAnswer = (feedAnswer * 101) / 100;
        _refreshFeed(block.timestamp);
        s.pokeNav();

        assertApproxEqRel(s.lastNav(), (navBefore * 101) / 100, 1e12, "lastNav should track the poked print");
        assertEq(s.lastNavUpdatedAt(), block.timestamp, "lastNavUpdatedAt should be refreshed");
    }

    function test_setAggregator_replacesFeedAndReseedsCache() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        // Replacement feed prints +50% — far beyond the deviation guard, accepted only via re-seed.
        MockReplacementAggregator replacement = new MockReplacementAggregator((feedAnswer * 150) / 100);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        s.setAggregator(address(replacement));

        vm.startPrank(admin);
        vm.expectRevert("Zero aggregator address");
        s.setAggregator(address(0));
        s.setAggregator(address(replacement));
        vm.stopPrank();

        assertEq(address(s.aggregator()), address(replacement), "aggregator not replaced");
        assertApproxEqRel(s.lastNav(), (_nav() * 150) / 100, 1e12, "lastNav should re-seed from new feed");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), (valueBefore * 150) / 100, 1e12, "valuation should follow new feed");
    }

    function test_navSetters_onlyOwnerAndBounds() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);

        vm.startPrank(address(0xBEEF));
        vm.expectRevert();
        s.setMaxNavStaleness(1 days);
        vm.expectRevert();
        s.setMaxNavDeviationBPS(300);
        vm.stopPrank();

        vm.startPrank(admin);
        s.setMaxNavStaleness(3 days);
        assertEq(s.maxNavStaleness(), 3 days, "staleness not updated");
        s.setMaxNavDeviationBPS(300);
        assertEq(s.maxNavDeviationBPS(), 300, "deviation not updated");

        vm.expectRevert("Zero staleness");
        s.setMaxNavStaleness(0);
        vm.expectRevert("Invalid deviation");
        s.setMaxNavDeviationBPS(10_000);
        vm.stopPrank();
    }

    function test_requestExit_accessAndSizing() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(2e18);
        uint256 position = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(address(0xBEEF));
        vm.expectRevert("Not keeper");
        s.requestExit(1e18);

        vm.prank(admin);
        s.setKeeper(address(0xBEEF));

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        s.requestExit(0);

        // Sized at lastNav, rounded up.
        uint256 expectedMTokens = (1e18 * 1e18 + s.lastNav() - 1) / s.lastNav();
        vm.prank(address(0xBEEF));
        uint256 id = s.requestExit(1e18);

        assertEq(s.pendingExitId(), id, "request id not stored");
        assertEq(IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy), position - expectedMTokens, "mTokens not escrowed");
        (address sender,, MidasRequestStatus status, uint256 amountMToken,,) = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT).redeemRequests(id);
        assertEq(sender, strategy, "request sender");
        assertEq(uint8(status), uint8(MidasRequestStatus.Pending), "request should be pending");
        assertEq(s.pendingExitMTokens(), amountMToken, "escrow view");

        // Escrow is still valued; no dip on request.
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore, 1e9, "value should hold through request");

        // Only one open request at a time.
        vm.prank(admin);
        vm.expectRevert("Exit pending");
        s.requestExit(0.1e18);
    }

    function test_requestExit_capsAtPosition() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 position = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);

        vm.prank(admin);
        s.requestExit(100e18);

        assertEq(IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy), 0, "whole position should be escrowed");
        assertEq(s.pendingExitMTokens(), position, "escrow should equal position (zero request fee)");
    }

    function test_requestExit_belowMidasMinimumReverts() public {
        _allocateDirect(1e18);
        vm.prank(admin);
        vm.expectRevert("RV: amount < min");
        Re7ETHMidasStrategy(strategy).requestExit(1);
    }

    function test_requestExit_doesNotRequireHealthyNav() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        vm.warp(block.timestamp + 8 days);
        _refreshFeed(block.timestamp - 8 days);

        vm.prank(admin);
        uint256 id = s.requestExit(0.5e18);
        assertEq(s.pendingExitId(), id, "request should go through on stale NAV");
    }

    function test_exit_settlesIntoIdle() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(2e18);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(admin);
        uint256 id = s.requestExit(1e18);
        uint256 escrow = s.pendingExitMTokens();

        _approveExit(id);

        uint256 idle = IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy);
        assertApproxEqAbs(idle, (escrow * _nav()) / 1e18, 1e9, "settled WETH should land as idle");
        assertEq(s.pendingExitMTokens(), 0, "processed request should not be counted");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore, 1e9, "value should hold through settlement");

        // Settled WETH is served by the normal deallocate path, no Midas call needed.
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), idle, "", address(vault));

        // Slot is free for the next request without clearing.
        vm.prank(admin);
        s.requestExit(0.5e18);
    }

    function test_exit_rejectedKeepsEscrowUntilCleared() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(1e18);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(admin);
        uint256 id = s.requestExit(0.5e18);

        vm.prank(admin);
        vm.expectRevert("Exit pending");
        s.clearExit();

        _rejectExit(id);

        // Midas returns cancelled mTokens off-chain; keep valuing the receivable until the owner clears it.
        assertGt(s.pendingExitMTokens(), 0, "cancelled escrow should still be counted");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore, 1e9, "value should hold through rejection");

        vm.prank(admin);
        vm.expectRevert("Exit pending");
        s.requestExit(0.1e18);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        s.clearExit();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.ExitCleared(id, MidasRequestStatus.Canceled);
        s.clearExit();

        assertEq(s.pendingExitMTokens(), 0, "cleared escrow should not be counted");
        assertEq(s.pendingExitId(), type(uint256).max, "slot should be free");

        vm.prank(admin);
        vm.expectRevert("No exit");
        s.clearExit();
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

    function _postCreateStrategy(address strategy_) internal override {
        // The handler warps up to a year at a time; pin the NAV so the Midas feed never trips its 30-day health check.
        navSnapshot = IMidasDataFeed(Re7ETHMidasAddresses.DATA_FEED).getDataInBase18();
        vm.mockCall(Re7ETHMidasAddresses.DATA_FEED, abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector), abi.encode(navSnapshot));
        deal(Re7ETHMidasAddresses.WETH, Re7ETHMidasAddresses.REDEMPTION_VAULT, Re7ETHMidasAddresses.REDEMPTION_LIQUIDITY);

        // The strategy reads the aggregator directly, whose on-fork print has a fixed timestamp; the
        // handler's raw warps would trip the 7-day staleness guard, so relax it for the fuzz campaign.
        // The deviation guard stays active (the pinned print never moves).
        vm.prank(admin);
        Re7ETHMidasStrategy(strategy_).setMaxNavStaleness(36_500 days);
    }

    /// @dev Midas rejects mints below `minAmount` mTokens; size fuzzed allocations above it (2x for slippage rounding).
    function _realStrategyMinAllocate() internal view override returns (uint256) {
        uint256 minMint = IMidasDepositVault(Re7ETHMidasAddresses.DEPOSIT_VAULT).minAmount();
        return (minMint * navSnapshot * 2) / 1e18;
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
