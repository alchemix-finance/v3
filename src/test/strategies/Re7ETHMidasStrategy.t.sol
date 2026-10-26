// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {Re7ETHMidasStrategy, IMidasDataFeed, IMidasDepositVault, IMidasRedemptionVault, MidasRequestStatus} from "../../strategies/Re7ETHMidasStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
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
        uint256 cap = s.MAX_NAV_STALENESS();
        vm.expectRevert("Staleness too high");
        s.setMaxNavStaleness(cap + 1);
        s.setMaxNavStaleness(cap);
        assertEq(s.maxNavStaleness(), 30 days, "cap should be accepted");
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

        // Midas returns cancelled mTokens off-chain; keep valuing the receivable until it is back or written off.
        uint256 escrow = s.pendingExitMTokens();
        assertGt(escrow, 0, "cancelled escrow should still be counted");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore, 1e9, "value should hold through rejection");

        vm.prank(admin);
        vm.expectRevert("Exit pending");
        s.requestExit(0.1e18);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        s.clearExit();

        // Owner cannot silently clear an unreturned escrow; the write-off is explicit.
        vm.prank(admin);
        vm.expectRevert("Escrow not returned");
        s.clearExit();

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.ExitWrittenOff(id, escrow);
        s.writeOffExit();

        assertEq(s.pendingExitMTokens(), 0, "written-off escrow should not be counted");
        assertEq(s.pendingExitId(), type(uint256).max, "slot should be free");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore - (escrow * _nav()) / 1e18, 1e9, "value drops by the escrow");

        vm.prank(admin);
        vm.expectRevert("No exit");
        s.clearExit();
        vm.prank(admin);
        vm.expectRevert("No exit");
        s.writeOffExit();
    }

    function test_writeOffExit_onlyCancelledAndOwner() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(1e18);

        vm.startPrank(admin);
        s.setKeeper(address(0xBEEF));
        uint256 id = s.requestExit(0.5e18);
        vm.expectRevert("Not cancelled");
        s.writeOffExit();
        vm.stopPrank();

        _rejectExit(id);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        s.writeOffExit();
        vm.prank(admin);
        s.writeOffExit();

        vm.prank(admin);
        uint256 settledId = s.requestExit(0.2e18);
        _approveExit(settledId);
        vm.prank(admin);
        vm.expectRevert("Not cancelled");
        s.writeOffExit();
    }

    /// @dev Regression: once Midas rejects a request and returns the escrow, the returned
    ///      mTokens are counted twice (wallet + escrow) until the slot is cleared; the
    ///      keeper must be able to clear it without waiting for the owner.
    function test_exit_cancelledRefundClearedByKeeper() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(1e18);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.startPrank(admin);
        s.setKeeper(address(0xBEEF));
        uint256 id = s.requestExit(0.5e18);
        vm.stopPrank();

        uint256 escrow = s.pendingExitMTokens();
        _rejectExit(id);

        // Midas returns the cancelled escrow; the returned tokens are now in the wallet
        // AND still counted as escrow — the double-count window.
        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow);
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore + (escrow * _nav()) / 1e18, 1e9, "double-count window");

        vm.prank(address(0xBEEF));
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.ExitCleared(id, MidasRequestStatus.Canceled);
        s.clearExit();
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore, 1e9, "value restored after clear");
    }

    /// @dev Canceled slots are keeper-clearable; Pending and Processed slots are not.
    function test_clearExit_access() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(1e18);

        vm.prank(admin);
        s.setKeeper(address(0xBEEF));

        vm.prank(admin);
        uint256 id = s.requestExit(0.5e18);

        // Pending: nobody may clear.
        vm.prank(address(0xBEEF));
        vm.expectRevert("Exit pending");
        s.clearExit();

        // Canceled: keeper or owner may clear only once the escrow is back.
        uint256 escrow = s.pendingExitMTokens();
        _rejectExit(id);
        vm.prank(address(0xCAFE));
        vm.expectRevert("Not keeper");
        s.clearExit();

        vm.prank(address(0xBEEF));
        vm.expectRevert("Escrow not returned");
        s.clearExit();

        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow - 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Escrow not returned");
        s.clearExit();

        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, 1);
        vm.prank(address(0xBEEF));
        s.clearExit();

        // Processed: owner-only again.
        vm.prank(admin);
        uint256 settledId = s.requestExit(0.5e18);
        _approveExit(settledId);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Not owner");
        s.clearExit();
        vm.prank(admin);
        s.clearExit();

        // Canceled with a short return: nobody may clear, owner must write it off.
        vm.prank(admin);
        uint256 shortId = s.requestExit(0.2e18);
        _rejectExit(shortId);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Escrow not returned");
        s.clearExit();
        vm.prank(admin);
        vm.expectRevert("Escrow not returned");
        s.clearExit();
        vm.prank(admin);
        s.writeOffExit();
    }

    /// @dev Mints and burns between request and clear must not let the keeper clear early (allocate) or lock it out (deallocate).
    /// @dev Once a cancelled escrow is back, the next allocate / deallocate / request clears the slot itself.
    function test_exit_returnedEscrowSettlesOnOwnMoves() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();

        // deallocate
        _allocateDirect(2e18);
        vm.prank(admin);
        uint256 id = s.requestExit(0.5e18);
        uint256 escrow = s.pendingExitMTokens();
        _rejectExit(id);
        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow);
        uint256 trueValue = (IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy) * _nav()) / 1e18;
        assertGt(IMYTStrategy(strategy).realAssets(), trueValue, "double counted before settle");

        vm.prank(vault);
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.ExitCleared(id, MidasRequestStatus.Canceled);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 0.3e18, "", address(vault));
        assertEq(s.pendingExitId(), type(uint256).max, "deallocate should settle the slot");

        // allocate
        vm.prank(admin);
        id = s.requestExit(0.5e18);
        escrow = s.pendingExitMTokens();
        _rejectExit(id);
        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow);
        vm.expectEmit(true, true, true, true, strategy);
        emit Re7ETHMidasStrategy.ExitCleared(id, MidasRequestStatus.Canceled);
        _allocateDirect(0.5e18);
        assertEq(s.pendingExitId(), type(uint256).max, "allocate should settle the slot");

        // requestExit
        vm.prank(admin);
        id = s.requestExit(0.5e18);
        escrow = s.pendingExitMTokens();
        _rejectExit(id);
        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow);
        vm.prank(admin);
        uint256 newId = s.requestExit(0.2e18);
        assertEq(s.pendingExitId(), newId, "request should settle the old slot and open a new one");

        // Not settled while the escrow is still out.
        _rejectExit(newId);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 0.1e18, "", address(vault));
        assertEq(s.pendingExitId(), newId, "unreturned escrow must not be settled");
    }

    function test_clearExit_keeperProofTracksOwnMoves() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _setupMidasAdmin();
        _allocateDirect(2e18);
        vm.prank(admin);
        s.setKeeper(address(0xBEEF));

        vm.prank(admin);
        uint256 id = s.requestExit(0.5e18);
        uint256 escrow = s.pendingExitMTokens();
        _rejectExit(id);

        // Allocating more than the escrow must not satisfy the proof.
        _allocateDirect(1e18);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Escrow not returned");
        s.clearExit();

        // Deallocating afterwards must not lock the keeper out once the escrow does return.
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 0.7e18, "", address(vault));
        vm.prank(address(0xBEEF));
        vm.expectRevert("Escrow not returned");
        s.clearExit();

        vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(strategy, escrow);
        vm.prank(address(0xBEEF));
        s.clearExit();
        assertEq(s.pendingExitId(), type(uint256).max, "cleared");
    }

    function test_aggregatorRevert_holdsLastNavAndBlocksExecution() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 healthyValue = IMYTStrategy(strategy).realAssets();

        vm.mockCallRevert(
            Re7ETHMidasAddresses.AGGREGATOR,
            abi.encodeWithSelector(IAggregatorV3Tiny.latestRoundData.selector),
            abi.encodeWithSignature("Error(string)", "feed down")
        );

        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "reverting feed should hold lastNav");
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "no idle, nothing previewable");

        vm.expectRevert("NAV unhealthy");
        s.pokeNav();

        deal(Re7ETHMidasAddresses.WETH, strategy, 0.5e18);
        vm.prank(vault);
        vm.expectRevert("NAV unhealthy");
        IMYTStrategy(strategy).allocate(getVaultParams(), 0.5e18, "", address(vault));

        vm.prank(vault);
        vm.expectRevert("NAV unhealthy");
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));

        // acceptNav cannot bypass a dead feed either.
        vm.prank(admin);
        vm.expectRevert("feed down");
        s.acceptNav();

        vm.clearMockedCalls();
        _refreshFeed(block.timestamp);
        s.pokeNav();
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), healthyValue + 0.5e18, 1e12, "value should recover with the feed");
    }

    function test_malformedPrints_areUnhealthy() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(1e18);
        uint256 healthyValue = IMYTStrategy(strategy).realAssets();

        int256[3] memory answers = [int256(0), int256(-1), feedAnswer];
        uint256[3] memory updatedAts = [block.timestamp, block.timestamp, uint256(0)];
        for (uint256 i = 0; i < 3; i++) {
            _mockPrint(answers[i], updatedAts[i]);
            assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "malformed print should hold lastNav");
            vm.expectRevert("NAV unhealthy");
            s.pokeNav();
        }

        // A print from the future is rejected too.
        _mockPrint(feedAnswer, block.timestamp + 1);
        assertEq(IMYTStrategy(strategy).realAssets(), healthyValue, "future print should hold lastNav");
        vm.expectRevert("NAV unhealthy");
        s.pokeNav();
        vm.prank(admin);
        vm.expectRevert("Invalid NAV");
        s.acceptNav();
    }

    function test_previewAdjustedWithdraw_cappedByTokenAllowance() public {
        _allocateDirect(3e18);
        IMidasRedemptionVault rv = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        (address feed, uint256 fee,, bool stable) = rv.tokensConfig(Re7ETHMidasAddresses.WETH);
        uint256 minRedeem = rv.minAmount();
        uint256 feeBps = _redeemFeeBps();

        // Allowance below one minimum redeem zeroes the preview.
        uint256 belowMin = (minRedeem * _nav()) / 1e18 - 1;
        _mockTokenConfig(feed, fee, belowMin, stable);
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "sub-minimum allowance should zero the preview");

        // Otherwise the net-of-fee allowance bounds it, and that amount must execute.
        _mockTokenConfig(feed, fee, 0.5e18, stable);
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(3e18);
        uint256 expected = (0.5e18 - (0.5e18 * feeBps) / 10_000) * (10_000 - 50) / 10_000;
        assertApproxEqRel(preview, expected, 1e12, "preview should cap at net allowance");
        vm.clearMockedCalls();
        _refreshFeed(block.timestamp);

        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), preview, "", address(vault));
        assertGe(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), preview, "preview should be honoured");
    }

    function test_deallocate_grossesUpForHigherFees() public {
        _allocateDirect(4e18);
        IMidasRedemptionVault rv = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        (address feed,, uint256 allowance, bool stable) = rv.tokensConfig(Re7ETHMidasAddresses.WETH);

        // 100 bps token fee + 200 bps instant fee as seen by the strategy; Midas itself still charges the real fee.
        _mockTokenConfig(feed, 100, allowance, stable);
        vm.mockCall(Re7ETHMidasAddresses.REDEMPTION_VAULT, abi.encodeWithSelector(IMidasRedemptionVault.instantFee.selector), abi.encode(200));

        uint256 target = 1e18;
        // The fee is paid by the position, not the delivered amount: a partial preview only nets slippage,
        // while a full-position preview nets the combined fee.
        assertApproxEqRel(IMYTStrategy(strategy).previewAdjustedWithdraw(target), (target * (10_000 - 50)) / 10_000, 1e12, "partial preview");
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 expectedFull = ((realAssets * (10_000 - 300)) / 10_000) * (10_000 - 50) / 10_000;
        assertApproxEqRel(IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets), expectedFull, 1e12, "full preview should net the combined fee");

        uint256 mBefore = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), target, "", address(vault));
        uint256 burned = mBefore - IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);

        uint256 netMTokens = (target * 1e18 + _nav() - 1) / _nav();
        uint256 expectedBurned = (netMTokens * 10_000 + (10_000 - 300) - 1) / (10_000 - 300);
        assertApproxEqRel(burned, expectedBurned, 1e12, "burn should gross up for the combined fee");
        assertGe(IERC20(Re7ETHMidasAddresses.WETH).balanceOf(strategy), target, "idle must cover the request");
        vm.clearMockedCalls();
    }

    function test_deallocate_cannotRedeemEscrowedExit() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(2e18);

        vm.prank(admin);
        s.requestExit(1.5e18);
        uint256 remaining = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(strategy);
        assertGt(remaining, 0, "some position should remain");

        // Preview only promises what the un-escrowed position can serve.
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(2e18);
        assertLe(preview, (remaining * _nav()) / 1e18, "preview must exclude escrow");

        // Asking for more than the remaining position reverts rather than touching escrow.
        vm.prank(vault);
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));

        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), preview, "", address(vault));
    }

    function test_exit_valuesMidasRecordedAmountNotRequested() public {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(strategy);
        _allocateDirect(2e18);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(admin);
        uint256 id = s.requestExit(1e18);
        uint256 recorded = s.pendingExitMTokens();

        // Simulate Midas having taken a 1% request fee: the escrow is what Midas recorded, net of fee.
        uint256 net = (recorded * 99) / 100;
        vm.mockCall(
            Re7ETHMidasAddresses.REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.redeemRequests.selector, id),
            abi.encode(strategy, Re7ETHMidasAddresses.WETH, MidasRequestStatus.Pending, net, _nav(), 1e18)
        );
        assertEq(s.pendingExitMTokens(), net, "escrow should follow Midas's record");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), valueBefore - ((recorded - net) * _nav()) / 1e18, 1e9, "fee should be reflected in value");
        vm.clearMockedCalls();
        _refreshFeed(block.timestamp);
    }

    function test_allocate_revertsWhenNothingMinted() public {
        deal(Re7ETHMidasAddresses.WETH, strategy, 1e18);
        vm.mockCall(Re7ETHMidasAddresses.DEPOSIT_VAULT, abi.encodeWithSelector(IMidasDepositVault.depositInstant.selector), "");

        vm.prank(vault);
        vm.expectRevert("No Re7ETH received");
        IMYTStrategy(strategy).allocate(getVaultParams(), 1e18, "", address(vault));
        vm.clearMockedCalls();
    }

    function test_constructor_revertsOnBadVenueState() public {
        IMYTStrategy.StrategyParams memory params = getStrategyConfig();

        vm.mockCall(Re7ETHMidasAddresses.DATA_FEED, abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector), abi.encode(uint256(0)));
        vm.expectRevert("Invalid NAV");
        new Re7ETHMidasStrategy(
            vault,
            params,
            Re7ETHMidasAddresses.RE7_ETH,
            Re7ETHMidasAddresses.DEPOSIT_VAULT,
            Re7ETHMidasAddresses.REDEMPTION_VAULT,
            Re7ETHMidasAddresses.DATA_FEED
        );
        vm.clearMockedCalls();

        _mockTokenConfig(address(0), 0, 0, true);
        vm.expectRevert("WETH not redeemable");
        new Re7ETHMidasStrategy(
            vault,
            params,
            Re7ETHMidasAddresses.RE7_ETH,
            Re7ETHMidasAddresses.DEPOSIT_VAULT,
            Re7ETHMidasAddresses.REDEMPTION_VAULT,
            Re7ETHMidasAddresses.DATA_FEED
        );
        vm.clearMockedCalls();
    }

    function _mockPrint(int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            Re7ETHMidasAddresses.AGGREGATOR,
            abi.encodeWithSelector(IAggregatorV3Tiny.latestRoundData.selector),
            abi.encode(feedRoundId, answer, updatedAt, updatedAt, feedRoundId)
        );
    }

    function _mockTokenConfig(address feed, uint256 fee, uint256 allowance, bool stable) internal {
        vm.mockCall(
            Re7ETHMidasAddresses.REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.tokensConfig.selector, Re7ETHMidasAddresses.WETH),
            abi.encode(feed, fee, allowance, stable)
        );
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

