# Codex Verification Report: Alchemix V3 Plamen Audit

## Scope And Method

This pass verifies the findings listed in `CODEX_VERIFICATION_PROMPT.md` against the code under `src/`.

I independently traced the cited execution paths instead of trusting the existing report or the included PoCs.

I also attempted to run the audit-specific Foundry tests, but the repository does not currently compile because required dependencies under `lib/` and `@openzeppelin` are missing from the checkout. That means the conclusions below are based on source review, not runtime execution.

## Summary Table

| ID | Verdict | Severity | Confidence | Notes |
|---|---|---|---|---|
| H-01 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | Debt/supply divergence is real; the permanent brick claim is overstated because `Transmuter` MYT is counted as backing |
| H-02 | CONFIRMED | AGREE | HIGH | Adapter fabricates `updatedAt = block.timestamp` |
| H-03 | PARTIALLY CONFIRMED | DISAGREE (suggest: Medium) | MEDIUM | Oracle inflation path is real, but the full extraction chain depends on external vault/oracle wiring |
| H-04 | CONFIRMED | DISAGREE (suggest: Medium) | HIGH | Missing protected-token override lets the owner rescue live `weETH` |
| H-05 | PARTIALLY CONFIRMED | DISAGREE (suggest: Medium) | MEDIUM | Retroactive liquidation risk is real; the brick chain depends on overstated H-01 logic |
| H-06 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | The math reverts in Solidity 0.8; not a silent overflow and not permanent |
| H-07 | CONFIRMED | DISAGREE (suggest: Medium) | HIGH | Gauge allocation is dead because `strategyList` is never populated |
| H-08 | CONFIRMED | DISAGREE (suggest: Medium) | HIGH | Same cap values are consumed as BPS in one place and absolute amounts in another |
| H-09 | REFUTED | DISAGREE (suggest: duplicate of M-26) | HIGH | Spread validation is distinct from H-02 and duplicates M-26 instead |
| M-10 | CONFIRMED | AGREE | HIGH | Silent clamp destroys local excess when drift already exists |
| M-11 | CONFIRMED | AGREE | HIGH | No fee snapshot on Transmuter positions |
| M-12 | REFUTED | DISAGREE (suggest: duplicate/operator trust only) | HIGH | `minIntermediateOut` is zeroed, but unused for `ActionType.swap` |
| M-13 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | Arbitrary target is true, but selector whitelist and operator gating remain |
| M-14 | CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | Immediate add/remove path exists, even though submit-based delayed path also exists |
| M-15 | CONFIRMED | DISAGREE (suggest: Low/Info) | HIGH | No adapter validation, but this is pure operator/admin trust |
| M-16 | CONFIRMED | DISAGREE (suggest: Info/Low) | HIGH | No event or delay on allowance-holder updates |
| M-17 | CONFIRMED | AGREE | HIGH | Collateralization parameters are retroactive and immediate |
| M-18 | CONFIRMED | AGREE | HIGH | Insolvent/global-stress liquidation can socialize liquidator fees through the fee vault |
| M-19 | CONFIRMED | DISAGREE (suggest: Low) | HIGH | Unbounded loop exists, but the caller supplies the array and self-OOGs |
| M-20 | CONFIRMED | DISAGREE (suggest: Info) | HIGH | Code fact is true, but the retired value is forwarded to `Transmuter` |
| M-21 | CONFIRMED | DISAGREE (suggest: Info) | HIGH | Same as M-20 for `_doLiquidation()` |
| M-22 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low) | MEDIUM | Deposit/mint gate exists, but normal liquidation does not create phantom bad debt |
| M-23 | CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | Vote removal uses the current balance, not the balance at vote time |
| M-24 | PARTIALLY CONFIRMED | DISAGREE (suggest: Info/Low) | MEDIUM | No `__gap`, but storage corruption is not automatic for every upgrade |
| M-25 | CONFIRMED | AGREE | HIGH | 7-day staleness window is explicitly coded |
| M-26 | CONFIRMED | AGREE | HIGH | Dual-oracle adapter never checks spread between `priceLow` and `priceHigh` |
| M-27 | CONFIRMED | AGREE | HIGH | No sequencer uptime guard in the in-scope oracle code |
| M-28 | REFUTED | DISAGREE | LOW | `_sync()` does update debt and earmarks; the report title does not match the code |
| M-29 | CONFIRMED | AGREE | HIGH | `ZeroXSwapVerifier` is dead code; `dexSwap()` never invokes it |
| M-30 | PARTIALLY CONFIRMED | DISAGREE (suggest: compound note, not separate finding) | MEDIUM | The scenario is plausible but is just H-02/H-03 plus operator-controlled calldata |
| M-31 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low/Medium) | HIGH | Unit mismatch is real, but not every `minAllocationOutBps > 0` reverts |
| M-32 | PARTIALLY CONFIRMED | DISAGREE (suggest: Low/Medium) | MEDIUM | The bound is real at `timeToTransmute = 1`, but failure is a revert, not silent corruption |
| M-33 | CONFIRMED | AGREE | HIGH | Duplicate restatement of M-11 |
| M-34 | CONFIRMED | DISAGREE (suggest: duplicate of M-27) | HIGH | Same missing sequencer check, framed as multi-chain confirmation |
| M-35 | CONFIRMED | DISAGREE (suggest: duplicate of M-13) | HIGH | Same selector-only permission model as M-13 |
| B5-7 | REFUTATION NOT VERIFIABLE | N/A | LOW | Original claim text not present in the repo |
| B5-3 | REFUTATION NOT VERIFIABLE | N/A | LOW | Original claim text not present in the repo |
| B1-5 | REFUTATION NOT VERIFIABLE | N/A | LOW | Original claim text not present in the repo |
| SC-4 | REFUTATION NOT VERIFIABLE | N/A | LOW | Original claim text not present in the repo |

