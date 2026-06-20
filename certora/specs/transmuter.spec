/*
 * Transmuter Spec — production-level invariants for the Transmuter.
 *
 * Target: TransmuterSceneHarness (real Transmuter with mocked AlchemistV3,
 *         MYT, and synthetic token).
 *
 * The StakingGraph (Fenwick tree) is included as-is — it only affects
 * `queryGraph` (used by the Alchemist's earmark), not the Transmuter's
 * own conservation properties.
 *
 * Categories:
 *   FEE  — Fee parameter bounds
 *   CAP  — Deposit cap & synthetics consistency
 *   LOCK — totalLocked / totalActiveLocked conservation
 */

methods {
    // --- Transmuter state getters ---
    function exitFee() external returns (uint256) envfree;
    function transmutationFee() external returns (uint256) envfree;
    function depositCap() external returns (uint256) envfree;
    function totalLocked() external returns (uint256) envfree;
    function totalActiveLocked() external returns (uint256) envfree;
    function timeToTransmute() external returns (uint256) envfree;

    // --- Harness helpers ---
    function __totalSyntheticsIssued() external returns (uint256) envfree;
    function __syntheticBalance() external returns (uint256) envfree;
    function __BPS() external returns (uint256) envfree;
}

/* =======================================================================
 * FEE — Fee parameter bounds
 * ===================================================================== */

/// Transmutation fee can never exceed BPS (100 %).
/// Enforced by constructor and setTransmutationFee's _checkArgument.
invariant transmutationFeeLeBps()
    transmutationFee() <= __BPS();

/// Exit fee can never exceed BPS (100 %).
/// Enforced by constructor and setExitFee's _checkArgument.
invariant exitFeeLeBps()
    exitFee() <= __BPS();

/// timeToTransmute is always positive (never zero).
/// Enforced by constructor and setTransmutationTime's _checkArgument.
invariant timeToTransmutePositive()
    timeToTransmute() > 0;

/* =======================================================================
 * CAP — Synthetics consistency
 * ===================================================================== */

/// totalLocked can never exceed totalSyntheticsIssued.
/// Enforced in createRedemption: reverts if
///   totalLocked + amount > alchemist.totalSyntheticsIssued().
/// The mock Alchemist only decrements totalSyntheticsIssued via
/// reduceSyntheticsIssued, maintaining the coupling.
invariant totalLockedLeSyntheticsIssued()
    totalLocked() <= __totalSyntheticsIssued();

/* =======================================================================
 * LOCK — Locked amount conservation
 * ===================================================================== */

/// totalActiveLocked is always ≤ totalLocked.
/// Active locked is a subset of total locked.
/// Each createRedemption increments both equally.
/// pokeMatured only decrements totalActiveLocked.
/// claimRedemption decrements both (totalActiveLocked only if the
/// position still counts toward cap).
invariant activeLockedLeTotalLocked()
    totalActiveLocked() <= totalLocked();

/// The Transmuter always holds at least totalLocked synthetic tokens.
/// createRedemption transfers synthetics IN (amount) and increments
/// totalLocked by the same amount. claimRedemption transfers/burns
/// synthetics OUT and decrements totalLocked by the same amount.
/// The gap is preserved at every state transition.
invariant syntheticBalanceCoversLocked()
    __syntheticBalance() >= totalLocked();
