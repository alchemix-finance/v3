/*
 * Collateralization Invariant Spec — position health and parameter bounds.
 *
 * Target: AlchemistV3SceneHarness (inheritance scene with typed anchors).
 *
 * Verifies:
 *   - Configuration parameters are in valid ranges at all times.
 *   - After a successful mint, the affected position satisfies the
 *     minimum-collateralization check (CV-SOUND).
 *   - After a successful withdraw, position health is maintained.
 *
 * Performance-fee interaction:
 *   Vault performance fee (≤ 5 %) dilutes convertToAssets, which can
 *   make previously-healthy positions undercollateralized — that is
 *   expected and triggers the bad-debt gate / liquidation path.
 */

methods {
    function minimumCollateralization() external returns (uint256) envfree;
    function liquidationTargetCollateralization() external returns (uint256) envfree;
    function protocolFee() external returns (uint256) envfree;
    function liquidatorFee() external returns (uint256) envfree;
    function repaymentFee() external returns (uint256) envfree;
    function underlyingConversionFactor() external returns (uint256) envfree;
    function __earmarkWeight() external returns (uint256) envfree;
    function __redemptionWeight() external returns (uint256) envfree;
    function __vaultPerformanceFee() external returns (uint96) envfree;
    function __storedCollateral(uint256) external returns (uint256) envfree;
    function __storedDebt(uint256) external returns (uint256) envfree;
    function convertYieldTokensToDebt(uint256) external returns (uint256) envfree;
}

/* =======================================================================
 * CFG-1: minimumCollateralization > 1e18 (always above 100 %).
 * ===================================================================== */
rule cfg_minCollatAboveOne(method f, calldataarg args, env e) {
    f(e, args);
    assert minimumCollateralization() > 1000000000000000000,
        "CFG-1: minCollateralization must be above 1e18";
}

/* =======================================================================
 * CFG-2: liquidationTargetCollateralization >= minimumCollateralization.
 * ===================================================================== */
rule cfg_liqTargetGeqMinCollat(method f, calldataarg args, env e) {
    f(e, args);
    assert liquidationTargetCollateralization() >= minimumCollateralization(),
        "CFG-2: liqTarget must be >= minCollateralization";
}

/* =======================================================================
 * CFG-3: Fee BPS within bounds.
 * ===================================================================== */
rule cfg_feeBounds(method f, calldataarg args, env e) {
    f(e, args);
    assert protocolFee() <= 10000, "protocolFee > BPS";
    assert liquidatorFee() <= 10000, "liquidatorFee > BPS";
    assert repaymentFee() <= 10000, "repaymentFee > BPS";
    assert __vaultPerformanceFee() <= 500, "vault perfFee > 500";
}

/* =======================================================================
 * CFG-4: Weights are positive.
 * ===================================================================== */
rule cfg_weightsPositive(method f, calldataarg args, env e) {
    f(e, args);
    assert __earmarkWeight() > 0, "earmarkWeight must be positive";
    assert __redemptionWeight() > 0, "redemptionWeight must be positive";
}

/* =======================================================================
 * CFG-5: underlyingConversionFactor == 1 (18/18 decimals).
 * ===================================================================== */
rule cfg_conversionFactorOne(method f, calldataarg args, env e) {
    f(e, args);
    assert underlyingConversionFactor() == 1,
        "conversionFactor must be 1";
}

/* =======================================================================
 * CV-SOUND: after a successful mint, the position's collateral covers
 * its debt at minimumCollateralization.
 * ===================================================================== */
rule cvSoundMint(method f, calldataarg args, env e) {
    f@withrevert(e, args);

    if (!lastReverted && f.selector == sig:mint(uint256, uint256)) {
        uint256 tokenId = args.arg1;
        uint256 storedCollateral = __storedCollateral(tokenId);
        uint256 storedDebt = __storedDebt(tokenId);

        if (storedDebt > 0) {
            uint256 collateralInDebt = convertYieldTokensToDebt(storedCollateral);
            assert collateralInDebt * 1000000000000000000
                >= storedDebt * minimumCollateralization(),
                "CV-SOUND: position undercollateralized after mint";
        }
    }
}

/* =======================================================================
 * CV-SOUND: after a successful withdraw, position health maintained.
 * ===================================================================== */
rule cvSoundWithdraw(method f, calldataarg args, env e) {
    f@withrevert(e, args);

    if (!lastReverted && f.selector == sig:withdraw(uint256, address, uint256)) {
        uint256 tokenId = args.arg2;
        uint256 storedCollateral = __storedCollateral(tokenId);
        uint256 storedDebt = __storedDebt(tokenId);

        if (storedDebt > 0) {
            uint256 collateralInDebt = convertYieldTokensToDebt(storedCollateral);
            assert collateralInDebt * 1000000000000000000
                >= storedDebt * minimumCollateralization(),
                "CV-SOUND: position undercollateralized after withdraw";
        }
    }
}
