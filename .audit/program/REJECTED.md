# Bug bounty: rejected and out-of-scope findings (internal AI audit)

This document indexes findings produced by an **internal, AI-assisted breadth audit** of Alchemix V3 (108 items: 9 High, 26 Medium, 57 Low, 16 Informational). The audit was useful for review hygiene but mixed **correct code observations** with **wrong impact**, **duplicates**, and **privileged/trust assumptions** presented as critical bugs.

**Manifest.** Full titles and claim text for every row are in **`FINDINGS-INDEX.md`**; the tables below match that inventory by tag and global ID.

**Policy.** Submissions that **duplicate** any item below—same contract, same mechanism, same outcome—will be **closed as duplicate or invalid** by our team and on Immunefi, unless you demonstrate a **new** vulnerability on **currently deployed, in-scope** code (different entrypoint, bypass of a fix, or materially different impact).

**Disposition labels**

| Label | Meaning |
|-------|---------|
| **Invalid** | Impact or mechanism does not hold against the actual code or math, **or** the claim is **not an in-scope vulnerability** under our program (e.g. requires malicious admin/operator, pure design or policy choice, no demonstrated user loss, documentation-only). |
| **Duplicate** | Same root cause or same paid story as another ID; one report only. |
| **Out of scope** | Handled under another track (e.g. strategy not in launch scope) or explicitly excluded by program scope. |
| **Resolved** | Addressed in the current codebase; reports against old revisions are N/A. |
| **Disputed** | Title or claimed behavior does not match implementation. |
| **Tracked elsewhere** | Governance, ops, or documentation; not accepted as a standalone security payout. |

---

## Master index — all findings by severity

| Bucket | Count |
|--------|------:|
| High | 9 |
| Medium | 26 |
| Low | 57 |
| Informational | 16 |
| **Subtotal (matches audit 108)** | **108** |
| Refuted (manifest R-01–R-04; listed separately) | 4 |
| **Total table rows in master index below** | **112** |

### High (9)

| ID | Report tag | Title (short) | Disposition |
|----|------------|---------------|-------------|
| H-01 | DEPTH-ST-1 | Phantom `totalSyntheticsIssued` / permanent brick | Invalid |
| H-02 | B8-1, DEPTH-EC-3 | Dual oracle fabricated `updatedAt` / staleness bypass | Out of scope |
| H-03 | DEPTH-EX-2 | Stale oracle → inflated collateral chain | Duplicate |
| H-04 | B5-1 | Etherfi missing `_isProtectedToken` | Out of scope |
| H-05 | DEPTH-ST-7 | Retroactive lower bound → mass liquidation → brick | Invalid |
| H-06 | B7-1 | `PerpetualGauge.executeAllocation` overflow DoS | Invalid |
| H-07 | B7-2 | `registerNewStrategy` unimplemented | Invalid |
| H-08 | SCA-1 | Classifier cap BPS vs absolute mismatch | Duplicate |
| H-09 | B8-5 (dup) | Oracle spread validation missing | Duplicate |

### Medium (26)

Manifest **M-01–M-26** in `FINDINGS-INDEX.md` correspond to **#10–#35** below (global medium slot = 9 + manifest M number).