/// @dev Drives the privileged exit lifecycle under fuzz: request as owner, settle as the (mocked) Midas admin.
contract Re7ETHMidasExitHandler is Test {
    Re7ETHMidasStrategy internal immutable strategy;
    address internal immutable strategyOwner;
    uint256 internal immutable nav;

    uint256 public requests;
    uint256 public approvals;
    uint256 public rejections;
    uint256 public keeperClears;
    uint256 public writeOffs;

    constructor(address _strategy, address _owner, uint256 _nav) {
        strategy = Re7ETHMidasStrategy(_strategy);
        strategyOwner = _owner;
        nav = _nav;
    }

    function requestExit(uint256 seed) external {
        if (strategy.pendingExitMTokens() != 0) return;
        uint256 minAmount = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT).minAmount();
        uint256 position = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(address(strategy));
        if (position < minAmount * 4) return;

        uint256 mTokens = bound(seed, minAmount * 2, position / 2);
        vm.prank(strategyOwner);
        strategy.requestExit((mTokens * nav) / 1e18);
        requests++;
    }

    function settleExit(uint256 seed) external {
        uint256 id = strategy.pendingExitId();
        if (id == type(uint256).max) return;
        (,, MidasRequestStatus status, uint256 amount,,) = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT).redeemRequests(id);
        if (status != MidasRequestStatus.Pending) return;

        IMidasRedemptionVaultAdmin rv = IMidasRedemptionVaultAdmin(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        if (seed % 4 == 0) {
            vm.prank(Re7ETHMidasAddresses.MIDAS_ADMIN);
            rv.rejectRequest(id);
            // Midas returns cancelled escrow off-chain; mirror that, then clear as the keeper. If a simulated
            // external loss has pushed the balance under the proof, the owner writes it off.
            vm.prank(Re7ETHMidasAddresses.REDEMPTION_VAULT);
            IERC20(Re7ETHMidasAddresses.RE7_ETH).transfer(address(strategy), amount);
            if (IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(address(strategy)) >= strategy.positionExEscrow() + amount) {
                strategy.clearExit();
                keeperClears++;
            } else {
                vm.prank(strategyOwner);
                strategy.writeOffExit();
                writeOffs++;
            }
            rejections++;
        } else {
            vm.prank(Re7ETHMidasAddresses.MIDAS_ADMIN);
            rv.approveRequest(id, nav);
            approvals++;
        }
    }
}

