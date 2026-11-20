// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {StrategyLauncher} from "../utils/StrategyLauncher.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {DeployYvWETHStrategyScript} from "../../script/DeployYvWETHStrategy.s.sol";
import {DeployStrategyLauncherScript} from "../../script/DeployStrategyLauncher.s.sol";
import {StrategyLaunchBase} from "../../script/launch/StrategyLaunchBase.s.sol";
import {LaunchYvWETHStrategyScript} from "../../script/launch/LaunchYvWETHStrategy.s.sol";

/// @notice Staged rollout of a direct path strategy, end to end on a mainnet fork: Yearn WETH-1, an
///         ERC4626Strategy, on the live ETH MYT. Nothing is stubbed. `_sendStep` is the whole bot.
contract StagedRolloutYvWETHTest is Test {
    uint256 internal constant FORK_BLOCK = 26_450_000;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal keeper = makeAddr("keeper");
    address internal sentinel = makeAddr("sentinel");

    LaunchYvWETHStrategyScript internal launchScript;
    StrategyLaunchBase.Config internal cfg;
    IVaultV2 internal vault;
    StrategyProbe internal probe;
    ClipAllocator internal clip;
    StrategyLauncher internal launcher;
    address internal strategy;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);

        launchScript = new LaunchYvWETHStrategyScript();
        StrategyLaunchBase.Config memory c = launchScript.loadConfig();
        vault = IVaultV2(c.c.myt);
        _preDeploy(c);
        c.c.probe = address(probe);
        c.c.clip = address(clip);
        c.c.launcher = address(launcher);
        cfg = c;

        strategy = new DeployYvWETHStrategyScript().run();
    }

    // ---- a step, as the bot sees it ---------------------------------------------------

    /// @dev What `nextStep` announces, read once per keeper call.
    struct Step {
        StrategyLauncher.Phase phase;
        uint8 index;
        uint256 amount;
        bool needsQuote;
        uint64 readyBlock;
    }

    function _nextStep() internal view returns (Step memory s) {
        (s.phase, s.index,, s.amount, s.needsQuote, s.readyBlock) = launcher.nextStep(strategy);
    }

    function _isProbePhase(Step memory s) internal pure returns (bool) {
        return s.phase == StrategyLauncher.Phase.Ladder;
    }

    function _isAllocationPhase(Step memory s) internal pure returns (bool) {
        return s.phase == StrategyLauncher.Phase.Pilot;
    }

    /// @dev Probe legs 2 and 4 take out what legs 1 and 3 put in.
    function _isExitLeg(Step memory s) internal pure returns (bool) {
        return _isProbePhase(s) && (s.index == 2 || s.index == 4);
    }

    // ---- the bot ------------------------------------------------------------------

    /// @dev The whole keeper for a direct strategy: wait for the ready block, then advance.
    function _sendStep(Step memory s) internal {
        assertFalse(s.needsQuote, "direct paths never need a quote");
        if (block.number < s.readyBlock) vm.roll(s.readyBlock);
        vm.prank(keeper);
        assertEq(launcher.advance(strategy, "", 0), s.index, "ran the announced step");
    }

    /// @dev Send and check steps until the launch leaves `phase`.
    function _runPhase(StrategyLauncher.Phase phase) internal returns (uint256 steps) {
        for (Step memory s = _nextStep(); s.phase == phase; s = _nextStep()) {
            _sendAndCheck(s);
            steps++;
        }
    }

    /// @dev Send and check the next `count` steps, whatever phase they are in.
    function _runSteps(uint256 count) internal {
        for (uint256 i; i < count; i++) {
            Step memory s = _nextStep();
            assertTrue(_isProbePhase(s) || _isAllocationPhase(s), "nothing left to run");
            _sendAndCheck(s);
        }
    }

    function _sendAndCheck(Step memory s) internal {
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _sendStep(s);
        _checkStep(s, realBefore);
    }

    // ---- checks per step ------------------------------------------------------------

    function _checkStep(Step memory s, uint256 realBefore) internal view {
        if (_isProbePhase(s)) _checkProbeLeg(s, realBefore);
        else _checkAllocationClip(s, realBefore);
    }

    /// @dev Legs 1 and 3 put the leg amount in. Legs 2 and 4 take it back out.
    function _checkProbeLeg(Step memory s, uint256 realBefore) internal view {
        uint256 expected = _isExitLeg(s) ? realBefore - s.amount : realBefore + s.amount;
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), expected, s.amount / 100, "probe leg moved the position");
        assertEq(launcher.launch(strategy).pilotAllocated, 0, "no allocation during the probe");
    }

    /// @dev A clip adds its amount to the position and to the launcher's count.
    function _checkAllocationClip(Step memory s, uint256 realBefore) internal view {
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), realBefore + s.amount, s.amount / 100, "clip landed");
        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(l.clipCount, s.index, "clip counted");
        assertLe(l.pilotAllocated, l.pilotTarget, "within the target");
    }

    // ---- checks per stage -----------------------------------------------------------

    /// @dev The deployed strategy waits for the Safe.
    function _checkDeployed() internal view {
        assertEq(MYTStrategy(strategy).owner(), cfg.c.safe, "owner");
        assertTrue(MYTStrategy(strategy).killSwitch(), "kill switch");
        assertFalse(vault.isAdapter(strategy), "not an adapter yet");
    }

    /// @dev Batch 1 opened the launch in the probe phase with the planned grant.
    function _checkLaunchOpened() internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Ladder), "ladder open");
        assertEq(r.launch.planHash, keccak256(abi.encode(cfg.plan)), "plan hash");
        assertEq(r.allocateGrantLeft, cfg.pilot.amount + cfg.pilotHeadroom, "pilot grant");
        assertEq(r.nextLeg, 1, "leg 1 is next");
        assertEq(r.nextAmount, cfg.plan.smallLeg, "small leg");
    }

    /// @dev The probe finished, handed back the idle it raised, and no clip ran.
    function _checkProbeCompleted(uint256 liquidityBefore) internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Pilot), "pilot open");
        assertTrue(r.probeLadderCompleted, "probe ladder completed");
        assertEq(r.launch.pilotAllocated, 0, "no clip ran during the ladder");
        assertApproxEqAbs(
            IMYTStrategy(cfg.c.liquidityAdapter).realAssets(), liquidityBefore, 1e12, "the probe returned what it raised"
        );
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "no idle left behind");
    }

    /// @dev The pilot target landed in four clips, an interval apart, leaving only the headroom.
    function _checkAllocationCompleted(uint256 startBlock) internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");
        assertEq(r.launch.clipCount, 4, "clip count");
        assertEq(r.launch.pilotAllocated, cfg.pilot.amount, "pilot allocated");
        assertEq(r.allocateGrantLeft, cfg.pilotHeadroom, "only the headroom is left");
        assertApproxEqRel(r.realAssets, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "pilot landed");
        assertApproxEqRel(r.booked, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "vault booked it");
        assertEq(block.number - startBlock, 3 * uint256(cfg.pilot.minIntervalBlocks), "three intervals");
        Step memory s = _nextStep();
        assertFalse(_isProbePhase(s) || _isAllocationPhase(s), "nothing left for the bot");
    }

    /// @dev Batch 2 raised the cap, closed the launcher's grant, and allocated the larger amount.
    function _checkGraduated() internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Graduated), "graduated");
        assertEq(vault.absoluteCap(IMYTStrategy(strategy).adapterId()), cfg.scaleAbsoluteCap, "scaled cap");
        assertEq(r.allocateGrantLeft, 0, "launcher grant closed");
        assertApproxEqRel(r.realAssets, cfg.pilot.amount + cfg.scaleManualAllocate, 1e15, "manual allocation landed");
    }

    // ---- the rollout ----------------------------------------------------------------

    /// @dev Deploy, Safe batch 1, the bot loop, Safe batch 2. The Safe signs twice and the bot does the rest.
    function test_stagedRollout_endToEnd() public {
        _checkDeployed();

        _executeBatch1();
        _checkLaunchOpened();

        uint256 liquidityBefore = IMYTStrategy(cfg.c.liquidityAdapter).realAssets();
        assertEq(_runPhase(StrategyLauncher.Phase.Ladder), 4, "four probe legs");
        _checkProbeCompleted(liquidityBefore);

        uint256 startBlock = block.number;
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 4, "four allocation clips");
        _checkAllocationCompleted(startBlock);

        _execute(launchScript.batch2(cfg, strategy));
        _checkGraduated();
    }

    /// @dev A stopped venue fails the step with the leg or clip named, changes nothing, and the same
    ///      loop finishes once the Safe lifts the pause. Once in the probe phase, once in allocation.
    function test_stagedRollout_failedStepThenRetry() public {
        _executeBatch1();
        _runSteps(2);

        vm.prank(keeper);
        launcher.pause(cfg.c.myt);
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _expectStepFailed(
            StrategyLauncher.Phase.Ladder, 3, StrategyLauncher.Venue.Probe, cfg.plan.largeLeg, StrategyProbe.ProbePaused.selector
        );
        vm.prank(keeper);
        launcher.advance(strategy, "", 0);
        assertEq(_nextStep().index, 3, "still leg 3");
        assertEq(IMYTStrategy(strategy).realAssets(), realBefore, "nothing moved");

        _unpause();
        assertEq(_runPhase(StrategyLauncher.Phase.Ladder), 2, "legs 3 and 4");
        _runSteps(1);

        vm.prank(keeper);
        launcher.pause(cfg.c.myt);
        vm.roll(_nextStep().readyBlock);
        _expectStepFailed(
            StrategyLauncher.Phase.Pilot, 2, StrategyLauncher.Venue.Clip, cfg.pilot.maxClip, ClipAllocator.MoverPaused.selector
        );
        vm.prank(keeper);
        launcher.advance(strategy, "", 0);
        assertEq(launcher.launch(strategy).pilotAllocated, cfg.pilot.maxClip, "one clip counted");

        _unpause();
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 3, "the other three clips");
        assertEq(uint8(launcher.launch(strategy).phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");
    }

    /// @dev The sentinel shrinks a pilot in flight and later runs a second round, with no Safe call.
    function test_stagedRollout_sentinelAdjustsThePilot() public {
        _executeBatch1();
        assertEq(_runPhase(StrategyLauncher.Phase.Ladder), 4, "four probe legs");
        _runSteps(1);

        StrategyLauncher.Plan memory plan = cfg.plan;
        plan.pilotTarget = 15 ether;
        vm.prank(sentinel);
        launcher.updatePlan(strategy, plan);
        assertEq(_nextStep().amount, 5 ether, "what is left under the new target");
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 1, "one smaller clip");
        assertEq(uint8(launcher.launch(strategy).phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");

        vm.prank(sentinel);
        launcher.resetPilot(strategy);
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 2, "second round");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), 30 ether, 1e15, "both rounds landed");
    }

    // ---- helpers ------------------------------------------------------------------

    function _expectStepFailed(
        StrategyLauncher.Phase phase,
        uint8 index,
        StrategyLauncher.Venue venue,
        uint256 amount,
        bytes4 reason
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyLauncher.StepFailed.selector,
                strategy,
                phase,
                index,
                venue,
                StrategyLauncher.Mode.Direct,
                true,
                amount,
                abi.encodeWithSelector(reason)
            )
        );
    }

    function _unpause() internal {
        vm.startPrank(cfg.c.safe);
        probe.setPaused(false);
        clip.setPaused(false);
        vm.stopPrank();
    }

    function _executeBatch1() internal {
        _execute(launchScript.batch1(cfg, strategy));
        vault.setForceDeallocatePenalty(strategy, cfg.forceDeallocatePenalty);
    }

    /// @dev What the probe and clip owners and the allocator admin have already done for this vault.
    function _preDeploy(StrategyLaunchBase.Config memory c) internal {
        probe = new StrategyProbe(c.c.allocator, c.plan.smallLeg, c.plan.largeLeg, c.probeToleranceBps, c.plan.exitBufferBps);
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
