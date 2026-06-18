/*
 * Proof #2 — debt/underlying normalization round-trip exactness
 *
 * Target:
 *   AlchemistV3.normalizeUnderlyingTokensToDebt  (view, src/AlchemistV3.sol:916)
 *     amount * underlyingConversionFactor
 *   AlchemistV3.normalizeDebtTokensToUnderlying  (view, src/AlchemistV3.sol:921)
 *     amount / underlyingConversionFactor
 *
 * The conversion factor is a power of 10 set once in initialize() and is >= 1
 * (debt decimals >= underlying decimals). We prove:
 *
 *   (A) normalizeDebtTokensToUnderlying(normalizeUnderlyingTokensToDebt(x)) == x
 *       exactly (multiplication by f then floor-division by f is a no-op when
 *       no overflow occurs), and
 *   (B) normalizeUnderlyingTokensToDebt(normalizeDebtTokensToUnderlying(x)) <= x
 *       (floor division loses at most the remainder).
 *
 * The view functions read a single storage slot and no env, so they are
 * envfree. The harness lets the prover set `underlyingConversionFactor`.
 */


methods {
    function normalizeUnderlyingTokensToDebt(uint256) external returns (uint256) envfree;
    function normalizeDebtTokensToUnderlying(uint256) external returns (uint256) envfree;
    function underlyingConversionFactor() external returns (uint256) envfree;
}

/*
 * Rule A: underlying -> debt -> underlying is an exact identity.
 * x * f is always a multiple of f, so the trailing division is lossless.
 */
rule roundTrip_underlying_exact(uint256 x) {
    uint256 f = underlyingConversionFactor();
    require f >= 1;
    // exclude only overflow-reverting inputs (x * f overflows uint256)
    require to_mathint(x) * f <= max_uint256;

    uint256 asDebt = normalizeUnderlyingTokensToDebt(x);
    uint256 back = normalizeDebtTokensToUnderlying(asDebt);

    assert back == x, "underlying->debt->underlying must be the identity";
}

/*
 * Rule B: debt -> underlying -> debt never exceeds the original (floor division
 * rounds the intermediate down, so multiplying back can at most recover x).
 */
rule roundTrip_debt_nonExpanding(uint256 x) {
    uint256 f = underlyingConversionFactor();
    require f >= 1;

    uint256 asUnderlying = normalizeDebtTokensToUnderlying(x);
    // asUnderlying <= x / 1 = x, and asUnderlying * f <= x * f; guard overflow:
    require to_mathint(asUnderlying) * f <= max_uint256;

    uint256 back = normalizeUnderlyingTokensToDebt(asUnderlying);

    assert back <= x, "debt->underlying->debt must never exceed the original";
}
