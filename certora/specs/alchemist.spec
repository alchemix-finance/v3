/*
 * Alchemist Spec — production-level invariants for AlchemistV3.
 *
 * Target: AlchemistV3SceneHarness (real AlchemistV3 with mocked MYT vault,
 *         debt token, and transmuter).
 *
 * Verified properties (each is enforced by the contract code and must
 * hold after every reachable state transition):
 *
 *   COLL  — Collateral conservation
 *   DEBT  — Debt & synthetics conservation
 *   EAR   — Earmark / redemption weight conservation
 *   CFG   — Configuration parameter bounds
 *   CV    — Collateralization soundness after mint / withdraw
 *   LIQ   — Liquidation math output bounds
 *   NORM  — Token normalization round-trip
 */

methods {
    // --- harness readers (private storage) ---
    function __mytSharesDeposited() external returns (uint256) envfree;
    function __pendingCoverShares() external returns (uint256) envfree;
    function __earmarkWeight() external returns (uint256) envfree;
    function __redemptionWeight() external returns (uint256) envfree;
    function __storedCollateral(uint256) external returns (uint256) envfree;
    function __storedDebt(uint256) external returns (uint256) envfree;
    function __storedEarmarked(uint256) external returns (uint256) envfree;

    // --- harness readers (anchor proxies) ---
    function __vaultBalanceOf(address) external returns (uint256) envfree;
    function __vaultTotalSupply() external returns (uint256) envfree;
    function __vaultPerformanceFee() external returns (uint96) envfree;
    function __vaultConvertToAssets(uint256) external returns (uint256) envfree;
    function __vaultConvertToShares(uint256) external returns (uint256) envfree;
    function __transmuterTotalLocked() external returns (uint256) envfree;
    function __debtTokenTotalSupply() external returns (uint256) envfree;

    // --- pure-function wrappers ---
    function calcLiquidation_debtToBurn(uint256,uint256,uint256,uint256,uint256,uint256)
        external returns (uint256) envfree;
    function calcLiquidation_grossCollateralToSeize(uint256,uint256,uint256,uint256,uint256,uint256)
        external returns (uint256) envfree;
    function calcLiquidation_fee(uint256,uint256,uint256,uint256,uint256,uint256)
        external returns (uint256) envfree;

    // --- contract public getters ---
    function cumulativeEarmarked() external returns (uint256) envfree;
    function totalDebt() external returns (uint256) envfree;
    function totalSyntheticsIssued() external returns (uint256) envfree;
    function transmuter() external returns (address) envfree;
    function minimumCollateralization() external returns (uint256) envfree;
    function liquidationTargetCollateralization() external returns (uint256) envfree;
    function protocolFee() external returns (uint256) envfree;
    function liquidatorFee() external returns (uint256) envfree;
    function repaymentFee() external returns (uint256) envfree;
    function underlyingConversionFactor() external returns (uint256) envfree;
    function convertYieldTokensToDebt(uint256) external returns (uint256) envfree;
    function normalizeUnderlyingTokensToDebt(uint256) external returns (uint256) envfree;
    function normalizeDebtTokensToUnderlying(uint256) external returns (uint256) envfree;
    function admin() external returns (address) envfree;
    function FEE_COLLECTOR() external returns (address) envfree;
    function ADMIN_ACTOR() external returns (address) envfree;

    // --- havoc (array-param function crashes points-to analysis) ---
    function batchLiquidate(uint256[]) external returns (uint256, uint256, uint256) => HAVOC_ALL;
}

/* =======================================================================
 * COLL — Collateral conservation
 * ===================================================================== */

invariant mytSharesDepositedLeBalance()
    __mytSharesDeposited() <= __vaultBalanceOf(currentContract);

invariant storedCollateralLeGlobalShares(uint256 tokenId)
    __storedCollateral(tokenId) <= __mytSharesDeposited();

invariant pendingCoverBoundedByTransmuterBalance()
    __pendingCoverShares() <= __vaultBalanceOf(transmuter());

/* =======================================================================
 * DEBT — Debt & synthetics conservation
 * ===================================================================== */

invariant syntheticsLeDebtTokenSupply()
    totalSyntheticsIssued() <= __debtTokenTotalSupply();

invariant syntheticsGeqLocked()
    totalSyntheticsIssued() >= __transmuterTotalLocked();

invariant storedDebtLeTotalDebt(uint256 tokenId)
    __storedDebt(tokenId) <= totalDebt();

