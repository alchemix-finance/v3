/*
 * MYT Conservation Spec — VaultV2 (Morpho V2 Vault) formal verification.
 *
 * Target: MYTSceneHarness (inherits the REAL VaultV2).
 *
 * The vault is verified with two MockStrategy adapters that the prover
 * can inject arbitrary yield or loss into, exercising the full range
 * of real vault behavior: interest accrual, fee minting, allocation
 * cap enforcement, and share-price dynamics.
 *
 * Invariant categories:
 *   FEE   — Fee parameter bounds & fee-recipient invariant
 *   RATE  — maxRate & force-deallocate penalty bounds
 *   CAP   — Relative cap ≤ WAD
 *   SHARE — Share price positivity & ERC4626 round-trip  (rules)
 *   ASSET — Total-assets bounded by real assets            (rule)
 *   ALLOC — Allocation & cap consistency
 */

methods {
    // --- VaultV2 state getters ---
    function performanceFee() external returns (uint96) envfree;
    function performanceFeeRecipient() external returns (address) envfree;
    function managementFee() external returns (uint96) envfree;
    function managementFeeRecipient() external returns (address) envfree;
    function maxRate() external returns (uint64) envfree;
    function totalSupply() external returns (uint256) envfree;
    function _totalAssets() external returns (uint128) envfree;
    function relativeCap(bytes32) external returns (uint256) envfree;
    function absoluteCap(bytes32) external returns (uint256) envfree;
    function allocation(bytes32) external returns (uint256) envfree;
    function forceDeallocatePenalty(address) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) optional;
    function convertToShares(uint256) external returns (uint256) optional;
    function balanceOf(address) external returns (uint256) envfree;
    function strategy0() external returns (address) envfree;
    function strategy1() external returns (address) envfree;
    function ZERO_ADDRESS() external returns (address) envfree;

    // --- Harness helpers ---
    function __adapterId(uint256) external returns (bytes32) envfree;
    function __idleBalance() external returns (uint256) envfree;
    function __strategyRealAssets(uint256) external returns (uint256) envfree;
    function __totalRealAssets() external returns (uint256) envfree;
    function __MAX_PERFORMANCE_FEE() external returns (uint256) envfree;
    function __MAX_MANAGEMENT_FEE() external returns (uint256) envfree;
    function __MAX_MAX_RATE() external returns (uint256) envfree;
    function __MAX_FORCE_DEALLOCATE_PENALTY() external returns (uint256) envfree;
    function FEE_RECIPIENT() external returns (address) envfree;
}

/* =======================================================================
 * FEE — Fee parameter bounds
 * ===================================================================== */

/// Performance fee can never exceed 50 % (MAX_PERFORMANCE_FEE).
/// Enforced by setPerformanceFee's require.
invariant performanceFeeBounded()
    performanceFee() <= __MAX_PERFORMANCE_FEE();

/// Management fee can never exceed 5 %/yr (MAX_MANAGEMENT_FEE).
/// Enforced by setManagementFee's require.
invariant managementFeeBounded()
    managementFee() <= __MAX_MANAGEMENT_FEE();

/// Fee invariant: a non-zero fee always has a non-zero recipient.
/// Enforced on every fee and recipient setter via FeeInvariantBroken.
invariant performanceFeeRecipientSet()
    performanceFee() == 0 || performanceFeeRecipient() != ZERO_ADDRESS();

invariant managementFeeRecipientSet()
    managementFee() == 0 || managementFeeRecipient() != ZERO_ADDRESS();

/* =======================================================================
 * RATE — maxRate & force-deallocate penalty bounds
 * ===================================================================== */

/// maxRate can never exceed 200 % APR (MAX_MAX_RATE).
/// Enforced by setMaxRate's require.
invariant maxRateBounded()
    maxRate() <= __MAX_MAX_RATE();

/// Force-deallocate penalty can never exceed 2 % per adapter.
/// Enforced by setForceDeallocatePenalty's require.
invariant forceDeallocPenaltyBounded0()
    forceDeallocatePenalty(strategy0()) <= __MAX_FORCE_DEALLOCATE_PENALTY();

invariant forceDeallocPenaltyBounded1()
    forceDeallocatePenalty(strategy1()) <= __MAX_FORCE_DEALLOCATE_PENALTY();

/* =======================================================================
 * CAP — Relative cap bounds
 * ===================================================================== */

/// Relative cap is always ≤ WAD (100 %).
/// Enforced by increaseRelativeCap's require.
invariant relativeCapBounded0()
    relativeCap(__adapterId(0)) <= 1000000000000000000;

invariant relativeCapBounded1()
    relativeCap(__adapterId(1)) <= 1000000000000000000;

/* =======================================================================
 * SHARE — Share price positivity & ERC4626 round-trip (rules)
 *
 * These are rules because convertToAssets/convertToShares read
 * block.timestamp (non-envfree) and invariants cannot pass env.
 * ===================================================================== */

/// Share price is always positive when shares exist AND the vault has assets.
/// The +1 virtual-asset offset guarantees this as long as totalAssets > 0.
/// When totalAssets == 0 (all strategies lost everything), shares are
/// worthless — this is expected, not a bug.
rule sharePricePositiveWhenSupplyPositive(method f, calldataarg args, env e) {
    f@withrevert(e, args);
    assert lastReverted || totalSupply() == 0
        || currentContract.totalAssets(e) == 0
        || convertToAssets(e, 1000000000000000000) > 0,
        "share price must be positive when supply > 0 and assets > 0";
}

/// ERC4626 round-trip: converting shares → assets → shares never
/// increases the original amount (floor division is contractive).
rule convertRoundTripNonExpanding(method f, calldataarg args, env e, uint256 shares) {
    f@withrevert(e, args);
    assert lastReverted || convertToShares(e, convertToAssets(e, shares)) <= shares,
        "round-trip must not expand";
}

/* =======================================================================
 * ASSET — Total-assets bounded by real assets (rule)
 * ===================================================================== */

/// totalAssets() = min(realAssets, maxTotalAssets), so it is always
/// ≤ the sum of idle balance + all adapter realAssets().
/// This ensures the vault never reports more assets than actually exist.
rule totalAssetsBoundedByReal(method f, calldataarg args, env e) {
    f@withrevert(e, args);
    assert lastReverted || currentContract.totalAssets(e) <= __totalRealAssets(),
        "totalAssets must not exceed real assets";
}

/* =======================================================================
 * ALLOC — Allocation cap consistency
 * ===================================================================== */

/// Relative cap for each adapter is always ≤ WAD (checked above).
/// Note: absoluteCap can be decreased below current allocation by
/// decreaseAbsoluteCap (only requires cap is non-increasing), so
/// "allocation > 0 implies absoluteCap > 0" is NOT a valid invariant.