| # | ID | Title (short) | Disposition |
|---|-----|---------------|-------------|
| 10 | B1-1 | `_subCollateralBalance` silent clamp | Invalid |
| 11 | B1-11 | Transmuter fees retroactive on locked positions | Tracked elsewhere |
| 12 | B2-1 | Operator swap MEV via `minIntermediateOut: 0` | Invalid |
| 13 | B2-2 | `PermissionedProxy` arbitrary target | Invalid |
| 14 | B2-4 | Curator strategy add/remove without timelock | Invalid |
| 15 | B2-7 | `setLiquidityAdapter` no validation | Invalid |
| 16 | B2-10 | `setAllowanceHolder` no event / timelock | Invalid |
| 17 | B3-5 | Retroactive collateralization parameters | Tracked elsewhere |
| 18 | B6-1 | `calculateLiquidation` / fee vault socializes insolvent fees | Invalid |
| 19 | B6-2 | `batchLiquidate` unbounded loop gas DoS | Invalid |
| 20 | B6-5 | `selfLiquidate` does not reduce `totalSyntheticsIssued` | Duplicate |
| 21 | B6-6 | `_doLiquidation` does not reduce `totalSyntheticsIssued` | Duplicate |
| 22 | B6-10 | Phantom issuance blocks deposits | Duplicate |
| 23 | B7-3 | PerpetualGauge vote weight desync | Invalid |
| 24 | B7-4 | No `__gap` on upgradeable proxy | Resolved |
| 25 | B8-2 | `MAX_ORACLE_STALENESS` 7 days | Invalid |
| 26 | B8-5 | No spread validation in dual oracle | Duplicate |
| 27 | B8-6 | No L2 sequencer uptime check | Invalid |
| 28 | DEPTH-ST-6 | `_sync` skips non-earmarked accounts | Disputed |
| 29 | DEPTH-EX-1 | `ZeroXSwapVerifier` never called | Invalid |
| 30 | DEPTH-EX-7 | Stale oracle + operator calldata compound | Duplicate |
| 31 | DA-1 | `_allocationSwapGuard` unit mismatch | Invalid |
| 32 | SGI-4 | Fenwick `DELTA_MAX` at ~26M alETH | Invalid |
| 33 | DEPTH-ST-2 | Transmuter fee retroactivity (no snapshot) | Duplicate |
| 34 | DEPTH-EX-3 | Multi-chain sequencer downtime | Duplicate |
| 35 | DEPTH-EX-5 | Selector-only keying on proxy | Duplicate |

### Low (57)

Global **L-36–L-92** align with manifest **L-01–L-57** in `FINDINGS-INDEX.md` (`L-36` = manifest `L-01`, …, `L-92` = manifest `L-57`). Each row includes a one-line claim summary from the manifest.

