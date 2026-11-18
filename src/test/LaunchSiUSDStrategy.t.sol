// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {StrategyLauncher} from "../utils/StrategyLauncher.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {DeploySiUSDStrategiesScript} from "../../script/DeploySiUSDStrategies.s.sol";
import {DeployStrategyLauncherScript} from "../../script/DeployStrategyLauncher.s.sol";
import {StrategyLaunchBase} from "../../script/launch/StrategyLaunchBase.s.sol";
import {LaunchSiUSDStrategyScript} from "../../script/launch/LaunchSiUSDStrategy.s.sol";

/// @notice Replays the SiUSD launch JSON on a mainnet fork against the live USDC MYT.
///         Pre-deploy gives the vault a probe, a clip allocator, and the launcher. The real
///         deploy script deploys a fresh SiUSD, the Safe executes batch 1, then the probe
///         ladder and the pilot clips run through the launcher.
contract LaunchSiUSDStrategyTest is Test {
    uint256 internal constant FORK_BLOCK = 26_437_000;

    address internal probeBot = makeAddr("probeBot");
    address internal clipBot = makeAddr("clipBot");

    LaunchSiUSDStrategyScript internal launchScript;
    StrategyLaunchBase.Config internal cfg;
    IVaultV2 internal vault;
    StrategyProbe internal probe;
    ClipAllocator internal clip;
    StrategyLauncher internal launcher;
    address internal strategy;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);

        launchScript = new LaunchSiUSDStrategyScript();
        StrategyLaunchBase.Config memory c = launchScript.loadConfig();
        vault = IVaultV2(c.c.myt);
        _preDeploy(c);
        c.c.probe = address(probe);
        c.c.clip = address(clip);
        c.c.launcher = address(launcher);
        cfg = c;

        DeploySiUSDStrategiesScript deployScript = new DeploySiUSDStrategiesScript();
        vm.deal(deployScript.newOwner(), 1 ether);
        strategy = deployScript.run();
    }

    function test_deployedStrategy_waitsForTheSafe() public view {
        assertEq(MYTStrategy(strategy).owner(), cfg.c.safe, "owner");
        assertTrue(MYTStrategy(strategy).killSwitch(), "kill switch");
        assertFalse(vault.isAdapter(strategy), "not registered before batch 1");
    }

    function test_batch1_configuresTheLaunch() public {
        _executeBatch1();

        bytes32 id = IMYTStrategy(strategy).adapterId();
        assertTrue(vault.isAdapter(strategy), "adapter");
        assertEq(AlchemistCurator(cfg.c.curator).adapterToMYT(strategy), cfg.c.myt, "curator mapping");
        assertEq(vault.absoluteCap(id), cfg.absoluteCap, "absolute cap");
        assertEq(vault.relativeCap(id), cfg.relativeCap, "relative cap");
        assertEq(vault.forceDeallocatePenalty(strategy), cfg.forceDeallocatePenalty, "penalty");
        assertEq(AlchemistStrategyClassifier(cfg.c.classifier).getStrategyRiskLevel(uint256(id)), cfg.riskClass, "risk");
        assertFalse(MYTStrategy(strategy).killSwitch(), "kill switch");

        (uint256 allocateBudget,,,,,,) = clip.allocateGrants(address(launcher), strategy);
        assertEq(allocateBudget, cfg.pilot.amount, "pilot grant");
        (uint256 liquidityBudget,,,,,,) = clip.deallocateGrants(address(launcher), cfg.c.liquidityAdapter);
        assertEq(liquidityBudget, cfg.liquidity.amount, "liquidity grant");

        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.Ladder), "phase");
        assertEq(l.planHash, keccak256(abi.encode(cfg.plan)), "plan hash");
        assertEq(l.pilotMax, cfg.pilot.amount, "pilot max");
    }

    function test_phase1_probeLadderThenPilot() public {
        _executeBatch1();

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Ladder));
        vm.prank(clipBot);
        launcher.clip(strategy, cfg.pilot.maxClip, "");

        _runLadder();
        uint256 dust = uint256(cfg.plan.smallLeg) * cfg.probeToleranceBps / 10_000;
        assertLe(IMYTStrategy(strategy).realAssets(), dust, "ladder leaves dust only");
        assertTrue(probe.ladderCompleted(strategy), "probe lock");

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        uint256 clips = _runPilot();
        assertEq(clips, (cfg.pilot.amount + cfg.pilot.maxClip - 1) / cfg.pilot.maxClip, "clip count");

        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.PilotComplete), "phase");
        assertEq(l.pilotAllocated, cfg.pilot.amount, "pilot allocated");

        // siUSD accrues while blocks roll between clips, so the position can sit just above the pilot.
        uint256 landed = IMYTStrategy(strategy).realAssets() - realBefore;
        assertApproxEqRel(landed, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "pilot landed");
        (uint256 left,,,,,,) = clip.allocateGrants(address(launcher), strategy);
        assertEq(left, 0, "pilot grant spent");

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.PilotComplete));
        vm.prank(clipBot);
        launcher.clip(strategy, 1, "");
    }

    function test_batch2_scalesAndGraduates() public {
        _executeBatch1();
        _runLadder();
        _runPilot();

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _execute(launchScript.batch2(cfg, strategy));

        bytes32 id = IMYTStrategy(strategy).adapterId();
        assertEq(vault.absoluteCap(id), cfg.scaleAbsoluteCap, "scaled cap");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets() - realBefore, cfg.scaleManualAllocate, 1e16, "manual allocation");
        assertEq(uint8(launcher.launch(strategy).phase), uint8(StrategyLauncher.Phase.Graduated), "graduated");
    }

    /// @dev What the probe and clip owners and the allocator admin have already done for this vault.
    function _preDeploy(StrategyLaunchBase.Config memory c) internal {
        StrategyLaunchBase.Config memory loaded = c;
        probe = new StrategyProbe(
            loaded.c.allocator, loaded.plan.smallLeg, loaded.plan.largeLeg, loaded.probeToleranceBps, loaded.plan.exitBufferBps
        );
        clip = new ClipAllocator(loaded.c.allocator);

        DeployStrategyLauncherScript launcherScript = new DeployStrategyLauncherScript();
        launcher = launcherScript.deploy(loaded.c.myt, address(probe), address(clip), loaded.c.safe, probeBot, clipBot);

        probe.setPoker(address(launcher), true);
        probe.transferOwnership(loaded.c.safe);
        clip.transferOwnership(loaded.c.safe);

        vm.startPrank(loaded.c.safe);
        probe.acceptOwnership();
        clip.acceptOwnership();
        launcher.acceptOwnership();
        AlchemistAllocator(loaded.c.allocator).setOperator(address(probe), true);
        AlchemistAllocator(loaded.c.allocator).setOperator(address(clip), true);
        vm.stopPrank();
    }

    function _executeBatch1() internal {
        _execute(launchScript.batch1(cfg, strategy));
        vault.setForceDeallocatePenalty(strategy, cfg.forceDeallocatePenalty);
    }

    function _runLadder() internal {
        for (uint8 leg = 1; leg <= 4; leg++) {
            (StrategyLauncher.Phase phase, uint8 next,,, bool needsQuote) = launcher.nextStep(strategy);
            assertEq(uint8(phase), uint8(StrategyLauncher.Phase.Ladder), "ladder phase");
            assertEq(next, leg, "next leg");
            assertFalse(needsQuote, "direct legs need no quote");
            vm.prank(probeBot);
            assertEq(launcher.step(strategy, "", 0), leg, "leg ran");
        }
    }

    function _runPilot() internal returns (uint256 clips) {
        while (true) {
            (StrategyLauncher.Phase phase,,, uint256 room,) = launcher.nextStep(strategy);
            if (phase != StrategyLauncher.Phase.Pilot) break;
            uint256 amount = room < cfg.pilot.maxClip ? room : cfg.pilot.maxClip;
            vm.prank(clipBot);
            launcher.clip(strategy, amount, "");
            clips++;
            vm.roll(block.number + cfg.pilot.minIntervalBlocks);
            vm.warp(block.timestamp + uint256(cfg.pilot.minIntervalBlocks) * 12);
        }
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
