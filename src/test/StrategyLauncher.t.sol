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
        launcher = deployScript.deploy(address(vault), address(probe), address(clip), address(this), probeBot, clipBot);
        launcher.acceptOwnership();
        probe.setPoker(address(launcher), true);

        asset.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, depositor);
        vm.stopPrank();
    }

    function test_probeLaunch_stopsAtPilotMax() public {
        MockMYTStrategy strategy = _registerStrategy("Probe strategy");
        _register(strategy, true);

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Ladder));
        vm.prank(clipBot);
        launcher.clip(address(strategy), 1 ether, "");

        for (uint8 leg = 1; leg <= 4; leg++) {
            vm.prank(probeBot);
            uint8 ran = launcher.step(address(strategy), "", 0);
            assertEq(ran, leg);
        }
        (StrategyLauncher.Phase phase,,,,) = launcher.nextStep(address(strategy));
        assertEq(uint8(phase), uint8(StrategyLauncher.Phase.Pilot));
        assertApproxEqAbs(strategy.realAssets(), 0, 1);

        clip.grantAllocate(address(launcher), address(strategy), PILOT, PILOT, 0, address(0), 0, MAX_LOSS);

        vm.prank(clipBot);
        launcher.clip(address(strategy), 12 ether, "");
        vm.prank(clipBot);
        launcher.clip(address(strategy), 8 ether, "");

        (StrategyLauncher.Phase done,,, uint256 room,) = launcher.nextStep(address(strategy));
        assertEq(room, 0);
        assertEq(uint8(done), uint8(StrategyLauncher.Phase.PilotComplete));
        assertApproxEqAbs(strategy.realAssets(), PILOT, 1);

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.PilotComplete));
        vm.prank(clipBot);
        launcher.clip(address(strategy), 1, "");

        launcher.graduate(address(strategy));
        (StrategyLauncher.Phase graduated,,,,) = launcher.nextStep(address(strategy));
        assertEq(uint8(graduated), uint8(StrategyLauncher.Phase.Graduated));
    }

    function test_clipLadder_runsWhenProbeCannot() public {
        MockMYTStrategy strategy = _registerStrategy("Clip ladder strategy");
        _register(strategy, false);

        uint256 allocateBudget = PILOT + SMALL + LARGE;
        clip.grantAllocate(address(launcher), address(strategy), allocateBudget, PILOT, 0, address(0), 0, MAX_LOSS);
        clip.grantDeallocate(address(launcher), address(strategy), SMALL + LARGE, LARGE, 0, address(0), 0, MAX_LOSS);

        for (uint8 leg = 1; leg <= 4; leg++) {
            vm.prank(probeBot);
            launcher.step(address(strategy), "", 0);
        }
        assertApproxEqAbs(strategy.realAssets(), 0, 1);

        vm.prank(clipBot);
        launcher.clip(address(strategy), PILOT, "");
        (StrategyLauncher.Phase done,,,,) = launcher.nextStep(address(strategy));
        assertEq(uint8(done), uint8(StrategyLauncher.Phase.PilotComplete));
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

    function test_abort_blocksTheLadder() public {
        MockMYTStrategy strategy = _registerStrategy("Aborted strategy");
        _register(strategy, true);
        launcher.abort(address(strategy));

        vm.expectRevert(abi.encodeWithSelector(StrategyLauncher.WrongPhase.selector, StrategyLauncher.Phase.Aborted));
        vm.prank(probeBot);
        launcher.step(address(strategy), "", 0);
    }

    function test_stranger_cannotStepOrClip() public {
        MockMYTStrategy strategy = _registerStrategy("Guarded strategy");
        _register(strategy, true);

        vm.expectRevert(StrategyLauncher.NotProbeKeeper.selector);
        launcher.step(address(strategy), "", 0);
        vm.expectRevert(StrategyLauncher.NotClipKeeper.selector);
        launcher.clip(address(strategy), 1, "");
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
            pilotMax: PILOT
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