## High Findings

## H-01 Phantom totalSyntheticsIssued After Liquidation
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `_mint()` increments `totalSyntheticsIssued` after `_addDebt()` increases `totalDebt` in `src/AlchemistV3.sol:919-924` and `1270-1283`.
- `burn()` decrements both `totalDebt` and `totalSyntheticsIssued` in `src/AlchemistV3.sol:512-543`.
- `reduceSyntheticsIssued()` also decrements supply, but only when called by `Transmuter`, in `src/AlchemistV3.sol:820-822`.
- `repay()`, `_forceRepay()`, `selfLiquidate()`, and `_doLiquidation()` all retire debt through `_subDebt()` without directly touching `totalSyntheticsIssued`, in `src/AlchemistV3.sol:554-600`, `943-984`, `745-769`, `1138-1230`, and `1289-1298`.
- `_isProtocolInBadDebt()` compares issued synthetics against backing equal to locked MYT in Alchemist plus MYT already held by `Transmuter`, in `src/AlchemistV3.sol:1704-1711`.

### Analysis
The accounting divergence is real: several debt-clearing paths reduce `totalDebt` without reducing `totalSyntheticsIssued`.

The report's impact claim is overstated. Those same paths also move MYT to `Transmuter`, and `_isProtocolInBadDebt()` explicitly counts `Transmuter` MYT as backing. So `totalDebt == 0` does not imply `backingDebt == 0`. The report's stated brick condition is therefore wrong as written.

### Impact Assessment
Normal liquidation, self-liquidation, and MYT repayment do not automatically brick the protocol. They can leave `totalSyntheticsIssued > totalDebt`, but that is consistent with synthetics still being in circulation and now backed by MYT in `Transmuter`.

The deposit/mint gate only trips when issued synthetics exceed total backing, which is actual bad debt, not phantom debt created by ordinary liquidations.

## H-02 Dual Oracle Timestamp Fabrication
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `FrxEthEthDualOracleAggregatorAdapter.latestRoundData()` calls `dualOracle.getPrices()`, averages `priceLow` and `priceHigh`, and returns `startedAt = block.timestamp` and `updatedAt = block.timestamp` in `src/FrxEthEthDualOracleAggregatorAdapter.sol:21-32`.
- `OraclePricedSwapStrategy._oracleAnswer()` trusts `updatedAt` from `latestRoundData()` and enforces `block.timestamp - updatedAt <= MAX_ORACLE_STALENESS` in `src/strategies/OraclePricedSwapStrategy.sol:130-135`.