| ID | Tag | Title (short) | Brief claim (from manifest) | Disposition |
|----|-----|---------------|----------------------------|-------------|
| L-36 | B1-2 | Anti-round-trip per tokenId; cross-position same-block bypass | Same-block deposit-then-withdraw across different positions bypasses per-tokenId protection. | Invalid |
| L-37 | B1-3 | `setMinimumCollateralization` silent clamping | Setter clamps without reverting or emitting an event when the value would violate constraints. | Invalid |
| L-38 | B1-4 | `setGlobalMinimumCollateralization` missing upper bound | No upper bound on global minimum; admin could set it high enough to block new borrows. | Invalid |
| L-39 | B1-6 | `redeem()` protocol fee skipped when `_mytSharesDeposited` insufficient | Fee skipped instead of reverting when global shares cannot cover the fee → accounting drift. | Invalid |
| L-40 | B1-9 | `setDepositCap` validates against `balanceOf` — donation lock | Donation above cap prevents lowering cap below current balance. | Invalid |
| L-41 | B1-10 | AlchemistV3 fees retroactive on existing positions | Fee parameter changes apply immediately; no per-position snapshot. | Invalid |
| L-42 | B1-12 | Earmark cover shares inflatable by MYT donation | Donating MYT to the contract can inflate cover shares and dilute holders. | Invalid |
| L-43 | B2-3 | Guardian can pause and unpause — bidirectional | Same role can unpause; no separation from governance-style unpause. | Invalid |
| L-44 | B2-8 | `assignStrategyRiskLevel` no event | Risk reclassification not visible to off-chain monitors. | Invalid |
| L-45 | B2-9 | Default risk caps `type(uint256).max` | Risk framework disabled until explicitly configured. | Invalid |
| L-46 | B2-11 | `setSlippageBPS` regression (50% → 99.98%) | Setter allows much higher slippage than prior limit. | Invalid |
| L-47 | B3-4 | `setTransmutationTime` front-running opportunity | Observers may adjust positions before new time applies. | Invalid |
| L-48 | B3-6 | Protocol fee retroactive on earmarked debt | Fee changes apply to already-earmarked debt. | Invalid |
| L-49 | B3-7 | `burn()` floor uses stale `totalLocked` — temporary burn DoS | Stale floor can temporarily block burns during some transitions. | Invalid |
| L-50 | B3-9 | ERC-4626 withdrawal limits — high utilization blocks deallocate | `withdraw` without `maxWithdraw` check can revert under high utilization. | Invalid |
| L-51 | B4-4 | Fee vaults use raw balance — donations become liquidator fees | Donations to fee vault spendable as liquidator incentives. | Invalid |
| L-52 | B4-7 | Bridge rate limits could block minting | High activity could hit bridge limits and block mint access. | Invalid |
| L-53 | B5-2 | `rescueTokens` unsafe raw transfer | Raw `transfer` instead of safe transfer for some token behaviors. | Invalid |
| L-54 | B5-5 | TokeAuto `claimRewards` swaps full balance | Pre-existing balance in contract swept into swap, not just rewards. | Invalid |
| L-55 | B6-3 | Health check gap zone; neither liquidatable nor withdrawable | Between lower bound and minimum collateralization, position can be stuck. | Invalid |
| L-56 | B6-7 | No reentrancy guard on liquidation paths | Future changes could add reentrancy risk; current flow argued safe. | Invalid |
| L-57 | B6-9 | Silent fee shortfall in `_forceRepay` | Insufficient fee vault absorbs shortfall without reverting. | Invalid |
| L-58 | B7-5 | `clearVote` leaves `voterIndex` stale | Index desync after clearing votes. | Invalid |
| L-59 | B7-6 | `executeAllocation` global cap underflow | Global cap path can underflow in edge conditions. | Invalid |
| L-60 | B8-3 | Missing `answeredInRound >= roundId` check | Oracle round freshness not fully validated. | Invalid |
| L-61 | B8-4 | No oracle price bounds check | Zero or extreme prices accepted. | Invalid |
| L-62 | B8-7 | Oracle revert causes complete strategy DoS | No fallback if feed reverts. | Invalid |
| L-63 | B9-3 | `_isProtocolInBadDebt` uses raw Transmuter balance | Transmuter donations inflate apparent backing. | Invalid |
| L-64 | INJ-1 | Insolvent liquidation path drains fee vault proportional to full debt | Insolvent path charges fee from shared vault proportional to debt (mass insolvency narrative). | Invalid |
| L-65 | SC-1 | `transferAdminOwnership(address(0))` locks admin (Allocator/Curator) | `pendingAdmin` zero makes `acceptAdminOwnership` unreachable. | Invalid |
| L-66 | SC-2 | `transferOwnership(address(0))` locks strategy classifier | Same lockout pattern on classifier ownership. | Invalid |
| L-67 | EC-1 | `BatchLiquidated` event never wired | Event defined but not emitted. | Invalid |
| L-68 | EC-2 | `setAlchemistPositionNFT` no event | NFT reference change not logged. | Invalid |
| L-69 | EC-3 | Position NFT admin setters missing events | `setMetadataRenderer` / `setAdmin` without events. | Invalid |
| L-70 | EC-4 | Pending admin nomination events missing | Nomination workflow lacks events on proxy/classifier. | Invalid |
| L-71 | EC-9 | AlchemistAllocator zero event emissions | No events on allocator state changes. | Invalid |
| L-72 | MS-1 | `repay()` has no ownership check | Third party can repay arbitrary `tokenId` (fee / `lastRepayBlock` effects). | Invalid |
| L-73 | MS-2 | `deposit()` no ownership check when `tokenId != 0` | Anyone can add collateral to another user’s position. | Invalid |
| L-74 | MS-3 | Router NFT round-trip wipes `approveMint` allowances | Double `resetMintAllowances` clears mint allowances. | Invalid |
| L-75 | MS-4 | `deallocate()` computes `totalValueBefore` but never uses it | No conservation check across deallocation. | Invalid |
| L-76 | DA-2 | `collateralInUnderlying` holds debt units — 1e12 maintenance risk | USDC 6 vs debt 18 decimals hazard for future changes. | Invalid |
| L-77 | DA-3 | `underlyingConversionFactor` `uint8` subtraction panic at init | `underlyingDecimals > 18` makes `18 - decimals` underflow in init. | Invalid |
| L-78 | SCA-2 | `vote()` weights array no overflow guard | Large weights could corrupt distribution. | Invalid |
| L-79 | SCA-3 | `setRiskClass()` no input validation | Arbitrary / contradictory risk classes possible. | Invalid |
| L-80 | SCA-4 | Bad-debt normalization divergence (Transmuter vs Alchemist) | Two contracts normalize bad debt differently. | Invalid |
| L-81 | SB-1 | CEI ordering in `deposit()`; `_mytSharesDeposited` after `safeTransferFrom` | Effects after transfer; impact depends on MYT hook behavior. | Invalid |
| L-82 | SB-3 | `createRedemption()` CEI — `totalLocked` after transfer | Same CEI pattern on Transmuter redemption path. | Invalid |
| L-83 | SB-4 | New `deposit()` does not validate `tokenId != 0` | Token id 0 edge case for new positions. | Invalid |
| L-84 | SB-5 | `deposit()` ERC-721 mint before `_earmark` / `_sync` | Callback during mint sees partially initialized state. | Invalid |
| L-85 | DEPTH-EX-4 | `_deallocate()` no `maxWithdraw()` check (depth) | Same ERC-4626 high-utilization revert as L-50. | Invalid |
| L-86 | DEPTH-EX-6 | `deallocateWithSwap` SFraxETH always reverts | `minIntermediateOut` hardcoded 0 conflicts with `require(minIntermediateOut > 0)`. | Invalid |
| L-87 | DEPTH-EC-4 | weETH ≠ WETH — Etherfi protected-token depth | Confirms base `_isProtectedToken` does not cover yield token. | Invalid |
| L-88 | DEPTH-EC-6 | Gap zone between bounds (depth) | Depth restatement of stuck-position band (see L-55). | Invalid |
| L-89 | DEPTH-ST-5 | `redeem()` fee skip → permanent accounting drift | Depth restatement of L-39 fee skip narrative. | Invalid |
| L-90 | DEPTH-ST-4 | `setCollateralizationLowerBound` no grace | Instant bound change enabling mass liquidation narrative. | Invalid |
| L-91 | DEPTH-ST-8 | `_subEarmarkedDebt` stale decrement | Latent local/global mismatch; argued unreachable with current callers. | Invalid |
| L-92 | DEPTH-EC-5 | `batchLiquidate` gas per iteration quantified | ~100–115k gas per iteration; large batches OOG (related to M-19). | Invalid |

