# Alchemix V3 — Cleaned Final Audit Triage

**Source:** distilled from `codex-verification-report.md`  
**Goal:** keep only root-cause issues worth carrying into a final report  
**Policy:** zero false positives, merge duplicates, and do not promote privileged design tradeoffs into standalone high-severity bugs without a concrete unexpected exploit path

## Recommendation

I would carry forward:
- `7` core findings in the main report
- `5` appendix-quality low/info findings if you want a longer report

I would merge or drop the rest.

## Main Report Findings

| Final ID | Title | Severity | Source IDs | Why keep |
|---|---|---|---|---|
| H-01 | Dual-oracle adapter fabricates freshness timestamps | High | H-02, H-03 | Real root cause with a direct code-level bypass of downstream staleness checks |
| M-01 | Etherfi strategy owner can rescue live `weETH` position tokens | Medium | H-04 | Real privileged drain path caused by a missing protected-token override |
| M-02 | Transmuter fees apply retroactively to existing positions | Medium | M-11, M-33 | No fee snapshot exists on `StakingPosition`; claim-time fees are fully mutable |
| M-03 | Collateralization parameter changes are retroactive | Medium | M-17, H-05 | Admin can instantly make existing positions newly liquidatable |
| M-04 | Liquidation can socialize fees through the communal fee vault | Medium | M-18 | Insolvent/stress liquidation pays liquidator incentives from shared protocol funds |
| M-05 | Oracle safeguards remain incomplete beyond the timestamp bug | Medium | M-25, M-26, M-27, M-34 | Separate oracle hardening gaps remain: no spread check, long stale window, no sequencer guard |
| M-06 | Privileged execution surfaces accept weakly validated targets/calldata | Medium | M-13, M-29, M-35, M-15, M-16 | Several operator/owner-controlled execution paths lack strong validation and defense-in-depth |

## Appendix-Quality Findings

| Final ID | Title | Severity | Source IDs | Why it is appendix-only |
|---|---|---|---|---|
| L-01 | Gauge/allocator stack is not production-ready | Low | H-06, H-07, H-08, M-23 | Real, but appears unused in production and has multiple overlapping failure modes |
| L-02 | Allocation swap guard compares mismatched units | Low | M-31 | Real logic bug, but impact is narrower than the original report claimed |
| L-03 | `_subCollateralBalance` destroys local excess once drift already exists | Low | M-10 | Real code path, but depends on a pre-existing local/global accounting mismatch |
| L-04 | `timeToTransmute = 1` creates a hard Fenwick capacity ceiling | Low | M-32 | Real extreme-config limit, but failure mode is a revert rather than silent corruption |
| I-01 | Missing `__gap` is upgrade hygiene debt, not an active exploit | Info | M-24 | Worth noting for upgrade discipline, but not as a present-tense storage corruption bug |

## Kept Findings

## H-01 — Dual-oracle adapter fabricates freshness timestamps

**Keep:** yes  
**From:** H-02 as root cause, H-03 as impact chain note

`src/FrxEthEthDualOracleAggregatorAdapter.sol:L21-L32` returns `updatedAt = block.timestamp` instead of propagating a real upstream timestamp. `src/strategies/OraclePricedSwapStrategy.sol:L130-L135` then treats that fabricated timestamp as fresh oracle data.

This is the cleanest High in the set and should remain.

## M-01 — Etherfi strategy owner can rescue live `weETH` position tokens

**Keep:** yes  
**From:** H-04

`src/MYTStrategy.sol:L184-L190` blocks rescue only for tokens covered by `_isProtectedToken()`. The base implementation in `src/MYTStrategy.sol:L270-L271` protects only `MYT.asset()`. `src/strategies/EtherfiEETHStrategy.sol` never overrides that function even though the live position asset is `weETH`.

This should stay, but as a privileged-drain Medium rather than a permissionless High.

## M-02 — Transmuter fees apply retroactively to existing positions

**Keep:** yes  
**From:** M-11, M-33

`src/interfaces/ITransmuter.sol:L7-L14` shows no fee snapshot on `StakingPosition`. `src/Transmuter.sol:L135-L147` lets admin update fees at any time, and `src/Transmuter.sol:L264-L278` applies the current fee at claim time.

This is one finding, not two.

## M-03 — Collateralization parameter changes are retroactive

**Keep:** yes  
**From:** M-17, with H-05 folded in as a consequence note

`src/AlchemistV3.sol:L301-L337` allows immediate admin updates to core collateralization parameters. `src/AlchemistV3.sol:L1124-L1130` then uses the current lower bound for health checks.

The important reportable issue is retroactivity. The claimed downstream "permanent brick" chain from H-05 should not stand on its own.

## M-04 — Liquidation can socialize fees through the communal fee vault

**Keep:** yes  
**From:** M-18

`src/AlchemistV3.sol:L781-L790` can return `outsourcedFee` in insolvent or system-stress liquidation paths. `_doLiquidation()` routes that through `_payWithFeeVault()` in `src/AlchemistV3.sol:L1163-L1165` and `L1225-L1226`.

This is a real cost-socialization behavior and worth keeping as a standalone Medium.

