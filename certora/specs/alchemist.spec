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

using AlchemistV3SceneHarness as alch;
using VaultAnchor as vaultC;
using DebtTokenAnchor as debtC;
using TransmuterAnchor as transC;
using AlchemistV3Position as positionNftC;

links {
    alch.myt => vaultC;
    alch.debtToken => debtC;
    alch.transmuter => transC;
    alch.vault => vaultC;
    alch.debtTokenAnchor => debtC;
    alch.transmuterAnchor => transC;
    alch.alchemistPositionNFT => positionNftC;
}

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
    function REDEMPTION_DUST_THRESHOLD() external returns (uint256) envfree;

    // --- batchLiquidate excluded via --exclude_method (array-param loop,
    //     same pattern as multicall in MYT) ---

    // --- AlchemistV3Position: HAVOC_ALL over-approximates the ERC721
    //     return values (e.g. ownerOf). This is intentional — it
    //     strengthens verification by exploring both authorized and
    //     unauthorized access paths. Induction tasks for Position's own
    //     functions are excluded via --exclude_rule. ---
    function AlchemistV3Position.ownerOf(uint256) external returns (address) => HAVOC_ALL;
    function AlchemistV3Position.transferFrom(address,address,uint256) external => HAVOC_ALL;
    function AlchemistV3Position.safeTransferFrom(address,address,uint256) external => HAVOC_ALL;
    function AlchemistV3Position.safeTransferFrom(address,address,uint256,bytes) external => HAVOC_ALL;
    function AlchemistV3Position.approve(address,uint256) external => HAVOC_ALL;
    function AlchemistV3Position.setApprovalForAll(address,bool) external => HAVOC_ALL;
    function AlchemistV3Position.mint(address) external returns (uint256) => HAVOC_ALL;
    function AlchemistV3Position.burn(uint256) external => HAVOC_ALL;
    function AlchemistV3Position.setMetadataRenderer(address) external => HAVOC_ALL;
    function AlchemistV3Position.setAdmin(address) external => HAVOC_ALL;
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
 * RED — Redemption effective-amount bounding
 *
 * The fixed redeem() deliberately sweeps dust (up to REDEMPTION_DUST_THRESHOLD)
 * to the trusted transmuter on a near-full redemption, and reverts if it would
 * under-deliver by more. These rules verify that the debt actually burned
 * (effectiveRedeemed) never strays from the clamped requested amount by more
 * than the dust threshold:
 *
 *   RED-OVER  — effectiveRedeemed <= clampedAmount + REDEMPTION_DUST_THRESHOLD
 *   RED-UNDER — effectiveRedeemed >= clampedAmount - REDEMPTION_DUST_THRESHOLD
 *
 * clampedAmount = min(requestedAmount, liveEarmarked). Because redeem()
 * overwrites cumulativeEarmarked with remainingEarmarked, and _earmark() never
 * touches totalDebt, liveEarmarked is reconstructible from observable state:
 *     effectiveRedeemed = totalDebt_before - totalDebt_after
 *     liveEarmarked     = effectiveRedeemed + cumulativeEarmarked_after
 *
 * This holds both when the redemption branch runs (cumulativeEarmarked is set
 * to remainingEarmarked) and when it is skipped (effectiveRedeemed == 0 and
 * cumulativeEarmarked is left at liveEarmarked).
 * ===================================================================== */

rule redeem_overshoot_bounded(env e, uint256 requestedAmount) {
    require e.msg.sender == transmuter();

    uint256 totalDebtBefore = totalDebt();

    redeem@withrevert(e, requestedAmount);
    bool reverted = lastReverted;

    mathint effectiveRedeemed = to_mathint(totalDebtBefore) - to_mathint(totalDebt());
    mathint liveEarmarked = effectiveRedeemed + to_mathint(cumulativeEarmarked());
    mathint threshold = to_mathint(REDEMPTION_DUST_THRESHOLD());
    // clampedAmount = min(requestedAmount, liveEarmarked).
    mathint clampedAmount =
        to_mathint(requestedAmount) < liveEarmarked ? to_mathint(requestedAmount) : liveEarmarked;

    assert reverted || effectiveRedeemed <= clampedAmount + threshold,
        "RED-OVER: effectiveRedeemed overshoot exceeds dust threshold";
}

rule redeem_undershoot_bounded(env e, uint256 requestedAmount) {
    require e.msg.sender == transmuter();

    uint256 totalDebtBefore = totalDebt();

    redeem@withrevert(e, requestedAmount);
    bool reverted = lastReverted;

    mathint effectiveRedeemed = to_mathint(totalDebtBefore) - to_mathint(totalDebt());
    mathint liveEarmarked = effectiveRedeemed + to_mathint(cumulativeEarmarked());
    mathint threshold = to_mathint(REDEMPTION_DUST_THRESHOLD());
    mathint clampedAmount =
        to_mathint(requestedAmount) < liveEarmarked ? to_mathint(requestedAmount) : liveEarmarked;

    assert reverted || effectiveRedeemed >= clampedAmount - threshold,
        "RED-UNDER: effectiveRedeemed under-delivery exceeds dust threshold (revert guard bypassed)";
}

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
