// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Views and calls the launcher makes. Inline so this file compiles on its own.
interface IStrategyProbeLite {
    function runNextLeg(address adapter) external returns (uint8 leg, uint256 residual);
    function setPaused(bool p) external;
    function paused() external view returns (bool);
    function ladderCompleted(address adapter) external view returns (bool);
    function nextLeg(address adapter) external view returns (uint8);
    function SMALL_LEG() external view returns (uint256);
    function LARGE_LEG() external view returns (uint256);
    function exitBufferBps(address adapter) external view returns (uint256);
    function openLadders(address adapter)
        external
        view
        returns (
            uint8 nextLeg,
            uint256 heldInStrategy,
            uint256 idleRaised,
            uint256 bookedAtOpen,
            uint256 realAssetsAtOpen,
            uint64 openedAt,
            address openedBy
        );
}

interface IClipAllocatorLite {
    function allocateClip(address adapter, uint256 assets) external;
    function allocateClipWithSwap(address adapter, uint256 assets, bytes calldata txData) external;
    function deallocateClip(address adapter, uint256 assets) external;
    function deallocateClipWithSwap(address adapter, uint256 assets, bytes calldata txData) external;
    function deallocateClipWithUnwrapAndSwap(address adapter, uint256 assets, bytes calldata txData, uint256 minIntermediateOut)
        external;
    function setPaused(bool p) external;
    function paused() external view returns (bool);
    function allocateGrants(address bot, address adapter)
        external
        view
        returns (uint256 remaining, uint256 maxClip, uint32 minIntervalBlocks, uint64 lastClipBlock, address, uint256, uint16);
    function deallocateGrants(address bot, address adapter)
        external
        view
        returns (uint256 remaining, uint256 maxClip, uint32 minIntervalBlocks, uint64 lastClipBlock, address, uint256, uint16);
}

interface IMYTStrategyLite {
    function realAssets() external view returns (uint256);
    function adapterId() external view returns (bytes32);
}

interface IVaultLite {
    function allocation(bytes32 id) external view returns (uint256);
}