### Analysis
The adapter does not propagate any upstream timestamp. It fabricates both timestamps from the current block time. That defeats downstream staleness checks whenever this adapter is used as `pricedTokenEthOracle`.

### Impact Assessment
If the upstream Frax dual oracle returns economically stale prices without setting `isBadData`, the strategy-level staleness guard will still pass, because the adapter always reports a fresh timestamp.

## H-03 Stale Oracle -> Inflated Collateral Chain
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Medium)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- `AlchemistV3.convertYieldTokensToUnderlying()` values MYT via `IVaultV2(myt).convertToAssets(amount)` in `src/AlchemistV3.sol:896-897`.
- `OraclePricedSwapStrategy._totalValue()` prices strategy TVL as idle assets plus `_oracleTokenToAsset(_positionBalance())` in `src/strategies/OraclePricedSwapStrategy.sol:102-118`.
- `SFraxETHStrategy` feeds oracle-priced `frxETH` value into strategy accounting while holding `sfrxETH` positions in `src/strategies/SFraxETHStrategy.sol:21-74`.

### Analysis
The stale timestamp bug in H-02 can propagate into strategy TVL. That much is real.

What is less certain from the in-repo code alone is the full end-to-end extraction claim: it depends on external vault accounting in `vault-v2` and on real deployment wiring. The repo checkout is missing that dependency, so the exact collateral-overvaluation magnitude is not fully provable from the available files.

### Impact Assessment
This is a legitimate risk extension of H-02, but it is better treated as a compound/derived issue than as an independently proven High by itself.

## H-04 EtherfiEETH Missing _isProtectedToken
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `MYTStrategy.rescueTokens()` blocks rescue only when `_isProtectedToken(token)` is true in `src/MYTStrategy.sol:184-190`.
- Base `_isProtectedToken()` only protects `MYT.asset()` in `src/MYTStrategy.sol:265-272`.
- `EtherfiEETHMYTStrategy` holds `weETH` as the strategy position via `_oracleToken()` and `_positionBalance()` in `src/strategies/EtherfiEETHStrategy.sol:104-115`.
- `EtherfiEETHMYTStrategy` does not override `_isProtectedToken()` anywhere in `src/strategies/EtherfiEETHStrategy.sol:1-118`.

### Analysis
This is a real privileged-footgun. The strategy's live position token is `weETH`, but the inherited protected-token list only covers the vault asset (`WETH`). That lets the owner use the generic rescue path to withdraw live strategy inventory.

### Impact Assessment
The issue is real, but it requires the privileged owner. That makes it more of an unexpected privileged-drain path than a permissionless High.

## H-05 Retroactive LowerBound -> Mass Liquidation -> Brick
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Medium)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- `setCollateralizationLowerBound()` can be called immediately by admin, with no delay, in `src/AlchemistV3.sol:322-327`.
- `_isAccountHealthy()` compares live ratio against `collateralizationLowerBound` in `src/AlchemistV3.sol:1124-1130`.

### Analysis
The retroactive parameter-change risk is real: admin can make previously healthy accounts liquidatable immediately.

The reported "permanent brick" consequence depends on H-01's overstated bad-debt logic. Since H-01 does not prove an automatic brick after normal liquidation flows, the chained High severity does not hold as written.

### Impact Assessment
This is a real governance/centralization risk, but the "single admin action irrecoverably bricks the protocol" conclusion is not established by the code.

## H-06 executeAllocation Overflow DoS
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `PerpetualGauge.executeAllocation()` computes `(indivCap * totalIdleAssets) / 1e4` and `(globalCap * totalIdleAssets) / 1e4` in `src/PerpetualGauge.sol:145-160`.
- `AlchemistStrategyClassifier` initializes all caps to `type(uint256).max` in `src/AlchemistStrategyClassifier.sol:35-38`.

### Analysis
With default caps unchanged, the multiplication can revert under Solidity 0.8 checked arithmetic.

The report overstates the failure mode. This is not a silent overflow, and it is not permanent because governance can set finite caps. Also, `executeAllocation()` first requires a non-empty `strategyList`, so H-07 often prevents reaching the overflow path at all.

### Impact Assessment
This is a real latent bug in the gauge path, but it is not a protocol-wide permanent DoS on its own.

