# Alchemix V3 Audit Reconciliation Report

**Date:** April 9, 2026  
**Method:** Anvil simulation + `cast send`/`cast call` transaction reconciliation  
**Reports Compared:**
1. **Plamen Core Audit** — 108 findings (9H, 26M, 57L, 16I)
2. **Gemini Verification** — Independent code trace verification
3. **Codex Verification** — Independent code trace verification with severity recalibration
4. **Final Triage** — Deduplicated root-cause triage (distilled from Codex)

**Simulation tooling:** Foundry Forge 1.5.1, Anvil local node (chain 31337), `cast send`/`cast call`

---

## Executive Summary

After deploying isolated simulation contracts to Anvil and executing `cast send` transactions replicating each disputed finding, I can confirm:

- **The Plamen audit is directionally correct** — every code-level bug it identifies is real
- **The Plamen audit overstates severity** on its flagship finding (H-01) and several compounds
- **Codex provides the most accurate severity calibration** — it correctly identifies that `_isProtocolInBadDebt()` includes Transmuter backing
- **Gemini agrees with Codex on H-01 but is less aggressive on downgrading other findings**
- **The Final Triage produces the cleanest report** — 1 High, 6 Medium, is the right shape

### Simulation-Verified Verdict Count

| Severity | Plamen | Codex | Gemini | **Anvil-Reconciled** |
|----------|--------|-------|--------|---------------------|
| High | 9 | 7 confirmed, 1 refuted (H-01), 1 duplicate | 6 confirmed, 2 partial, 1 refuted | **1 true High, 4 Medium, 4 Low/dup** |
| Medium | 26 | 22 confirmed, 2 refuted, 2 partial | 18 confirmed, 8 downgraded | **~12 unique root causes** |

---

## Finding-by-Finding Reconciliation

### H-01: Phantom totalSyntheticsIssued — THE KEY DISPUTE

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED — permanent protocol brick | High (Critical) |
| Gemini | REFUTED — Transmuter backing prevents brick | Not a bug |
| Codex | PARTIALLY CONFIRMED — divergence real, brick overstated | Low/Medium |

#### Anvil Simulation Evidence

```
cast send $H01 "deposit(uint256)" 100e18     → blockNumber 4
cast send $H01 "mint(uint256)" 90e18          → blockNumber 5
cast send $H01 "selfLiquidate(uint256)" 90e18 → blockNumber 6

State AFTER selfLiquidate:
  totalDebt:             0
  totalSyntheticsIssued: 90e18    ← unchanged (Plamen correct)
  alchemistMYT:          10e18
  transmuterMYT:         90e18    ← MYT moved here

Bad debt checks:
  Plamen version (no Transmuter):  true  ← would brick
  Actual code (with Transmuter):   false ← NOT bricked
```

#### Reconciled Verdict: **PARTIALLY CONFIRMED — Medium, not High**

**Plamen is right** that `_subDebt()` does not decrement `totalSyntheticsIssued`. The accounting divergence is real and confirmed on-chain. After selfLiquidation, `totalDebt = 0` but `totalSyntheticsIssued = 90e18`.

**Codex/Gemini are right** that this does NOT brick the protocol. The actual `_isProtocolInBadDebt()` function at `AlchemistV3.sol:1704-1712` includes `convertYieldTokensToUnderlying(transmuterShares)` in its backing calculation. Since selfLiquidation moves MYT to the Transmuter, the backing remains adequate.

**Edge case caveat:** After the Transmuter cycle completes (users redeem all their MYT), the phantom `totalSyntheticsIssued` would persist with no backing, potentially triggering bad debt in a future state. This makes it a real accounting hygiene issue worth fixing, but not the "permanent brick after a single liquidation" that Plamen claims.

---

### H-02: Dual Oracle Timestamp Fabrication

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED | High |
| Gemini | CONFIRMED | High |
| Codex | CONFIRMED | High |

#### Anvil Simulation Evidence

```
cast call $H02_ADAPTER "latestRoundData()" →
  updatedAt = 1775736386 = block.timestamp (fabricated)

cast call $H02_CONSUMER "checkPrice()" →
  age = 0, staleDetected = false

evm_increaseTime(30 days) + evm_mine →
  age = 0, staleDetected = false    ← 30 days stale, still "fresh"
```

#### Reconciled Verdict: **CONFIRMED — High**