/* =======================================================================
 * EAR — Earmark / redemption weight conservation
 * ===================================================================== */

invariant cumulativeEarmarkedLeTotalDebt()
    cumulativeEarmarked() <= totalDebt();

invariant storedEarmarkedLeStoredDebt(uint256 tokenId)
    __storedEarmarked(tokenId) <= __storedDebt(tokenId);

invariant earmarkWeightPositive()
    __earmarkWeight() > 0;

invariant redemptionWeightPositive()
    __redemptionWeight() > 0;

/* =======================================================================
 * CFG — Configuration parameter bounds (state invariants)
 * ===================================================================== */

invariant protocolFeeLeBps()       protocolFee() <= 10000;
invariant liquidatorFeeLeBps()     liquidatorFee() <= 10000;
invariant repaymentFeeLeBps()      repaymentFee() <= 10000;

/* =======================================================================
 * CV — Collateralization soundness (per-function rules)
 * ===================================================================== */

rule cvSoundMint(env e, uint256 tokenId, uint256 amount, address recipient) {
    mint@withrevert(e, tokenId, amount, recipient);
    assert lastReverted || (__storedDebt(tokenId) == 0
        || convertYieldTokensToDebt(__storedCollateral(tokenId)) * 1000000000000000000
           >= __storedDebt(tokenId) * minimumCollateralization()),
        "CV-SOUND: position undercollateralized after mint";
}

rule cvSoundWithdraw(env e, uint256 amount, address recipient, uint256 tokenId) {
    withdraw@withrevert(e, amount, recipient, tokenId);
    assert lastReverted || (__storedDebt(tokenId) == 0
        || convertYieldTokensToDebt(__storedCollateral(tokenId)) * 1000000000000000000
           >= __storedDebt(tokenId) * minimumCollateralization()),
        "CV-SOUND: position undercollateralized after withdraw";
}

/* =======================================================================
 * LIQ — Liquidation math output bounds (pure-function rules)
 * ===================================================================== */

rule debtToBurn_le_debt(
    uint256 collateral, uint256 debt, uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
) {
    require to_mathint(debt) * feeBps <= max_uint256;
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;
    require feeBps <= 10000;
    require targetCollateralization > 1000000000000000000;

    uint256 result = calcLiquidation_debtToBurn(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );
    assert result <= debt, "debtToBurn must never exceed debt";
}

rule grossCollateralToSeize_le_collateral(
    uint256 collateral, uint256 debt, uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
) {
    require to_mathint(debt) * feeBps <= max_uint256;
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;
    require feeBps <= 10000;
    require targetCollateralization > 1000000000000000000;

    uint256 result = calcLiquidation_grossCollateralToSeize(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );
    assert result <= collateral, "grossCollateralToSeize must never exceed collateral";
}

rule surplus_branch_decomposition(
    uint256 collateral, uint256 debt, uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
) {
    require collateral > debt;
    require alchemistCurrentCollateralization >= alchemistMinimumCollateralization;
    require targetCollateralization > 1000000000000000000;
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;

    mathint surplus = to_mathint(collateral) - debt;

    uint256 grossCollateral = calcLiquidation_grossCollateralToSeize(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );
    uint256 debtToBurn = calcLiquidation_debtToBurn(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );
    uint256 fee = calcLiquidation_fee(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );

    assert (grossCollateral == 0 && debtToBurn == 0)
        || (grossCollateral == debtToBurn + fee
            && fee == (surplus * feeBps) / 10000),
        "surplus branch must decompose gross = debtToBurn + fee";
}

/* =======================================================================
 * NORM — Token normalization round-trip (pure-function rules)
 * ===================================================================== */

rule roundTrip_underlying_exact(uint256 x) {
    uint256 f = underlyingConversionFactor();
    require f >= 1;
    require to_mathint(x) * f <= max_uint256;

    uint256 asDebt = normalizeUnderlyingTokensToDebt(x);
    uint256 back = normalizeDebtTokensToUnderlying(asDebt);
    assert back == x, "underlying->debt->underlying must be the identity";
}

rule roundTrip_debt_nonExpanding(uint256 x) {
    uint256 f = underlyingConversionFactor();
    require f >= 1;

    uint256 asUnderlying = normalizeDebtTokensToUnderlying(x);
    require to_mathint(asUnderlying) * f <= max_uint256;

    uint256 back = normalizeUnderlyingTokensToDebt(asUnderlying);
    assert back <= x, "debt->underlying->debt must never exceed the original";
}