## M-05 — Oracle safeguards remain incomplete beyond the timestamp bug

**Keep:** yes  
**From:** M-25, M-26, M-27, M-34

This is the right bucket for the remaining oracle issues:
- `src/FrxEthEthDualOracleAggregatorAdapter.sol:L26-L32` averages `priceLow` and `priceHigh` with no spread check
- `src/strategies/OraclePricedSwapStrategy.sol:L8-L9` allows a `7 days` staleness window
- the in-scope oracle consumers contain no sequencer uptime guard

These are real, but they should be grouped as oracle hardening gaps rather than spread across several separate findings.

## M-06 — Privileged execution surfaces accept weakly validated targets/calldata

**Keep:** yes  
**From:** M-13, M-29, M-35, with M-15 and M-16 as supporting notes

This is the right merged finding for the operator/owner-controlled execution plane:
- `src/utils/PermissionedProxy.sol:L62-L71` authorizes by selector only, then calls an arbitrary target
- `src/MYTStrategy.sol:L125-L134` forwards raw calldata to `allowanceHolder` without invoking `ZeroXSwapVerifier`
- `src/AlchemistAllocator.sol:L117-L121` accepts any liquidity adapter address
- `src/MYTStrategy.sol:L214-L217` changes `allowanceHolder` without an event or delay

These should not be scattered into many standalone Mediums. They are one root cause: privileged integration surfaces trust supplied targets and calldata too much.

## Appendix Findings

## L-01 — Gauge/allocator stack is not production-ready

**Keep only if you want a longer report**  
**From:** H-06, H-07, H-08, M-23

This is best presented as one low-severity bundle:
- `registerNewStrategy()` is unimplemented
- cap semantics differ between `PerpetualGauge` and `AlchemistAllocator`
- default caps can cause checked-math reverts in the gauge path
- vote accounting can drift when voter balances change

It reads more like an unfinished subsystem than a set of separate production-grade vulnerabilities.

## L-02 — Allocation swap guard compares mismatched units

**Keep only if you want a longer report**  
**From:** M-31

`src/strategies/OraclePricedSwapStrategy.sol:L158-L163` compares oracle-token output against a threshold built from asset units. The bug is real, but the original report overstated the blast radius.

## L-03 — `_subCollateralBalance` destroys local excess once drift already exists

**Keep only if you want a longer report**  
**From:** M-10

`src/AlchemistV3.sol:L1015-L1029` clamps account-local collateral down to `_mytSharesDeposited` before subtraction. Real, but conditional on prior drift.

## L-04 — `timeToTransmute = 1` creates a hard Fenwick capacity ceiling

**Keep only if you want a longer report**  
**From:** M-32

The numeric bound is directionally right, but `src/libraries/StakingGraph.sol:L53-L60` and `L164-L166` show the failure mode is a revert, not silent corruption.

## I-01 — Missing `__gap` is upgrade hygiene debt

**Keep only as info**  
**From:** M-24

No `__gap` exists in `src/AlchemistV3.sol`, but that is not enough to claim that any future upgrade will corrupt state. Keep only as a hygiene note if needed.

## Merge Or Drop

| Original ID(s) | Action | Reason |
|---|---|---|
| H-01, M-20, M-21, M-22 | Drop | The debt/supply divergence is real, but the report's "phantom bad debt permanently bricks deposit/mint" theory ignores that `_isProtocolInBadDebt()` counts MYT already held by `Transmuter` |
| H-03 | Merge into H-01 | Best treated as the impact chain for the timestamp-fabrication bug, not as its own root cause |
| H-05 | Merge into M-03 | The real issue is retroactive collateralization changes; the brick consequence is overstated |
| H-06 | Merge into L-01 | Checked arithmetic revert in the same unfinished gauge subsystem |
| H-09 | Drop as standalone | It duplicates M-26, not H-02 |
| M-12 | Drop | `minIntermediateOut` is zeroed, but unused for the cited `ActionType.swap` path |
| M-19 | Drop | Caller-controlled self-OOG footgun; not worth keeping as a security finding |
| M-28 | Drop | `_sync()` does update debt and earmarks; the finding title does not match the code |
| M-30 | Merge into H-01 + M-06 | Compound scenario, not a separate root cause |
| M-33 | Merge into M-02 | Same fee-retroactivity bug |
| M-34 | Merge into M-05 | Same sequencer-gap issue on a multi-chain framing |
| M-35 | Merge into M-06 | Same selector-only authorization surface as M-13 |

## Unverifiable Refutations

I would not mention these in a final report unless you can recover the original scratchpad text:
- `B5-7`
- `B5-3`
- `B1-5`
- `SC-4`

The provided repository only contains the IDs in `CODEX_VERIFICATION_PROMPT.md` and `v3-plamen-audit-report.md`, not the original claim bodies.

## Suggested Final Count

If you want the cleanest publishable version, I would ship:
- `1` High
- `6` Medium
- `2` Low

If you want a longer appendix, add:
- `2` more Low
- `1` Informational

That gets you a much tighter report than the original breadth-first output while preserving the issues that are actually code-backed and non-duplicative.