## H-07 registerNewStrategy Is Unimplemented
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `registerNewStrategy()` only sets `lastStrategyAddedAt` and contains `// TODO` in `src/PerpetualGauge.sol:110-113`.
- `getCurrentAllocations()` and `executeAllocation()` both depend on `strategyList[ytId]` in `src/PerpetualGauge.sol:115-171`.
- No production code populates `strategyList`; repo search only found tests and PoCs touching the gauge.

### Analysis
This finding is correct: the gauge cannot function as designed because strategies are never registered into the list it later iterates over.

Severity is lower than reported because I found no production integration of `PerpetualGauge` in the repo; it appears unused outside tests and PoCs.

### Impact Assessment
If the gauge is meant to be live, allocation through it is dead. If it is vestigial or not deployed, the impact is mostly dead-code quality risk.

## H-08 Classifier Cap Semantic Mismatch
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `PerpetualGauge.executeAllocation()` treats caps as BPS by dividing by `1e4` in `src/PerpetualGauge.sol:152-160`.
- `AlchemistAllocator._validateCaps()` compares `getGlobalCap()` and `getIndividualCap()` directly as absolute amounts in `src/AlchemistAllocator.sol:128-171`.
- The shared interface comment explicitly says cap values may be "in bps or absolute" in `src/interfaces/IStrategyClassifier.sol:5-9`.

### Analysis
This is a real semantic mismatch across consumers of the same interface. The report is right on the design bug.

Severity is lower than reported because the gauge path itself appears unused and separately broken by H-07.

### Impact Assessment
If both consumers are ever used together, governance cannot supply one cap configuration that both interpret correctly.

## H-09 Oracle Spread Validation Missing
**VERDICT: REFUTED**  
**SEVERITY: DISAGREE (suggest: duplicate of M-26)**  
**CONFIDENCE: HIGH**

### Code Trace
- The dual-oracle adapter averages `priceLow` and `priceHigh` without any spread check in `src/FrxEthEthDualOracleAggregatorAdapter.sol:26-32`.

### Analysis
That missing spread validation is real, but it is not a duplicate of H-02. H-02 is about fabricated timestamps; spread validation is a separate control and is already captured by M-26.

### Impact Assessment
This should not stand as a separate High. It duplicates M-26's substance instead.

## Medium Findings

## M-10 _subCollateralBalance Silent Clamping
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `_subCollateralBalance()` clamps `account.collateralBalance` down to `_mytSharesDeposited` before subtraction in `src/AlchemistV3.sol:1015-1029`.

### Analysis
If local account storage exceeds the global MYT share total, the excess is simply deleted from the account and not redistributed anywhere.

### Impact Assessment
This is a real loss-allocation hazard when prior drift has already occurred.

## M-11 Transmuter Fee Retroactivity
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `setTransmutationFee()` updates the global fee with no delay in `src/Transmuter.sol:135-139`.
- `StakingPosition` stores only `amount`, `startBlock`, and `maturationBlock` in `src/interfaces/ITransmuter.sol:7-14`.
- `claimRedemption()` uses the live `transmutationFee` at claim time in `src/Transmuter.sol:264-278`.

### Analysis
There is no per-position fee snapshot. Existing locked positions are exposed to whatever fee is current when they claim.

### Impact Assessment
This is a real privileged policy risk on already-open positions.

## M-12 Operator Swap MEV via minIntermediateOut:0
**VERDICT: REFUTED**  
**SEVERITY: DISAGREE (suggest: duplicate/operator trust only)**  
**CONFIDENCE: HIGH**

### Code Trace
- `AlchemistAllocator.allocateWithSwap()` and `deallocateWithSwap()` do set `minIntermediateOut: 0` in `src/AlchemistAllocator.sol:63-95`.
- But `MYTStrategy.allocate()` and `MYTStrategy.deallocate()` ignore `minIntermediateOut` for `ActionType.swap`; it is only consumed for `ActionType.unwrapAndSwap` in `src/MYTStrategy.sol:65-119`.

### Analysis
The zero value exists in the struct, but it is not the active guard for the paths cited by the report. Allocation and one-hop deallocation use other swap checks, not `minIntermediateOut`.

