# Certora reuse map

Baseline: `origin/certora` at `46c54a8f508f62fe4f0c82d65979655ac431b50e`.
Current source: `4891f80565911f88eed9e9410e5109439d988e5b`.

The branch contains 38 active declarations: 20 for Alchemist, 12 for MYT and six for Transmuter.
The global specification contains candidate comments only. It has no executable rules or integration harness.
No committed or local proof result was found. A specification declaration is not a completed proof.

## Reuse decisions

| Specification | Existing property | Action | Planned suite | Reason |
|---|---|---|---|---|
| `alchemist.spec` | `mytSharesDepositedLeBalance` | `REUSE_PROPERTY` | `AlchemistAccountingSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `storedCollateralLeGlobalShares` | `REASSESS` | `AlchemistAccountingSymbolic.t.sol` | Local account storage can lag global redemption. Distinguish stored, projected and synchronized state before asserting bounds. |
| `alchemist.spec` | `pendingCoverBoundedByTransmuterBalance` | `REASSESS_CHANGED_CODE` | `AlchemistCoverSymbolic.t.sol` | Current setTransmuterTokenBalance records positive inflow deltas and no longer clamps cover after outflows. Replace the old balance invariant with a justified sequence property. |
| `alchemist.spec` | `syntheticsLeDebtTokenSupply` | `REASSESS_EXTERNAL_SUPPLY` | `AlchemistAccountingSymbolic.t.sol` | Actual debt token includes bridging and public burn behavior. Tie this relation to a stated supply model and test the real token surface. |
| `alchemist.spec` | `syntheticsGeqLocked` | `REUSE_PROPERTY` | `AlchemistAccountingSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `storedDebtLeTotalDebt` | `REASSESS` | `AlchemistAccountingSymbolic.t.sol` | Local account storage can lag global redemption. Distinguish stored, projected and synchronized state before asserting bounds. |
| `alchemist.spec` | `cumulativeEarmarkedLeTotalDebt` | `REUSE_PROPERTY` | `AlchemistAccountingSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `storedEarmarkedLeStoredDebt` | `REUSE_PROPERTY` | `AlchemistAccountingSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `earmarkWeightPositive` | `REASSESS` | `AlchemistWeightLemmas.t.sol` | Check packed weight normalization, zero index and epoch rollover. Positivity of packed values must follow actual reachable paths. |
| `alchemist.spec` | `redemptionWeightPositive` | `REASSESS` | `AlchemistWeightLemmas.t.sol` | Check packed weight normalization, zero index and epoch rollover. Positivity of packed values must follow actual reachable paths. |
| `alchemist.spec` | `protocolFeeLeBps` | `REUSE_PROPERTY` | `AlchemistAdminSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `liquidatorFeeLeBps` | `REUSE_PROPERTY` | `AlchemistAdminSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `repaymentFeeLeBps` | `REUSE_PROPERTY` | `AlchemistAdminSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `cvSoundMint` | `REUSE_PROPERTY` | `AlchemistBorrowSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `cvSoundWithdraw` | `REUSE_PROPERTY` | `AlchemistDepositSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `debtToBurn_le_debt` | `REUSE_PROPERTY` | `AlchemistLiquidationLemmas.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `grossCollateralToSeize_le_collateral` | `REUSE_PROPERTY` | `AlchemistLiquidationLemmas.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `surplus_branch_decomposition` | `REUSE_PROPERTY` | `AlchemistLiquidationLemmas.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `roundTrip_underlying_exact` | `REUSE_PROPERTY` | `AlchemistConversionSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `alchemist.spec` | `roundTrip_debt_nonExpanding` | `REUSE_PROPERTY` | `AlchemistConversionSymbolic.t.sol` | Port the existing property to current bytecode with reachable setup and explicit success paths. |
| `myt.spec` | `performanceFeeBounded` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `managementFeeBounded` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `performanceFeeRecipientSet` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `managementFeeRecipientSet` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `maxRateBounded` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `forceDeallocPenaltyBounded0` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `forceDeallocPenaltyBounded1` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `relativeCapBounded0` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `relativeCapBounded1` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `sharePricePositiveWhenSupplyPositive` | `REASSESS` | `VaultV2IntegrationSymbolic.t.sol` | Integer conversion may round a chosen share amount to zero even when assets and supply are positive. Check this specification before reuse. |
| `myt.spec` | `convertRoundTripNonExpanding` | `REUSE_PROPERTY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 source is unchanged. Reuse the existing two-adapter harness assumptions and retain dependency claims separately from v3 strategy claims. |
| `myt.spec` | `totalAssetsBoundedByReal` | `QUALIFY_TRANSACTION_BOUNDARY` | `VaultV2IntegrationSymbolic.t.sol` | VaultV2 returns cached assets after firstTotalAssets is set within a transaction. Require a fresh transaction or state the cache condition before comparing to current strategy assets. |
| `transmuter.spec` | `transmutationFeeLeBps` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |
| `transmuter.spec` | `exitFeeLeBps` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |
| `transmuter.spec` | `timeToTransmutePositive` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |
| `transmuter.spec` | `totalLockedLeSyntheticsIssued` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |
| `transmuter.spec` | `activeLockedLeTotalLocked` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |
| `transmuter.spec` | `syntheticBalanceCoversLocked` | `REUSE_PROPERTY` | `TransmuterSymbolic.t.sol` | Transmuter source is unchanged from the Certora branch. Reuse the property and mock setup, then validate composition with real Alchemist. |

## Harness corrections before reuse

1. `MYTSceneHarness.sol:51` omits the boolean argument when it encodes `setIsAllocator(address,bool)`.
2. `AlchemistV3SceneHarness.sol:245` reverses the `amount` and `recipientId` arguments to `burn`.
3. Scene wrappers use fixed callers. Extend actor coverage before using them for authorization claims.
4. Move constructor calls to external self methods into post-deployment setup before using the MYT harness in the EVM.
5. VaultAnchor uses BPS fees and omits production virtual shares. Keep it as an explicit model, not production vault evidence.
6. Recheck every storage slot against compiler output. Slots 26 through 34 and account offsets 0 through 2 match the current layout.

Both call defects exist in the Certora branch. They are harness issues, not findings against production contracts.
Reuse setup and read helpers after correction. Keep the original property names in test documentation and result records.

## Changes since the baseline

Current Alchemist code changes redemption dust handling and cover accounting during balance updates, liquidation and self-liquidation.
The old cover-balance invariant needs reassessment. Local stored balances can lag global redemptions until an account sync.
Current strategy code changes ERC4626, Etherfi and Toke. StakeDAO and YearnV3 strategies are new relative to the Certora baseline.
Transmuter and VaultV2 source match the baseline. Reuse their existing specifications before adding coverage.

## Global candidates

Do not assume the commented candidate equalities hold. Donations can make a token balance exceed tracked deposits.
External token burns and bridge operations can change supply without the same change in protocol-issued accounting.
Separate fee caps do not establish a cap on their sum. Test the actual claim branches and token conservation.

## Sources

- [Certora baseline](https://github.com/alchemix-finance/v3/tree/46c54a8f508f62fe4f0c82d65979655ac431b50e/certora)
- [Current source](https://github.com/alchemix-finance/v3/tree/4891f80565911f88eed9e9410e5109439d988e5b/src)
