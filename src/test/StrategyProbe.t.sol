// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";

/// @dev Balance the test can set per holder; the stub allocator moves it
///      between the vault and the adapters.
contract ProbeToken {
    mapping(address => uint256) public balanceOf;

    function set(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function move(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "idle");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Position whose `realAssets` moves by exactly what the stub allocator
///      pushes in or pulls out, with two switches to script a venue failure.
contract ProbeStrategy {
    bytes32 public immutable adapterId;
    uint256 public realAssets;
    bool public revertAllocate;
    bool public revertDeallocate;

    constructor(bytes32 id) {
        adapterId = id;
    }

    function setRealAssets(uint256 v) external {
        realAssets = v;
    }

    function setRevert(bool onAllocate, bool onDeallocate) external {
        revertAllocate = onAllocate;
        revertDeallocate = onDeallocate;
    }

    function onAllocate(uint256 amount) external virtual {
        require(!revertAllocate, "venue");
        realAssets += amount;
    }

    function onDeallocate(uint256 amount) external virtual {
        require(!revertDeallocate, "venue");
        realAssets -= amount;
    }
}

contract ProbeVault {
    address public asset;
    address public liquidityAdapter;
    mapping(address => bool) public isAdapter;
    mapping(bytes32 => uint256) public allocation;

    constructor(address _asset) {
        asset = _asset;
    }

    function setAdapter(address a, bool ok) external {
        isAdapter[a] = ok;
    }

    function setLiquidityAdapter(address a) external {
        liquidityAdapter = a;
    }

    function book(bytes32 id, int256 delta) external {
        allocation[id] = uint256(int256(allocation[id]) + delta);
    }
}

/// @dev Enough of AlchemistAllocator for the probe: operator gate, idle moves
///      vault <-> adapter, realAssets and the vault's booking kept in step.
contract ProbeAllocator {
    address public vault;
    ProbeToken public token;
    mapping(address => bool) public operators;

    constructor(address _vault, ProbeToken _token) {
        vault = _vault;
        token = _token;
    }

    function setOperator(address op, bool ok) external {
        operators[op] = ok;
    }

    function allocate(address adapter, uint256 amount) external {
        require(operators[msg.sender], "PD");
        token.move(vault, adapter, amount);
        ProbeStrategy(adapter).onAllocate(amount);
        ProbeVault(vault).book(ProbeStrategy(adapter).adapterId(), int256(amount));
    }

    function deallocate(address adapter, uint256 amount) external {
        require(operators[msg.sender], "PD");
        ProbeStrategy(adapter).onDeallocate(amount);
        token.move(adapter, vault, amount);
        ProbeVault(vault).book(ProbeStrategy(adapter).adapterId(), -int256(amount));
    }
}

/// @dev Venue that, once armed, calls back into the probe from inside a leg.
///      Stands in for third-party code running under a whitelisted poker.
contract ReenteringStrategy is ProbeStrategy {
    StrategyProbe public probe;
    bytes public reenterCall;
    bytes public lastRevert;

    constructor(bytes32 id) ProbeStrategy(id) {}

    function arm(StrategyProbe _probe, bytes calldata call) external {
        probe = _probe;
        reenterCall = call;
    }

    function onAllocate(uint256 amount) external override {
        realAssets += amount;
        _reenter();
    }

    function onDeallocate(uint256 amount) external override {
        realAssets -= amount;
        _reenter();
    }

    function _reenter() internal {
        if (reenterCall.length == 0) return;
        (bool ok, bytes memory ret) = address(probe).call(reenterCall);
        require(!ok, "reentered");
        lastRevert = ret;
    }
}

contract StrategyProbeResetTest is Test {
    uint256 internal constant SMALL = 1e15;
    uint256 internal constant LARGE = 1e16;
    uint256 internal constant TOL_BPS = 100;
    uint256 internal constant LIQ_START = 100 ether;

    ProbeToken internal token;
    ProbeStrategy internal strat;
    ProbeStrategy internal liq;
    ProbeVault internal vault;
    ProbeAllocator internal allocator;
    StrategyProbe internal probe;
    address internal poker = makeAddr("poker");

    function setUp() public {
        token = new ProbeToken();
        strat = new ProbeStrategy(keccak256("strat"));
        liq = new ProbeStrategy(keccak256("liq"));
        vault = new ProbeVault(address(token));
        allocator = new ProbeAllocator(address(vault), token);
        probe = new StrategyProbe(address(allocator), SMALL, LARGE, TOL_BPS, 0);

        vault.setAdapter(address(strat), true);
        vault.setAdapter(address(liq), true);
        vault.setLiquidityAdapter(address(liq));
        // deposits sit in the liquidity adapter: vault idle is 0
        liq.setRealAssets(LIQ_START);
        token.set(address(liq), LIQ_START);
        vault.book(liq.adapterId(), int256(LIQ_START));

        allocator.setOperator(address(probe), true);
        probe.setPoker(poker, true);
    }

    // ---- helpers ------------------------------------------------------------

    function _leg() internal returns (uint8 leg, uint256 residual) {
        vm.prank(poker);
        return probe.runNextLeg(address(strat));
    }

    /// @dev legs 1 and 2 pass, then the venue refuses the LARGE allocate. The
    ///      leg-3 revert unwinds its own raise, so the ladder sits at nextLeg 3
    ///      with idleRaised = SMALL and that SMALL sitting idle in the vault.
    function _stallAtLeg3() internal {
        _leg();
        _leg();
        strat.setRevert(true, false);
        vm.expectRevert("venue");
        _leg();
        assertEq(probe.nextLeg(address(strat)), 3);
        assertEq(_idleRaised(), SMALL);
        assertEq(token.balanceOf(address(vault)), SMALL);
        assertEq(liq.realAssets(), LIQ_START - SMALL);
    }

    function _idleRaised() internal view returns (uint256 idleRaised) {
        (,, idleRaised,,,,) = probe.openLadders(address(strat));
    }

    function _assertCleared() internal view {
        (uint8 nextLeg, uint256 held, uint256 idleRaised, uint256 bookedAtOpen, uint256 realAtOpen, uint64 openedAt, address openedBy) =
            probe.openLadders(address(strat));
        assertEq(nextLeg, 0);
        assertEq(held, 0);
        assertEq(idleRaised, 0);
        assertEq(bookedAtOpen, 0);
        assertEq(realAtOpen, 0);
        assertEq(openedAt, 0);
        assertEq(openedBy, address(0));
        assertFalse(probe.ladderCompleted(address(strat)));
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) n++;
        }
    }

    // ---- reset: returns the raised idle, then clears -------------------------

    function test_reset_returnsIdleAndClears() public {
        _stallAtLeg3();

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.IdleReturned(address(liq), SMALL, SMALL, int256(SMALL));
        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), false, 3, 0, SMALL, SMALL, false);
        probe.reset(address(strat));

        _assertCleared();
        assertEq(token.balanceOf(address(vault)), 0, "idle went back");
        assertEq(liq.realAssets(), LIQ_START, "liquidity adapter whole again");
        assertEq(vault.allocation(liq.adapterId()), LIQ_START);
    }

    /// @dev With an exit buffer the deallocate leg brings back less than the
    ///      allocate put in, so the vault is short by the buffer: the return is
    ///      clamped to what is there and the event says so.
    function test_reset_clampsReturnToVaultIdle() public {
        uint16 bufferBps = 100;
        probe.setAdapterOverrides(address(strat), uint16(TOL_BPS), bufferBps);
        uint256 leftInStrategy = SMALL * bufferBps / 10_000;

        _leg();
        _leg();
        strat.setRevert(true, false);
        vm.expectRevert("venue");
        _leg();
        assertEq(token.balanceOf(address(vault)), SMALL - leftInStrategy);

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.IdleReturned(address(liq), SMALL, SMALL - leftInStrategy, int256(SMALL - leftInStrategy));
        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), false, 3, 0, SMALL, SMALL - leftInStrategy, false);
        probe.reset(address(strat));

        _assertCleared();
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(strat.realAssets(), leftInStrategy, "dust stays in the strategy");
    }

    /// @dev Nothing to put back when the ladder stalled with the leg still in
    ///      the venue: no IdleReturned, the strategy keeps the SMALL leg.
    function test_reset_afterStalledDeallocate_returnsNothing() public {
        _leg();
        strat.setRevert(false, true);
        vm.expectRevert("venue");
        _leg();
        assertEq(probe.nextLeg(address(strat)), 2);

        vm.recordLogs();
        probe.reset(address(strat));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countTopic(logs, StrategyProbe.IdleReturned.selector), 0);
        assertEq(_countTopic(logs, StrategyProbe.LadderReset.selector), 1);
        _assertCleared();
        assertEq(strat.realAssets(), SMALL, "leg stays in the strategy");
        assertEq(liq.realAssets(), LIQ_START - SMALL, "nothing was there to return");
    }

    function test_reset_clearsOneLadderLockAfterCompletion() public {
        for (uint256 i; i < 4; i++) _leg();
        assertTrue(probe.ladderCompleted(address(strat)));
        vm.expectRevert(abi.encodeWithSelector(StrategyProbe.LadderAlreadyCompleted.selector, address(strat)));
        _leg();

        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), true, 0, 0, 0, 0, false);
        probe.reset(address(strat));
        assertEq(_countTopic(vm.getRecordedLogs(), StrategyProbe.IdleReturned.selector), 0);

        _assertCleared();
        (uint8 leg,) = _leg();
        assertEq(leg, 1, "re-armed");
    }

    function test_reset_skipsReturnWhenNoLiquidityAdapter() public {
        _stallAtLeg3();
        vault.setLiquidityAdapter(address(0));

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), false, 3, 0, SMALL, 0, false);
        probe.reset(address(strat));

        _assertCleared();
        assertEq(token.balanceOf(address(vault)), SMALL, "idle parked in the vault");
    }

    // ---- reset is atomic; forceReset is the way out --------------------------

    function test_reset_revertsWholeAndKeepsStateWhenReturnFails() public {
        _stallAtLeg3();
        liq.setRevert(true, false); // caps / paused venue on the way back

        vm.expectRevert("venue");
        probe.reset(address(strat));

        assertEq(probe.nextLeg(address(strat)), 3, "ladder untouched");
        assertEq(_idleRaised(), SMALL);
        assertEq(token.balanceOf(address(vault)), SMALL);
    }

    function test_forceReset_clearsWithoutTouchingTheVault() public {
        _stallAtLeg3();
        liq.setRevert(true, false);

        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), false, 3, 0, SMALL, 0, true);
        probe.forceReset(address(strat));
        assertEq(_countTopic(vm.getRecordedLogs(), StrategyProbe.IdleReturned.selector), 0);

        _assertCleared();
        assertEq(token.balanceOf(address(vault)), SMALL, "idle left where it was");
        assertEq(liq.realAssets(), LIQ_START - SMALL, "liquidity adapter not touched");
        assertEq(strat.realAssets(), 0);
    }

    function test_forceReset_reportsWhatIsStillInTheStrategy() public {
        _leg();
        strat.setRevert(false, true);
        vm.expectRevert("venue");
        _leg();

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), false, 2, SMALL, SMALL, 0, true);
        probe.forceReset(address(strat));

        _assertCleared();
        assertEq(strat.realAssets(), SMALL);
    }

    function test_forceReset_afterCompletion() public {
        for (uint256 i; i < 4; i++) _leg();

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.LadderReset(address(strat), true, 0, 0, 0, 0, true);
        probe.forceReset(address(strat));

        _assertCleared();
        (uint8 leg,) = _leg();
        assertEq(leg, 1);
    }

    function test_forceReset_thenNewLadderRunsClean() public {
        _stallAtLeg3();
        liq.setRevert(true, false);
        probe.forceReset(address(strat));
        liq.setRevert(false, false);
        strat.setRevert(false, false);

        // the parked SMALL is reused as idle: leg 1 raises nothing
        (uint8 leg,) = _leg();
        assertEq(leg, 1);
        assertEq(_idleRaised(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // ---- guards -------------------------------------------------------------

    function test_reset_revertsWhenNothingOpen() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyProbe.NothingToReset.selector, address(strat)));
        probe.reset(address(strat));
    }

    function test_forceReset_revertsWhenNothingOpen() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyProbe.NothingToReset.selector, address(strat)));
        probe.forceReset(address(strat));
    }

    function test_reset_onlyOwner() public {
        _stallAtLeg3();
        vm.prank(poker);
        vm.expectRevert(StrategyProbe.NotOwner.selector);
        probe.reset(address(strat));
    }

    function test_forceReset_onlyOwner() public {
        _stallAtLeg3();
        vm.prank(poker);
        vm.expectRevert(StrategyProbe.NotOwner.selector);
        probe.forceReset(address(strat));
    }

    // ---- overrides: stored 0 is a real value, not "use default" --------------

    function test_overrides_unsetUsesDefaults() public view {
        assertEq(probe.toleranceBps(address(strat)), TOL_BPS);
        assertEq(probe.exitBufferBps(address(strat)), 0);
        (uint16 t, uint16 b, bool set) = probe.overrides(address(strat));
        assertEq(t, 0);
        assertEq(b, 0);
        assertFalse(set);
    }

    function test_overrides_zeroIsHonored() public {
        StrategyProbe p = new StrategyProbe(address(allocator), SMALL, LARGE, TOL_BPS, 50);
        assertEq(p.exitBufferBps(address(strat)), 50, "default buffer");

        p.setAdapterOverrides(address(strat), 0, 0);
        assertEq(p.toleranceBps(address(strat)), 0);
        assertEq(p.exitBufferBps(address(strat)), 0);

        p.setAdapterOverrides(address(strat), uint16(TOL_BPS), 0);
        assertEq(p.toleranceBps(address(strat)), TOL_BPS);
        assertEq(p.exitBufferBps(address(strat)), 0, "zero buffer sticks, not the default 50");
    }

    function test_overrides_zeroExitBufferDeallocatesInFull() public {
        StrategyProbe p = new StrategyProbe(address(allocator), SMALL, LARGE, TOL_BPS, 50);
        p.setPoker(poker, true);
        p.setAdapterOverrides(address(strat), uint16(TOL_BPS), 0);
        allocator.setOperator(address(p), true);

        vm.prank(poker);
        p.runNextLeg(address(strat));
        vm.prank(poker);
        p.runNextLeg(address(strat));

        assertEq(strat.realAssets(), 0, "no dust left behind");
        assertEq(token.balanceOf(address(vault)), SMALL);
    }

    // ---- leg 4 shares the same return path -----------------------------------

    function test_closeLadder_returnsRaisedIdleAndReports() public {
        for (uint256 i; i < 3; i++) _leg();
        // leg 1 raised SMALL, leg 3 topped up to LARGE
        assertEq(_idleRaised(), LARGE);

        vm.expectEmit(true, false, false, true, address(probe));
        emit StrategyProbe.IdleReturned(address(liq), LARGE, LARGE, int256(LARGE));
        vm.expectEmit(true, true, true, true, address(probe));
        emit StrategyProbe.LadderCompleted(address(strat), strat.adapterId(), poker, LARGE, LARGE, 0);
        (uint8 leg, uint256 residual) = _leg();

        assertEq(leg, 4);
        assertEq(residual, 0);
        assertTrue(probe.ladderCompleted(address(strat)));
        assertEq(probe.nextLeg(address(strat)), 0);
        assertEq(token.balanceOf(address(vault)), 0, "vault idle unchanged after a full ladder");
        assertEq(liq.realAssets(), LIQ_START);
        assertEq(strat.realAssets(), 0);
    }

    /// @dev The liquidity adapter unset mid-ladder used to revert leg 4 inside
    ///      the allocator; now the close just reports nothing returned.
    function test_closeLadder_doesNotBrickWhenLiquidityAdapterUnset() public {
        for (uint256 i; i < 3; i++) _leg();
        vault.setLiquidityAdapter(address(0));

        vm.expectEmit(true, true, true, true, address(probe));
        emit StrategyProbe.LadderCompleted(address(strat), strat.adapterId(), poker, LARGE, 0, 0);
        (uint8 leg,) = _leg();

        assertEq(leg, 4);
        assertTrue(probe.ladderCompleted(address(strat)));
        assertEq(token.balanceOf(address(vault)), LARGE, "idle parked in the vault");
    }

    function test_closeLadder_revertsWholeWhenReturnFails() public {
        for (uint256 i; i < 3; i++) _leg();
        liq.setRevert(true, false);

        vm.expectRevert("venue");
        _leg();

        assertEq(probe.nextLeg(address(strat)), 4, "leg 4 still pending");
        assertEq(strat.realAssets(), LARGE, "deallocate rolled back with it");
    }

    // ---- reentrancy -----------------------------------------------------------

    function _reenteringSetup() internal returns (ReenteringStrategy venue) {
        venue = new ReenteringStrategy(keccak256("venue"));
        vault.setAdapter(address(venue), true);
        probe.setPoker(address(venue), true); // worst case: the venue is also a whitelisted poker
    }

    /// @dev Without the guard the inner call would run leg 2 before leg 1 has
    ///      written heldInStrategy / nextLeg, and the outer leg would then
    ///      overwrite them.
    function test_runNextLeg_blocksReentrantLeg() public {
        ReenteringStrategy venue = _reenteringSetup();
        venue.arm(probe, abi.encodeCall(probe.runNextLeg, (address(venue))));

        vm.prank(poker);
        (uint8 leg,) = probe.runNextLeg(address(venue));

        assertEq(leg, 1);
        assertEq(bytes4(venue.lastRevert()), StrategyProbe.Reentrancy.selector);
        assertEq(probe.nextLeg(address(venue)), 2, "exactly one leg ran");
        (, uint256 held,,,,,) = probe.openLadders(address(venue));
        assertEq(held, SMALL);
    }

    function test_runNextLeg_blocksReentrantLegOnOtherAdapter() public {
        ReenteringStrategy venue = _reenteringSetup();
        venue.arm(probe, abi.encodeCall(probe.runNextLeg, (address(strat))));

        vm.prank(poker);
        probe.runNextLeg(address(venue));

        assertEq(bytes4(venue.lastRevert()), StrategyProbe.Reentrancy.selector);
        assertEq(probe.nextLeg(address(strat)), 0, "other ladder never opened");
    }

    /// @dev `reset` calls the liquidity adapter; a reentering liquidity adapter
    ///      must not be able to drive a leg while the reset is mid-flight.
    function test_reset_blocksReentrantLeg() public {
        ReenteringStrategy venue = _reenteringSetup();
        // make the reentering venue the liquidity adapter, funded like liq
        venue.setRealAssets(LIQ_START);
        token.set(address(venue), LIQ_START);
        vault.setLiquidityAdapter(address(venue));

        _leg(); // raises SMALL from venue, allocates to strat
        _leg(); // SMALL back to vault idle
        strat.setRevert(true, false);
        vm.expectRevert("venue");
        _leg(); // stalled at 3, SMALL idle, idleRaised SMALL

        venue.arm(probe, abi.encodeCall(probe.runNextLeg, (address(strat))));
        probe.reset(address(strat));

        assertEq(bytes4(venue.lastRevert()), StrategyProbe.Reentrancy.selector);
        _assertCleared();
        assertEq(venue.realAssets(), LIQ_START, "idle returned");
    }

    /// @dev The guard releases: the next honest call goes through.
    function test_nonReentrant_releasesAfterCall() public {
        ReenteringStrategy venue = _reenteringSetup();
        venue.arm(probe, abi.encodeCall(probe.runNextLeg, (address(venue))));

        vm.prank(poker);
        probe.runNextLeg(address(venue));
        vm.prank(poker);
        (uint8 leg,) = probe.runNextLeg(address(venue));

        assertEq(leg, 2);
    }
}