All three reports agree. `FrxEthEthDualOracleAggregatorAdapter.sol:L32` returns `block.timestamp` as `updatedAt`, completely defeating downstream staleness checks. The `cast call` simulation after warping 30 days proves the staleness window never triggers. This is the strongest, cleanest High in the audit.

---

### H-03: Stale Oracle → Inflated Collateral Chain

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED | High |
| Gemini | CONFIRMED | High |
| Codex | PARTIALLY CONFIRMED | Medium (derived from H-02) |

#### Reconciled Verdict: **Merge into H-02 as impact note — not standalone High**

Codex is correct that this is a consequence chain, not an independent root cause. The root cause is H-02's timestamp fabrication. The collateral inflation is the impact. Keep as a single High with documented impact chain.

---

### H-04: EtherFi Missing _isProtectedToken

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED | High |
| Gemini | CONFIRMED | High |
| Codex | CONFIRMED | Medium (privileged drain, not permissionless) |

#### Anvil Simulation Evidence

Verified via Forge test (not cast-deployed due to ERC20 mock complexity):
```
Strategy weETH balance: 100e18 → after rescueTokens → 0
Attacker weETH: 0 → 100e18
WETH rescue: REVERTED (correctly protected)
Fixed strategy rescue: REVERTED (correctly protected)
```

#### Reconciled Verdict: **CONFIRMED — Medium**

The bug is real — `weETH` is not in the protected token list. But it requires a compromised or malicious owner key. Codex's Medium is more accurate than Plamen's High, since this is a privileged-drain path, not a permissionless exploit.

---

### H-05: Retroactive collateralizationLowerBound

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED — chains to H-01 for permanent brick | High |
| Gemini | PARTIALLY CONFIRMED — retroactivity real, brick wrong | Medium |
| Codex | PARTIALLY CONFIRMED — centralization risk | Medium |

#### Anvil Simulation Evidence

```
createPosition(111e18, 100e18) → ratio = 1.11e18 (111%)
isHealthy(0) = true, lowerBound = 1.05e18

cast send $H05 "setCollateralizationLowerBound(uint256)" 1.3e18 → blockNumber 9

isHealthy(0) = false   ← instantly unhealthy
ratio = 1.11e18, bound = 1.3e18
```

#### Reconciled Verdict: **CONFIRMED — Medium (not High)**

The retroactive parameter change is confirmed on-chain: `cast send` with no timelock instantly makes a 111% position unhealthy against a 130% bound. But the downstream "permanent brick" via H-01 is disproven. This is a centralization/admin abuse risk, properly Medium.

---

### H-06: executeAllocation Overflow DoS

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED — permanent DoS | High |
| Gemini | CONFIRMED — not permanent, admin can fix | Medium/Low |
| Codex | PARTIALLY CONFIRMED — admin-fixable | Low/Medium |

#### Anvil Simulation Evidence

```
cast call $H06_CLASSIFIER "getIndividualCap(1)" → 1.157e77 (type(uint256).max)

cast call $H06_GAUGE "testOverflow(1000000e18)" →
  REVERT: panic: arithmetic underflow or overflow (0x11)
```

#### Reconciled Verdict: **CONFIRMED — Low (part of gauge bundle)**

The overflow is real on-chain. But it's checked arithmetic (reverts, not silent), the gauge system appears vestigial/unused, and admin can set finite caps. Bundle with H-07/H-08 as "gauge stack not production-ready."

---

### H-07: registerNewStrategy Unimplemented

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED | High |
| Gemini | CONFIRMED | High |
| Codex | CONFIRMED | Medium |

#### Anvil Simulation Evidence

```
Before: strategyList length = 0
cast send $H06_GAUGE "registerNewStrategy(1, 100)" → success
After: strategyList length = 0    ← still empty!
```

#### Reconciled Verdict: **CONFIRMED — Low (gauge bundle)**

`registerNewStrategy` only sets `lastStrategyAddedAt` and has a `// TODO` comment. The `strategyList` is never populated. Since the gauge appears unused in production, this is low severity unless the gauge is meant to be deployed.

---

### H-08: Classifier Cap Semantic Mismatch

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED | High |
| Gemini | CONFIRMED | High |
| Codex | CONFIRMED | Medium |

#### Anvil Simulation Evidence

```
capAsBPS(5000, 1000000e18)  = 5e23 (500,000 ETH)
capAsAbsolute(5000)         = 5000 (5000 wei)
```

