// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {StrategyLauncher} from "../utils/StrategyLauncher.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {DeployStrategyLauncherScript} from "../../script/DeployStrategyLauncher.s.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @notice Launcher state machine on a local vault with mock strategies. No live RPC.
///         The probe and the clip allocator are deployed here and made allocator operators
///         before the launcher is used.
contract StrategyLauncherTest is Test {
    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal operator = makeAddr("operator");
    address internal depositor = makeAddr("depositor");
    address internal probeBot = makeAddr("probeBot");
    address internal clipBot = makeAddr("clipBot");
    address internal sentinel = makeAddr("sentinel");

    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant SMALL = 1 ether;
    uint256 internal constant LARGE = 10 ether;
    uint256 internal constant PILOT = 20 ether;
    uint16 internal constant MAX_LOSS = 50;

    TestERC20 internal asset;
    MockMYTVault internal vault;
    AlchemistStrategyClassifier internal classifier;
    AlchemistAllocator internal allocator;
    StrategyProbe internal probe;
    ClipAllocator internal clip;
    StrategyLauncher internal launcher;

    function setUp() public {
        asset = new TestERC20(0, 18);
        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(address(asset), admin, curator);
        classifier = new AlchemistStrategyClassifier(admin);
        allocator = new AlchemistAllocator(address(vault), admin, operator, address(classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        bytes memory setAllocator = abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true));
        vault.submit(setAllocator);
        vault.setIsAllocator(address(allocator), true);
        vm.stopPrank();

        vm.prank(admin);
        allocator.setMaxRate(uint256(200e16) / 365 days);

        probe = new StrategyProbe(address(allocator), SMALL, LARGE, 100, 0);
        clip = new ClipAllocator(address(allocator));
        vm.startPrank(admin);
        allocator.setOperator(address(probe), true);
        allocator.setOperator(address(clip), true);
        vm.stopPrank();

        DeployStrategyLauncherScript deployScript = new DeployStrategyLauncherScript();
        launcher = deployScript.deploy(address(vault), address(probe), address(clip), address(this), probeBot, clipBot, sentinel);
        launcher.acceptOwnership();
        probe.setPoker(address(launcher), true);

        asset.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, depositor);
        vm.stopPrank();
    }

    function test_probeLaunch_stopsAtPilotTarget() public {
        MockMYTStrategy strategy = _registerStrategy("Probe strategy");
        _register(strategy, true);

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Ladder));
        vm.prank(clipBot);
        launcher.clip(address(strategy), 1 ether, "");

        _runLadder(strategy);
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.Pilot));
        assertApproxEqAbs(strategy.realAssets(), 0, 1);

        clip.grantAllocate(address(launcher), address(strategy), PILOT, PILOT, 0, address(0), 0, MAX_LOSS);

        vm.prank(clipBot);
        launcher.clip(address(strategy), 12 ether, "");
        vm.prank(clipBot);
        launcher.clip(address(strategy), 8 ether, "");

        (StrategyLauncher.Phase done,,, uint256 room,,) = launcher.nextStep(address(strategy));
        assertEq(room, 0);
        assertEq(uint8(done), uint8(StrategyLauncher.Phase.PilotComplete));
        assertApproxEqAbs(strategy.realAssets(), PILOT, 1);

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.PilotComplete));
        vm.prank(clipBot);
        launcher.clip(address(strategy), 1, "");

        launcher.graduate(address(strategy));
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.Graduated));
    }

    function test_clipLadder_runsWhenProbeCannot() public {
        MockMYTStrategy strategy = _registerStrategy("Clip ladder strategy");
        _register(strategy, false);

        uint256 allocateBudget = PILOT + SMALL + LARGE;
        clip.grantAllocate(address(launcher), address(strategy), allocateBudget, PILOT, 0, address(0), 0, MAX_LOSS);
        clip.grantDeallocate(address(launcher), address(strategy), SMALL + LARGE, LARGE, 0, address(0), 0, MAX_LOSS);

        _runLadder(strategy);
        assertApproxEqAbs(strategy.realAssets(), 0, 1);

        vm.prank(clipBot);
        launcher.clip(address(strategy), PILOT, "");
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.PilotComplete));
        assertApproxEqAbs(strategy.realAssets(), PILOT, 1);
        (uint256 left,,,,,,) = clip.allocateGrants(address(launcher), address(strategy));
        assertEq(left, 0);
    }

    function test_swapLeg_requiresQuote() public {
        MockMYTStrategy strategy = _registerStrategy("Swap strategy");
        launcher.registerLaunch(address(strategy), _plan(false, StrategyLauncher.Mode.Swap, StrategyLauncher.Mode.Swap));

        vm.expectRevert(StrategyLauncher.QuoteRequired.selector);
        vm.prank(probeBot);
        launcher.step(address(strategy), "", 0);
    }

    /// @dev A venue revert comes back as StepFailed with the venue's own revert data inside.
    function test_probeFailure_reportsTheLegAndReason() public {
        MockMYTStrategy strategy = _registerStrategy("Paused probe strategy");
        _register(strategy, true);
        probe.setPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyLauncher.StepFailed.selector,
                address(strategy),
                StrategyLauncher.Phase.Ladder,
                uint8(1),
                StrategyLauncher.Venue.Probe,
                StrategyLauncher.Mode.Direct,
                true,
                SMALL,
                abi.encodeWithSelector(StrategyProbe.ProbePaused.selector)
            )
        );
        vm.prank(probeBot);
        launcher.step(address(strategy), "", 0);
    }

    function test_clipFailure_reportsTheClipAndReason() public {
        MockMYTStrategy strategy = _registerStrategy("No grant strategy");
        _register(strategy, true);
        vm.prank(sentinel);
        launcher.setLeg(address(strategy), 5, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyLauncher.StepFailed.selector,
                address(strategy),
                StrategyLauncher.Phase.Pilot,
                uint8(1),
                StrategyLauncher.Venue.Clip,
                StrategyLauncher.Mode.Direct,
                true,
                5 ether,
                abi.encodeWithSelector(ClipAllocator.NoGrant.selector, address(launcher), address(strategy), true)
            )
        );
        vm.prank(clipBot);
        launcher.clip(address(strategy), 5 ether, "");
    }

    function test_abort_blocksTheLadder() public {
        MockMYTStrategy strategy = _registerStrategy("Aborted strategy");
        _register(strategy, true);
        launcher.abort(address(strategy));

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Aborted));
        vm.prank(probeBot);
        launcher.step(address(strategy), "", 0);
    }

    function test_sentinel_reopensAnAbortedLaunch() public {
        MockMYTStrategy strategy = _registerStrategy("Reopened strategy");
        _register(strategy, false);
        vm.prank(sentinel);
        launcher.abort(address(strategy));

        StrategyLauncher.Plan memory plan = _plan(false, StrategyLauncher.Mode.Direct, StrategyLauncher.Mode.Direct);
        plan.pilotTarget = 5 ether;
        vm.prank(sentinel);
        launcher.registerLaunch(address(strategy), plan);

        StrategyLauncher.Launch memory l = launcher.launch(address(strategy));
        assertEq(l.attempt, 2);
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.Ladder));
        assertEq(l.pilotTarget, 5 ether);
        assertEq(l.planHash, keccak256(abi.encode(plan)));
        assertEq(launcher.launchCount(), 1, "listed once");
    }

    function test_sentinel_editsThePilot() public {
        MockMYTStrategy strategy = _registerStrategy("Edited strategy");
        _register(strategy, false);
        clip.grantAllocate(address(launcher), address(strategy), 100 ether, PILOT, 0, address(0), 0, MAX_LOSS);
        vm.startPrank(sentinel);
        launcher.setLeg(address(strategy), 5, 0);
        vm.stopPrank();

        vm.prank(clipBot);
        launcher.clip(address(strategy), 10 ether, "");

        StrategyLauncher.Plan memory plan = _plan(false, StrategyLauncher.Mode.Direct, StrategyLauncher.Mode.Direct);
        plan.pilotTarget = 10 ether;
        vm.prank(sentinel);
        launcher.updatePlan(address(strategy), plan);
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.PilotComplete), "target lowered to what landed");

        plan.pilotTarget = 15 ether;
        vm.prank(sentinel);
        launcher.updatePlan(address(strategy), plan);
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.Pilot), "target raised reopens");
        vm.prank(clipBot);
        launcher.clip(address(strategy), 5 ether, "");
        assertEq(uint8(_phase(strategy)), uint8(StrategyLauncher.Phase.PilotComplete));

        vm.prank(sentinel);
        launcher.resetPilot(address(strategy));
        StrategyLauncher.Launch memory l = launcher.launch(address(strategy));
        assertEq(uint8(l.phase), uint8(StrategyLauncher.Phase.Pilot));
        assertEq(l.pilotAllocated, 0);
        assertEq(l.clipCount, 0);
        assertApproxEqAbs(strategy.realAssets(), 15 ether, 1, "clips stay in the strategy");
    }

    function test_setLeg_rejectsProbeLegs() public {
        MockMYTStrategy strategy = _registerStrategy("Probe legs strategy");
        _register(strategy, true);

        vm.startPrank(sentinel);
        vm.expectRevert(StrategyLauncher.ProbeOwnsLadder.selector);
        launcher.setLeg(address(strategy), 3, 0);
        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.InvalidLeg.selector, uint8(6)));
        launcher.setLeg(address(strategy), 6, 0);
        vm.stopPrank();
    }

    function test_stranger_cannotRunOrManage() public {
        MockMYTStrategy strategy = _registerStrategy("Guarded strategy");
        _register(strategy, true);
        StrategyLauncher.Plan memory plan = _plan(true, StrategyLauncher.Mode.Direct, StrategyLauncher.Mode.Direct);
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        vm.expectRevert(StrategyLauncher.NotProbeKeeper.selector);
        launcher.step(address(strategy), "", 0);
        vm.expectRevert(StrategyLauncher.NotClipKeeper.selector);
        launcher.clip(address(strategy), 1, "");
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.registerLaunch(address(strategy), plan);
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.updatePlan(address(strategy), plan);
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.setLeg(address(strategy), 5, 0);
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.resetPilot(address(strategy));
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.abort(address(strategy));
        vm.expectRevert(StrategyLauncher.NotSentinel.selector);
        launcher.graduate(address(strategy));
        vm.expectRevert(StrategyLauncher.NotKeeper.selector);
        launcher.pause(address(vault));
        vm.expectRevert(StrategyLauncher.NotOwner.selector);
        launcher.setSentinel(stranger, true);
        vm.stopPrank();
    }

    function _runLadder(MockMYTStrategy strategy) internal {
        for (uint8 leg = 1; leg <= 4; leg++) {
            vm.prank(probeBot);
            assertEq(launcher.step(address(strategy), "", 0), leg);
        }
    }

    function _phase(MockMYTStrategy strategy) internal view returns (StrategyLauncher.Phase) {
        return launcher.launch(address(strategy)).phase;
    }

    function _register(MockMYTStrategy strategy, bool useProbe) internal {
        StrategyLauncher.Mode mode = StrategyLauncher.Mode.Direct;
        launcher.registerLaunch(address(strategy), _plan(useProbe, mode, mode));
    }

    function _plan(bool useProbe, StrategyLauncher.Mode allocMode, StrategyLauncher.Mode deallocMode)
        internal
        view
        returns (StrategyLauncher.Plan memory)
    {
        return StrategyLauncher.Plan({
            myt: address(vault),
            useProbe: useProbe,
            allocMode: allocMode,
            deallocMode: deallocMode,
            smallLeg: uint128(SMALL),
            largeLeg: uint128(LARGE),
            exitBufferBps: 0,
            pilotTarget: PILOT
        });
    }

    function _registerStrategy(string memory name) internal returns (MockMYTStrategy strategy) {
        MockYieldToken yieldToken = new MockYieldToken(address(asset));
        strategy = new MockMYTStrategy(
            address(vault),
            address(yieldToken),
            IMYTStrategy.StrategyParams({
                owner: admin,
                name: name,
                protocol: "Mock",
                riskClass: IMYTStrategy.RiskClass.LOW,
                cap: 1_000 ether,
                globalCap: 1e18,
                estimatedYield: 100e18,
                additionalIncentives: false,
                slippageBPS: 1
            })
        );
        uint256 strategyId = uint256(strategy.adapterId());
        vm.prank(admin);
        classifier.assignStrategyRiskLevel(strategyId, uint8(IMYTStrategy.RiskClass.LOW));

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.addAdapter, address(strategy)));
        vault.addAdapter(address(strategy));
        bytes memory idData = strategy.getIdData();
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 1_000 ether)));
        vault.increaseAbsoluteCap(idData, 1_000 ether);
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();
    }

    function _submitAndExecute(bytes memory data) internal {
        vault.submit(data);
        vm.warp(block.timestamp + vault.timelock(bytes4(data)));
    }
}
