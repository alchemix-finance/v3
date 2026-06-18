// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AlchemistV3} from "../../src/AlchemistV3.sol";

/// @notice Test-only harness for Certora verification of AlchemistV3.
///
/// AlchemistV3 is an upgradeable contract: its `constructor() initializer {}`
/// permanently disables `initialize()` on the implementation, so a deployed
/// instance cannot be initialized normally. This harness bypasses that by
/// exposing minimal, state-only setters so that the prover can set up just the
/// storage needed for the targeted proofs. It does NOT alter the logic of any
/// verified function; every rule/invariant is checked against the real
/// AlchemistV3 code.
///
/// Setters that could weaken an in-progress proof are intentionally omitted.
/// For the proofs in this batch (calculateLiquidation bounds, normalization
/// round-trip, fee-setter bounds) none of the setters below touch the
/// quantities under verification.
contract AlchemistV3Harness is AlchemistV3 {
    /// @dev CVL only: set the debt<->underlying conversion factor directly.
    function setUnderlyingConversionFactor(uint256 v) external {
        underlyingConversionFactor = v;
    }

    /// @dev CVL only: set the admin address directly.
    function setAdmin(address a) external {
        admin = a;
    }

    // -----------------------------------------------------------------------
    // Pure passthrough wrappers for calculateLiquidation's four return values.
    // CVL cannot destructure multiple return values inline, so we expose one
    // single-return wrapper per field. Each forwards to the REAL
    // calculateLiquidation (no logic change), so the proofs cover the original
    // implementation.
    // -----------------------------------------------------------------------

    function calcLiquidation_grossCollateralToSeize(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        (uint256 grossCollateralToSeize, , , ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return grossCollateralToSeize;
    }

    function calcLiquidation_debtToBurn(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        ( , uint256 debtToBurn, , ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return debtToBurn;
    }

    function calcLiquidation_fee(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        ( , , uint256 fee, ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return fee;
    }
}