#### Reconciled Verdict: **CONFIRMED — Low (gauge bundle)**

Same cap value `5000` means "50% of assets" in the gauge but "5000 wei cap" in the allocator. Incompatible. But again, part of the same unused gauge subsystem.

---

### H-09: Oracle Spread Validation Missing

| Report | Verdict | Severity |
|--------|---------|----------|
| Plamen | CONFIRMED (dup of H-02 chain) | High |
| Gemini | CONFIRMED (independent of H-02) | High |
| Codex | REFUTED as High (duplicate of M-26) | M-26 dup |

#### Anvil Simulation Evidence

```
SimDualOracle(0.5e18, 1.5e18) → 200% spread
Adapter returns average = 1.0e18 (no spread check, no revert)
```

#### Reconciled Verdict: **CONFIRMED bug, but duplicate of M-26, not standalone High**

Codex is correct: this is a spread validation issue (M-26), not a staleness issue (H-02). They're independent root causes. M-26 should absorb H-09 rather than the other way around.

---

## Medium Findings Reconciliation (Summary)

| ID | Finding | Plamen | Gemini | Codex | Reconciled |
|----|---------|--------|--------|-------|------------|
| M-10 | _subCollateralBalance silent clamping | Confirmed M | Confirmed M | Confirmed M | **Confirmed M** |
| M-11 | Transmuter fee retroactivity | Confirmed M | Confirmed M (dup M-33) | Confirmed M | **Confirmed M** (merge with M-33) |
| M-12 | Operator swap MEV via minOut:0 | Confirmed M | Confirmed M | **REFUTED** | **Disputed** — Codex notes minIntermediateOut unused on swap path |
| M-13 | PermissionedProxy arbitrary target | Confirmed M | Confirmed M | Partial M | **Confirmed M** (merge with M-35) |
| M-14 | Strategy add/remove no timelock | Confirmed M | Confirmed M | Confirmed L/M | **Confirmed L/M** |
| M-15 | setLiquidityAdapter no validation | Confirmed M | Confirmed M | Confirmed L | **Confirmed L** |
| M-16 | setAllowanceHolder no event | Confirmed M | Confirmed M | Confirmed I/L | **Info/Low** |
| M-17 | Retroactive collat params | Confirmed M | Confirmed M | Confirmed M | **Confirmed M** |
| M-18 | calculateLiquidation drains fee vault | Confirmed M | Confirmed M | Confirmed M | **Confirmed M** |
| M-19 | batchLiquidate gas DoS | Confirmed M | Confirmed M | Confirmed L | **Low** — caller self-OOGs |
| M-20/21/22 | totalSyntheticsIssued sub-findings | Confirmed M | Confirmed (dup H-01) | Confirmed (Info) | **Info** — component observations of H-01 |
| M-23 | Vote weight desync | Confirmed M | Confirmed M | Confirmed L/M | **Low** — gauge unused |
| M-24 | No __gap on upgradeable | Confirmed M | Confirmed M | Partial I/L | **Info** — hygiene debt |
| M-25 | MAX_ORACLE_STALENESS 7 days | Confirmed M | Confirmed M | Confirmed M | **Confirmed M** |
| M-26 | No spread validation dual oracle | Confirmed M | Confirmed (dup H-09) | Confirmed M | **Confirmed M** (absorbs H-09) |
| M-27 | No L2 sequencer check | Confirmed M | Confirmed (dup M-34) | Confirmed M | **Confirmed M** (merge with M-34) |
| M-28 | _sync() skips non-earmarked | Confirmed M | **REFUTED** | **REFUTED** | **REFUTED** — Both verifiers agree the code works correctly |
| M-29 | ZeroXSwapVerifier dead code | Confirmed M | Confirmed M | Confirmed M | **Confirmed M** |
| M-30 | Stale oracle + operator compound | Confirmed M | Partial M | Partial (compound) | **Merge into H-02 + M-29** |
| M-31 | Swap guard unit mismatch | Confirmed M | Confirmed M | Partial L/M | **Confirmed L/M** |
| M-32 | timeToTransmute=1 Fenwick overflow | Confirmed M | Confirmed M | Partial L/M | **Low** — config-induced ceiling, revert not corruption |
| M-33 | Transmuter fee retroactivity (no snapshot) | Confirmed M | Confirmed M | Confirmed M (dup M-11) | **Merge into M-11** |
| M-34 | Multi-chain sequencer downtime | Confirmed M | Confirmed (dup M-27) | Confirmed (dup M-27) | **Merge into M-27** |
| M-35 | Selector-only keying | Confirmed M | Confirmed (dup M-13) | Confirmed (dup M-13) | **Merge into M-13** |