### Impact Assessment
The specific reported MEV path is not established by the code. The remaining operator-calldata risk is better captured by M-29 and M-13.

## M-13 PermissionedProxy Arbitrary Target Calls
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `PermissionedProxy.proxy()` extracts a selector from calldata, checks `permissionedCalls[selector]`, then performs `vault.call(data)` to an arbitrary address in `src/utils/PermissionedProxy.sol:62-71`.

### Analysis
The arbitrary target observation is correct. But the report understates the remaining guards: only operators can call it, and the selector must be whitelisted.

### Impact Assessment
This is a real operator-risk/misconfiguration surface, not an unconstrained arbitrary-call vulnerability.

## M-14 Strategy Add/Remove Without Timelock
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `setStrategy()` and `removeStrategy()` act immediately in `src/AlchemistCurator.sol:32-46`.
- Separate delayed `submitSetStrategy()` and `submitRemoveStrategy()` paths also exist in `src/AlchemistCurator.sol:26-31` and `49-60`.

### Analysis
The report is right that there is an immediate path with no timelock.

### Impact Assessment
This is a privileged operational risk. It matters if the protocol relies on `submit*` flows socially rather than enforcing them on-chain.

## M-15 setLiquidityAdapter No Validation
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Info)**  
**CONFIDENCE: HIGH**

### Code Trace
- `setLiquidityAdapter()` forwards any adapter address and calldata to the vault with no validation in `src/AlchemistAllocator.sol:117-121`.

### Analysis
The code fact is correct. There is no adapter allowlist or interface validation here.

### Impact Assessment
Because the call is already restricted to admin/operators, this is mostly a privileged trust/configuration issue, not a standalone user-facing exploit.

## M-16 setAllowanceHolder No Event/Timelock
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Info/Low)**  
**CONFIDENCE: HIGH**

### Code Trace
- `setAllowanceHolder()` updates the address with only an `onlyOwner` check and no event in `src/MYTStrategy.sol:214-217`.

### Analysis
The report is correct on the code, but this is mostly governance hygiene.

### Impact Assessment
This is low-signal by itself. It matters more when combined with M-29's raw `allowanceHolder.call(callData)` behavior.

## M-17 Retroactive Collateralization Parameters
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `setMinimumCollateralization()`, `setGlobalMinimumCollateralization()`, `setCollateralizationLowerBound()`, and `setLiquidationTargetCollateralization()` are immediate admin actions in `src/AlchemistV3.sol:301-337`.

### Analysis
There is no timelock or grace-period logic in these setters. They immediately change health and liquidation thresholds.

### Impact Assessment
This is a real privileged parameter-retroactivity risk.

## M-18 calculateLiquidation Drains Fee Vault
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `calculateLiquidation()` returns `outsourcedFee = debt * feeBps / BPS` when `debt >= collateral` or when the system is globally undercollateralized in `src/AlchemistV3.sol:773-817`.
- `_doLiquidation()` pays that outsourced fee through `_payWithFeeVault()` in `src/AlchemistV3.sol:1163-1165` and `1225-1226`.
- `_payWithFeeVault()` pulls from the communal fee vault in `src/AlchemistV3.sol:1099-1115`.

### Analysis
This behavior is real. Insolvent or stressed liquidations can socialize liquidator incentives through the fee vault rather than the liquidated position.

### Impact Assessment
Whether this is intended design or not, it is a real cross-user cost surface.

## M-19 batchLiquidate Unbounded Loop Gas DoS
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low)**  
**CONFIDENCE: HIGH**

### Code Trace
- `batchLiquidate()` iterates over the full caller-supplied `accountIds` array with no length cap in `src/AlchemistV3.sol:619-650`.

### Analysis
The unbounded loop is real, but the caller chooses the array. An oversized array self-OOGs the caller's own transaction.

### Impact Assessment
This is an operational gas footgun, not a protocol-wide DoS.

## M-20 selfLiquidate Does Not Reduce totalSyntheticsIssued
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Info)**  
**CONFIDENCE: HIGH**

### Code Trace
- `selfLiquidate()` clears debt via `_subDebt()` and moves MYT to `Transmuter`, but never decrements `totalSyntheticsIssued`, in `src/AlchemistV3.sol:745-769`.