/// @title StrategyLauncher
/// @notice Runs and reports a strategy's ladder and pilot. Its limits are soft and only bound runs
///         through it. The clip allocator grants, the probe and the vault caps are the hard limits.
contract StrategyLauncher {
    enum Phase { None, Ladder, Pilot, PilotComplete, Graduated, Aborted }
    enum Mode { None, Direct, Swap, UnwrapAndSwap }
    enum Venue { Probe, Clip }

    struct Venues {
        address probe;
        address clip;
    }

    /// @dev One run's settings. `planHash` is keccak256(abi.encode(plan)).
    struct Plan {
        address myt;
        bool useProbe;
        Mode allocMode;
        Mode deallocMode;
        uint128 smallLeg;
        uint128 largeLeg;
        uint16 exitBufferBps;
        uint256 pilotTarget;
    }

    struct Launch {
        address myt;
        bytes32 planHash;
        Phase phase;
        uint32 attempt;
        bool useProbe;
        Mode allocMode;
        Mode deallocMode;
        uint128 smallLeg;
        uint128 largeLeg;
        uint16 exitBufferBps;
        uint8 nextLeg;
        uint256 held;
        uint256 pilotTarget;
        uint256 pilotAllocated;
        uint32 clipCount;
        uint64 registeredAt;
        uint64 ladderCompletedAt;
        uint64 pilotCompletedAt;
        uint64 lastSuccessBlock;
    }

    /// @dev Everything a bot or dashboard needs about one launch, read in one call.
    struct Report {
        Launch launch;
        uint8 nextLeg;
        Mode nextMode;
        uint256 nextAmount;
        bool needsQuote;
        uint64 readyBlock;
        uint256 allocateGrantLeft;
        uint256 deallocateGrantLeft;
        bool clipPaused;
        uint8 probeNextLeg;
        bool probeLadderCompleted;
        bool probePaused;
        uint256 realAssets;
        uint256 booked;
    }

    /// @dev What the launcher was doing when a venue call reverted.
    struct Step {
        Phase phase;
        uint8 index;
        Venue venue;
        Mode mode;
        bool isAllocate;
        uint256 amount;
    }

    uint256 internal constant BPS = 10_000;

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public sentinels;
    mapping(address => bool) public probeKeepers;
    mapping(address => bool) public clipKeepers;
    mapping(address => Venues) public venues;
    mapping(address => Launch) internal launches;
    address[] public launchList;

    event VenueUpdated(address indexed myt, address probe, address clip);
    event KeeperUpdated(address indexed keeper, bool probeRole, bool allowed);
    event SentinelUpdated(address indexed sentinel, bool allowed);
    event LaunchRegistered(
        address indexed adapter, address indexed myt, uint32 attempt, bytes32 planHash, bool useProbe, uint256 pilotTarget
    );
    event PlanUpdated(address indexed adapter, uint32 attempt, bytes32 oldHash, bytes32 newHash);
    event LegSet(address indexed adapter, uint32 attempt, uint8 leg, uint256 held, address indexed by);
    event PilotReset(address indexed adapter, uint32 attempt, uint256 pilotAllocatedBefore, address indexed by);
    event LegExecuted(
        address indexed adapter, uint32 attempt, uint8 leg, Mode mode, address indexed keeper, uint256 amount, int256 realAssetsDelta
    );
    event LadderCompleted(address indexed adapter, uint32 attempt, address indexed keeper);
    event PilotClip(
        address indexed adapter,
        uint32 attempt,
        uint32 clipNumber,
        address indexed keeper,
        uint256 assets,
        uint256 pilotAllocated,
        uint256 pilotTarget
    );
    event PilotCompleted(address indexed adapter, uint32 attempt);
    event LaunchGraduated(address indexed adapter, uint32 attempt);
    event LaunchAborted(address indexed adapter, uint32 attempt, Phase atPhase);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnerUpdated(address indexed owner);

    error NotOwner();
    error NotSentinel();
    error NotProbeKeeper();
    error NotClipKeeper();
    error NotKeeper();
    error NoVenue(address myt);
    error NotRegistered(address adapter);
    error WrongPhase(Phase phase);
    error LadderNotConfigured();
    error ProbePathMustBeDirect();
    error ProbeOwnsLadder();
    error InvalidLeg(uint8 leg);
    error MytMismatch(address registered, address given);
    error QuoteRequired();
    error UnexpectedQuote();
    error ModeUnsupported(Mode mode);
    error BufferTooHigh(uint16 exitBufferBps);
    error PilotExceeded(uint256 pilotAllocated, uint256 pilotTarget);
    /// @notice A probe or clip allocator call reverted. `reason` is that call's revert data, untouched.
    error StepFailed(
        address adapter, Phase phase, uint8 step, Venue venue, Mode mode, bool isAllocate, uint256 amount, bytes reason
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySentinel() {
        if (msg.sender != owner && !sentinels[msg.sender]) revert NotSentinel();
        _;
    }

    modifier onlyProbeKeeper() {
        if (!probeKeepers[msg.sender]) revert NotProbeKeeper();
        _;
    }

    modifier onlyClipKeeper() {
        if (!clipKeepers[msg.sender]) revert NotClipKeeper();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ---- owner: venues, roles, succession ----------------------------------------

    /// @notice Point `myt` at the probe and clip allocator already serving that vault.
    function setVenue(address myt, address probe, address clipAllocator) external onlyOwner {
        if (myt == address(0) || probe == address(0) || clipAllocator == address(0)) revert NoVenue(myt);
        venues[myt] = Venues(probe, clipAllocator);
        emit VenueUpdated(myt, probe, clipAllocator);
    }

    function setSentinel(address sentinel, bool allowed) external onlyOwner {
        sentinels[sentinel] = allowed;
        emit SentinelUpdated(sentinel, allowed);
    }

    function setProbeKeeper(address keeper, bool allowed) external onlyOwner {
        probeKeepers[keeper] = allowed;
        emit KeeperUpdated(keeper, true, allowed);
    }

    function setClipKeeper(address keeper, bool allowed) external onlyOwner {
        clipKeepers[keeper] = allowed;
        emit KeeperUpdated(keeper, false, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerUpdated(owner);
    }

    // ---- sentinel: open, edit, rewind, close -------------------------------------

    /// @notice Open a new attempt at leg 1 from any phase. Progress from the last attempt is dropped,
    ///         and anything it left in the strategy stays there.
    function registerLaunch(address adapter, Plan calldata plan) external onlySentinel {
        if (adapter == address(0)) revert NotRegistered(adapter);
        _validate(plan);
        Launch storage l = launches[adapter];
        uint32 attempt = l.attempt + 1;
        if (attempt == 1) launchList.push(adapter);

        bytes32 planHash = keccak256(abi.encode(plan));
        launches[adapter] = Launch({
            myt: plan.myt,
            planHash: planHash,
            phase: Phase.Ladder,
            attempt: attempt,
            useProbe: plan.useProbe,
            allocMode: plan.allocMode,
            deallocMode: plan.deallocMode,
            smallLeg: plan.smallLeg,
            largeLeg: plan.largeLeg,
            exitBufferBps: plan.exitBufferBps,
            nextLeg: 0,
            held: 0,
            pilotTarget: plan.pilotTarget,
            pilotAllocated: 0,
            clipCount: 0,
            registeredAt: uint64(block.timestamp),
            ladderCompletedAt: 0,
            pilotCompletedAt: 0,
            lastSuccessBlock: 0
        });
        emit LaunchRegistered(adapter, plan.myt, attempt, planHash, plan.useProbe, plan.pilotTarget);
    }

    /// @notice Replace the plan and keep progress. A pilot whose target moves past or below
    ///         `pilotAllocated` flips between Pilot and PilotComplete.
    function updatePlan(address adapter, Plan calldata plan) external onlySentinel {
        Launch storage l = _registered(adapter);
        if (plan.myt != l.myt) revert MytMismatch(l.myt, plan.myt);
        _validate(plan);
        bytes32 oldHash = l.planHash;
        l.planHash = keccak256(abi.encode(plan));
        l.useProbe = plan.useProbe;
        l.allocMode = plan.allocMode;
        l.deallocMode = plan.deallocMode;
        l.smallLeg = plan.smallLeg;
        l.largeLeg = plan.largeLeg;
        l.exitBufferBps = plan.exitBufferBps;
        l.pilotTarget = plan.pilotTarget;
        if (l.phase == Phase.Pilot && l.pilotAllocated >= plan.pilotTarget) {
            _completePilot(adapter, l);
        } else if (l.phase == Phase.PilotComplete && l.pilotAllocated < plan.pilotTarget) {
            l.phase = Phase.Pilot;
            l.pilotCompletedAt = 0;
        }
        emit PlanUpdated(adapter, l.attempt, oldHash, l.planHash);
    }

    /// @notice Move a swap ladder to `leg` (1 to 4), with `held` as what the next exit leg takes out.
    ///         Leg 5 skips to the pilot, for probe launches too. The probe owns its own leg counter.
    function setLeg(address adapter, uint8 leg, uint256 held) external onlySentinel {
        Launch storage l = _registered(adapter);
        if (leg == 0 || leg > 5) revert InvalidLeg(leg);
        if (leg == 5) {
            l.phase = Phase.Pilot;
            l.nextLeg = 0;
            l.held = 0;
            l.ladderCompletedAt = uint64(block.timestamp);
        } else {
            if (l.useProbe) revert ProbeOwnsLadder();
            l.phase = Phase.Ladder;
            l.nextLeg = leg;
            l.held = held;
        }
        emit LegSet(adapter, l.attempt, leg, held, msg.sender);
    }

    /// @notice Start the pilot count again at zero. Clips that landed stay in the strategy.
    function resetPilot(address adapter) external onlySentinel {
        Launch storage l = _registered(adapter);
        if (l.phase == Phase.Ladder) revert WrongPhase(l.phase);
        uint256 before = l.pilotAllocated;
        l.phase = Phase.Pilot;
        l.pilotAllocated = 0;
        l.clipCount = 0;
        l.pilotCompletedAt = 0;
        emit PilotReset(adapter, l.attempt, before, msg.sender);
    }

    /// @notice Close a reviewed launch. Later allocation is no longer this contract's job.
    function graduate(address adapter) external onlySentinel {
        Launch storage l = _registered(adapter);
        if (l.phase != Phase.Pilot && l.phase != Phase.PilotComplete) revert WrongPhase(l.phase);
        l.phase = Phase.Graduated;
        emit LaunchGraduated(adapter, l.attempt);
    }

    /// @notice Stop a launch. Funds already in the strategy stay there. `registerLaunch` reopens it.
    function abort(address adapter) external onlySentinel {
        Launch storage l = _registered(adapter);
        Phase at = l.phase;
        if (at == Phase.Aborted) revert WrongPhase(at);
        l.phase = Phase.Aborted;
        emit LaunchAborted(adapter, l.attempt, at);
    }

    // ---- keepers ----------------------------------------------------------------

    /// @notice Run the next ladder leg. Leg 4 moves the launch to Pilot.
    ///         `txData` is required only when that leg's mode is a swap.
    function step(address adapter, bytes calldata txData, uint256 minIntermediateOut)
        external
        onlyProbeKeeper
        returns (uint8 leg)
    {
        Launch storage l = launches[adapter];
        if (l.phase != Phase.Ladder) revert WrongPhase(l.phase);
        Venues memory v = venues[l.myt];
        if (l.useProbe) {
            if (txData.length != 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            leg = _stepProbe(adapter, v.probe);
        } else {
            leg = _stepSwap(adapter, v.clip, txData, minIntermediateOut);
        }
        l.lastSuccessBlock = uint64(block.number);
        if (leg == 4) {
            l.phase = Phase.Pilot;
            l.nextLeg = 0;
            l.ladderCompletedAt = uint64(block.timestamp);
            emit LadderCompleted(adapter, l.attempt, msg.sender);
        }
    }

    /// @notice Allocate one pilot clip. Reverts outside Pilot or above `pilotTarget`.
    function clip(address adapter, uint256 assets, bytes calldata txData) external onlyClipKeeper {
        Launch storage l = launches[adapter];
        if (l.phase != Phase.Pilot) revert WrongPhase(l.phase);
        if (assets == 0 || l.pilotAllocated + assets > l.pilotTarget) revert PilotExceeded(l.pilotAllocated, l.pilotTarget);
        uint32 n = l.clipCount + 1;
        _call(
            adapter,
            venues[l.myt].clip,
            _allocateCall(l.allocMode, adapter, assets, txData),
            Step(Phase.Pilot, uint8(n), Venue.Clip, l.allocMode, true, assets)
        );
        l.clipCount = n;
        l.pilotAllocated += assets;
        l.lastSuccessBlock = uint64(block.number);
        emit PilotClip(adapter, l.attempt, n, msg.sender, assets, l.pilotAllocated, l.pilotTarget);
        if (l.pilotAllocated >= l.pilotTarget) _completePilot(adapter, l);
    }

    /// @notice Pause the venue's probe and, when the launcher holds clip budget, the clip allocator.
    function pause(address myt) external {
        if (!probeKeepers[msg.sender] && !clipKeepers[msg.sender] && !sentinels[msg.sender] && msg.sender != owner) {
            revert NotKeeper();
        }
        Venues memory v = venues[myt];
        if (v.probe == address(0)) revert NoVenue(myt);
        IStrategyProbeLite(v.probe).setPaused(true);
        try IClipAllocatorLite(v.clip).setPaused(true) {} catch {}
    }

    // ---- views ------------------------------------------------------------------

    /// @notice The next keeper call: phase, leg, path, amount, whether it needs a quote, and the first
    ///         block the clip allocator accepts it. In Pilot the amount is one clip at most.
    function nextStep(address adapter)
        public
        view
        returns (Phase phase, uint8 leg, Mode mode, uint256 amount, bool needsQuote, uint64 readyBlock)
    {
        Launch memory l = launches[adapter];
        phase = l.phase;
        Venues memory v = venues[l.myt];
        if (phase == Phase.Ladder) {
            if (l.useProbe) {
                (leg, amount, mode) = _probeNext(v.probe, adapter);
            } else {
                leg = l.nextLeg == 0 ? 1 : l.nextLeg;
                bool isAllocate = leg == 1 || leg == 3;
                mode = isAllocate ? l.allocMode : l.deallocMode;
                amount = isAllocate ? (leg == 1 ? l.smallLeg : l.largeLeg) : _buffered(l.held, l.exitBufferBps);
                (,, readyBlock) = _grant(v.clip, adapter, isAllocate);
            }
            needsQuote = mode != Mode.Direct;
        } else if (phase == Phase.Pilot) {
            mode = l.allocMode;
            amount = l.pilotTarget - l.pilotAllocated;
            uint256 maxClip;
            (, maxClip, readyBlock) = _grant(v.clip, adapter, true);
            if (maxClip != 0 && maxClip < amount) amount = maxClip;
            needsQuote = mode == Mode.Swap;
        }
    }

    /// @notice The launch, its next step, the launcher's grants, the probe state and the position.
    function report(address adapter) external view returns (Report memory r) {
        r.launch = launches[adapter];
        if (r.launch.phase == Phase.None) return r;
        (, r.nextLeg, r.nextMode, r.nextAmount, r.needsQuote, r.readyBlock) = nextStep(adapter);
        Venues memory v = venues[r.launch.myt];
        (r.allocateGrantLeft,,) = _grant(v.clip, adapter, true);
        (r.deallocateGrantLeft,,) = _grant(v.clip, adapter, false);
        r.clipPaused = IClipAllocatorLite(v.clip).paused();
        r.probeNextLeg = IStrategyProbeLite(v.probe).nextLeg(adapter);
        r.probeLadderCompleted = IStrategyProbeLite(v.probe).ladderCompleted(adapter);
        r.probePaused = IStrategyProbeLite(v.probe).paused();
        r.realAssets = IMYTStrategyLite(adapter).realAssets();
        r.booked = IVaultLite(r.launch.myt).allocation(IMYTStrategyLite(adapter).adapterId());
    }

    function launchCount() external view returns (uint256) {
        return launchList.length;
    }

    function launch(address adapter) external view returns (Launch memory) {
        return launches[adapter];
    }

    // ---- internals ---------------------------------------------------------------

    function _stepProbe(address adapter, address probe) internal returns (uint8 leg) {
        (uint8 expected, uint256 amount,) = _probeNext(probe, adapter);
        uint256 before = IMYTStrategyLite(adapter).realAssets();
        try IStrategyProbeLite(probe).runNextLeg(adapter) returns (uint8 ran, uint256) {
            leg = ran;
        } catch (bytes memory reason) {
            revert StepFailed(adapter, Phase.Ladder, expected, Venue.Probe, Mode.Direct, expected == 1 || expected == 3, amount, reason);
        }
        _emitLeg(adapter, leg, Mode.Direct, before);
    }

    function _stepSwap(address adapter, address clip_, bytes calldata txData, uint256 minIntermediateOut)
        internal
        returns (uint8 leg)
    {
        Launch storage l = launches[adapter];
        leg = l.nextLeg == 0 ? 1 : l.nextLeg;
        bool isAllocate = leg == 1 || leg == 3;
        Mode mode = isAllocate ? l.allocMode : l.deallocMode;
        uint256 amount = isAllocate ? (leg == 1 ? l.smallLeg : l.largeLeg) : _buffered(l.held, l.exitBufferBps);
        if (isAllocate && minIntermediateOut != 0) revert UnexpectedQuote();
        bytes memory data = isAllocate
            ? _allocateCall(mode, adapter, amount, txData)
            : _deallocateCall(mode, adapter, amount, txData, minIntermediateOut);

        uint256 before = IMYTStrategyLite(adapter).realAssets();
        _call(adapter, clip_, data, Step(Phase.Ladder, leg, Venue.Clip, mode, isAllocate, amount));
        if (isAllocate) {
            uint256 landed = IMYTStrategyLite(adapter).realAssets() - before;
            l.held = landed < amount ? landed : amount;
        } else {
            l.held = 0;
        }
        l.nextLeg = leg + 1;
        _emitLeg(adapter, leg, mode, before);
    }

    function _call(address adapter, address target, bytes memory data, Step memory s) internal {
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) revert StepFailed(adapter, s.phase, s.index, s.venue, s.mode, s.isAllocate, s.amount, reason);
    }

    function _allocateCall(Mode mode, address adapter, uint256 amount, bytes calldata txData)
        internal
        pure
        returns (bytes memory)
    {
        if (mode == Mode.Direct) {
            if (txData.length != 0) revert UnexpectedQuote();
            return abi.encodeCall(IClipAllocatorLite.allocateClip, (adapter, amount));
        }
        if (mode == Mode.Swap) {
            if (txData.length == 0) revert QuoteRequired();
            return abi.encodeCall(IClipAllocatorLite.allocateClipWithSwap, (adapter, amount, txData));
        }
        revert ModeUnsupported(mode);
    }

    function _deallocateCall(Mode mode, address adapter, uint256 amount, bytes calldata txData, uint256 minIntermediateOut)
        internal
        pure
        returns (bytes memory)
    {
        if (mode == Mode.Direct) {
            if (txData.length != 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            return abi.encodeCall(IClipAllocatorLite.deallocateClip, (adapter, amount));
        }
        if (mode == Mode.Swap) {
            if (txData.length == 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            return abi.encodeCall(IClipAllocatorLite.deallocateClipWithSwap, (adapter, amount, txData));
        }
        if (mode == Mode.UnwrapAndSwap) {
            if (txData.length == 0) revert QuoteRequired();
            return abi.encodeCall(IClipAllocatorLite.deallocateClipWithUnwrapAndSwap, (adapter, amount, txData, minIntermediateOut));
        }
        revert ModeUnsupported(mode);
    }

    /// @dev Only what the launcher needs to pick a call. Everything else the venues check.
    function _validate(Plan calldata plan) internal view {
        if (venues[plan.myt].probe == address(0)) revert NoVenue(plan.myt);
        if (plan.pilotTarget == 0 || plan.allocMode == Mode.None) revert LadderNotConfigured();
        if (plan.useProbe) {
            if (plan.allocMode != Mode.Direct || plan.deallocMode != Mode.Direct) revert ProbePathMustBeDirect();
        } else if (plan.deallocMode == Mode.None) {
            revert LadderNotConfigured();
        }
        if (plan.allocMode == Mode.UnwrapAndSwap) revert ModeUnsupported(plan.allocMode);
        if (plan.exitBufferBps > BPS) revert BufferTooHigh(plan.exitBufferBps);
    }

    function _registered(address adapter) internal view returns (Launch storage l) {
        l = launches[adapter];
        if (l.phase == Phase.None) revert NotRegistered(adapter);
    }

    function _completePilot(address adapter, Launch storage l) internal {
        l.phase = Phase.PilotComplete;
        l.pilotCompletedAt = uint64(block.timestamp);
        emit PilotCompleted(adapter, l.attempt);
    }

    function _emitLeg(address adapter, uint8 leg, Mode mode, uint256 realBefore) internal {
        int256 delta = int256(IMYTStrategyLite(adapter).realAssets()) - int256(realBefore);
        uint256 amount = delta >= 0 ? uint256(delta) : uint256(-delta);
        emit LegExecuted(adapter, launches[adapter].attempt, leg, mode, msg.sender, amount, delta);
    }

    /// @dev Remaining budget, clip size and first accepted block of the launcher's grant on `adapter`.
    function _grant(address clip_, address adapter, bool isAllocate)
        internal
        view
        returns (uint256 remaining, uint256 maxClip, uint64 readyBlock)
    {
        uint32 interval;
        uint64 last;
        if (isAllocate) {
            (remaining, maxClip, interval, last,,,) = IClipAllocatorLite(clip_).allocateGrants(address(this), adapter);
        } else {
            (remaining, maxClip, interval, last,,,) = IClipAllocatorLite(clip_).deallocateGrants(address(this), adapter);
        }
        if (last != 0) readyBlock = last + interval;
    }

    function _probeNext(address probe, address adapter) internal view returns (uint8 leg, uint256 amount, Mode mode) {
        uint8 n = IStrategyProbeLite(probe).nextLeg(adapter);
        leg = n == 0 ? 1 : n;
        mode = Mode.Direct;
        if (leg == 1) amount = IStrategyProbeLite(probe).SMALL_LEG();
        else if (leg == 3) amount = IStrategyProbeLite(probe).LARGE_LEG();
        else {
            (, uint256 held,,,,,) = IStrategyProbeLite(probe).openLadders(adapter);
            amount = _buffered(held, IStrategyProbeLite(probe).exitBufferBps(adapter));
        }
    }

    function _buffered(uint256 held, uint256 bufferBps) internal pure returns (uint256) {
        return held - held * bufferBps / BPS;
    }
}