contract Re7ETHMidasInvariantTest is E2EInvariantStrategyTest {
    using stdStorage for StdStorage;

    uint256 internal navSnapshot;
    Re7ETHMidasExitHandler internal exitHandler;

    function setUp() public override {
        super.setUp();
        exitHandler = new Re7ETHMidasExitHandler(realStrategy, admin, navSnapshot);
        // The handler drives the full keeper lifecycle: request as owner, clear cancelled slots itself.
        vm.prank(admin);
        Re7ETHMidasStrategy(realStrategy).setKeeper(address(exitHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = exitHandler.requestExit.selector;
        selectors[1] = exitHandler.settleExit.selector;
        targetContract(address(exitHandler));
        targetSelector(FuzzSelector({addr: address(exitHandler), selectors: selectors}));
    }

    /// @dev The slot only ever holds a live or settled request. a cancelled one is cleared as soon as its escrow returns.
    function invariant_exitSlotConsistent() public view {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(realStrategy);
        uint256 id = s.pendingExitId();
        if (id == type(uint256).max) {
            assertEq(s.pendingExitMTokens(), 0, "no slot, no escrow");
            return;
        }
        (address sender,, MidasRequestStatus status, uint256 amount,,) = IMidasRedemptionVault(Re7ETHMidasAddresses.REDEMPTION_VAULT).redeemRequests(id);
        assertEq(sender, realStrategy, "slot must be ours");
        assertTrue(status != MidasRequestStatus.Canceled, "cancelled slot should be cleared");
        assertEq(s.pendingExitMTokens(), status == MidasRequestStatus.Pending ? amount : 0, "escrow follows status");
    }

    /// @dev Escrow is never double counted: the position plus pending escrow at NAV equals value minus idle.
    function invariant_escrowAccountedOnce() public view {
        Re7ETHMidasStrategy s = Re7ETHMidasStrategy(realStrategy);
        uint256 mTokens = IERC20(Re7ETHMidasAddresses.RE7_ETH).balanceOf(realStrategy) + s.pendingExitMTokens();
        uint256 idle = IERC20(Re7ETHMidasAddresses.WETH).balanceOf(realStrategy);
        assertApproxEqAbs(IMYTStrategy(realStrategy).realAssets(), idle + (mTokens * navSnapshot) / 1e18, 1e9, "escrow accounting");
    }

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
        // handler's raw warps would trip the staleness guard, so disable it for the fuzz campaign by writing
        // past the setter's cap. The deviation guard stays active (the pinned print never moves).
        stdstore.target(strategy_).sig("maxNavStaleness()").checked_write(36_500 days);

        // Request settlement pulls WETH from Midas's `requestRedeemer` under the vault admin role.
        IMidasRedemptionVaultAdmin rv = IMidasRedemptionVaultAdmin(Re7ETHMidasAddresses.REDEMPTION_VAULT);
        vm.mockCall(
            rv.accessControl(), abi.encodeWithSelector(IMidasAccessControl.hasRole.selector, rv.vaultRole(), Re7ETHMidasAddresses.MIDAS_ADMIN), abi.encode(true)
        );
        deal(Re7ETHMidasAddresses.WETH, rv.requestRedeemer(), Re7ETHMidasAddresses.REDEMPTION_LIQUIDITY);
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