### Analysis
The report is correct on the code fact. It is not, by itself, proof of phantom issuance, because the retired value is simultaneously forwarded to `Transmuter` and still counts as backing under `_isProtocolInBadDebt()`.

### Impact Assessment
This is better treated as an accounting observation than a standalone Medium vulnerability.

## M-21 _doLiquidation Does Not Reduce totalSyntheticsIssued
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Info)**  
**CONFIDENCE: HIGH**

### Code Trace
- `_doLiquidation()` uses `_subDebt()` repeatedly and may move collateral to `Transmuter`, but never decrements `totalSyntheticsIssued`, in `src/AlchemistV3.sol:1138-1230`.

### Analysis
Same reasoning as M-20. The code fact is real; the standalone vulnerability claim is weak.

### Impact Assessment
This is a component observation behind H-01, not a separately demonstrated exploit.

## M-22 Phantom totalSyntheticsIssued Blocks Deposits
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- `deposit()`, `mint()`, and `mintFrom()` all gate on `!_isProtocolInBadDebt()` in `src/AlchemistV3.sol:417-422`, `475-490`, and `493-508`.
- `_isProtocolInBadDebt()` uses total backing, including MYT held by `Transmuter`, in `src/AlchemistV3.sol:1704-1711`.

### Analysis
The gate exists, but the report's "phantom issuance permanently blocks deposits" conclusion depends on H-01's incorrect assumption that backing falls to zero when `totalDebt` falls to zero.

### Impact Assessment
The protocol does block deposits/mints under actual bad debt. Normal liquidation flows do not prove a permanent block.

## M-23 PerpetualGauge Vote Weight Desync
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `vote()` removes prior vote weight using the voter's current token balance, not their old vote-time balance, in `src/PerpetualGauge.sol:64-82`.
- `clearVote()` does the same in `src/PerpetualGauge.sol:94-107`.

### Analysis
Weights can drift if the voter's balance changes between vote submission and vote replacement/removal.

### Impact Assessment
This is real gauge-accounting drift, but its importance depends on whether the gauge is ever used in production.

## M-24 No __gap On Upgradeable Proxy
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Info/Low)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- `AlchemistV3` imports `Initializable` and is deployed behind `TransparentUpgradeableProxy` in tests and PoCs, but no `__gap` exists in `src/AlchemistV3.sol`.

### Analysis
Missing `__gap` is real upgrade-layout hygiene debt.

The report overstates the impact. Storage corruption is not automatic for every upgrade. Append-only upgrades can still be safe; risk rises when inheritance/storage layout changes are introduced later.

### Impact Assessment
This is a real upgradeability concern, but it is not a concrete present-tense state corruption bug from the current code alone.

## M-25 MAX_ORACLE_STALENESS 7 Days
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `OraclePricedSwapStrategy` sets `MAX_ORACLE_STALENESS = 7 days` in `src/strategies/OraclePricedSwapStrategy.sol:8-9`.

### Analysis
The constant value is exactly as reported and is actively used in `_oracleAnswer()`.

### Impact Assessment
This is a real stale-price policy risk.

## M-26 No Spread Validation In Dual Oracle
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- The adapter averages `priceLow` and `priceHigh` with no sanity check on their spread in `src/FrxEthEthDualOracleAggregatorAdapter.sol:26-32`.

### Analysis
This is independent from H-02's timestamp bug. Even with honest timestamps, a large disagreement between the two prices would still go unchecked.

### Impact Assessment
This is a real missing-validation issue in the dual-oracle design.

## M-27 No L2 Sequencer Uptime Check
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- No in-scope oracle contract references a sequencer uptime feed. `OraclePricedSwapStrategy._oracleAnswer()` only checks `raw > 0`, `updatedAt != 0`, and staleness in `src/strategies/OraclePricedSwapStrategy.sol:130-135`.

### Analysis
The absence is real in the reviewed code.

### Impact Assessment
This matters on L2 deployments and should be treated as deployment-context-sensitive oracle hardening debt.

## M-28 _sync() Skips Non-Earmarked Accounts
**VERDICT: REFUTED**  
**SEVERITY: DISAGREE**  
**CONFIDENCE: LOW**

