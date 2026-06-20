/*
 * Global Spec — cross-contract invariants spanning AlchemistV3,
 * Transmuter, and MYT (VaultV2).
 *
 * This is the integration-gate spec: all three REAL contracts are
 * deployed in one scene. It verifies properties that hold only when
 * the contracts interact correctly — properties that individual
 * specs (which mock the other two) cannot prove.
 *
 * Target: GlobalSceneHarness (deploys real AlchemistV3 + real Transmuter
 *         + real VaultV2 with mock strategies).
 *
 * Categories:
 *   SYNC  — totalSyntheticsIssued consistency across Alchemist ↔ Transmuter
 *   FLOW  — Value flow conservation across contract boundaries
 *   BOUND — Cross-contract parameter consistency
 */

/*
 * NOTE: This is a skeleton. The GlobalSceneHarness and full invariant
 * set will be implemented after the individual specs (alchemist,
 * transmuter, myt) are verified and stable. The harness needs to wire
 * all three real contracts together with mock strategies only.
 */

/*
 * Candidate global invariants:
 *
 * SYNC-1: Alchemist.totalSyntheticsIssued() == DebtToken.totalSupply()
 *         (maintained by mint/burn/reduceSyntheticsIssued)
 *
 * SYNC-2: Transmuter.totalLocked <= Alchemist.totalSyntheticsIssued()
 *         (maintained by createRedemption's check + reduceSyntheticsIssued)
 *
 * SYNC-3: Alchemist._mytSharesDeposited == VaultV2.balanceOf(Alchemist)
 *         (maintained by deposit/withdraw/redeem/liquidate)
 *
 * FLOW-1: Alchemist cumulativeEarmarked <= Alchemist totalDebt
 *         (same as alchemist.spec but verified in the integrated scene)
 *
 * FLOW-2: VaultV2 totalAssets == idle + sum(strategy.realAssets())
 *         (same as myt.spec but verified with real Alchemist as depositor)
 *
 * BOUND-1: Transmuter.transmutationFee + Transmuter.exitFee <= BPS
 *          (combined fee bound)
 */
