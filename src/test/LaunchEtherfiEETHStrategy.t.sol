// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {StrategyLauncher} from "../utils/StrategyLauncher.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {DeployEtherfiEETHStrategyScript} from "../../script/DeployEtherfiEETHStrategy.s.sol";
import {DeployStrategyLauncherScript} from "../../script/DeployStrategyLauncher.s.sol";
import {StrategyLaunchBase} from "../../script/launch/StrategyLaunchBase.s.sol";
import {LaunchEtherfiEETHStrategyScript} from "../../script/launch/LaunchEtherfiEETHStrategy.s.sol";

/// @dev Stands in for the 0x allowance holder: pulls `amountIn` of `from` and pays `amountOut` of `to`.
contract StubSwapper {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

/// @notice Replays the Ether.fi launch JSON on a mainnet fork against the live ETH MYT, on the swap paths.
///         Only the swap is stubbed: each quote names what the stub pays, so a test picks a fair quote,
///         a thin one, or a dead one. The vault, the allocator, the strategy and the oracle are real.
contract LaunchEtherfiEETHStrategyTest is Test {
    uint256 internal constant FORK_BLOCK = 26_450_000;
    uint256 internal constant BPS = 10_000;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    AggregatorV3Interface internal constant WEETH_ETH_ORACLE = AggregatorV3Interface(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22);

    /// @dev Quote shortfalls against the oracle price. The strategy floor is its slippageBPS (125),
    ///      the grant's loss bound is pilot.maxLossBps (50). THIN sits between them, BELOW_FLOOR under both.
    uint256 internal constant FAIR = 0;
    uint256 internal constant THIN = 80;
    uint256 internal constant BELOW_FLOOR = 200;

    address internal keeper = makeAddr("keeper");
    address internal sentinel = makeAddr("sentinel");

    LaunchEtherfiEETHStrategyScript internal launchScript;
    StrategyLaunchBase.Config internal cfg;
    IVaultV2 internal vault;
    StrategyProbe internal probe;
    ClipAllocator internal clip;
    StrategyLauncher internal launcher;
    StubSwapper internal swapper;
    address internal strategy;

    struct State {
        StrategyLauncher.Phase phase;
        uint256 pilotAllocated;
        uint256 allocateGrantLeft;
        uint64 lastClipBlock;
        uint256 liquidityGrantLeft;
        uint256 realAssets;
        uint256 booked;
        uint256 vaultIdle;
    }

    /// @dev The fields of StrategyLauncher.StepFailed, as a bot decodes them.
    struct Failure {
        address adapter;
        StrategyLauncher.Phase phase;
        uint8 step;
        StrategyLauncher.Venue venue;
        StrategyLauncher.Mode mode;
        bool isAllocate;
        uint256 amount;
        bytes reason;
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);

        launchScript = new LaunchEtherfiEETHStrategyScript();
        StrategyLaunchBase.Config memory c = launchScript.loadConfig();
        vault = IVaultV2(c.c.myt);
        _preDeploy(c);
        c.c.probe = address(probe);
        c.c.clip = address(clip);
        c.c.launcher = address(launcher);
        cfg = c;

        strategy = new DeployEtherfiEETHStrategyScript().run();

        swapper = new StubSwapper();
        deal(WETH, address(swapper), 1_000 ether);
        deal(WEETH, address(swapper), 1_000 ether);
        vm.prank(cfg.c.safe);
        MYTStrategy(strategy).setAllowanceHolder(address(swapper));
    }

    // ---- deploy and batch 1 -----------------------------------------------------

    function test_deployedStrategy_waitsForTheSafe() public view {
        assertEq(MYTStrategy(strategy).owner(), cfg.c.safe, "owner");
        assertTrue(MYTStrategy(strategy).killSwitch(), "kill switch");
        assertFalse(vault.isAdapter(strategy), "not registered before batch 1");
    }

    function test_batch1_configuresTheSwapLaunch() public {
        _executeBatch1();

        bytes32 id = IMYTStrategy(strategy).adapterId();
        assertTrue(vault.isAdapter(strategy), "adapter");
        assertEq(AlchemistCurator(cfg.c.curator).adapterToMYT(strategy), cfg.c.myt, "curator mapping");
        assertEq(vault.absoluteCap(id), cfg.absoluteCap, "absolute cap");
        assertEq(vault.relativeCap(id), cfg.relativeCap, "relative cap");
        assertEq(vault.forceDeallocatePenalty(strategy), cfg.forceDeallocatePenalty, "penalty");
        assertEq(AlchemistStrategyClassifier(cfg.c.classifier).getStrategyRiskLevel(uint256(id)), cfg.riskClass, "risk");
        assertFalse(MYTStrategy(strategy).killSwitch(), "kill switch");

        uint256 legs = uint256(cfg.plan.smallLeg) + cfg.plan.largeLeg;
        (uint256 allocateBudget,,,,,,) = clip.allocateGrants(address(launcher), strategy);
        assertEq(allocateBudget, cfg.pilot.amount + cfg.pilotHeadroom + legs, "pilot, headroom and ladder grant");
        (uint256 exitBudget,,,,,,) = clip.deallocateGrants(address(launcher), strategy);
        assertEq(exitBudget, legs, "ladder exit grant");
        (uint256 liquidityBudget,,,,,,) = clip.deallocateGrants(address(launcher), cfg.c.liquidityAdapter);
        assertEq(liquidityBudget, cfg.liquidity.amount, "liquidity grant");

        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.Ladder), "phase");
        assertEq(l.attempt, 1, "first attempt");
        assertEq(l.planHash, keccak256(abi.encode(cfg.plan)), "plan hash");
        assertFalse(l.useProbe, "swap ladder");
        assertEq(uint8(l.allocMode), uint8(StrategyLauncher.Mode.Swap), "allocate mode");
        assertEq(uint8(l.deallocMode), uint8(StrategyLauncher.Mode.Swap), "deallocate mode");
        assertEq(l.pilotTarget, cfg.pilot.amount, "pilot target");
    }

    // ---- ladder -----------------------------------------------------------------

    function test_ladder_fourSwapLegsOpenThePilot() public {
        _executeBatch1();

        _runLadder();

        assertEq(uint8(_state().phase), uint8(StrategyLauncher.Phase.Pilot), "pilot open");
        assertEq(_state().pilotAllocated, 0, "no pilot clip ran during the ladder");
        uint256 legs = uint256(cfg.plan.smallLeg) + cfg.plan.largeLeg;
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), legs * cfg.plan.exitBufferBps / BPS, 1e9, "only the exit buffer stays");
        (uint256 exitLeft,,,,,,) = clip.deallocateGrants(address(launcher), strategy);
        assertLe(exitLeft, legs * cfg.plan.exitBufferBps / BPS + 1e9, "ladder exit grant used");
    }

    /// @dev A deallocate leg whose swap pays under the requested WETH reverts in the strategy.
    ///      The ladder stays on that leg with the same amount, and a fair quote then runs it.
    function test_ladder_rejectedLegStaysOnThatLeg() public {
        _executeBatch1();
        assertEq(_step(FAIR), 1, "leg 1");

        (, uint8 leg,, uint256 amount,,) = launcher.nextStep(strategy);
        Failure memory f = _stepFails(_sell(amount, THIN));
        _assertFailure(f, StrategyLauncher.Phase.Ladder, 2, false, amount, IMYTStrategy.InvalidAmount.selector);

        (, uint8 legAfter,, uint256 amountAfter,,) = launcher.nextStep(strategy);
        assertEq(leg, 2, "leg 2 was next");
        assertEq(legAfter, 2, "still leg 2");
        assertEq(amountAfter, amount, "same amount");
        assertEq(_step(FAIR), 2, "leg 2 on retry");
    }

    // ---- pilot: success ---------------------------------------------------------

    function test_pilot_fourSwapClipsComplete() public {
        _launchToPilot();
        State memory before = _state();

        uint256 clips = _runPilot();

        State memory done = _state();
        assertEq(clips, 4, "four clips");
        assertEq(uint8(done.phase), uint8(StrategyLauncher.Phase.PilotComplete), "phase");
        assertEq(done.pilotAllocated, cfg.pilot.amount, "pilot allocated");
        assertEq(done.allocateGrantLeft, cfg.pilotHeadroom, "only the headroom is left");
        assertApproxEqRel(done.realAssets - before.realAssets, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "pilot landed");

        bytes memory quote = _buy(1 ether, FAIR);
        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.PilotComplete));
        vm.prank(keeper);
        launcher.advance(strategy, quote, 0);
    }

    /// @dev A clip that lands starts the grant's interval. `nextStep` names the block it ends.
    function test_pilot_clipAfterSuccessWaitsTheInterval() public {
        _launchToPilot();
        _goodClip();

        (,,,,, uint64 readyBlock) = launcher.nextStep(strategy);
        assertEq(readyBlock, block.number + cfg.pilot.minIntervalBlocks, "ready block");

        uint256 amount = _clipAmount();
        Failure memory f = _clipFails(amount, _buy(amount, FAIR));
        _assertFailure(f, StrategyLauncher.Phase.Pilot, 2, true, amount, ClipAllocator.TooSoon.selector);

        _rollInterval();
        _goodClip();
        assertEq(_state().pilotAllocated, 2 * cfg.pilot.maxClip, "two clips");
    }

    // ---- pilot: a rejected clip, then the retry ------------------------------------

    /// @dev The swap pays under the strategy's oracle floor, so the strategy reverts.
    ///      The inner reason carries the floor and what the swap paid.
    function test_pilot_strategyRejectsQuoteBelowFloor_thenRetry() public {
        _launchToPilot();
        Failure memory f = _failThenRetry(_buy(cfg.pilot.maxClip, BELOW_FLOOR), IMYTStrategy.InvalidAmount.selector);

        (uint256 minOut, uint256 received) = abi.decode(_args(f.reason), (uint256, uint256));
        uint256 fairOut = cfg.pilot.maxClip * _oracleScale() / _oraclePrice();
        assertLt(received, minOut, "paid under the floor");
        assertApproxEqRel(received, fairOut * (BPS - BELOW_FLOOR) / BPS, 1e12, "received is the quote");
    }

    /// @dev The swap clears the strategy floor but loses more than the grant allows, so the clip allocator reverts.
    function test_pilot_clipAllocatorRejectsLoss_thenRetry() public {
        _launchToPilot();
        _failThenRetry(_buy(cfg.pilot.maxClip, THIN), ClipAllocator.LossExceedsLimit.selector);
    }

    /// @dev Calldata the swap target rejects, as an expired quote would be.
    function test_pilot_deadQuote_thenRetry() public {
        _launchToPilot();
        _failThenRetry(hex"deadbeef", IMYTStrategy.CounterfeitSettler.selector);
    }

    // ---- pilot: stopping ----------------------------------------------------------

    /// @dev A keeper pause stops every clip on the vault's clip allocator. Only the Safe lifts it.
    function test_pilot_keeperPauses_safeResumes() public {
        _launchToPilot();
        _goodClip();
        _rollInterval();

        vm.prank(keeper);
        launcher.pause(cfg.c.myt);
        assertTrue(clip.paused(), "clip allocator paused");
        assertTrue(probe.paused(), "probe paused");
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertTrue(r.clipPaused && r.probePaused, "report shows the pause");

        State memory before = _state();
        uint256 amount = _clipAmount();
        Failure memory f = _clipFails(amount, _buy(amount, FAIR));
        _assertFailure(f, StrategyLauncher.Phase.Pilot, 2, true, amount, ClipAllocator.MoverPaused.selector);
        _assertUnchanged(before, _state());

        vm.expectRevert(ClipAllocator.NotBotOrOwner.selector);
        vm.prank(keeper);
        clip.setPaused(false);

        vm.startPrank(cfg.c.safe);
        clip.setPaused(false);
        probe.setPaused(false);
        vm.stopPrank();

        _goodClip();
        assertEq(_state().pilotAllocated, before.pilotAllocated + amount, "resumed");
    }

    /// @dev Abort only closes the launch. The Safe also zeroes the grant, turns allocation off,
    ///      and pulls the pilot back out through the allocator.
    function test_pilot_safeAbortsAndUnwinds() public {
        _launchToPilot();
        _goodClip();
        _rollInterval();
        _goodClip();
        _rollInterval();

        vm.startPrank(cfg.c.safe);
        launcher.abort(strategy);
        clip.revokeAllocate(address(launcher), strategy);
        MYTStrategy(strategy).setKillSwitch(true);
        vm.stopPrank();

        bytes memory quote = _buy(cfg.pilot.maxClip, FAIR);
        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Aborted));
        vm.prank(keeper);
        launcher.advance(strategy, quote, 0);
        assertEq(_state().allocateGrantLeft, 0, "grant revoked");

        uint256 held = IMYTStrategy(strategy).realAssets();
        uint256 pull = held * (BPS - cfg.plan.exitBufferBps) / BPS;
        bytes memory exit = _sell(pull, FAIR);
        uint256 idleBefore = IERC20(WETH).balanceOf(address(vault));
        vm.prank(cfg.c.safe);
        AlchemistAllocator(cfg.c.allocator).deallocateWithSwap(strategy, pull, exit);

        assertEq(IERC20(WETH).balanceOf(address(vault)) - idleBefore, pull, "pilot back in the vault");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), held - pull, 1e9, "only the exit buffer stays");
    }

    // ---- sentinel: reopen, rewind, reset --------------------------------------------

    /// @dev Attempt 2 on the same address. The sentinel skips the ladder that already passed,
    ///      and the grant left over from attempt 1 funds the new pilot.
    function test_sentinel_reopensAfterAbort() public {
        _launchToPilot();
        _goodClip();
        _rollInterval();
        _goodClip();
        _rollInterval();

        vm.startPrank(sentinel);
        launcher.abort(strategy);
        launcher.registerLaunch(strategy, cfg.plan);
        launcher.setLeg(strategy, 5, 0);
        vm.stopPrank();

        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(l.attempt, 2, "second attempt");
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.Pilot), "ladder skipped");
        assertEq(l.pilotAllocated, 0, "fresh count");

        assertEq(_runPilot(), 4, "four clips on attempt 2");
        assertEq(uint8(_state().phase), uint8(StrategyLauncher.Phase.PilotComplete), "attempt 2 complete");
        assertEq(_state().allocateGrantLeft, 0, "the grant, not the launcher, ran out");
    }

    /// @dev Rerun the large legs. The exit leg runs out of deallocate grant, which only the Safe refills.
    function test_sentinel_rerunsTheLargeLegs() public {
        _launchToPilot();

        vm.prank(sentinel);
        launcher.setLeg(strategy, 3, 0);
        assertEq(_step(FAIR), 3, "leg 3 again");
        _rollInterval();

        (, uint8 leg,, uint256 amount,,) = launcher.nextStep(strategy);
        Failure memory f = _stepFails(_sell(amount, FAIR));
        _assertFailure(f, StrategyLauncher.Phase.Ladder, leg, false, amount, ClipAllocator.GrantExhausted.selector);
        (uint256 remaining, uint256 requested) = abi.decode(_args(f.reason), (uint256, uint256));
        assertLt(remaining, requested, "exit grant short");

        vm.prank(cfg.c.safe);
        clip.topUpDeallocate(address(launcher), strategy, cfg.plan.largeLeg);
        assertEq(_step(FAIR), 4, "leg 4 after the top up");
        assertEq(uint8(_state().phase), uint8(StrategyLauncher.Phase.Pilot), "back in pilot");
    }

    /// @dev A second pilot round after a reset spends the headroom, then the grant stops it.
    function test_sentinel_resetPilot_spendsHeadroomThenTheGrantStops() public {
        _launchToPilot();
        _runPilot();

        vm.prank(sentinel);
        launcher.resetPilot(strategy);
        _goodClip();
        _rollInterval();
        _goodClip();
        _rollInterval();
        assertEq(_state().pilotAllocated, cfg.pilotHeadroom, "headroom spent");

        uint256 amount = _clipAmount();
        Failure memory f = _clipFails(amount, _buy(amount, FAIR));
        _assertFailure(f, StrategyLauncher.Phase.Pilot, 3, true, amount, ClipAllocator.GrantExhausted.selector);
    }

    function test_report_snapshotsTheLaunch() public {
        _launchToPilot();
        _goodClip();

        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Pilot), "phase");
        assertEq(r.launch.attempt, 1, "attempt");
        assertEq(r.launch.clipCount, 1, "clip count");
        assertEq(r.launch.pilotAllocated, cfg.pilot.maxClip, "allocated");
        assertEq(r.launch.lastSuccessBlock, block.number, "last success");
        assertEq(r.nextAmount, cfg.pilot.maxClip, "next clip");
        assertTrue(r.needsQuote, "swap clip");
        assertEq(r.readyBlock, block.number + cfg.pilot.minIntervalBlocks, "ready block");
        (uint256 grantLeft,,,,,,) = clip.allocateGrants(address(launcher), strategy);
        assertEq(r.allocateGrantLeft, grantLeft, "allocate grant");
        assertFalse(r.clipPaused || r.probePaused, "nothing paused");
        assertEq(r.realAssets, IMYTStrategy(strategy).realAssets(), "real assets");
        assertEq(r.booked, vault.allocation(IMYTStrategy(strategy).adapterId()), "booked");
    }

    // ---- batch 2 ------------------------------------------------------------------

    function test_batch2_raisesTheCapAndGraduates() public {
        _launchToPilot();
        _runPilot();

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _execute(launchScript.batch2(cfg, strategy));

        assertEq(vault.absoluteCap(IMYTStrategy(strategy).adapterId()), cfg.scaleAbsoluteCap, "scaled cap");
        assertEq(IMYTStrategy(strategy).realAssets(), realBefore, "swap launches leave the larger allocation to a keeper");
        assertEq(uint8(_state().phase), uint8(StrategyLauncher.Phase.Graduated), "graduated");
    }

    // ---- helpers ------------------------------------------------------------------

    /// @dev Two fair clips, one rejected clip, then the same clip with a fair quote in the same block.
    ///      The rejected clip must change nothing, and the retry must not wait an interval.
    function _failThenRetry(bytes memory badQuote, bytes4 expectedReason) internal returns (Failure memory f) {
        _goodClip();
        _rollInterval();
        _goodClip();
        _rollInterval();

        State memory before = _state();
        uint256 amount = _clipAmount();
        f = _clipFails(amount, badQuote);
        _assertFailure(f, StrategyLauncher.Phase.Pilot, 3, true, amount, expectedReason);
        _assertUnchanged(before, _state());

        _goodClip();
        State memory retried = _state();
        assertEq(retried.pilotAllocated, before.pilotAllocated + amount, "retry counted once");
        assertEq(retried.allocateGrantLeft, before.allocateGrantLeft - amount, "retry spent one clip");

        _rollInterval();
        _goodClip();
        assertEq(uint8(_state().phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot completes after the retry");
    }

    function _clipFails(uint256, bytes memory quote) internal returns (Failure memory) {
        return _stepFails(quote);
    }

    function _stepFails(bytes memory quote) internal returns (Failure memory) {
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(launcher).call(abi.encodeCall(StrategyLauncher.advance, (strategy, quote, 0)));
        assertFalse(ok, "step should revert");
        return _decodeFailure(ret);
    }

    function _decodeFailure(bytes memory ret) internal pure returns (Failure memory f) {
        assertEq(bytes4(ret), StrategyLauncher.StepFailed.selector, "not StepFailed");
        (f.adapter, f.phase, f.step, f.venue, f.mode, f.isAllocate, f.amount, f.reason) = abi.decode(
            _args(ret),
            (address, StrategyLauncher.Phase, uint8, StrategyLauncher.Venue, StrategyLauncher.Mode, bool, uint256, bytes)
        );
    }

    function _assertFailure(
        Failure memory f,
        StrategyLauncher.Phase phase,
        uint8 stepIndex,
        bool isAllocate,
        uint256 amount,
        bytes4 reason
    ) internal view {
        assertEq(f.adapter, strategy, "adapter");
        assertEq(uint8(f.phase), uint8(phase), "phase");
        assertEq(f.step, stepIndex, "step");
        assertEq(uint8(f.venue), uint8(StrategyLauncher.Venue.Clip), "venue");
        assertEq(uint8(f.mode), uint8(StrategyLauncher.Mode.Swap), "mode");
        assertEq(f.isAllocate, isAllocate, "direction");
        assertEq(f.amount, amount, "amount");
        assertEq(bytes4(f.reason), reason, "reason");
    }

    /// @dev Revert data without its 4 byte selector.
    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    function _assertUnchanged(State memory a, State memory b) internal pure {
        assertEq(uint8(b.phase), uint8(a.phase), "phase moved");
        assertEq(b.pilotAllocated, a.pilotAllocated, "pilotAllocated moved");
        assertEq(b.allocateGrantLeft, a.allocateGrantLeft, "allocate grant spent");
        assertEq(b.lastClipBlock, a.lastClipBlock, "interval restarted");
        assertEq(b.liquidityGrantLeft, a.liquidityGrantLeft, "liquidity grant spent");
        assertEq(b.realAssets, a.realAssets, "strategy position moved");
        assertEq(b.booked, a.booked, "vault allocation moved");
        assertEq(b.vaultIdle, a.vaultIdle, "vault idle moved");
    }

    function _state() internal view returns (State memory s) {
        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        s.phase = l.phase;
        s.pilotAllocated = l.pilotAllocated;
        (s.allocateGrantLeft,,, s.lastClipBlock,,,) = clip.allocateGrants(address(launcher), strategy);
        (s.liquidityGrantLeft,,,,,,) = clip.deallocateGrants(address(launcher), cfg.c.liquidityAdapter);
        s.realAssets = IMYTStrategy(strategy).realAssets();
        s.booked = vault.allocation(IMYTStrategy(strategy).adapterId());
        s.vaultIdle = IERC20(WETH).balanceOf(address(vault));
    }

    function _launchToPilot() internal {
        _executeBatch1();
        _runLadder();
    }

    function _executeBatch1() internal {
        _execute(launchScript.batch1(cfg, strategy));
        vault.setForceDeallocatePenalty(strategy, cfg.forceDeallocatePenalty);
    }

    function _runLadder() internal {
        for (uint8 leg = 1; leg <= 4; leg++) {
            assertEq(_step(FAIR), leg, "leg ran");
            _rollInterval();
        }
    }

    /// @dev What the keeper bot does in the ladder: read the next leg, quote its amount, send it.
    function _step(uint256 shortBps) internal returns (uint8 leg) {
        (StrategyLauncher.Phase phase, uint8 next,, uint256 amount, bool needsQuote,) = launcher.nextStep(strategy);
        assertEq(uint8(phase), uint8(StrategyLauncher.Phase.Ladder), "ladder phase");
        assertTrue(needsQuote, "swap legs need a quote");
        bytes memory quote = (next == 1 || next == 3) ? _buy(amount, shortBps) : _sell(amount, shortBps);
        vm.prank(keeper);
        leg = launcher.advance(strategy, quote, 0);
    }

    function _runPilot() internal returns (uint256 clips) {
        while (_state().phase == StrategyLauncher.Phase.Pilot) {
            _goodClip();
            clips++;
            _rollInterval();
        }
    }

    function _goodClip() internal returns (uint256 amount) {
        amount = _clipAmount();
        bytes memory quote = _buy(amount, FAIR);
        vm.prank(keeper);
        launcher.advance(strategy, quote, 0);
    }

    /// @dev The clip the launcher will size next, which is the amount the keeper bot quotes for.
    function _clipAmount() internal view returns (uint256 amount) {
        bool needsQuote;
        (,,, amount, needsQuote,) = launcher.nextStep(strategy);
        assertTrue(needsQuote, "swap clips need a quote");
    }

    /// @dev Blocks only. The clip interval counts blocks, and the oracle staleness check counts seconds.
    function _rollInterval() internal {
        vm.roll(block.number + cfg.pilot.minIntervalBlocks);
    }

    /// @dev WETH in, weETH out, paying `shortBps` under the oracle price.
    function _buy(uint256 wethIn, uint256 shortBps) internal view returns (bytes memory) {
        uint256 weEthOut = wethIn * _oracleScale() / _oraclePrice() * (BPS - shortBps) / BPS;
        return abi.encodeCall(StubSwapper.swap, (WETH, WEETH, wethIn, weEthOut));
    }

    /// @dev weETH in at the oracle price, WETH out, paying `shortBps` under `wethOut`.
    function _sell(uint256 wethOut, uint256 shortBps) internal view returns (bytes memory) {
        uint256 price = _oraclePrice();
        uint256 weEthIn = (wethOut * _oracleScale() + price - 1) / price;
        return abi.encodeCall(StubSwapper.swap, (WEETH, WETH, weEthIn, wethOut * (BPS - shortBps) / BPS));
    }

    function _oraclePrice() internal view returns (uint256) {
        (, int256 answer,,,) = WEETH_ETH_ORACLE.latestRoundData();
        return uint256(answer);
    }

    function _oracleScale() internal view returns (uint256) {
        return 10 ** WEETH_ETH_ORACLE.decimals();
    }

    /// @dev What the probe and clip owners and the allocator admin have already done for this vault.
    function _preDeploy(StrategyLaunchBase.Config memory c) internal {
        probe = new StrategyProbe(c.c.allocator, c.plan.smallLeg, c.plan.largeLeg, c.probeToleranceBps, 0);
        clip = new ClipAllocator(c.c.allocator);

        DeployStrategyLauncherScript launcherScript = new DeployStrategyLauncherScript();
        launcher = launcherScript.deploy(c.c.myt, address(probe), address(clip), c.c.safe, keeper, sentinel);

        probe.setPoker(address(launcher), true);
        probe.transferOwnership(c.c.safe);
        clip.transferOwnership(c.c.safe);

        vm.startPrank(c.c.safe);
        probe.acceptOwnership();
        clip.acceptOwnership();
        launcher.acceptOwnership();
        AlchemistAllocator(c.c.allocator).setOperator(address(probe), true);
        AlchemistAllocator(c.c.allocator).setOperator(address(clip), true);
        vm.stopPrank();
    }

    /// @dev Each call as its own Safe transaction, in order, bubbling the revert with its label.
    function _execute(StrategyLaunchBase.Call[] memory calls) internal {
        for (uint256 i; i < calls.length; i++) {
            vm.prank(cfg.c.safe);
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                emit log_named_string("failed call", calls[i].label);
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
