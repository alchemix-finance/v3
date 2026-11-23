// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IWstETHLike} from "../interfaces/IWstETHLike.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {StrategyLauncher} from "../utils/StrategyLauncher.sol";
import {StrategyProbe} from "../utils/StrategyProbe.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {DeployWstETHEthereumStrategyScript} from "../../script/DeployWstETHEthereumStrategy.s.sol";
import {DeployStrategyLauncherScript} from "../../script/DeployStrategyLauncher.s.sol";
import {StrategyLaunchBase} from "../../script/launch/StrategyLaunchBase.s.sol";
import {LaunchWstETHStrategyScript} from "../../script/launch/LaunchWstETHStrategy.s.sol";

/// @dev Stands in for the 0x allowance holder: pulls `amountIn` of `from` and pays `amountOut` of `to`.
contract WstETHStubSwapper {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

/// @notice Staged rollout of a swap path strategy on a mainnet fork: wstETH on the live ETH MYT. The ladder
///         is skipped, so the launch opens in the allocation phase with small clips. Only the swap is stubbed.
contract StagedRolloutWstETHTest is Test {
    uint256 internal constant FORK_BLOCK = 26_450_000;
    uint256 internal constant BPS = 10_000;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IWstETHLike internal constant WSTETH = IWstETHLike(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    AggregatorV3Interface internal constant STETH_ETH_ORACLE = AggregatorV3Interface(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);

    /// @dev Quote shortfalls against the oracle price. The strategy floor is its slippageBPS (50),
    ///      the grant's loss bound is pilot.maxLossBps (20). THIN sits between them, BELOW_FLOOR under both.
    uint256 internal constant FAIR = 0;
    uint256 internal constant THIN = 35;
    uint256 internal constant BELOW_FLOOR = 100;

    address internal keeper = makeAddr("keeper");
    address internal sentinel = makeAddr("sentinel");

    LaunchWstETHStrategyScript internal launchScript;
    StrategyLaunchBase.Config internal cfg;
    IVaultV2 internal vault;
    StrategyProbe internal probe;
    ClipAllocator internal clip;
    StrategyLauncher internal launcher;
    WstETHStubSwapper internal swapper;
    address internal strategy;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);

        launchScript = new LaunchWstETHStrategyScript();
        StrategyLaunchBase.Config memory c = launchScript.loadConfig();
        vault = IVaultV2(c.c.myt);
        _preDeploy(c);
        c.c.probe = address(probe);
        c.c.clip = address(clip);
        c.c.launcher = address(launcher);
        cfg = c;

        strategy = address(new DeployWstETHEthereumStrategyScript().run());

        swapper = new WstETHStubSwapper();
        deal(WETH, address(swapper), 1_000 ether);
        deal(address(WSTETH), address(swapper), 1_000 ether);
        vm.prank(cfg.c.safe);
        MYTStrategy(strategy).setAllowanceHolder(address(swapper));
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

    function _isAllocationPhase(Step memory s) internal pure returns (bool) {
        return s.phase == StrategyLauncher.Phase.Pilot;
    }

    // ---- the bot ------------------------------------------------------------------

    /// @dev The whole keeper for a swap strategy: wait for the ready block, quote the announced
    ///      amount, then advance. A real bot gets the calldata from the 0x API instead of `_buyQuote`.
    function _sendStep(Step memory s) internal {
        assertTrue(s.needsQuote, "swap clips need a quote");
        if (block.number < s.readyBlock) vm.roll(s.readyBlock);
        bytes memory txData = _buyQuote(s.amount, FAIR);
        vm.prank(keeper);
        assertEq(launcher.advance(strategy, txData, 0), s.index, "ran the announced step");
    }

    /// @dev Send and check steps until the launch leaves `phase`.
    function _runPhase(StrategyLauncher.Phase phase) internal returns (uint256 steps) {
        for (Step memory s = _nextStep(); s.phase == phase; s = _nextStep()) {
            _sendAndCheck(s);
            steps++;
        }
    }

    /// @dev Send and check the next `count` steps.
    function _runSteps(uint256 count) internal {
        for (uint256 i; i < count; i++) {
            Step memory s = _nextStep();
            assertTrue(_isAllocationPhase(s), "nothing left to run");
            _sendAndCheck(s);
        }
    }

    function _sendAndCheck(Step memory s) internal {
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _sendStep(s);
        _checkAllocationClip(s, realBefore);
    }

    // ---- quotes -------------------------------------------------------------------

    /// @dev WETH in, wstETH out, paying `shortBps` under the stETH/ETH oracle price.
    function _buyQuote(uint256 wethIn, uint256 shortBps) internal view returns (bytes memory) {
        uint256 wstEthOut = WSTETH.getWstETHByStETH(wethIn * _oracleScale() / _oraclePrice()) * (BPS - shortBps) / BPS;
        return abi.encodeCall(WstETHStubSwapper.swap, (WETH, address(WSTETH), wethIn, wstEthOut));
    }

    /// @dev wstETH in at the oracle price, WETH out, paying `shortBps` under `wethOut`.
    function _sellQuote(uint256 wethOut, uint256 shortBps) internal view returns (bytes memory) {
        uint256 price = _oraclePrice();
        uint256 stEthIn = (wethOut * _oracleScale() + price - 1) / price;
        uint256 wstEthIn = WSTETH.getWstETHByStETH(stEthIn) + 1;
        return abi.encodeCall(WstETHStubSwapper.swap, (address(WSTETH), WETH, wstEthIn, wethOut * (BPS - shortBps) / BPS));
    }

    function _oraclePrice() internal view returns (uint256) {
        (, int256 answer,,,) = STETH_ETH_ORACLE.latestRoundData();
        return uint256(answer);
    }

    function _oracleScale() internal view returns (uint256) {
        return 10 ** STETH_ETH_ORACLE.decimals();
    }

    // ---- checks per step ------------------------------------------------------------

    /// @dev A clip adds its amount to the position and to the launcher's count, and stays under the clip size.
    function _checkAllocationClip(Step memory s, uint256 realBefore) internal view {
        assertLe(s.amount, cfg.pilot.maxClip, "no larger than one clip");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), realBefore + s.amount, s.amount / 100, "clip landed");
        StrategyLauncher.Launch memory l = launcher.launch(strategy);
        assertEq(l.clipCount, s.index, "clip counted");
        assertLe(l.pilotAllocated, l.pilotTarget, "within the target");
    }

    /// @dev Send `badQuote` for the next clip. It must fail with `reason` inside StepFailed and change nothing.
    function _checkClipFails(bytes memory badQuote, bytes4 reason) internal {
        Step memory s = _nextStep();
        if (block.number < s.readyBlock) vm.roll(s.readyBlock);
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        StrategyLauncher.Report memory before = launcher.report(strategy);

        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(launcher).call(abi.encodeCall(StrategyLauncher.advance, (strategy, badQuote, 0)));
        assertFalse(ok, "clip should revert");
        assertEq(bytes4(ret), StrategyLauncher.StepFailed.selector, "not StepFailed");
        (
            address adapter,
            StrategyLauncher.Phase phase,
            uint8 index,
            StrategyLauncher.Venue venue,
            StrategyLauncher.Mode mode,
            bool isAllocate,
            uint256 amount,
            bytes memory inner
        ) = abi.decode(
            _args(ret), (address, StrategyLauncher.Phase, uint8, StrategyLauncher.Venue, StrategyLauncher.Mode, bool, uint256, bytes)
        );
        assertEq(adapter, strategy, "adapter");
        assertEq(uint8(phase), uint8(StrategyLauncher.Phase.Pilot), "phase");
        assertEq(index, s.index, "clip number");
        assertEq(uint8(venue), uint8(StrategyLauncher.Venue.Clip), "venue");
        assertEq(uint8(mode), uint8(StrategyLauncher.Mode.Swap), "mode");
        assertTrue(isAllocate, "direction");
        assertEq(amount, s.amount, "amount");
        assertEq(bytes4(inner), reason, "reason");

        StrategyLauncher.Report memory afterFail = launcher.report(strategy);
        assertEq(afterFail.launch.pilotAllocated, before.launch.pilotAllocated, "pilotAllocated moved");
        assertEq(afterFail.launch.clipCount, before.launch.clipCount, "clip counted");
        assertEq(afterFail.allocateGrantLeft, before.allocateGrantLeft, "grant spent");
        assertEq(afterFail.readyBlock, before.readyBlock, "interval restarted");
        assertEq(IMYTStrategy(strategy).realAssets(), realBefore, "position moved");
    }

    /// @dev Revert data without its 4 byte selector.
    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    // ---- checks per stage -----------------------------------------------------------

    /// @dev The deployed strategy waits for the Safe.
    function _checkDeployed() internal view {
        assertEq(MYTStrategy(strategy).owner(), cfg.c.safe, "owner");
        assertTrue(MYTStrategy(strategy).killSwitch(), "kill switch");
        assertFalse(vault.isAdapter(strategy), "not an adapter yet");
    }

    /// @dev Batch 1 opened the launch straight in the allocation phase, with a pilot grant and no ladder grant.
    function _checkLaunchOpened() internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Pilot), "ladder skipped");
        assertEq(r.launch.planHash, keccak256(abi.encode(cfg.plan)), "plan hash");
        assertEq(uint8(r.launch.allocMode), uint8(StrategyLauncher.Mode.Swap), "swap in");
        assertEq(uint8(r.launch.deallocMode), uint8(StrategyLauncher.Mode.Swap), "swap out");
        assertEq(r.allocateGrantLeft, cfg.pilot.amount + cfg.pilotHeadroom, "pilot grant");
        assertEq(r.deallocateGrantLeft, 0, "no ladder exit grant");
        assertEq(r.nextLeg, 1, "clip 1 is next");
        assertEq(r.nextAmount, cfg.pilot.maxClip, "one small clip");
        assertTrue(r.needsQuote, "swap clip");
        assertFalse(MYTStrategy(strategy).killSwitch(), "allocation on");
    }

    /// @dev The pilot target landed in small clips, an interval apart, leaving only the headroom.
    function _checkAllocationCompleted(uint256 clips, uint256 startBlock) internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");
        assertEq(clips, cfg.pilot.amount / cfg.pilot.maxClip, "target in clips of maxClip");
        assertEq(r.launch.clipCount, clips, "clip count");
        assertEq(r.launch.pilotAllocated, cfg.pilot.amount, "pilot allocated");
        assertEq(r.allocateGrantLeft, cfg.pilotHeadroom, "only the headroom is left");
        assertApproxEqRel(r.realAssets, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "pilot landed");
        assertApproxEqRel(r.booked, cfg.pilot.amount, uint256(cfg.pilot.maxLossBps) * 1e14, "vault booked it");
        assertEq(block.number - startBlock, (clips - 1) * uint256(cfg.pilot.minIntervalBlocks), "an interval between clips");
        assertFalse(_isAllocationPhase(_nextStep()), "nothing left for the bot");
    }

    /// @dev The swap out works: the Safe sells part of the pilot back to WETH through the allocator.
    function _checkExitBySwap(uint256 wethOut) internal {
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        uint256 idleBefore = IERC20(WETH).balanceOf(address(vault));
        bytes memory txData = _sellQuote(wethOut, FAIR);
        vm.prank(cfg.c.safe);
        AlchemistAllocator(cfg.c.allocator).deallocateWithSwap(strategy, wethOut, txData);
        assertEq(IERC20(WETH).balanceOf(address(vault)) - idleBefore, wethOut, "WETH back in the vault");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), realBefore - wethOut, wethOut / 100, "position reduced");
    }

    /// @dev Batch 2 raised the cap and closed the launcher's grant. Swap strategies get no manual allocation.
    function _checkGraduated(uint256 realBefore) internal view {
        StrategyLauncher.Report memory r = launcher.report(strategy);
        assertEq(uint8(r.launch.phase), uint8(StrategyLauncher.Phase.Graduated), "graduated");
        assertEq(vault.absoluteCap(IMYTStrategy(strategy).adapterId()), cfg.scaleAbsoluteCap, "scaled cap");
        assertEq(r.allocateGrantLeft, 0, "launcher grant closed");
        assertEq(r.realAssets, realBefore, "batch 2 moves nothing");
    }

    // ---- the rollout ----------------------------------------------------------------

    /// @dev Deploy, Safe batch 1, the bot loop with swap calldata, a swap back out, Safe batch 2.
    function test_stagedRollout_endToEnd() public {
        _checkDeployed();

        _executeBatch1();
        _checkLaunchOpened();

        uint256 startBlock = block.number;
        uint256 clips = _runPhase(StrategyLauncher.Phase.Pilot);
        _checkAllocationCompleted(clips, startBlock);

        _checkExitBySwap(cfg.pilot.amount / 4);

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        _execute(launchScript.batch2(cfg, strategy));
        _checkGraduated(realBefore);
    }

    /// @dev Three bad quotes, each rejected at a different layer with nothing changed, each followed
    ///      by the same clip landing with a fair quote and no extra wait.
    function test_stagedRollout_failedClipThenRetry() public {
        _executeBatch1();
        _runSteps(2);

        _checkClipFails(_buyQuote(cfg.pilot.maxClip, BELOW_FLOOR), IMYTStrategy.InvalidAmount.selector);
        _runSteps(1);

        _checkClipFails(_buyQuote(cfg.pilot.maxClip, THIN), ClipAllocator.LossExceedsLimit.selector);
        _runSteps(1);

        _checkClipFails(hex"deadbeef", IMYTStrategy.CounterfeitSettler.selector);
        _runSteps(1);

        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 3, "the other three clips");
        assertEq(uint8(launcher.launch(strategy).phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");
    }

    /// @dev The sentinel shrinks a pilot in flight and later runs a second round, with no Safe call.
    function test_stagedRollout_sentinelAdjustsThePilot() public {
        _executeBatch1();
        _runSteps(2);

        StrategyLauncher.Plan memory plan = cfg.plan;
        plan.pilotTarget = 6 ether;
        vm.prank(sentinel);
        launcher.updatePlan(strategy, plan);
        assertEq(_nextStep().amount, 1 ether, "what is left under the new target");
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 1, "one smaller clip");
        assertEq(uint8(launcher.launch(strategy).phase), uint8(StrategyLauncher.Phase.PilotComplete), "pilot complete");

        vm.prank(sentinel);
        launcher.resetPilot(strategy);
        assertEq(_runPhase(StrategyLauncher.Phase.Pilot), 3, "second round");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), 12 ether, 2e15, "both rounds landed");
    }

    // ---- setup ------------------------------------------------------------------

    function _executeBatch1() internal {
        _execute(launchScript.batch1(cfg, strategy));
        vault.setForceDeallocatePenalty(strategy, cfg.forceDeallocatePenalty);
    }

    /// @dev What the probe and clip owners and the allocator admin have already done for this vault.
    function _preDeploy(StrategyLaunchBase.Config memory c) internal {
        probe = new StrategyProbe(c.c.allocator, 0.1 ether, 1 ether, c.probeToleranceBps, 0);
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
