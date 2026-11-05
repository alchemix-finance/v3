// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {YieldBouncer} from "../../utils/YieldBouncer.sol";
import {YieldBouncerUSD} from "../../utils/YieldBouncerUSD.sol";
import {YieldBouncerETH} from "../../utils/YieldBouncerETH.sol";
import {IRateSource} from "../../utils/rates/IRateSource.sol";

/// @dev A position whose value the stub allocator moves.
contract StubStrategy {
    uint256 public realAssets;

    constructor(uint256 initial) {
        realAssets = initial;
    }

    function shift(int256 delta) external {
        realAssets = uint256(int256(realAssets) + delta);
    }
}

/// @dev Also stands in for the vault's asset (6 decimals, like USDC).
contract StubVault {
    mapping(address => bool) public isAdapter;
    address public liquidityAdapter;
    uint256 public totalAssets = 100_000_000 * 1e6;

    function setAdapter(address a, bool on) external {
        isAdapter[a] = on;
    }

    function setLiquidityAdapter(address a) external {
        liquidityAdapter = a;
    }

    function setTotalAssets(uint256 t) external {
        totalAssets = t;
    }

    function asset() external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @dev Moves value one to one unless a test scripts the next pair of legs, or blocks
///      the allocate leg the way a cap would.
contract StubAllocator {
    address public vault;
    bool public scripted;
    int256 public nextFromDelta;
    int256 public nextToDelta;
    bool public blockAllocate;

    constructor(address _vault) {
        vault = _vault;
    }

    function script(int256 fromDelta, int256 toDelta) external {
        scripted = true;
        nextFromDelta = fromDelta;
        nextToDelta = toDelta;
    }

    function setBlockAllocate(bool on) external {
        blockAllocate = on;
    }

    function deallocate(address adapter, uint256 amount) external {
        StubStrategy(adapter).shift(scripted ? nextFromDelta : -int256(amount));
    }

    function allocate(address adapter, uint256 amount) external {
        require(!blockAllocate, "EffectiveCap");
        StubStrategy(adapter).shift(scripted ? nextToDelta : int256(amount));
        scripted = false;
    }
}

/// @dev rate(venue) = base − slope × realAssets / 1e6. Venue = the stub strategy.
contract StubRateSource is IRateSource {
    mapping(address => uint256) public base;
    mapping(address => uint256) public slope;

    function set(address venue, uint256 b, uint256 s) external {
        base[venue] = b;
        slope[venue] = s;
    }

    function supplyRate(address venue) external view returns (uint256) {
        uint256 drop = slope[venue] * StubStrategy(venue).realAssets() / 1e6;
        return drop >= base[venue] ? 0 : base[venue] - drop;
    }
}

contract BrokenRateSource is IRateSource {
    function supplyRate(address) external pure returns (uint256) {
        revert("cannot read");
    }
}

/// @dev Calls back into the bouncer from inside a leg.
contract ReentrantAllocator {
    address public vault;
    YieldBouncer public target;
    address public from;
    address public to;

    constructor(address _vault) {
        vault = _vault;
    }

    function arm(YieldBouncer t, address f, address d) external {
        target = t;
        from = f;
        to = d;
    }

    function deallocate(address adapter, uint256 amount) external {
        StubStrategy(adapter).shift(-int256(amount));
        target.bounce(from, to, amount);
    }

    function allocate(address adapter, uint256 amount) external {
        StubStrategy(adapter).shift(int256(amount));
    }
}

contract YieldBouncerTest is Test {
    uint256 internal constant U = 1e6;          // one USDC
    uint256 internal constant BP = 1e14;        // one APR basis point, WAD

    address internal owner = makeAddr("owner");
    address internal bot = makeAddr("bot");
    address internal stranger = makeAddr("stranger");
    address internal safe = makeAddr("safe");

    StubVault internal vault;
    StubAllocator internal allocator;
    StubRateSource internal rates;
    YieldBouncer internal bouncer;
    StubStrategy internal steak;               // a
    StubStrategy internal fluid;               // b
    StubStrategy internal outsider;            // not an adapter

    function setUp() public {
        vault = new StubVault();
        allocator = new StubAllocator(address(vault));
        rates = new StubRateSource();
        steak = new StubStrategy(1_000_000 * U);
        fluid = new StubStrategy(40_000 * U);
        outsider = new StubStrategy(0);
        vault.setAdapter(address(steak), true);
        vault.setAdapter(address(fluid), true);
        vm.prank(owner);
        bouncer = new YieldBouncerUSD(address(allocator));
        vm.startPrank(owner);
        bouncer.setRateSource(address(steak), address(rates), address(steak));
        bouncer.setRateSource(address(fluid), address(rates), address(fluid));
        // reference 5.5% ± 200 bp: every rate these tests set (5.0%–6.0%) is in band
        bouncer.setRateRef(address(steak), 55 * 10 * BP, 200);
        bouncer.setRateRef(address(fluid), 55 * 10 * BP, 200);
        vm.stopPrank();
        _favour(address(fluid));
    }

    // ---- helpers ------------------------------------------------------------------

    function _limits(uint256 toB, uint256 toA) internal pure returns (YieldBouncer.Limits memory l) {
        l = YieldBouncer.Limits({
            maxNetToB: toB,
            maxNetToA: toA,
            maxClip: 1_000_000 * U,
            minIntervalBlocks: 0,
            maxLossBps: 2,
            minSpreadBps: 0,
            expiresAtBlock: 0
        });
    }

    function _grant(YieldBouncer.Limits memory l) internal {
        vm.prank(owner);
        bouncer.grantPair(bot, address(steak), address(fluid), l);
    }

    /// @dev Flat rates: `hi` pays 6%, the other 5%.
    function _favour(address hi) internal {
        address lo = hi == address(fluid) ? address(steak) : address(fluid);
        rates.set(hi, 6e16, 0);
        rates.set(lo, 5e16, 0);
    }

    function _bounce(address from, address to, uint256 assets) internal returns (uint256 rFrom, uint256 rTo, int256 net) {
        vm.prank(bot);
        return bouncer.bounce(from, to, assets);
    }

    function _net() internal view returns (int256) {
        return bouncer.pairOf(bot, address(steak), address(fluid)).net;
    }

    // ---- the net band -------------------------------------------------------------

    /// The off-weight start agreed for the first pair: up to 100 from Steakhouse into
    /// Fluid and back, never more out of Fluid than went in.
    function test_offWeightBand_userExample() public {
        _grant(_limits(100 * U, 0));

        _favour(address(fluid));
        _bounce(address(steak), address(fluid), 100 * U);
        assertEq(_net(), int256(100 * U));

        _favour(address(steak));
        _bounce(address(fluid), address(steak), 50 * U);
        assertEq(_net(), int256(50 * U));

        _favour(address(fluid));
        _bounce(address(steak), address(fluid), 50 * U);
        assertEq(_net(), int256(100 * U));

        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, int256(100 * U + 1), int256(100 * U)));
        _bounce(address(steak), address(fluid), 1);

        _favour(address(steak));
        _bounce(address(fluid), address(steak), 100 * U);
        assertEq(_net(), 0);

        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, int256(-1), int256(0)));
        _bounce(address(fluid), address(steak), 1);

        // the 40,000 booked in Fluid before the grant is untouched
        assertEq(fluid.realAssets(), 40_000 * U);
    }

    function test_symmetricBand_leansBothWays() public {
        _grant(_limits(100 * U, 100 * U));
        _bounce(address(steak), address(fluid), 100 * U);
        _favour(address(steak));
        _bounce(address(fluid), address(steak), 200 * U);
        assertEq(_net(), -int256(100 * U));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, -int256(100 * U + 1), -int256(100 * U)));
        _bounce(address(fluid), address(steak), 1);
    }

    function test_volumeIsUnlimitedInsideTheBand() public {
        _grant(_limits(10 * U, 0));
        for (uint256 i = 0; i < 20; i++) {
            _favour(address(fluid));
            _bounce(address(steak), address(fluid), 10 * U);
            _favour(address(steak));
            _bounce(address(fluid), address(steak), 10 * U);
        }
        assertEq(_net(), 0);
    }

    function test_rewriteKeepsNet_andABandBelowNetOnlyUnwinds() public {
        _grant(_limits(100 * U, 0));
        _bounce(address(steak), address(fluid), 60 * U);
        _grant(_limits(0, 0));
        assertEq(_net(), int256(60 * U));

        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, int256(60 * U + 1), int256(0)));
        _bounce(address(steak), address(fluid), 1);

        _favour(address(steak));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, int256(-1), int256(0)));
        _bounce(address(fluid), address(steak), 60 * U + 1);

        _bounce(address(fluid), address(steak), 60 * U);
        assertEq(_net(), 0);
    }

    function test_recenter() public {
        _grant(_limits(100 * U, 0));
        _bounce(address(steak), address(fluid), 100 * U);
        bytes32 key = bouncer.pairKey(bot, address(steak), address(fluid));
        vm.expectEmit(true, true, false, true);
        emit YieldBouncer.Recentered(bot, key, int256(100 * U));
        vm.prank(owner);
        bouncer.recenter(bot, address(fluid), address(steak));   // either order names the pair
        assertEq(_net(), 0);
        _bounce(address(steak), address(fluid), 100 * U);
        assertEq(_net(), int256(100 * U));
    }

    function test_room() public {
        _grant(_limits(100 * U, 0));
        assertEq(bouncer.room(bot, address(steak), address(fluid)), 100 * U);
        assertEq(bouncer.room(bot, address(fluid), address(steak)), 0);
        _bounce(address(steak), address(fluid), 30 * U);
        assertEq(bouncer.room(bot, address(steak), address(fluid)), 70 * U);
        assertEq(bouncer.room(bot, address(fluid), address(steak)), 30 * U);
        assertEq(bouncer.room(stranger, address(steak), address(fluid)), 0);
    }

    function testFuzz_netNeverLeavesTheBand(uint32[8] calldata amounts, bool[8] calldata towardB) public {
        uint256 toB = 500 * U;
        uint256 toA = 200 * U;
        _grant(_limits(toB, toA));
        for (uint256 i = 0; i < 8; i++) {
            uint256 assets = uint256(amounts[i]) % (400 * U) + 1;
            (address from, address to) = towardB[i] ? (address(steak), address(fluid)) : (address(fluid), address(steak));
            _favour(to);
            int256 expected = _net() + (towardB[i] ? int256(assets) : -int256(assets));
            bool fits = expected <= int256(toB) && expected >= -int256(toA);
            vm.prank(bot);
            try bouncer.bounce(from, to, assets) {
                assertTrue(fits, "moved outside the band");
            } catch {
                assertFalse(fits, "refused a move inside the band");
            }
            assertLe(_net(), int256(toB));
            assertGe(_net(), -int256(toA));
        }
    }

    // ---- the rate check -----------------------------------------------------------

    /// Steakhouse flat at 5.20%; Fluid 5.60% − 0.005% per 1,000 USDC held, so 5.40% at the
    /// 40,000 it holds and 5.20% at 80,000: the rates cross after 40,000 moved.
    function _fluidCurve() internal {
        rates.set(address(steak), 520 * BP, 0);
        rates.set(address(fluid), 560 * BP, 5 * BP / 10_000);   // 0.005% per 1,000 USDC
    }

    function test_spread_capsTheSizeAtTheCrossing() public {
        _grant(_limits(100_000 * U, 0));
        _fluidCurve();
        (uint256 rFrom, uint256 rTo, int256 net) = _bounce(address(steak), address(fluid), 30_000 * U);
        assertEq(rFrom, 520 * BP);
        assertEq(rTo, 525 * BP);                    // 70,000 held
        assertEq(net, int256(30_000 * U));
        assertEq(rTo, bouncer.rateOf(address(fluid)));

        // 15,000 more would hold 85,000: 5.175% < 5.20%
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.SpreadTooThin.selector, 5175 * BP / 10, 520 * BP, uint16(0)));
        _bounce(address(steak), address(fluid), 15_000 * U);

        // exactly to the crossing passes: equal rates meet a zero spread
        _bounce(address(steak), address(fluid), 10_000 * U);
        assertEq(bouncer.rateOf(address(fluid)), 520 * BP);
    }

    function test_spread_minSpreadBps() public {
        YieldBouncer.Limits memory l = _limits(100_000 * U, 0);
        l.minSpreadBps = 10;                         // Fluid must stay ≥ 5.30%: hold ≤ 60,000
        _grant(l);
        _fluidCurve();
        _bounce(address(steak), address(fluid), 20_000 * U);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.SpreadTooThin.selector, 530 * BP - 5e10, 520 * BP, uint16(10)));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_spread_wrongDirectionReverts() public {
        _grant(_limits(100 * U, 100 * U));
        _favour(address(steak));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.SpreadTooThin.selector, 5e16, 6e16, uint16(0)));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_rateSources_required() public {
        StubStrategy third = new StubStrategy(0);
        vault.setAdapter(address(third), true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoRateSource.selector, address(third)));
        bouncer.grantPair(bot, address(steak), address(third), _limits(1, 1));

        _grant(_limits(100 * U, 0));
        vm.prank(owner);
        bouncer.setRateSource(address(fluid), address(0), address(fluid));
        (address source, address venue) = bouncer.rateFeeds(address(fluid));
        assertEq(source, address(0));
        assertEq(venue, address(0));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoRateSource.selector, address(fluid)));
        _bounce(address(steak), address(fluid), 1 * U);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoRateSource.selector, address(fluid)));
        bouncer.rateOf(address(fluid));
    }

    function test_setRateSource_refusesAFeedThatCannotRead() public {
        BrokenRateSource broken = new BrokenRateSource();
        vm.prank(owner);
        vm.expectRevert("cannot read");
        bouncer.setRateSource(address(fluid), address(broken), address(fluid));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NotAdapter.selector, address(outsider)));
        bouncer.setRateSource(address(outsider), address(rates), address(outsider));
    }

    // ---- the APR deviation guard --------------------------------------------------

    /// A same-block pump: Fluid printed 6% a block ago, now says 9%. The live rate is
    /// outside the reference band, so the bounce refuses it instead of believing it.
    function test_guard_rejectsAPumpedRate() public {
        _grant(_limits(100 * U, 0));
        rates.set(address(fluid), 9e16, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RateDeviates.selector, address(fluid), 9e16, 55 * 10 * BP, uint16(200)));
        _bounce(address(steak), address(fluid), 1 * U);
        // and a depressed source is refused the same way
        rates.set(address(fluid), 6e16, 0);
        rates.set(address(steak), 2e16, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RateDeviates.selector, address(steak), 2e16, 55 * 10 * BP, uint16(200)));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_guard_bandEdges() public {
        _grant(_limits(100 * U, 0));
        rates.set(address(fluid), 55 * 10 * BP + 200 * BP, 0);     // exactly +band passes
        _bounce(address(steak), address(fluid), 1 * U);
        rates.set(address(fluid), 55 * 10 * BP + 200 * BP + 1, 0); // one wei over does not
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RateDeviates.selector, address(fluid), 55 * 10 * BP + 200 * BP + 1, 55 * 10 * BP, uint16(200)));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_guard_noReferenceBlocksMoves() public {
        _grant(_limits(100 * U, 0));
        vm.prank(owner);
        bouncer.setRateRef(address(fluid), 1e18, 0);              // 0 band clears it, rate ignored
        (uint256 rate, uint16 band,,) = bouncer.rateRefs(address(fluid));
        assertEq(rate, 0);
        assertEq(band, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoRateRef.selector, address(fluid)));
        _bounce(address(steak), address(fluid), 1 * U);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoRateRef.selector, address(fluid)));
        bouncer.proposeRateRef(address(fluid));
    }

    /// Only the owner or a bot with an active pair may propose a reference.
    function test_guard_proposalIsBotOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(YieldBouncer.NotBotOrOwner.selector);
        bouncer.proposeRateRef(address(fluid));
        vm.prank(bot);                                              // no pair yet
        vm.expectRevert(YieldBouncer.NotBotOrOwner.selector);
        bouncer.proposeRateRef(address(fluid));
        _grant(_limits(100 * U, 0));
        vm.prank(bot);
        bouncer.proposeRateRef(address(fluid));
        vm.prank(owner);
        bouncer.proposeRateRef(address(fluid));
        vm.prank(owner);
        bouncer.revokePair(bot, address(steak), address(fluid));
        vm.prank(bot);
        vm.expectRevert(YieldBouncer.NotBotOrOwner.selector);
        bouncer.proposeRateRef(address(fluid));
    }

    /// A granted bot proposes the live rate as the next reference; it must be in band
    /// now and only counts REF_LAG later, so the reference walks at most one band per lag.
    function test_guard_proposalPromotesAfterLag() public {
        _grant(_limits(100 * U, 0));
        rates.set(address(fluid), 7e16, 0);                        // +150 bp, in band
        uint256 t0 = block.timestamp;
        vm.prank(bot);
        bouncer.proposeRateRef(address(fluid));
        (uint256 rate,, uint256 pendingRate, uint64 pendingAt) = bouncer.rateRefs(address(fluid));
        assertEq(rate, 55 * 10 * BP);                              // unchanged
        assertEq(pendingRate, 7e16);
        assertEq(pendingAt, uint64(t0));

        // 8% is +250 bp from the current reference: refused even though 7% is pending
        rates.set(address(fluid), 8e16, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RateDeviates.selector, address(fluid), 8e16, 55 * 10 * BP, uint16(200)));
        _bounce(address(steak), address(fluid), 1 * U);

        // one second short of the lag: a new proposal replaces the pending one, no promotion
        rates.set(address(fluid), 7e16, 0);
        vm.warp(t0 + bouncer.REF_LAG() - 1);
        vm.prank(bot);
        bouncer.proposeRateRef(address(fluid));
        (rate,,, pendingAt) = bouncer.rateRefs(address(fluid));
        assertEq(rate, 55 * 10 * BP);
        assertEq(pendingAt, uint64(t0 + bouncer.REF_LAG() - 1));

        // after the lag the pending 7% becomes the reference and 8% is now in band
        vm.warp(t0 + 2 * bouncer.REF_LAG());
        vm.prank(bot);
        bouncer.proposeRateRef(address(fluid));
        (rate,,,) = bouncer.rateRefs(address(fluid));
        assertEq(rate, 7e16);
        rates.set(address(fluid), 8e16, 0);
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_guard_proposalMustBeInBand() public {
        rates.set(address(fluid), 9e16, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RateDeviates.selector, address(fluid), 9e16, 55 * 10 * BP, uint16(200)));
        bouncer.proposeRateRef(address(fluid));
        // the owner can still jump the reference directly, and that clears any pending proposal
        rates.set(address(fluid), 6e16, 0);
        vm.prank(owner);
        bouncer.proposeRateRef(address(fluid));
        vm.prank(owner);
        bouncer.setRateRef(address(fluid), 9e16, 50);
        (uint256 rate, uint16 band, uint256 pendingRate, uint64 pendingAt) = bouncer.rateRefs(address(fluid));
        assertEq(rate, 9e16);
        assertEq(band, 50);
        assertEq(pendingRate, 0);
        assertEq(pendingAt, 0);
    }

    // ---- the source guard ---------------------------------------------------------

    function _liquidityBudget() internal view returns (uint128 perDay, uint128 available, uint64 updatedAt) {
        return bouncer.liquidityBudget();
    }

    /// @dev Makes Steakhouse the vault's liquidity adapter and lets the owner draw from it.
    function _enableLiquidity() internal {
        vault.setLiquidityAdapter(address(steak));
        uint16 maxMoveBps = bouncer.DEFAULT_MAX_MOVE_BPS();
        vm.prank(owner);
        bouncer.setSourceGuard(true, maxMoveBps);
    }

    function test_source_defaults() public view {
        (bool movable, uint16 maxMoveBps) = bouncer.sourceGuard();
        assertFalse(movable);
        assertEq(maxMoveBps, 500);
        assertEq(bouncer.LIQ_ADAPTER_MAX(), 200_000 * U);
        (uint128 perDay, uint128 available,) = _liquidityBudget();
        assertEq(perDay, 100_000 * U);
        assertEq(available, 0);
    }

    function test_source_ethCeiling() public {
        vm.prank(owner);
        YieldBouncer b2 = new YieldBouncerETH(address(allocator));
        assertEq(b2.LIQ_ADAPTER_MAX(), 50 * U);             // the stub asset has 6 decimals
        (uint128 perDay,,) = b2.liquidityBudget();
        assertEq(perDay, 25 * U);
    }

    function test_source_liquidityBlockedByDefault() public {
        _grant(_limits(100 * U, 100 * U));
        vault.setLiquidityAdapter(address(steak));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.FromLiquidityAdapter.selector, address(steak)));
        _bounce(address(steak), address(fluid), 1 * U);
        // into the liquidity adapter is never limited
        _favour(address(steak));
        _bounce(address(fluid), address(steak), 1 * U);
    }

    function test_source_maxMoveBps() public {
        YieldBouncer.Limits memory l = _limits(10_000_000 * U, 0);
        l.maxClip = 10_000_000 * U;
        _grant(l);
        vault.setTotalAssets(1_000_000 * U);                // 5% = 50,000
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.MoveTooLarge.selector, 50_000 * U + 1, 50_000 * U));
        _bounce(address(steak), address(fluid), 50_000 * U + 1);
        _bounce(address(steak), address(fluid), 50_000 * U);
    }

    function test_source_setterBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.BadMaxMoveBps.selector, uint16(0)));
        bouncer.setSourceGuard(false, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.BadMaxMoveBps.selector, uint16(2_001)));
        bouncer.setSourceGuard(false, 2_001);
        bouncer.setSourceGuard(false, 2_000);
        bouncer.setLiquidityPerDay(uint128(200_000 * U));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityPerDayTooHigh.selector, 200_000 * U + 1, 200_000 * U));
        bouncer.setLiquidityPerDay(uint128(200_000 * U + 1));
        vm.stopPrank();

        _grant(_limits(1, 1));
        vm.startPrank(bot);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.setSourceGuard(true, 500);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.setLiquidityPerDay(1);
        vm.stopPrank();
    }

    /// Enabling draws starts the budget empty, so a bot cannot take a full day at once.
    function test_budget_startsEmptyOnEnable() public {
        _grant(_limits(1_000_000 * U, 0));
        _enableLiquidity();
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityBudgetExceeded.selector, 1 * U, 0));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_budget_refillsAndCaps() public {
        _grant(_limits(1_000_000 * U, 0));
        _enableLiquidity();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 12 hours);                             // half of 100,000
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityBudgetExceeded.selector, 50_000 * U + 1, 50_000 * U));
        _bounce(address(steak), address(fluid), 50_000 * U + 1);
        _bounce(address(steak), address(fluid), 50_000 * U);
        (, uint128 available, uint64 updatedAt) = _liquidityBudget();
        assertEq(available, 0);
        assertEq(updatedAt, uint64(t0 + 12 hours));

        vm.warp(t0 + 10 days);                              // the budget holds one day, no more
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityBudgetExceeded.selector, 100_000 * U + 1, 100_000 * U));
        _bounce(address(steak), address(fluid), 100_000 * U + 1);
        _bounce(address(steak), address(fluid), 100_000 * U);
    }

    function test_budget_sharedAcrossBots() public {
        address bot2 = makeAddr("bot2");
        _grant(_limits(1_000_000 * U, 0));
        vm.prank(owner);
        bouncer.grantPair(bot2, address(steak), address(fluid), _limits(1_000_000 * U, 0));
        _enableLiquidity();
        vm.warp(block.timestamp + 1 days);
        _bounce(address(steak), address(fluid), 60_000 * U);
        vm.prank(bot2);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityBudgetExceeded.selector, 40_000 * U + 1, 40_000 * U));
        bouncer.bounce(address(steak), address(fluid), 40_000 * U + 1);
        vm.prank(bot2);
        bouncer.bounce(address(steak), address(fluid), 40_000 * U);
    }

    /// Moves from other strategies do not spend the budget, and changing only maxMoveBps keeps it.
    function test_budget_onlyLiquidityDrawsSpend() public {
        _grant(_limits(1_000_000 * U, 1_000_000 * U));
        vault.setLiquidityAdapter(address(fluid));
        uint256 t0 = block.timestamp;
        vm.prank(owner);
        bouncer.setSourceGuard(true, 500);
        vm.warp(t0 + 1 days);
        _bounce(address(steak), address(fluid), 10_000 * U);
        (, uint128 available, uint64 updatedAt) = _liquidityBudget();
        assertEq(available, 0);
        assertEq(updatedAt, uint64(t0));

        _favour(address(steak));
        _bounce(address(fluid), address(steak), 30_000 * U);
        vm.prank(owner);
        bouncer.setSourceGuard(true, 1_000);
        (, available,) = _liquidityBudget();
        assertEq(available, 70_000 * U);
    }

    function test_budget_setPerDayRestartsEmpty() public {
        _grant(_limits(1_000_000 * U, 0));
        _enableLiquidity();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days);
        vm.prank(owner);
        bouncer.setLiquidityPerDay(uint128(200_000 * U));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LiquidityBudgetExceeded.selector, 1 * U, 0));
        _bounce(address(steak), address(fluid), 1 * U);
        vm.warp(t0 + 2 days);
        _bounce(address(steak), address(fluid), 200_000 * U);
    }

    // ---- per-move limits ----------------------------------------------------------

    function test_maxClip() public {
        YieldBouncer.Limits memory l = _limits(100 * U, 0);
        l.maxClip = 10 * U;
        _grant(l);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.ClipTooLarge.selector, 10 * U, 10 * U + 1));
        _bounce(address(steak), address(fluid), 10 * U + 1);
        _bounce(address(steak), address(fluid), 10 * U);
    }

    function test_spacing_sharedByBothDirections() public {
        YieldBouncer.Limits memory l = _limits(100 * U, 0);
        l.minIntervalBlocks = 5;
        _grant(l);
        uint256 n0 = block.number;   // via_ir may cache block.number in this frame
        _bounce(address(steak), address(fluid), 10 * U);
        uint64 readyAt = uint64(n0 + 5);

        vm.roll(n0 + 4);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.TooSoon.selector, readyAt));
        _bounce(address(steak), address(fluid), 10 * U);
        _favour(address(steak));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.TooSoon.selector, readyAt));
        _bounce(address(fluid), address(steak), 10 * U);

        vm.roll(n0 + 5);
        _bounce(address(fluid), address(steak), 10 * U);
    }

    function test_expiry() public {
        YieldBouncer.Limits memory l = _limits(100 * U, 0);
        uint256 n0 = block.number;
        l.expiresAtBlock = uint64(n0 + 1);
        _grant(l);
        _bounce(address(steak), address(fluid), 1 * U);
        vm.roll(n0 + 1);
        _bounce(address(steak), address(fluid), 1 * U);
        vm.roll(n0 + 2);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.PairExpired.selector, l.expiresAtBlock));
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_zeroAmount() public {
        _grant(_limits(100 * U, 0));
        vm.expectRevert(YieldBouncer.ZeroAmount.selector);
        _bounce(address(steak), address(fluid), 0);
    }

    // ---- per-leg loss bound -------------------------------------------------------

    function test_loss_fromLegEdge() public {
        _grant(_limits(100 * U, 0));
        // 2 bps: from may drop by at most 10,002,000 on a 10,000,000 move
        allocator.script(-10_002_001, 10_000_000);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LossExceedsLimit.selector, 10_002_001, 10_002_000, false));
        _bounce(address(steak), address(fluid), 10 * U);
        allocator.script(-10_002_000, 10_000_000);
        _bounce(address(steak), address(fluid), 10 * U);
    }

    function test_loss_toLegEdge() public {
        _grant(_limits(100 * U, 0));
        allocator.script(-10_000_000, 9_997_999);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.LossExceedsLimit.selector, 9_997_999, 9_998_000, true));
        _bounce(address(steak), address(fluid), 10 * U);
        allocator.script(-10_000_000, 9_998_000);
        _bounce(address(steak), address(fluid), 10 * U);
    }

    function test_loss_legsMustMove() public {
        _grant(_limits(100 * U, 0));
        allocator.script(0, 10_000_000);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RealAssetsDidNotMove.selector, 10 * U, int256(0)));
        _bounce(address(steak), address(fluid), 10 * U);
        allocator.script(-10_000_000, 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.RealAssetsDidNotMove.selector, 10 * U, int256(0)));
        _bounce(address(steak), address(fluid), 10 * U);
    }

    /// A cap on the allocate leg reverts the whole move: nothing lands in idle, net
    /// and spacing stay where they were.
    function test_blockedAllocateRevertsTheWholeMove() public {
        YieldBouncer.Limits memory l = _limits(100 * U, 0);
        l.minIntervalBlocks = 10;
        _grant(l);
        allocator.setBlockAllocate(true);
        vm.expectRevert("EffectiveCap");
        _bounce(address(steak), address(fluid), 10 * U);
        assertEq(_net(), 0);
        assertEq(bouncer.pairOf(bot, address(steak), address(fluid)).lastMoveBlock, 0);
        assertEq(steak.realAssets(), 1_000_000 * U);
        allocator.setBlockAllocate(false);
        _bounce(address(steak), address(fluid), 10 * U);
    }

    // ---- grants -------------------------------------------------------------------

    function test_grant_orientationIsFixed() public {
        _grant(_limits(100 * U, 0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.OrientationMismatch.selector, address(steak), address(fluid)));
        bouncer.grantPair(bot, address(fluid), address(steak), _limits(100 * U, 0));
    }

    function test_grant_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.SameStrategy.selector, address(steak)));
        bouncer.grantPair(bot, address(steak), address(steak), _limits(1, 1));
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NotAdapter.selector, address(outsider)));
        bouncer.grantPair(bot, address(steak), address(outsider), _limits(1, 1));
        YieldBouncer.Limits memory l = _limits(1, 1);
        l.maxClip = 0;
        vm.expectRevert("grant");
        bouncer.grantPair(bot, address(steak), address(fluid), l);
        l = _limits(1, 1);
        l.maxLossBps = 10_001;
        vm.expectRevert(bytes("loss"));
        bouncer.grantPair(bot, address(steak), address(fluid), l);
        l = _limits(uint256(type(int256).max) + 1, 1);
        vm.expectRevert("range");
        bouncer.grantPair(bot, address(steak), address(fluid), l);
        vm.stopPrank();
    }

    function test_revoke_thenRegrantKeepsNet() public {
        _grant(_limits(100 * U, 0));
        _bounce(address(steak), address(fluid), 40 * U);
        vm.prank(owner);
        bouncer.revokePair(bot, address(steak), address(fluid));
        assertEq(bouncer.activePairs(bot), 0);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoPair.selector, bot, address(steak), address(fluid)));
        _bounce(address(steak), address(fluid), 1 * U);

        _grant(_limits(100 * U, 0));
        assertEq(bouncer.activePairs(bot), 1);
        assertEq(_net(), int256(40 * U));
        assertEq(bouncer.room(bot, address(steak), address(fluid)), 60 * U);
    }

    function test_onlyTheGrantedBotMoves() public {
        _grant(_limits(100 * U, 0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NoPair.selector, stranger, address(steak), address(fluid)));
        bouncer.bounce(address(steak), address(fluid), 1 * U);
    }

    function test_bouncedEvent() public {
        _grant(_limits(100 * U, 0));
        bytes32 key = bouncer.pairKey(bot, address(steak), address(fluid));
        vm.expectEmit(true, true, true, true);
        emit YieldBouncer.Bounced(bot, key, address(steak), address(fluid), 10 * U, int256(10 * U), 5e16, 6e16,
                                  -int256(10 * U), int256(10 * U));
        _bounce(address(steak), address(fluid), 10 * U);
    }

    // ---- authority ----------------------------------------------------------------

    function test_pause() public {
        _grant(_limits(100 * U, 0));
        vm.prank(stranger);
        vm.expectRevert(YieldBouncer.NotBotOrOwner.selector);
        bouncer.setPaused(true);

        vm.prank(bot);
        bouncer.setPaused(true);
        vm.expectRevert(YieldBouncer.MoverPaused.selector);
        _bounce(address(steak), address(fluid), 1 * U);
        vm.prank(bot);
        vm.expectRevert(YieldBouncer.NotBotOrOwner.selector);
        bouncer.setPaused(false);

        vm.prank(owner);
        bouncer.setPaused(false);
        _bounce(address(steak), address(fluid), 1 * U);
    }

    function test_ownership_twoStep() public {
        vm.prank(stranger);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.grantPair(bot, address(steak), address(fluid), _limits(1, 1));

        vm.prank(owner);
        bouncer.transferOwnership(safe);
        assertEq(bouncer.pendingOwner(), safe);
        vm.prank(stranger);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.acceptOwnership();

        vm.prank(safe);
        bouncer.acceptOwnership();
        assertEq(bouncer.owner(), safe);
        vm.prank(owner);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.grantPair(bot, address(steak), address(fluid), _limits(1, 1));
        vm.prank(safe);
        bouncer.grantPair(bot, address(steak), address(fluid), _limits(1, 1));
    }

    function test_reentryFromALegReverts() public {
        ReentrantAllocator evil = new ReentrantAllocator(address(vault));
        vm.prank(owner);
        YieldBouncer b2 = new YieldBouncerUSD(address(evil));
        vm.startPrank(owner);
        b2.setRateSource(address(steak), address(rates), address(steak));
        b2.setRateSource(address(fluid), address(rates), address(fluid));
        b2.setRateRef(address(steak), 55 * 10 * BP, 200);
        b2.setRateRef(address(fluid), 55 * 10 * BP, 200);
        b2.grantPair(bot, address(steak), address(fluid), _limits(100 * U, 0));
        vm.stopPrank();
        evil.arm(b2, address(steak), address(fluid));
        vm.prank(bot);
        vm.expectRevert(YieldBouncer.Reentrant.selector);
        b2.bounce(address(steak), address(fluid), 1 * U);
    }

    // ---- the rate-feed registry ---------------------------------------------------

    function _fed() internal view returns (address[] memory) {
        return bouncer.fedStrategies();
    }

    function _has(address[] memory list, address x) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == x) return true;
        }
        return false;
    }

    /// The owner adds a feed when a strategy joins the vault and clears it when the
    /// strategy leaves; fedStrategies() lists what is fed now, no duplicates.
    function test_registry_addReplaceClear() public {
        assertEq(_fed().length, 2);
        assertTrue(_has(_fed(), address(steak)) && _has(_fed(), address(fluid)));

        StubStrategy third = new StubStrategy(0);
        vault.setAdapter(address(third), true);
        StubRateSource other = new StubRateSource();
        vm.startPrank(owner);
        bouncer.setRateSource(address(third), address(rates), address(third));
        assertEq(_fed().length, 3);
        // pointing a fed strategy at another source keeps one entry
        bouncer.setRateSource(address(steak), address(other), address(steak));
        assertEq(_fed().length, 3);
        (address src,) = bouncer.rateFeeds(address(steak));
        assertEq(src, address(other));

        // clear from the middle, from the end, and twice
        bouncer.setRateSource(address(fluid), address(0), address(0));
        assertEq(_fed().length, 2);
        assertFalse(_has(_fed(), address(fluid)));
        assertTrue(_has(_fed(), address(steak)) && _has(_fed(), address(third)));
        bouncer.setRateSource(address(third), address(0), address(0));
        bouncer.setRateSource(address(third), address(0), address(0));
        assertEq(_fed().length, 1);
        assertEq(_fed()[0], address(steak));

        // a strategy that left the vault keeps its feed until the owner clears it,
        // and cannot be fed again while it is not an adapter
        vault.setAdapter(address(fluid), false);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NotAdapter.selector, address(fluid)));
        bouncer.setRateSource(address(fluid), address(rates), address(fluid));
        bouncer.setRateSource(address(steak), address(0), address(0));
        vm.stopPrank();
        assertEq(_fed().length, 0);
    }
}
