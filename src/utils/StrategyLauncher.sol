// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Views and calls the launcher makes. Inline so this file compiles on its own.
interface IStrategyProbeLite {
    function runNextLeg(address adapter) external returns (uint8 leg, uint256 residual);
    function setPaused(bool p) external;
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
}

interface IMYTStrategyLite {
    function realAssets() external view returns (uint256);
}

/// @title StrategyLauncher
/// @notice Entry point for a strategy's probe ladder and pilot allocation. One per chain.
///         A poker on the probe and a grantee on the clip allocator, not an allocator operator.
contract StrategyLauncher {
    enum Phase { None, Ladder, Pilot, PilotComplete, Graduated, Aborted }
    enum Mode { None, Direct, Swap, UnwrapAndSwap }

    struct Venue {
        address probe;
        address clip;
    }

    /// @dev What the Safe fixes for one adapter. `planHash` is keccak256(abi.encode(plan)).
    struct Plan {
        address myt;
        bool useProbe;
        Mode allocMode;
        Mode deallocMode;
        uint128 smallLeg;
        uint128 largeLeg;
        uint16 exitBufferBps;
        uint256 pilotMax;
    }

    struct Launch {
        address myt;
        bytes32 planHash;
        Phase phase;
        bool useProbe;
        Mode allocMode;
        Mode deallocMode;
        uint128 smallLeg;
        uint128 largeLeg;
        uint16 exitBufferBps;
        uint8 nextLeg;
        uint256 held;
        uint256 pilotMax;
        uint256 pilotAllocated;
        uint64 registeredAt;
        uint64 ladderCompletedAt;
        uint64 pilotCompletedAt;
    }

    uint256 internal constant MAX_BUFFER_BPS = 1_000;

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public probeKeepers;
    mapping(address => bool) public clipKeepers;
    mapping(address => Venue) public venues;
    mapping(address => Launch) internal launches;
    address[] public launchList;

    event VenueUpdated(address indexed myt, address probe, address clip);
    event KeeperUpdated(address indexed keeper, bool probeRole, bool allowed);
    event LaunchRegistered(address indexed adapter, address indexed myt, bytes32 planHash, bool useProbe, uint256 pilotMax);
    event LegExecuted(address indexed adapter, uint8 leg, Mode mode, address indexed keeper, uint256 amount, int256 realAssetsDelta);
    event LadderCompleted(address indexed adapter, address indexed keeper);
    event PilotClip(address indexed adapter, address indexed keeper, uint256 assets, uint256 pilotAllocated, uint256 pilotMax);
    event PilotCompleted(address indexed adapter);
    event LaunchGraduated(address indexed adapter);
    event LaunchAborted(address indexed adapter, Phase atPhase);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnerUpdated(address indexed owner);

    error NotOwner();
    error NotProbeKeeper();
    error NotClipKeeper();
    error NoVenue(address myt);
    error LaunchExists(address adapter);
    error NotRegistered(address adapter);
    error WrongPhase(Phase phase);
    error LadderNotConfigured();
    error ProbePathMustBeDirect();
    error QuoteRequired();
    error UnexpectedQuote();
    error ModeUnsupported(Mode mode);
    error BufferTooHigh(uint16 exitBufferBps);
    error PilotExceeded(uint256 pilotAllocated, uint256 pilotMax);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
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

    // ---- owner: venues, keepers, launches, succession ---------------------------

    /// @notice Point `myt` at the probe and clip allocator already serving that vault.
    function setVenue(address myt, address probe, address clipAllocator) external onlyOwner {
        if (myt == address(0) || probe == address(0) || clipAllocator == address(0)) revert NoVenue(myt);
        venues[myt] = Venue(probe, clipAllocator);
        emit VenueUpdated(myt, probe, clipAllocator);
    }

    function setProbeKeeper(address keeper, bool allowed) external onlyOwner {
        probeKeepers[keeper] = allowed;
        emit KeeperUpdated(keeper, true, allowed);
    }

    function setClipKeeper(address keeper, bool allowed) external onlyOwner {
        clipKeepers[keeper] = allowed;
        emit KeeperUpdated(keeper, false, allowed);
    }

    /// @notice Open a launch in the Ladder phase. The plan hash is stored so the
    ///         manifest that produced the Safe batch can be checked against this call.
    function registerLaunch(address adapter, Plan calldata plan) external onlyOwner {
        if (adapter == address(0)) revert NotRegistered(adapter);
        if (launches[adapter].phase != Phase.None) revert LaunchExists(adapter);
        if (venues[plan.myt].probe == address(0)) revert NoVenue(plan.myt);
        if (plan.pilotMax == 0 || plan.allocMode == Mode.None) revert LadderNotConfigured();
        if (plan.useProbe) {
            if (plan.allocMode != Mode.Direct || plan.deallocMode != Mode.Direct) revert ProbePathMustBeDirect();
        } else if (plan.smallLeg == 0 || plan.largeLeg < plan.smallLeg || plan.deallocMode == Mode.None) {
            revert LadderNotConfigured();
        }
        if (plan.exitBufferBps > MAX_BUFFER_BPS) revert BufferTooHigh(plan.exitBufferBps);
        if (plan.allocMode == Mode.UnwrapAndSwap) revert ModeUnsupported(plan.allocMode);

        launches[adapter] = Launch({
            myt: plan.myt,
            planHash: keccak256(abi.encode(plan)),
            phase: Phase.Ladder,
            useProbe: plan.useProbe,
            allocMode: plan.allocMode,
            deallocMode: plan.deallocMode,
            smallLeg: plan.smallLeg,
            largeLeg: plan.largeLeg,
            exitBufferBps: plan.exitBufferBps,
            nextLeg: 0,
            held: 0,
            pilotMax: plan.pilotMax,
            pilotAllocated: 0,
            registeredAt: uint64(block.timestamp),
            ladderCompletedAt: 0,
            pilotCompletedAt: 0
        });
        launchList.push(adapter);
        emit LaunchRegistered(adapter, plan.myt, launches[adapter].planHash, plan.useProbe, plan.pilotMax);
    }

    /// @notice Mark a reviewed pilot as finished. Later allocation is no longer this contract's job.
    function graduate(address adapter) external onlyOwner {
        Launch storage l = launches[adapter];
        if (l.phase != Phase.PilotComplete) revert WrongPhase(l.phase);
        l.phase = Phase.Graduated;
        emit LaunchGraduated(adapter);
    }

    /// @notice Stop a launch. Funds already in the strategy stay there.
    function abort(address adapter) external onlyOwner {
        Launch storage l = launches[adapter];
        Phase at = l.phase;
        if (at == Phase.None || at == Phase.Graduated || at == Phase.Aborted) revert WrongPhase(at);
        l.phase = Phase.Aborted;
        emit LaunchAborted(adapter, at);
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
        Venue memory v = venues[l.myt];
        if (l.useProbe) {
            if (txData.length != 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            leg = _stepProbe(adapter, v.probe);
        } else {
            leg = _stepSwap(adapter, v.clip, txData, minIntermediateOut);
        }
        if (leg == 4) {
            l.phase = Phase.Pilot;
            l.nextLeg = 0;
            l.ladderCompletedAt = uint64(block.timestamp);
            emit LadderCompleted(adapter, msg.sender);
        }
    }

    /// @notice Allocate one pilot clip. Reverts outside Pilot or above `pilotMax`.
    function clip(address adapter, uint256 assets, bytes calldata txData) external onlyClipKeeper {
        Launch storage l = launches[adapter];
        if (l.phase != Phase.Pilot) revert WrongPhase(l.phase);
        if (assets == 0 || l.pilotAllocated + assets > l.pilotMax) revert PilotExceeded(l.pilotAllocated, l.pilotMax);
        _allocate(venues[l.myt].clip, adapter, l.allocMode, assets, txData);
        l.pilotAllocated += assets;
        emit PilotClip(adapter, msg.sender, assets, l.pilotAllocated, l.pilotMax);
        if (l.pilotAllocated == l.pilotMax) {
            l.phase = Phase.PilotComplete;
            l.pilotCompletedAt = uint64(block.timestamp);
            emit PilotCompleted(adapter);
        }
    }

    /// @notice Pause the venue's probe and, when the launcher holds clip budget, the clip allocator.
    function pause(address myt) external {
        if (!probeKeepers[msg.sender] && !clipKeepers[msg.sender]) revert NotProbeKeeper();
        Venue memory v = venues[myt];
        if (v.probe == address(0)) revert NoVenue(myt);
        IStrategyProbeLite(v.probe).setPaused(true);
        try IClipAllocatorLite(v.clip).setPaused(true) {} catch {}
    }

    /// @notice The next keeper call for `adapter`: phase, leg, path, amount, and whether a quote is required.
    ///         In Pilot, `amount` is the remaining room under `pilotMax`, not the clip size.
    function nextStep(address adapter) external view returns (Phase phase, uint8 leg, Mode mode, uint256 amount, bool needsQuote) {
        Launch memory l = launches[adapter];
        phase = l.phase;
        if (phase == Phase.Ladder) {
            if (l.useProbe) {
                (leg, amount, mode) = _probeNext(venues[l.myt].probe, adapter);
            } else {
                leg = l.nextLeg == 0 ? 1 : l.nextLeg;
                bool isAllocate = leg == 1 || leg == 3;
                mode = isAllocate ? l.allocMode : l.deallocMode;
                amount = isAllocate ? (leg == 1 ? l.smallLeg : l.largeLeg) : _buffered(l.held, l.exitBufferBps);
            }
            needsQuote = mode != Mode.Direct;
        } else if (phase == Phase.Pilot) {
            mode = l.allocMode;
            amount = l.pilotMax - l.pilotAllocated;
            needsQuote = mode == Mode.Swap;
        }
    }

    function launchCount() external view returns (uint256) {
        return launchList.length;
    }

    function launch(address adapter) external view returns (Launch memory) {
        return launches[adapter];
    }

    // ---- internals ---------------------------------------------------------------

    function _stepProbe(address adapter, address probe) internal returns (uint8 leg) {
        uint256 before = IMYTStrategyLite(adapter).realAssets();
        (leg,) = IStrategyProbeLite(probe).runNextLeg(adapter);
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
        uint256 before = IMYTStrategyLite(adapter).realAssets();
        if (isAllocate) {
            _allocate(clip_, adapter, mode, amount, txData);
            if (minIntermediateOut != 0) revert UnexpectedQuote();
            uint256 landed = IMYTStrategyLite(adapter).realAssets() - before;
            l.held = landed < amount ? landed : amount;
        } else {
            _deallocate(clip_, adapter, mode, amount, txData, minIntermediateOut);
            l.held = 0;
        }
        l.nextLeg = leg + 1;
        _emitLeg(adapter, leg, mode, before);
    }

    function _allocate(address clip_, address adapter, Mode mode, uint256 amount, bytes calldata txData) internal {
        if (mode == Mode.Direct) {
            if (txData.length != 0) revert UnexpectedQuote();
            IClipAllocatorLite(clip_).allocateClip(adapter, amount);
        } else if (mode == Mode.Swap) {
            if (txData.length == 0) revert QuoteRequired();
            IClipAllocatorLite(clip_).allocateClipWithSwap(adapter, amount, txData);
        } else {
            revert ModeUnsupported(mode);
        }
    }

    function _deallocate(address clip_, address adapter, Mode mode, uint256 amount, bytes calldata txData, uint256 minIntermediateOut)
        internal
    {
        if (mode == Mode.Direct) {
            if (txData.length != 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            IClipAllocatorLite(clip_).deallocateClip(adapter, amount);
        } else if (mode == Mode.Swap) {
            if (txData.length == 0 || minIntermediateOut != 0) revert UnexpectedQuote();
            IClipAllocatorLite(clip_).deallocateClipWithSwap(adapter, amount, txData);
        } else if (mode == Mode.UnwrapAndSwap) {
            if (txData.length == 0) revert QuoteRequired();
            IClipAllocatorLite(clip_).deallocateClipWithUnwrapAndSwap(adapter, amount, txData, minIntermediateOut);
        } else {
            revert ModeUnsupported(mode);
        }
    }

    function _emitLeg(address adapter, uint8 leg, Mode mode, uint256 realBefore) internal {
        int256 delta = int256(IMYTStrategyLite(adapter).realAssets()) - int256(realBefore);
        uint256 amount = delta >= 0 ? uint256(delta) : uint256(-delta);
        emit LegExecuted(adapter, leg, mode, msg.sender, amount, delta);
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
        return held - held * bufferBps / 10_000;
    }
}