**Manifest continuation.** `FINDINGS-INDEX.md` also defines **L-58 [SGI-5]** (`_survivalAccumulator` theoretical overflow at extreme scale) and **L-59 [BLIND-A2]** (`mintFrom` recipient unvalidated → stranded alAssets if recipient is a bad contract). They sit after L-57 in the manifest; the global bounty table maps **only** manifest L-01–L-57 to **L-36–L-92**. Duplicate triage for L-58/L-59 matches other lows: **Invalid** unless a new permissionless loss path is shown on in-scope code.

### Informational (16)

Aligned with manifest **I-01–I-16** in `FINDINGS-INDEX.md` (replaces generic EC buckets and INFO-A–E labels).

| ID | Tag | Title (short) | Brief note (from manifest) | Disposition |
|----|-----|---------------|---------------------------|-------------|
| I-01 | B1-8 | `normalizeDebtTokensToUnderlying` dust truncation | Small amounts can truncate to zero in decimal normalization. | Invalid |
| I-02 | B2-5 | No cap validation on deallocations | By design: withdrawals should remain possible. | Invalid |
| I-03 | B2-6 | `minIntermediateOut: 0` unused field — future risk | Hardcoded zero; future activation could reintroduce slippage issues. | Invalid |
| I-04 | B4-6 | `redeem()` fee all-or-nothing skip | Full fee or skip; no partial fee (design). | Invalid |
| I-05 | B5-6 | Cross-strategy loss propagation | Shared vault means one strategy’s loss can affect others (design). | Invalid |
| I-06 | INJ-2 | `repay()` does not decrement `_mytSharesDeposited` | Repay frees debt but not deposit-cap accounting; withdraw needed to reclaim cap. | Invalid |
| I-07 | SB-2 | `pauseLoans` does not gate `burn` / `repay` | Paused loans still allow debt reduction (design). | Invalid |
| I-08 | SB-6 | `initialize()` does not set `alchemistPositionNFT` | Post-init configuration window. | Invalid |
| I-09 | SC-3 | `setPendingAdmin` accepts zero address | Ambiguous cancel vs mistake. | Invalid |
| I-10 | EC-5 | `setOperator` event missing bool | Logs cannot tell add vs remove. | Invalid |
| I-11 | EC-6 | `Redemption` event missing fields | Less observability for redemptions. | Invalid |
| I-12 | EC-7 | `setAuthorization` no event | Gate auth changes not logged. | Invalid |
| I-13 | EC-8 | `claimRedemption` event missing fee details | Incomplete fee breakdown in logs. | Invalid |
| I-14 | SCA-5 | BPS magic number `1e4` undocumented | Raw `1e4` vs named `BPS` elsewhere. | Invalid |
| I-15 | MS-6 | `batchLiquidate` permissionless — by design | Open liquidation market (design). | Invalid |
| I-16 | MS-7 | `mintFrom` recipient parameter — by design | Composability with arbitrary recipient (design). | Invalid |