### Code Trace
- `_sync()` always writes `account.earmarked = newEarmarked` and `account.debt = newDebt` in `src/AlchemistV3.sol:1431-1460`.
- Collateral is only debited when both `globalDebtDelta != 0` and the account-local `redeemedTotal != 0` in `src/AlchemistV3.sol:1436-1446`.

### Analysis
The report title does not match the code. `_sync()` does not "skip debt/earmark updates for accounts with zero earmarked balance." It always updates them.

I did not find a clean code path proving the stated "wealth transfer" framing from the available files alone.

### Impact Assessment
This specific finding is not established by the cited code.

## M-29 ZeroXSwapVerifier Never Called
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- `MYTStrategy.dexSwap()` approves tokens to `allowanceHolder`, does `allowanceHolder.call(callData)`, then only checks output balance in `src/MYTStrategy.sol:124-135`.
- `ZeroXSwapVerifier` exists under `src/utils/ZeroXSwapVerifier.sol`, but repo search found no production import sites outside tests.

### Analysis
The verifier is dead code in production paths. The strategy never validates calldata against the helper library that exists for exactly that purpose.

### Impact Assessment
This is a real defense-in-depth gap in a highly privileged swap path.

## M-30 Stale Oracle + Operator Calldata Compound Extraction
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: compound note, not separate finding)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- The stale-timestamp side is H-02.
- The operator-calldata side comes from `AlchemistAllocator.allocateWithSwap()` and raw `allowanceHolder.call(callData)` via `MYTStrategy.dexSwap()` in `src/AlchemistAllocator.sol:63-75` and `src/MYTStrategy.sol:124-135`.

### Analysis
The scenario is plausible as a composed attack story, but it is not a distinct root-cause finding. It is just H-02/H-03 plus the operator-controlled swap surface.

### Impact Assessment
Keep it as a composability note under the higher-severity oracle issue instead of a standalone Medium.

## M-31 Swap Guard Unit Mismatch
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: HIGH**

### Code Trace
- `_allocationSwapGuard()` compares `oracleTokenReceived` against `minAllocationOut = assetAmountIn * minAllocationOutBps / 10_000` in `src/strategies/OraclePricedSwapStrategy.sol:154-163`.

### Analysis
The unit mismatch is real: the threshold is built in asset units while the comparison uses oracle-token units.

The report overstates the consequence. Not every non-zero `minAllocationOutBps` reverts. Reversion depends on the asset/oracle-token exchange ratio and the chosen BPS threshold.

### Impact Assessment
This is a real guard bug, but the threshold at which it breaks is narrower than reported.

## M-32 timeToTransmute=1 Fenwick Overflow
**VERDICT: PARTIALLY CONFIRMED**  
**SEVERITY: DISAGREE (suggest: Low/Medium)**  
**CONFIDENCE: MEDIUM**

### Code Trace
- `createRedemption()` computes `syntheticDepositAmount * BLOCK_SCALING_FACTOR / timeToTransmute` in `src/Transmuter.sol:176-206`.
- `BLOCK_SCALING_FACTOR = 1e8` in `src/Transmuter.sol:25-27`.
- `StakingGraph` bounds deltas to `DELTA_MAX = 2^111 - 1` and reverts when exceeded in `src/libraries/StakingGraph.sol:28-30` and `53-60`.

### Analysis
At `timeToTransmute = 1`, the report's order-of-magnitude bound is directionally correct: around 26 million 18-decimal tokens is where the delta hits the signed 112-bit ceiling.

The failure mode is overstated. The graph code reverts on overflow; it does not silently corrupt the Fenwick tree.

### Impact Assessment
This is a configuration-induced scale ceiling, not silent state corruption.

## M-33 Transmuter Fee Retroactivity (No Snapshot)
**VERDICT: CONFIRMED**  
**SEVERITY: AGREE**  
**CONFIDENCE: HIGH**

### Code Trace
- Same code path as M-11: `StakingPosition` has no fee snapshot, and `claimRedemption()` uses live fee settings in `src/interfaces/ITransmuter.sol:7-14` and `src/Transmuter.sol:264-278`.

### Analysis
This is the same issue as M-11, just framed from the storage-model side.

### Impact Assessment
Keep one of M-11/M-33 and merge the other as duplicate support.

