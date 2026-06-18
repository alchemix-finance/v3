/*
 * Proof #1 — calculateLiquidation output bounds
 *
 * Target: AlchemistV3.calculateLiquidation (public pure, src/AlchemistV3.sol:774)
 *
 * We prove that, for any inputs on which the function returns normally (i.e. no
 * Solidity 0.8 multiplication overflow), the outputs never exceed the supplied
 * collateral / debt:
 *
 *   (1) debtToBurn             <= debt
 *   (2) grossCollateralToSeize <= collateral
 *   (3) in the surplus branch: grossCollateralToSeize == debtToBurn + fee
 *       and fee == (surplus * feeBps) / BPS, where surplus = collateral - debt
 *
 * These are the core safety guarantees of a liquidation: the protocol never
 * burns more debt than is owed and never seizes more collateral than exists.
 *
 * The functions are pure, so they are marked envfree and need no harness state.
 * The `require`s below only exclude inputs that would cause a 0.8 revert
 * (multiplication overflow) — they impose no unrealistic value bounds.
 */


methods {
    function calcLiquidation_debtToBurn(uint256, uint256, uint256, uint256, uint256, uint256)
        external returns (uint256) envfree;
    function calcLiquidation_grossCollateralToSeize(uint256, uint256, uint256, uint256, uint256, uint256)
        external returns (uint256) envfree;
    function calcLiquidation_fee(uint256, uint256, uint256, uint256, uint256, uint256)
        external returns (uint256) envfree;
}

/*
 * Rule A: debtToBurn never exceeds the supplied debt.
 */
rule debtToBurn_le_debt(
    uint256 collateral,
    uint256 debt,
    uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization,
    uint256 alchemistMinimumCollateralization,
    uint256 feeBps
) {
    // exclude only overflow-reverting inputs (use unbounded mathint here)
    require to_mathint(debt) * feeBps <= max_uint256;
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;

    uint256 debtToBurn = calcLiquidation_debtToBurn(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );

    assert debtToBurn <= debt, "calculateLiquidation: debtToBurn must never exceed debt";
}

/*
 * Rule B: gross collateral seized never exceeds the supplied collateral.
 */
rule grossCollateralToSeize_le_collateral(
    uint256 collateral,
    uint256 debt,
    uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization,
    uint256 alchemistMinimumCollateralization,
    uint256 feeBps
) {
    require to_mathint(debt) * feeBps <= max_uint256;
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;

    uint256 grossCollateralToSeize = calcLiquidation_grossCollateralToSeize(
        collateral, debt, targetCollateralization,
        alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
    );

    assert grossCollateralToSeize <= collateral,
        "calculateLiquidation: grossCollateralToSeize must never exceed collateral";
}

/*
 * Rule C: in the surplus branch (collateral > debt, not the high-LTV path),
 * the seized collateral decomposes exactly as debtToBurn + fee, and the fee is
 * the configured fraction of the surplus.
 */
rule surplus_branch_decomposition(
    uint256 collateral,
    uint256 debt,
    uint256 targetCollateralization,
    uint256 alchemistCurrentCollateralization,
    uint256 alchemistMinimumCollateralization,
    uint256 feeBps
) {
    require collateral > debt;                                    // surplus exists
    require alchemistCurrentCollateralization >= alchemistMinimumCollateralization; // not the high-LTV branch
    require to_mathint(collateral) * feeBps <= max_uint256;
    require to_mathint(targetCollateralization) * debt <= max_uint256;

    mathint surplus = to_mathint(collateral) - debt;

    uint256 grossCollateralToSeize = calcLiquidation_grossCollateralToSeize(
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

    // Either nothing is liquidated, or the seize equals debt-to-burn plus fee
    // and the fee is the configured fraction of the surplus.
    assert (grossCollateralToSeize == 0 && debtToBurn == 0)
        || (grossCollateralToSeize == debtToBurn + fee
            && fee == (surplus * feeBps) / 10000),
        "calculateLiquidation: surplus branch must decompose gross = debtToBurn + fee";
}