### Refuted (manifest R-01–R-04)

| ID | Title (short) | Disposition |
|----|---------------|-------------|
| B5-7 | `deallocate` totalValue check incorrect — **refuted** | Invalid — original claim wrong; check matches intended accounting. |
| B5-3 | Strategy donation inflates `_totalValue` — **refuted** | Invalid — donation may inflate view; Morpho-style accounting blocks the claimed extraction. |
| B1-5 | `setTransmutationTime` retroactive — **refuted** | Invalid — Fenwick entries fixed at stake; time change affects new positions only. |
| SC-4 | VaultV2 flash loan — **refuted** | Invalid — no flash-loan entrypoint; vector not possible. |

---

## Rationale by severity (High → Informational)

### High

**H-01 — Invalid.** Debt-clearing paths do not decrement `totalSyntheticsIssued`; that accounting gap is real. The reported **impact** is wrong: `_isProtocolInBadDebt()` compares issued synthetics to backing that includes **MYT held by the Transmuter**. Liquidations move MYT to the Transmuter, so backing does **not** drop to zero when `totalDebt` hits zero. Permanent brick does not follow.

**H-02 — Out of scope.** The dual-oracle adapter issue was real; it is **fixed** (truthful timestamps, spread limit, strategy integration). Affected strategies are **not in current launch scope** for the bounty program.

**H-03 — Duplicate.** Same oracle root as H-02; “inflated collateral” is a consequence narrative, not a second root cause.

**H-04 — Out of scope.** Missing `_isProtectedToken` on Etherfi was real; **fixed**. Etherfi path **not in current launch scope**.

**H-05 — Invalid** (as a “brick” finding). Admin can change collateralization bounds without grace; that is a **governance/trust** topic. The claimed **irrecoverable brick** depends on H-01, which is invalid.

**H-06 — Invalid.** Multiplication with default `type(uint256).max` caps **reverts** under Solidity 0.8 (no silent wrap). Admin can set finite caps. The gauge path is often unreachable anyway while `strategyList` is empty (H-07).

**H-07 — Invalid.** `registerNewStrategy` is effectively a stub; the gauge subsystem is not treated as production-critical for bounty purposes.

**H-08 — Duplicate.** Same gauge + classifier consumption problem as H-06/H-07; not a separate paid finding.

**H-09 — Duplicate.** Spread check is the same oracle workstream as H-02 / M-26; not a distinct High.

### Medium

**M-10 (B1-1) — Invalid.** Clamping only bites if global `_mytSharesDeposited` already diverges from per-account sums; not a generic user-triggerable exploit.

**M-11 (B1-11) — Tracked elsewhere.** Fees apply at claim time without per-position snapshot; this is **admin/governance** risk if you treat malicious admin as in scope. We do not pay it as a standalone critical finding duplicate.

**M-12 (B2-1) — Invalid** as framed. Allocator passes `minIntermediateOut: 0`, but on the cited **`ActionType.swap`** paths the strategy does **not** use that field the way the report assumes; the specific MEV story is overstated.

**M-13 (B2-2) — Invalid.** Operator-only; selector allowlist still applies. “Arbitrary contract” is constrained by role and whitelist design.