## M-34 Multi-Chain Sequencer Downtime
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: duplicate of M-27)**  
**CONFIDENCE: HIGH**

### Code Trace
- Same code basis as M-27: the in-scope oracle code does not consult a sequencer uptime feed.

### Analysis
The report is right on the missing check, but wrong to count this as an independent finding from M-27. It is deployment-context confirmation, not a new root cause.

### Impact Assessment
Treat this as duplicate/supporting evidence for M-27.

## M-35 Selector-Only Keying
**VERDICT: CONFIRMED**  
**SEVERITY: DISAGREE (suggest: duplicate of M-13)**  
**CONFIDENCE: HIGH**

### Code Trace
- `PermissionedProxy.proxy()` keys authorization only on the 4-byte selector via `permissionedCalls[selector]` in `src/utils/PermissionedProxy.sol:62-71`.

### Analysis
This is the same mechanism as M-13, just framed around selector collisions rather than arbitrary target choice.

### Impact Assessment
Merge into M-13 instead of reporting separately.

## Refuted Findings

## B5-7
**VERDICT: REFUTATION NOT VERIFIABLE FROM PROVIDED MATERIALS**  
**CONFIDENCE: LOW**

### Code Trace
Repo search only found the ID in `CODEX_VERIFICATION_PROMPT.md` and the summary line in `v3-plamen-audit-report.md`.

### Analysis
The original claim text and scratchpad/refutation rationale are not present in the provided repo, so there is no way to independently verify why it was dropped.

### Impact Assessment
No conclusion possible without the original finding body.

## B5-3
**VERDICT: REFUTATION NOT VERIFIABLE FROM PROVIDED MATERIALS**  
**CONFIDENCE: LOW**

### Code Trace
Repo search only found the ID in `CODEX_VERIFICATION_PROMPT.md` and the summary line in `v3-plamen-audit-report.md`.

### Analysis
Same problem as B5-7: the underlying claim is missing.

### Impact Assessment
No conclusion possible without the original finding body.

## B1-5
**VERDICT: REFUTATION NOT VERIFIABLE FROM PROVIDED MATERIALS**  
**CONFIDENCE: LOW**

### Code Trace
Repo search only found the ID in `CODEX_VERIFICATION_PROMPT.md` and the summary line in `v3-plamen-audit-report.md`.

### Analysis
The repo does not include the original B1-5 claim or a scratchpad explaining the refutation.

### Impact Assessment
No conclusion possible without the original finding body.

## SC-4
**VERDICT: REFUTATION NOT VERIFIABLE FROM PROVIDED MATERIALS**  
**CONFIDENCE: LOW**

### Code Trace
Repo search only found the ID in `CODEX_VERIFICATION_PROMPT.md` and the summary line in `v3-plamen-audit-report.md`.

### Analysis
There is not enough material in the checkout to independently validate the refutation.

### Impact Assessment
No conclusion possible without the original finding body.

## New Findings

No new high-confidence vulnerabilities surfaced during this verification pass.

The main thing the original report missed is not an extra bug, but a reporting problem:
- It overstates the H-01/H-05/M-22 "phantom issuance bricks the protocol" chain.
- It treats several duplicates and compound narratives as separate findings.
- It promotes multiple admin/operator-trust observations to Medium/High without a concrete unexpected exploit path.

## Overall Assessment

The report is directionally useful, but materially over-reports severity and duplicates.

The strongest confirmed items are:
- H-02 timestamp fabrication in the Frax dual-oracle adapter
- H-04 missing protected-token override in the Etherfi strategy
- H-07/H-08 if the gauge system is intended to be live
- M-11/M-33 Transmuter fee retroactivity
- M-29 dead swap verifier

The weakest or overstated items are:
- H-01, H-05, and M-22, because the report ignores that `_isProtocolInBadDebt()` counts MYT already held by `Transmuter`
- H-06, because checked arithmetic reverts and the failure is not permanent
- M-12, because the cited `minIntermediateOut` field is unused on the claimed paths
- M-24 and M-32, because both describe real engineering debt but overstate present-day exploitability

The systemic bias is clear: the report tends to turn design ambiguity, privileged control surfaces, dead/unused components, and compound scenarios into separate medium/high findings instead of collapsing them into a smaller set of root causes.