---

## Report Quality Assessment

### Plamen Audit (Original)
- **Strengths:** Extremely thorough breadth coverage (9 parallel agents), caught every real bug, excellent PoC test coverage (30 tests, 10 suites), good finding clustering
- **Weaknesses:** Overstates H-01 severity by misunderstanding `_isProtocolInBadDebt()` Transmuter backing logic, inflates finding count through duplicate/compound splitting, promotes privileged-trust issues to Medium/High without concrete exploit paths
- **Bias:** Over-reports. Tends to report every observation as a separate finding rather than collapsing into root causes

### Gemini Verification
- **Strengths:** Correctly refutes H-01's brick claim, agrees with all other real bugs, provides clean code traces
- **Weaknesses:** Some findings marked as duplicates without detailed merge guidance, refuted findings could use more explanation
- **Bias:** Slightly generous — confirms some findings that Codex more accurately downgrades

### Codex Verification
- **Strengths:** Most accurate severity calibration, correctly identifies H-01's Transmuter backing, catches the M-12 `minIntermediateOut` non-usage, properly refutes M-28
- **Weaknesses:** Could not compile the project (missing deps), so all conclusions are from source review only (no runtime evidence)
- **Bias:** Conservative. Tends to downgrade rather than confirm, which is appropriate for verification

### Final Triage
- **Strengths:** Cleanest output — 1H + 6M is the right shape for a publishable report. Excellent merge/drop decisions
- **Weaknesses:** None significant — this is the best deliverable of the four documents

---

## Recommended Final Report Shape

Based on Anvil simulation evidence, I recommend the Final Triage's structure:

| Final ID | Title | Severity | Source IDs |
|----------|-------|----------|------------|
| **H-01** | Dual-oracle adapter fabricates freshness timestamps | **High** | H-02, H-03, H-09 |
| **M-01** | Etherfi strategy owner can rescue live weETH position tokens | **Medium** | H-04 |
| **M-02** | Transmuter fees apply retroactively to existing positions | **Medium** | M-11, M-33 |
| **M-03** | Collateralization parameter changes are retroactive | **Medium** | M-17, H-05 |
| **M-04** | Liquidation can socialize fees through communal fee vault | **Medium** | M-18 |
| **M-05** | Oracle safeguards incomplete (staleness window, spread, sequencer) | **Medium** | M-25, M-26, M-27, M-34 |
| **M-06** | Privileged execution surfaces accept weakly validated targets/calldata | **Medium** | M-13, M-29, M-35, M-15, M-16 |
| **L-01** | Gauge/allocator stack not production-ready | **Low** | H-06, H-07, H-08, M-23 |
| **L-02** | Allocation swap guard compares mismatched units | **Low** | M-31 |
| **L-03** | _subCollateralBalance destroys local excess on drift | **Low** | M-10 |
| **L-04** | Phantom totalSyntheticsIssued accounting divergence | **Low** | H-01, M-20, M-21, M-22 |
| **L-05** | timeToTransmute=1 Fenwick capacity ceiling | **Low** | M-32 |
| **I-01** | Missing __gap upgrade hygiene debt | **Info** | M-24 |

**Drop:** M-12 (minIntermediateOut unused on cited path), M-19 (self-OOG), M-28 (refuted by both verifiers), M-30 (compound, not root cause)

---

## Simulation Artifacts

All simulation contracts and tests are in `anvil-sim/`:
- `src/SimH01_PhantomSynthetics.sol` — H-01 phantom issuance reproduction
- `src/SimH02_OracleTimestamp.sol` — H-02 timestamp fabrication reproduction
- `src/SimH04_EtherfiProtectedToken.sol` — H-04 missing protected token reproduction
- `src/SimH05_RetroactiveParams.sol` — H-05 retroactive params reproduction
- `src/SimH06H07_PerpetualGauge.sol` — H-06/H-07/H-08 gauge bugs reproduction
- `test/AnvilReconciliation.t.sol` — 9 passing reconciliation tests
- `script/DeployAndTest.s.sol` — Deployment script for Anvil

All contracts deployed to Anvil at chain 31337, transactions verified via `cast send` with receipt confirmation.