**M-14 (B2-4), M-15 (B2-7), M-16 (B2-10) — Invalid.** Privileged operator/owner configuration surfaces. Not permissionless theft.

**M-17 (B3-5) — Tracked elsewhere.** Same class as H-05 without the false brick chain.

**M-18 (B6-1) — Invalid.** Insolvent or stressed liquidation can pay liquidator incentives from the shared fee vault; known economic design, not a user-draining bug.

**M-19 (B6-2) — Invalid** as protocol DoS. The caller supplies the array; oversized batches only **self-revert**.

**M-20 – M-22 (B6-5, B6-6, B6-10) — Duplicate** of H-01. Components of the invalidated brick narrative.

**M-23 (B7-3) — Invalid.** Gauge voting math can drift; gauge is not a bounty-critical production gate.

**M-24 (B7-4) — Resolved.** `__gap` added to `AlchemistV3`.

**M-25 (B8-2) — Invalid.** Long staleness constant is a policy / hardening choice, not a standalone permissionless exploit. **M-26 (B8-5) — Duplicate** of the dual-oracle spread work (out-of-scope strategy track).

**M-27 (B8-6) — Invalid.** Missing L2 sequencer feed is deployment-hardening, not a demonstrated loss path on its own. **M-34 (DEPTH-EX-3) — Duplicate** of M-27.

**M-28 (DEPTH-ST-6) — Disputed.** `_sync` updates debt and earmarks; the “skip non-earmarked” framing does not match the implementation.

**M-29 (DEPTH-EX-1) — Invalid.** Verifier not wired into `dexSwap`; defense-in-depth gap under operator trust model.

**M-30 (DEPTH-EX-7) — Duplicate.** Combines oracle + operator themes already covered.

**M-31 (DA-1) — Invalid.** Unit mismatch in swap guard is real; impact is configuration-dependent, not “all swaps always revert” at stated generality.

**M-32 (SGI-4) — Invalid.** Fenwick overflow threshold was **miscalculated** in the audit (~26M vs ~137B alETH scale). Fuzzing to 100M alETH passes.

**M-33 (DEPTH-ST-2) — Duplicate** of M-11 (fee retroactivity).

**M-35 (DEPTH-EX-5) — Duplicate** of M-13 (selector + target model).

### Low

**L-36 through L-92 — Invalid** (see master table). Same general basis: documentation, monitoring, privileged configuration, design choices, or edge cases with **no permissionless bounty-grade impact**. **Bulk paste of AI audit Low lists without a new in-scope path = duplicate.**

**L-36 (B1-2) — Invalid.** Same-block / cross-position anti-round-trip edge; no demonstrated fund loss at bounty bar.

**L-55 (B6-3) — Invalid.** Narrow health-band behavior; design / UX, not critical exploit.

**L-64 (INJ-1) — Invalid.** Overlaps fee-vault / liquidation economics already under M-18.

**L-65 (SC-1) — Invalid.** Admin footgun (`address(0)`); privileged mistake.

**L-72 (MS-1) — Invalid.** Third-party repayment is often intentional; not theft of principal without further steps.

**L-75 (MS-4) — Invalid.** Unused local; possible future check, not current vulnerability.

**L-81 (SB-1) — Invalid.** CEI vs ERC-777-style hooks; dormant for standard ERC-20 MYT.

### Informational

**I-01 through I-16 — Invalid.** Housekeeping, design documentation, or observability gaps as framed in the manifest; not in-scope security payouts unless the Immunefi program explicitly rewards informational findings.

### Refuted IDs (B5-7, B5-3, B1-5, SC-4)

**Disposition: Invalid.** Claims are **refuted** in the manifest with counter-analysis; do not resubmit the original thesis without new code proof.

---

## What we will still review

- **Permissionless** impact on **in-scope, deployed** contracts: loss of funds, broken accounting, unauthorized mint/burn, etc.
- **New** regression: fix bypass, wrong invariant, or different attack path than any row above.
- Evidence: concrete traces, state diffs, or tests — not a re-export of this audit’s tables.

Confirm strategy and deployment **scope** against the current bug-bounty program before filing oracle- or strategy-specific reports.
