// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal views of the live contracts the probe touches. Kept inline so the
/// file compiles on its own (no v3 remappings needed).
interface IAlchemistAllocator {
    function vault() external view returns (address);
    function allocate(address adapter, uint256 amount) external;
    function deallocate(address adapter, uint256 amount) external;
    function operators(address) external view returns (bool);
}

interface IVaultV2Lite {
    function asset() external view returns (address);
    function isAdapter(address account) external view returns (bool);
    function allocation(bytes32 id) external view returns (uint256);
    function liquidityAdapter() external view returns (address);
}

interface IMYTStrategyLite {
    function adapterId() external view returns (bytes32);
    function realAssets() external view returns (uint256);
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title StrategyProbe
 * @notice A scoped allocator operator for strategy smoke tests. Registered
 *         as an operator of the live AlchemistAllocator (one Safe call:
 *         `setOperator(probe, true)`), it runs the standard registration
 *         ladder on one adapter, four legs:
 *
 *           1 allocate SMALL_LEG   2 deallocate it   3 allocate LARGE_LEG   4 deallocate it
 *
 *         One entry point, from the poker whitelist: `runNextLeg(adapter)` executes
 *         the NEXT leg and nothing else. Four calls complete a ladder. A leg
 *         that reverts (a venue with a withdrawal delay, an epoch exit) is
 *         simply retried later; the probe remembers which leg is next and how
 *         much it physically holds in the strategy.
 *
 *         Buffers: venues do not always deposit or withdraw the exact amount
 *         asked. An allocate leg therefore records what actually landed
 *         (realAssets delta, capped at the request) and the matching
 *         deallocate leg asks for that measured amount minus a per-adapter
 *         buffer (bps). The leftover stays in the strategy as dust and is
 *         reported, never chased.
 *
 *         Authority: one owner. The deployer starts as owner, whitelists the
 *         first pokers, then hands ownership to the allocator admin (the
 *         chain's Safe) with the classic two-step transfer; the Safe accepts.
 *         From then on the Safe owns the whitelist, the per-adapter
 *         overrides, the reset and the pause. Any poker may hit the pause
 *         as an emergency stop; only the owner can lift it.
 *
 *         Compared with a plain EOA operator the scope is fixed by code:
 *
 *         - amounts are immutable constants (nobody can raise them);
 *         - a deallocate leg only ever returns what the probe's own previous
 *           allocate leg put in (the allocator's `deallocate` has no cap
 *           check, so a plain operator could unwind a whole strategy — this
 *           cannot);
 *         - every leg is checked against the adapter's realAssets (the
 *           physical position) within a per-adapter tolerance; a mismatch
 *           reverts that leg. The vault's booked delta is reported alongside,
 *           since it also carries the catch-up on whatever yield or loss was
 *           unbooked before the touch;
 *         - legs run strictly in order 1 → 4; there is no way to skip one;
 *         - ONE ladder per strategy, ever: once leg 4 closes (or a ladder
 *           stalls) the probe refuses every further allocate / deallocate
 *           on that adapter until the owner (the Safe) calls `reset(adapter)`;
 *         - the Safe keeps the kill switch: `setOperator(probe, false)`.
 *
 *         Direct-mechanism adapters only (Aave, Euler, Yearn, Morpho, Fluid,
 *         ...). Swap-mechanism adapters need 0x calldata per leg and are out
 *         of scope: their direct `allocate` reverts inside the adapter and
 *         the probe reverts with it.
 *
 *         Idle cash: deposits sit in the liquidity adapter, so the vault's own
 *         balance is usually ~0. An allocate leg raises the shortfall from
 *         the liquidity adapter (a vault-internal move); the close returns it,
 *         so the vault's idle position is unchanged after a full ladder.
 */
contract StrategyProbe {
    IAlchemistAllocator public immutable allocator;
    IVaultV2Lite public immutable vault;
    IERC20Lite public immutable asset;

    /// ladder sizes in asset units (e.g. 1e15 / 1e16 for WETH, 1e6 / 1e7 for USDC)
    uint256 public immutable SMALL_LEG;
    uint256 public immutable LARGE_LEG;
    /// defaults, overridable per adapter: tolerance on a leg's realAssets
    /// delta, and the exit buffer a deallocate leg leaves behind (both bps)
    uint256 public immutable TOLERANCE_BPS;
    uint256 public immutable EXIT_BUFFER_BPS;

    struct AdapterOverrides {
        uint16 toleranceBps;         // 0 = TOLERANCE_BPS
        uint16 exitBufferBps;      // 0 = EXIT_BUFFER_BPS
        bool set;
    }

    struct Ladder {
        uint8 nextLeg;            // 0 = idle (no ladder open), else the next leg 1..4
        uint256 heldInStrategy;   // what the last allocate leg physically put into the strategy, still to withdraw
        uint256 idleRaised;      // idle cash raised from the liquidity adapter, returned at close
        uint256 bookedAtOpen;    // vault.allocation(id) before leg 1
        uint256 realAssetsAtOpen;     // adapter.realAssets() before leg 1
        uint64 openedAt;
        address openedBy;         // who opened the ladder
    }

    address public owner;                          // the deployer, then the Safe after the two-step transfer
    address public pendingOwner;
    bool public paused;
    mapping(address => bool) public pokers;        // whitelist, set by the owner
    mapping(address => bool) public ladderCompleted;     // adapter → ladder finished, probe locked out until the Safe resets
    mapping(address => Ladder) public openLadders;     // adapter → ladder in progress
    mapping(address => AdapterOverrides) public overrides;         // adapter → tolerance / exit-buffer overrides

    event PokerUpdated(address indexed poker, bool allowed);
    event OverridesUpdated(address indexed adapter, uint16 toleranceBps, uint16 exitBufferBps);
    event Paused(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnerUpdated(address indexed owner);
    event LegExecuted(
        address indexed adapter,
        bytes32 indexed id,
        uint8 leg,                // 1..4
        bool isAllocate,
        uint256 requested,         // SMALL_LEG / LARGE_LEG on an allocate; measured − buffer on a deallocate
        int256 realAssetsDelta,          // adapter.realAssets() after − before: what physically moved
        int256 bookedAllocationDelta,    // vault.allocation(id) after − before (includes the booking catch-up)
        uint256 realAssetsAfter
    );
    event LadderCompleted(
        address indexed adapter,
        bytes32 indexed id,
        address indexed poker,
        uint256 idleRaisedFromLiquidityAdapter,
        uint256 idleReturnedToLiquidityAdapter,
        uint256 realAssetsResidual  // adapter.realAssets() after − before the ladder (dust + accrual)
    );
    event LadderReset(address indexed adapter, bool wasCompleted, uint8 atLeg, uint256 heldInStrategy, uint256 idleReturned);

    error NotOwner();
    error NotPoker();
    error NotPokerOrOwner();
    error ProbePaused();
    error NotAdapter(address adapter);
    error LadderAlreadyCompleted(address adapter);
    error NothingToReset(address adapter);
    error IdleUnavailable(uint256 needed, uint256 vaultIdle, address liquidityAdapter);
    error RealAssetsMismatch(uint8 leg, uint256 expected, int256 got);
    error RealAssetsLost(uint256 realAssetsAtOpen, uint256 realAssetsNow);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPoker() {
        if (paused) revert ProbePaused();
        if (!pokers[msg.sender]) revert NotPoker();
        _;
    }

    constructor(address _allocator, uint256 _smallLeg, uint256 _largeLeg,
                uint256 _toleranceBps, uint256 _exitBufferBps) {
        require(_allocator != address(0), "zero");
        require(_smallLeg > 0 && _largeLeg >= _smallLeg, "sizes");
        require(_toleranceBps <= 1_000 && _exitBufferBps <= 1_000, "bps");   // never more than 10%
        allocator = IAlchemistAllocator(_allocator);
        vault = IVaultV2Lite(allocator.vault());
        asset = IERC20Lite(vault.asset());
        owner = msg.sender;                            // the deployer, until the Safe accepts
        SMALL_LEG = _smallLeg;
        LARGE_LEG = _largeLeg;
        TOLERANCE_BPS = _toleranceBps;
        EXIT_BUFFER_BPS = _exitBufferBps;
    }

    // ---- the owner (the Safe once accepted): whitelist, overrides, reset, pause

    function setPoker(address poker, bool allowed) external onlyOwner {
        pokers[poker] = allowed;
        emit PokerUpdated(poker, allowed);
    }

    /// @notice Per-adapter tolerance (oracle-priced venues book an entry
    ///         haircut) and deallocate buffer (venues that return a little
    ///         less than asked). Both bounded at 10%.
    function setAdapterOverrides(address adapter, uint16 _toleranceBps, uint16 _exitBufferBps) external onlyOwner {
        require(_toleranceBps <= 1_000 && _exitBufferBps <= 1_000, "bps");
        overrides[adapter] = AdapterOverrides(_toleranceBps, _exitBufferBps, true);
        emit OverridesUpdated(adapter, _toleranceBps, _exitBufferBps);
    }

    function toleranceBps(address adapter) public view returns (uint256) {
        AdapterOverrides memory t = overrides[adapter];
        return (t.set && t.toleranceBps != 0) ? t.toleranceBps : TOLERANCE_BPS;
    }

    function exitBufferBps(address adapter) public view returns (uint256) {
        AdapterOverrides memory t = overrides[adapter];
        return (t.set && t.exitBufferBps != 0) ? t.exitBufferBps : EXIT_BUFFER_BPS;
    }

    /// @notice Emergency stop: any poker may pause, only the owner may unpause.
    function setPaused(bool p) external {
        if (msg.sender != owner && !(p && pokers[msg.sender])) revert NotPokerOrOwner();
        paused = p;
        emit Paused(p);
    }

    /// @notice Classic two-step transfer: the deployer names the Safe, the
    ///         Safe accepts. Until it accepts, the deployer stays owner.
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

    /// @notice Re-arm the probe on `adapter`: clears the one-ladder lock after
    ///         a completed run, or abandons a stalled ladder (e.g. a venue that
    ///         will not release the small leg). Raised idle goes back to the
    ///         liquidity adapter when the vault holds it; whatever is still
    ///         allocated to the adapter stays there — vault money in a
    ///         registered strategy.
    function reset(address adapter) external onlyOwner {
        Ladder memory l = openLadders[adapter];
        bool wasDone = ladderCompleted[adapter];
        if (l.nextLeg == 0 && !wasDone) revert NothingToReset(adapter);
        uint256 returned;
        if (l.idleRaised > 0) {
            address liq = vault.liquidityAdapter();
            uint256 idle = asset.balanceOf(address(vault));
            returned = l.idleRaised < idle ? l.idleRaised : idle;
            if (liq != address(0) && returned > 0) allocator.allocate(liq, returned);
        }
        emit LadderReset(adapter, wasDone, l.nextLeg, l.heldInStrategy, returned);
        delete openLadders[adapter];
        ladderCompleted[adapter] = false;
    }

    // ---- the ladder ---------------------------------------------------------

    /// @notice The next leg only. Opens a ladder on the first call, closes it
    ///         after the fourth. `nextLeg(adapter)` says where it stands;
    ///         no call can execute any leg other than the next one. A leg
    ///         that reverts leaves the ladder where it was: retry later.
    function runNextLeg(address adapter) external onlyPoker returns (uint8 leg, uint256 residual) {
        Ladder storage l = openLadders[adapter];
        if (l.nextLeg == 0) _openLadder(adapter);
        leg = openLadders[adapter].nextLeg;
        _runLeg(adapter, leg);
        if (leg == 4) residual = _closeLadder(adapter);
        else openLadders[adapter].nextLeg = leg + 1;
    }

    function nextLeg(address adapter) external view returns (uint8) {
        return openLadders[adapter].nextLeg;
    }

    function _openLadder(address adapter) internal {
        Ladder storage l = openLadders[adapter];
        if (ladderCompleted[adapter]) revert LadderAlreadyCompleted(adapter);
        if (!vault.isAdapter(adapter)) revert NotAdapter(adapter);
        l.nextLeg = 1;
        l.openedAt = uint64(block.timestamp);
        l.openedBy = msg.sender;
        l.bookedAtOpen = vault.allocation(IMYTStrategyLite(adapter).adapterId());
        l.realAssetsAtOpen = IMYTStrategyLite(adapter).realAssets();
    }

    function _runLeg(address adapter, uint8 leg) internal {
        Ladder storage l = openLadders[adapter];
        bytes32 id = IMYTStrategyLite(adapter).adapterId();
        bool isAllocate = (leg == 1 || leg == 3);
        uint256 amount;
        if (isAllocate) {
            amount = (leg == 1) ? SMALL_LEG : LARGE_LEG;
            l.idleRaised += _raiseIdle(amount, adapter);
            uint256 landed = _moveAndCheck(adapter, id, leg, true, amount);
            // what physically landed, never more than asked: the next
            // deallocate can only take this out
            l.heldInStrategy = landed < amount ? landed : amount;
        } else {
            // the measured put-in minus the buffer: venues that return a
            // little less than asked would otherwise revert the exit
            amount = l.heldInStrategy - l.heldInStrategy * exitBufferBps(adapter) / 10_000;
            l.heldInStrategy = 0;
            _moveAndCheck(adapter, id, leg, false, amount);
        }
    }

    function _closeLadder(address adapter) internal returns (uint256 residual) {
        Ladder memory l = openLadders[adapter];
        bytes32 id = IMYTStrategyLite(adapter).adapterId();
        // return the idle raised from the liquidity adapter, bounded by what
        // the vault holds now
        // (the buffers may have left a little in the strategy)
        uint256 returned;
        if (l.idleRaised > 0) {
            uint256 idle = asset.balanceOf(address(vault));
            returned = l.idleRaised < idle ? l.idleRaised : idle;
            if (returned > 0) allocator.allocate(vault.liquidityAdapter(), returned);
        }
        // what the adapter physically holds now vs before leg 1. Atomic: only
        // share-rounding dust. Stepwise across blocks: dust plus the interest
        // the venue accrued meanwhile. Either way the vault must not have
        // LOST more than the tolerance on SMALL_LEG; gains are reported, not judged.
        uint256 endReal = IMYTStrategyLite(adapter).realAssets();
        if (endReal + SMALL_LEG * toleranceBps(adapter) / 10_000 < l.realAssetsAtOpen) revert RealAssetsLost(l.realAssetsAtOpen, endReal);
        residual = endReal > l.realAssetsAtOpen ? endReal - l.realAssetsAtOpen : 0;
        emit LadderCompleted(adapter, id, l.openedBy, l.idleRaised, returned, residual);
        delete openLadders[adapter];
        ladderCompleted[adapter] = true;       // locked until the owner resets
    }

    /// @return moved the absolute physical change in the adapter's realAssets
    function _moveAndCheck(address adapter, bytes32 id, uint8 leg, bool isAllocate, uint256 amount)
        internal
        returns (uint256 moved)
    {
        uint256 allocBefore = vault.allocation(id);
        uint256 realBefore = IMYTStrategyLite(adapter).realAssets();
        if (isAllocate) {
            allocator.allocate(adapter, amount);
        } else {
            allocator.deallocate(adapter, amount);
        }
        uint256 allocAfter = vault.allocation(id);
        uint256 realAssetsAfter = IMYTStrategyLite(adapter).realAssets();
        int256 dAlloc = int256(allocAfter) - int256(allocBefore);
        int256 dReal = int256(realAssetsAfter) - int256(realBefore);
        int256 want = isAllocate ? int256(amount) : -int256(amount);
        int256 tol = int256(amount * toleranceBps(adapter) / 10_000);
        // realAssets is the physical truth: it must move by the leg, both ways
        if (dReal < want - tol || dReal > want + tol) revert RealAssetsMismatch(leg, amount, dReal);
        // the vault's booking catches up on ALL unbooked yield or loss since
        // the adapter's last touch (sfrxETH booked −0.3 ETH of oracle drift
        // on a 0.001 ETH leg), so its delta is reported, never judged
        emit LegExecuted(adapter, id, leg, isAllocate, amount, dReal, dAlloc, realAssetsAfter);
        moved = dReal >= 0 ? uint256(dReal) : uint256(-dReal);
    }

    function _raiseIdle(uint256 needed, address target) internal returns (uint256 idleRaised) {
        uint256 idle = asset.balanceOf(address(vault));
        if (idle >= needed) return 0;
        address liq = vault.liquidityAdapter();
        // probing the liquidity adapter itself: nothing to raise from. The
        // raise/return moves on the liquidity adapter are exempt from the
        // one-ladder lock: bounded by LARGE_LEG per ladder, returned at close
        // (leg 4) or on a Safe reset; until then it sits idle in the vault.
        if (liq == address(0) || liq == target) revert IdleUnavailable(needed, idle, liq);
        idleRaised = needed - idle;
        allocator.deallocate(liq, idleRaised);
    }
}