# X-Ray Report

> Alchemix V3 | 4,361 nSLOC | b1506d8 (`master`) | Foundry | 12/06/26

---

## 1. Protocol Overview

**What it does:** Self-repaying loans — users deposit yield-bearing MYT vault shares as collateral, mint a synthetic alAsset against them at up to ~90% LTV, and the collateral's yield plus a continuous redemption pipeline pays the debt down without borrower action.

- **Users**: Borrowers (CDP owners via position NFTs), alAsset stakers (Transmuter redeemers), permissionless liquidators, trusted operators (capital allocation), DAO admin + guardians.
- **Core flow**: deposit MYT → mint alAsset → Transmuter stakers earmark slices of everyone's debt per block → matured stakes redeem debt + collateral → debt shrinks passively.
- **Key mechanism**: CDP engine with lazy per-position accounting (packed Q128 weight accumulators sync positions on touch), a Fenwick-tree staking graph sizing per-block earmarks, and a Morpho VaultV2 ("MYT") routing collateral across 10 strategy adapters.
- **Token model**: MYT (ERC4626-style vault share, the collateral), alAsset (`AlTokenV3` xERC20 synthetic, the debt), `AlchemistV3Position` (ERC721 CDP), Transmuter stake NFTs.
- **Admin model**: DAO multisig admin on every contract (two-step transfer, no timelocks in scope); guardians can pause deposits/loans; curator/allocator operators are trusted roles per protocol docs *(per spec)*; cap increases on the MYT vault go through VaultV2's own timelock.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Core CDP | AlchemistV3, AlchemistV3Position, AlchemistV3PositionRenderer | 1,215 | Collateral, debt, earmark/redemption accounting, liquidations, position NFTs |
| Redemption | Transmuter, StakingGraph, FixedPointMath | 464 | alAsset→MYT staking queue, Fenwick graph, Q128 math |
| Synthetic token | AlTokenV3 | 40 | Cross-chain canonical alAsset (xERC20 bridge limits) |
| Yield ops | MYTStrategy, AlchemistAllocator, AlchemistCurator, AlchemistStrategyClassifier, PermissionedProxy | 541 | Strategy adapter base, cap-checked allocation, adapter lifecycle, risk classes |
| Strategies | AaveStrategy, ERC4626Strategy, MoonwellStrategy, TokeAutoStrategy, OraclePricedSwapStrategy, WstETHEthereumStrategy, WstETHL2Strategy, SFraxETHStrategy, EtherfiEETHStrategy, SiUSDStrategy | 953 | Per-protocol adapters under the MYT vault |
| Periphery | AlchemistRouter, AlchemistETHVault, AlchemistTokenVault, AbstractFeeVault, AlchemistGate, Whitelist, FrxEthEthDualOracleAggregatorAdapter, EulerUSDCAdapter | 542 | One-tx UX router, liquidator fee vaults, oracle adapter |
| Support libs | TokenUtils, SafeERC20, SafeCast, Sets, NFTMetadataGenerator | 269 | Safe token calls, casting, on-chain SVG |
| Inactive (in repo, no callers) | PerpetualGauge, ZeroXSwapVerifier, AlEth | 329 | See backwards-compatibility note below |

### Backwards-Compatibility / Inactive Code

- `PerpetualGauge` — gauge-voting allocation; `strategyList` has no write path and `registerNewStrategy` is a TODO stub, so `executeAllocation` iterates an empty list. Declared "unused and out of scope" by protocol docs *(per spec)*. Not active functionality.
- `ZeroXSwapVerifier` — fully implemented 0x Settler calldata verifier with **zero import sites** in `src/` (only tests). Swap-calldata validation in live paths relies on slippage floors instead.
- `src/external/AlEth.sol` — stripped local copy of the legacy alETH token with **no access control on `setWhitelist`/`pauseAlchemist`/`setCeiling`** and an unenforced mint ceiling; zero in-repo callers outside tests. Worth confirming it is excluded from deployment artifacts.
- `AlchemistV3.tokenAdapter` + `EulerUSDCAdapter` — `tokenAdapter` is written by its setter (`AlchemistV3.sol:288`) and never read; the Euler price adapter has no callers.
- `AlchemistGate` — authorization map with no in-repo consumers (intended as a VaultV2 gate, wired off-chain if at all).
- `AlchemistV3.lastRedemptionBlock` — written (`:188`, `:710`) and never read.

### How It Fits Together

The core trick: debt is repaid *globally and lazily* — the Transmuter earmarks a per-block slice of all debt (sized by its Fenwick staking graph), and each position discovers its share of redeemed debt/collateral only when next touched, via Q128 weight-accumulator deltas in `_sync`.

### Deposit & Borrow

```
AlchemistRouter.depositETH()
├─ WETH.deposit()                          ── wrap
├─ VaultV2(MYT).deposit()                  ── ETH → MYT shares
└─ AlchemistV3.deposit()
   ├─ _earmark()                           ── *global accrual runs before every state change*
   ├─ AlchemistV3Position.mint()           ── new CDP NFT (tokenId 0)
   ├─ MYT.safeTransferFrom(user → alchemist)
   └─ AlchemistV3.mint() / mintFrom()
      ├─ _sync(tokenId)                    ── *position catches up on redemptions*
      ├─ _addDebt()                        ── LTV check here (G-9)
      └─ alAsset.safeMint(recipient)       ── totalSyntheticsIssued += amount
```

### Earmark → Redeem Pipeline

```
Transmuter.createRedemption(amount)
├─ alAsset.safeTransferFrom(staker → transmuter)
└─ StakingGraph.addStake(rate = amount/timeToTransmute)

AlchemistV3._earmark()                      ── piggybacks on every user action
├─ Transmuter.queryGraph(lastEarmarkBlock+1, block.number)
├─ cover: Δ(transmuter MYT balance) → _pendingCoverShares   ── *untracked donations enter here (X-2)*
└─ cumulativeEarmarked += effective; _earmarkWeight updated

Transmuter.claimRedemption(id)              ── after maturationBlock
├─ AlchemistV3.redeem(amount)
│  ├─ totalDebt -= effectiveRedeemed        ── *global only; positions sync later*
│  ├─ MYT.safeTransfer(→ transmuter)        ── collateral backing the redeemed debt
│  └─ _mytSharesDeposited -= collRedeemed
├─ alAsset.safeBurn(transmuted)  +  AlchemistV3.reduceSyntheticsIssued()
├─ MYT.safeTransfer(→ claimer, scaled by bad-debt ratio)
└─ AlchemistV3.setTransmuterTokenBalance()  ── re-sync cover accounting
```

### Liquidation

```
AlchemistV3.liquidate(accountId)            ── permissionless
├─ _earmark() → _sync(accountId)
├─ _forceRepay(earmarked portion)           ── *uses position collateral; repayment fee path*
│  └─ may restore health → early return     ── fee re-check added in cbe70ed
├─ calculateLiquidation()                   ── partial to target, or full if global ratio low
├─ MYT → Transmuter (debt) ; MYT fee → liquidator
└─ IFeeVault.withdraw(liquidator)           ── outsourced fee when collateral can't cover (FeeShortfall event)
```

### Capital Allocation

```
AlchemistAllocator.allocateWithSwap(adapter, amount, txData)   ── operator
├─ _validateCaps()                          ── vault absolute/relative + classifier WAD risk caps, cumulative
└─ VaultV2.allocate(adapter, params, amount)
   └─ MYTStrategy.allocate()                ── onlyVault, killSwitch-gated
      └─ _allocate(amount, txData)
         └─ dexSwap(allowanceHolder, txData) ── *0x calldata executes against strategy approvals*
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Lending/Borrowing (CDP)** with **Stablecoin** and **Yield Aggregator** characteristics

CDP signals dominate (deposit/mint/repay/liquidate, collateralization ratios, liquidation target restoration); the alAsset + Transmuter redemption queue is a stablecoin peg mechanism; the MYT/strategy/allocator layer is a yield aggregator on Morpho VaultV2.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Admin (DAO multisig) | Trusted *(per spec)* | ~25 instant setters per deployment incl. all collateralization ratios (retroactive, no grace period), all fees (≤100%, retroactive), transmuter address, fee receivers. Two-step transfer but zero operational delay. |
| Guardian | Bounded (pause-only) | `pauseDeposits`/`pauseLoans` — bidirectional (can also unpause). Cannot touch funds or params. |
| Operator (allocator/curator) | Trusted *(per spec)* | Moves vault capital between strategies with arbitrary 0x swap calldata (`minIntermediateOut: 0` on swap paths per runbook); adds/removes adapters (adds via VaultV2 timelock); cumulative WAD risk caps bound operators but `admin` bypasses local caps (`AlchemistAllocator.sol:168`). |
| Strategy owner | Trusted | Per-strategy: killSwitch, slippageBPS (up to 99.98%, I-12), allowanceHolder address, oracle address + staleness, rescueTokens (protected-token-gated). |
| Transmuter (contract) | Trusted by AlchemistV3 | Only caller of `redeem`/`reduceSyntheticsIssued`/`setTransmuterTokenBalance`; admin can repoint `Transmuter.alchemist` and `AlchemistV3.transmuter` pairing. |
| Position owner | Bounded (own position) | withdraw/mint/selfLiquidate/approveMint on owned tokenIds only. |
| Liquidator | Bounded (health-gated) | Permissionless liquidate/batchLiquidate below `collateralizationLowerBound`; paid from victim collateral or fee vault. |
| Any address | Bounded (griefing-shaped) | `deposit` into, `repay`/`burn` against any position (sets its `lastRepayBlock`); `poke` any position; donate to transmuter/fee vaults. |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Accounting-drift attacker** — exploits the lazy global-vs-per-position reconciliation (earmark/sync/redeem) that dominates fix history and paid bounties.
2. **Oracle/share-price manipulator** — MYT share price is the collateral price; it aggregates strategy `realAssets()` including Chainlink and a synthesized-timestamp Frax feed.
3. **Permissionless-touch griefer** — third-party `repay`/`deposit`/`poke` on arbitrary positions interacts with same-block guards and fee deductions.
4. **Donation attacker** — raw-balance reads (transmuter MYT balance, fee vaults, deposit-cap floor) are externally movable.
5. **Compromised operator/strategy-owner** — trusted by program scope, but the swap-calldata and slippage-parameter surface defines the blast radius if that trust fails.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Admin → all protocol params** — two-step seat transfer only; every operational setter is instant; worst instant action: collateralization-bound changes that re-classify every position's health (`AlchemistV3.sol:301-333`). *Git signal: AlchemistV3.sol has 57 modifications and 6 of the top-10 fix-scored commits.*

- **Transmuter ↔ AlchemistV3 pairing** — `onlyTransmuter` gates redemption-side state (`redeem`, `reduceSyntheticsIssued`, `setTransmuterTokenBalance`); `setAlchemist`/transmuter repointing has no migration logic for weight accumulators.

- **Operator → vault capital** — `PermissionedProxy.proxy` is selector-whitelisted (G-27, switched from denylist) and allocator caps are cumulative (G-25), but swap `txData` content is unverified on-chain (ZeroXSwapVerifier unwired); slippage floors are the only economic backstop.

- **MYT vault (Morpho VaultV2, internalized lib) → collateral valuation** — `convertYieldTokensToUnderlying` trusts `VaultV2.convertToAssets`, which sums strategy `realAssets()`; the vault code itself is out of audit scope but lives in `lib/vault-v2` as an internalized fork.

- **Guardian → pause** — bidirectional pause/unpause (can prematurely unpause during an incident); burn/repay/withdraw/liquidate are deliberately never pausable.

### Key Attack Surfaces

- **Earmark/sync/redeem weight pipeline** &nbsp;[[I-1](invariants.md#i-1), [I-2](invariants.md#i-2), [I-3](invariants.md#i-3)] — `_earmark` (`AlchemistV3.sol:1583-1640`), `_sync` (`:1430-1471`), `redeem` (`:655-727`) reconcile global totals against lazily-synced positions via packed Q128 epoch/index accumulators; worth tracing epoch transitions, the survival accumulator, and `_subCollateralBalance`'s reconciliation clamp across interleavings of repay/redeem/poke.

- **Transmuter cover-shares sync** &nbsp;[[X-2](invariants.md#x-2), [X-3](invariants.md#x-3)] — `_pendingCoverShares`/`lastTransmuterTokenBalance` (`AlchemistV3.sol:826-847,1586-1607`) infer cover from raw balance deltas; worth checking every MYT-transfer-to-transmuter path (repay, both liquidation flavors, redeem, donations) updates the snapshot consistently.

- **Liquidation fee paths** &nbsp;[[G-13](invariants.md#g-13), [E-2](invariants.md#e-2)] — `_liquidate`/`_forceRepay`/`calculateLiquidation` (`AlchemistV3.sol:739-1205`) blend repayment fees, surplus-based liquidator fees, and fee-vault outsourcing; four of the top fix-scored commits (0dd2836, 92adbd7, bea4436, fb4c225) live here — worth re-deriving the fee math against the health re-check added in cbe70ed.

- **`totalSyntheticsIssued` ledger asymmetry** &nbsp;[[I-15](invariants.md#i-15), [E-1](invariants.md#e-1), [X-4](invariants.md#x-4)] — mint/burn move it, repay/liquidate/redeem don't, `reduceSyntheticsIssued` moves it alone; worth confirming the transmuter-side burn pairing covers every debt-clearing path the bad-debt gate depends on.

- **Permissionless third-party touches** &nbsp;[[I-9](invariants.md#i-9)] — `repay`/`burn`/`deposit` accept any tokenId and stamp `lastRepayBlock` (`AlchemistV3.sol:541,593`), which gates the owner's `mint` (`:930`); worth checking dust-sized touches against mint availability and fee deduction from victim collateral.

- **Operator swap surface** &nbsp;[[G-24](invariants.md#g-24), [G-27](invariants.md#g-27), [I-12](invariants.md#i-12)] — `dexSwap` executes arbitrary `allowanceHolder` calldata under approval (`MYTStrategy.sol:126-133`); runbook hardcodes `minIntermediateOut: 0` on swap paths and the verifier library is unwired; worth quantifying worst-case extraction within slippage floors per strategy.

- **Collateral valuation chain** &nbsp;[[X-7](invariants.md#x-7), [I-19](invariants.md#i-19)] — Alchemist conversions → VaultV2 share price → strategy `realAssets()` → oracles; the Frax adapter synthesizes `updatedAt = block.timestamp` (`FrxEthEthDualOracleAggregatorAdapter.sol:36`), making G-26 a no-op for that source; worth mapping which deployments rely on which feed and what `isBadData` actually covers.

- **Strategy deallocation liveness** &nbsp;[[G-22](invariants.md#g-22), [G-30](invariants.md#g-30)] — Etherfi instant-redemption availability, SiUSD gateway queue/floors (`SiUSDStrategy.sol:91-113`), and Tokemak iterative unwinding all sit on the vault's withdrawal path; worth checking each strategy's behavior when the external protocol gates exits while `killSwitch` (allocate-only) is engaged.

- **Position NFT custody flows** &nbsp;[[X-6](invariants.md#x-6)] — router withdraw/self-liquidate round-trips transfer the CDP NFT through the router, firing `resetMintAllowances` twice; worth checking integrations that assume allowances survive routine router usage.

- **Same-block guard granularity on L2s** — guards keyed on `block.number` (`:516,559,930`; Transmuter `:216`) inherit each chain's block semantics (Arbitrum's `block.number` tracks L1); worth confirming `timeToTransmute` and round-trip windows per target chain.

### Upgrade Architecture Concerns

- **AlchemistV3 behind TransparentUpgradeableProxy** — dense hand-packed storage (Q128 accumulators, epoch maps at `AlchemistV3.sol:113-141`); worth verifying gap/layout discipline on every upgrade — the contract previously brushed the EIP-170 size limit, so refactors under size pressure are likely.
- **Post-initialize configuration window** — `initialize` doesn't set `alchemistPositionNFT` or the fee vault; deposits before NFT wiring revert, but the window between proxy init and full wiring deserves a deployment-script check.
- **AlTokenV3 implementation self-locks** (`constructor() initializer`), limiting implementation-takeover surface.

### Protocol-Type Concerns

**As a CDP/Lending protocol:**
- Liquidation restores to `liquidationTargetCollateralization` only when globally healthy; below `globalMinimumCollateralization` it goes full-seizure (`calculateLiquidation`, `AlchemistV3.sol:781+`) — the regime switch is a discontinuity worth fuzzing around the boundary.
- The health band between `collateralizationLowerBound` and `minimumCollateralization` is neither operable nor liquidatable by design — positions parked there only move via earmark/redemption or price.

**As a Stablecoin:**
- `_isProtocolInBadDebt` divides at 18-dec normalization (`normalizeUnderlyingTokensToDebt`) — 6-decimal underlying (USDC deployments) makes 1-wei rounding near the gate threshold meaningful.
- Transmuter claim scaling (bad-debt ratio) is explicitly best-effort *(per spec)* — "fairness" findings are out of program scope, but ratio-manipulation timing is not.

**As a Yield Aggregator:**
- `realAssets()` must never revert (Morpho VaultV2 liveness assumption) — oracle reverts were a vault-wide DoS pre-f1f2dff; worth re-checking each strategy's `_totalValue()` failure modes after the oracle-replaceability fix.
- ERC4626 strategies use `previewRedeem` in `_totalValue` (`ERC4626Strategy.sol:46-50`) — fee-charging vault integrations depend on that choice staying consistent across new strategy copies.

### Temporal Risk Profile

**Deployment & Initialization:**
- Post-init wiring window (NFT, fee vault, transmuter pairing) — mitigated by revert-on-unset but unverified ordering in deploy scripts; keystore/gnosis deployment per 49a04bd.
- Fresh-market dust: 6-decimal markets with near-zero `totalSyntheticsIssued` make the bad-debt gate twitchy (1-wei phantom issuance trips G-2).

**Market Stress:**
- MYT share price falls → mass positions in the unliquidatable band (E-2); fee vault drains via outsourced fees during global undercollateralization (FeeShortfall events are the only signal).
- Strategy exit gates (Etherfi liquidity, SiUSD queue, Aave utilization) can pin the vault's liquidity adapter while the Transmuter keeps promising MYT — documented as intended *(per spec)*, but the earmark pipeline keeps accruing meanwhile.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Morpho VaultV2 (MYT)** — via `AlchemistV3.convertYieldTokensToUnderlying`, `Transmuter.claimRedemption`, all allocator calls
> - Assumes: honest `convertToAssets/convertToShares`; adapters never revert in `realAssets()`
> - Validates: NONE (price taken as-is)
> - Mutability: internalized fork in `lib/vault-v2` (not a submodule — upstream fixes won't auto-propagate); vault config via curator timelock
> - On failure: valuation chain reverts → deposits/mints/liquidations revert

> **Chainlink feeds + FrxEth adapter** — via `OraclePricedSwapStrategy._oracleAnswer`
> - Assumes: positive price, real `updatedAt`
> - Validates: staleness + positivity (G-26); Frax source synthesizes `updatedAt` (X-7) and relies on `isBadData`
> - Mutability: oracle address owner-replaceable per strategy (post-f1f2dff)
> - On failure: swap paths and `_totalValue` revert (vault-wide impact pre-fix; replaceability is the recovery path)

> **0x AllowanceHolder/Settler** — via `MYTStrategy.dexSwap`
> - Assumes: calldata produced by trusted operator from a real quote
> - Validates: balance-delta ≥ minAmountOut only; calldata content unverified (verifier lib unwired)
> - Mutability: `allowanceHolder` owner-settable per strategy
> - On failure: swap revert bubbles up; approval reset to 0 after each call

> **External yield protocols (Aave, Moonwell, Lido, Frax, Ether.fi, InfiniFi, Tokemak)** — via strategy `_allocate/_deallocate`
> - Assumes: synchronous exits within each strategy's supported routes; protocol-specific exit fees/queues respected per route guards (G-29, G-30)
> - Validates: per-strategy floors and balance checks
> - Mutability: all upgradeable/governed third parties
> - On failure: deallocation reverts → vault withdrawal liveness depends on idle buffer + other strategies

> **Connext/xERC20 bridges** — via `AlTokenV3.burn/burnFrom` + inherited mint limits
> - Assumes: per-bridge limits configured; cross-chain supply accounting handled by bridge layer
> - Validates: burn/mint limits when caller is a registered bridge
> - Mutability: bridge registry via inherited admin functions (lib v2-foundry)
> - On failure: bridge mint/burn reverts at limit

**Token Assumptions** *(unvalidated only)*:
- MYT and alAsset are protocol-controlled (standard 18-dec, no hooks) — `TokenUtils` tolerates no-return-value tokens but nothing handles fee-on-transfer or rebasing collateral; assumption is safe only while collateral remains the in-house MYT.
- Underlying USDC (6 dec): `underlyingConversionFactor` paths assume `decimals <= 18`.

**Shared State Exposure**:
- The transmuter's raw MYT balance is shared state between the cover system, the bad-debt gate, and claim scaling — any holder can move it (X-2, X-3).
- alAsset liquidity pools (peg) are external; protocol explicitly tolerates sub-peg pricing under withdrawal queues *(per spec)*.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **30 Enforced Guards** (`G-1` … `G-30`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **19 Single-Contract Invariants** (`I-1` … `I-19`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **7 Cross-Contract Invariants** (`X-1` … `X-7`) — caller/callee pairs that cross scope boundaries
> - **3 Economic Invariants** (`E-1` … `E-3`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks (12 of 29) are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-2]`, `[I-15]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present (template) | Repo-template boilerplate; protocol-specific docs live elsewhere |
| NatSpec | Thorough on interfaces | Repo convention: interfaces are the documentation entrypoint (`src/interfaces/IAlchemistV3.sol` is 914 lines); implementations use `@inheritdoc` |
| Spec/Whitepaper | Operational runbooks present | `ALCHEMIST_ALLOCATOR_RUNBOOK.md` (caller rules per allocation route), `STRATEGY_DEPLOYMENT_RUNBOOK.md` (adapter contract + `realAssets()` liveness rules), `SECURITY.md` |
| Inline Comments | Adequate | Dense in weight-accumulator math; sparse in fee paths |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 72 | File scan (always reliable) |
| Test functions | 606 | File scan (always reliable) |
| Line coverage | Unavailable — stack-too-deep | `forge coverage` fails; `--ir-minimum` retry hits a Yul "variable too deep" exception in `AlchemistV3.sol` liquidation code |
| Branch coverage | Unavailable — same | Coverage tool requires compilation without via-IR optimization |

### Test Depth

| Category | Count | Contracts Covered |
|----------|------:|-------------------|
| Unit | ~390 | broad — core, transmuter, router, every strategy |
| Integration | 1 suite + per-strategy allocator tests | `IntegrationTest.t.sol`, `AlchemistAllocator.t.sol` |
| Fork | 15 files | strategy tests against live protocols |
| Stateless Fuzz | 73 | parameterized tests across core + strategies |
| Stateful Fuzz (Foundry) | 145 invariant functions / 6 invariant suites + handler harnesses | `MultiStrategy{ETH,USDC,ARB*,OP*}.invariant.t.sol`, `HardenedInvariantsTest`, `CrucibleTest` |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora/Halmos/HEVM) | 0 | none |

### Gaps

- No formal verification anywhere — the Q128 weight-accumulator and Fenwick-graph math (`FixedPointMath.mulQ128` rounding, `StakingGraph` packing) are the strongest candidates.
- No Echidna/Medusa second fuzzer for the earmark/sync/redeem state space (the area with the densest fix history).
- Coverage metrics unverifiable until the stack-too-deep blocker is resolved (e.g., a coverage profile with via-IR or refactored locals) — 606 test functions exist regardless.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 159 source-touching commits over 225 days (2025-10-29 → 2026-06-11), analyzed branch: `master` at `b1506d8`.

### Contributors

| Author | Commits | Source Lines (+) | % of Source Changes |
|--------|--------:|------------------|--------------------:|
| hesnicewithit | 47 | +10,999 | 67.5% |
| d0m0l33 | 83* | +2,390 | 14.7% |
| silur | 87+10* | +1,638 | 10.0% |
| t0rbik | 9 | +850 | 5.2% |
| Dominic | 22 | +429 | 2.6% |

*commit counts include non-source commits; percentages computed from source line additions. Two identities (silur/Silur, Dominic/domo) appear split.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 9 (≈6 after identity merge) | Small team |
| Merge commits | 30 of 270 (11%) | PR flow exists; majority of commits land direct |
| Repo age | 2025-10-29 → 2026-06-11 | 7.5 months |
| Recent source activity (30d) | 2 source commits | Quiet — stabilization phase |
| Test co-change rate | 69.8% | High file co-modification (not coverage); fix-without-test rate 0% |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/AlchemistV3.sol | 57 | #1 churn AND #1 attack-surface concentration |
| src/strategies/mainnet/WStethStrategy.sol | 16 | path renamed since; wstETH strategy family heavily reworked |
| src/MYTStrategy.sol | 14 | adapter base; access-control + slippage rework |
| src/strategies/OraclePricedSwapStrategy.sol | 13 | oracle hardening series (Apr–May 2026) |
| src/interfaces/IAlchemistV3.sol | 13 | tracks core churn |

### Security-Relevant Commits

**Score** = weighted fix-signal sum; **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 0dd2836 | 2026-02-15 | multi epoch and liquidation fix | 18 | spans 5 security domains, accounting |
| 92adbd7 | 2025-11-12 | audit fixes 56363,56365,56560 (global var consistency, liquidation fee deduction, partial fees) | 18 | 6 domains, fee logic |
| bea4436 | 2026-02-09 | repayment fee stranded when liquidation proceeds after forced repayment | 16 | liquidation fee path |
| fb4c225 | 2025-12-10 | 58616 outsourced fee rounding + no debt dust after liquidation | 16 | rounding guards |
| 49b5747 | 2026-01-13 | 56555 fix rework | 15 | Alchemist+Transmuter, guard removal |
| 568dc65 | 2026-03-10 | alchemist router | 15 | new fund-flow surface |
| f1f2dff | 2026-04-27 | oracle failure DoS — no clean recovery path | 14 | oracle replaceability |
| 372b35d | 2026-03-20 | slippageBPS calc error, wst slippage to 20% | 14 | swap floors |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 107 | AlchemistV3, MYTStrategy, strategies/* |
| access_control | 102 | AlchemistV3, PermissionedProxy, MYTStrategy |
| oracle_price | 78 | OraclePricedSwapStrategy, SFraxETH/SiUSD/wstETH strategies |
| state_machines | 71 | AlchemistV3, MYTStrategy |
| liquidation | 67 | AlchemistV3, Transmuter, Router |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| vault-v2 | lib/vault-v2 | Morpho VaultV2 | **Internalized** (not a submodule) | Upstream security fixes won't auto-propagate; the MYT vault core lives here |
| openzeppelin, chainlink, permit2, solmate, v2-foundry | lib/* | various | Submodules | standard |

### Technical Debt Markers

| File:Line | Type | Text | Author | Date |
|-----------|------|------|--------|------|
| src/PerpetualGauge.sol:112 | TODO | (empty stub — registerNewStrategy) | hesnicewithit | 2025-10-29 |
| src/PerpetualGauge.sol:164 | TODO | double-check limits here? | hesnicewithit | 2025-10-29 |
| src/utils/ZeroXSwapVerifier.sol:128,141 | TODO ×2 | shall we also verify saa.buyToken? | hesnicewithit | 2025-10-29 |

All four sit in inactive code (gauge unused per spec; verifier unwired) — not in live security-critical paths.

### Security Observations

- **Single-dev concentration** — hesnicewithit wrote 67.5% of source lines; core accounting reviewability hinges on one author's intent.
- **Audit-fix cadence visible** — commit subjects directly reference external finding IDs (56363/56555/58616, "1 -", "3 -", "29 -"), tying history to audit rounds.
- **AlchemistV3.sol is both #1 hotspot (57 mods) and host of 6/8 top fix commits** — liquidation + earmark code.
- **Late changes minimal** — only 2 source commits in the last 30 days (oracle decimals handling 5ee5966, configurable forceDeallocate blocking 0749ddb), both with tests.
- **Zero fix-without-test commits** — every fix-scored commit co-changed test files.
- **Internalized vault-v2 fork** — the highest-value dependency is the one that won't receive upstream patches automatically.

### Cross-Reference Synthesis

- **Fix history concentrates exactly where invariants go On-chain=No** — liquidation-fee commits (0dd2836/92adbd7/bea4436/fb4c225) + earmark/cover commits (8dd21a2, 49b5747) → I-1/I-2/I-15/X-2 are the live fault lines, not theoretical ones.
- **Oracle hardening series (Apr–May 2026: f1f2dff, 8247d62, 3baa8dc, 5ee5966) ends at a documented compromise** — X-7's synthesized timestamp is an accepted residual, stated in the adapter's NatSpec.
- **`block forceDeallocate for dex swap paths` (07ecc24) + `configurable forceDeallocate blocking` (0749ddb)** → G-23 was added reactively; the permissionless-forceDeallocate-with-calldata class deserves a regression check on every new strategy.
- **Gauge + verifier TODOs (all from initial commit) match the inactive-code findings** — I-16/I-17 are stale subsystems, not abandoned mid-feature.

---

## X-Ray Verdict

**HARDENED** — unit + stateless fuzz + six stateful invariant suites, interface-thorough NatSpec with operational runbooks, and clear role boundaries with multisig admin and emergency pause; formal verification absent and the TODO markers sit only in inactive code.

**Structural facts:**
1. 4,361 in-scope nSLOC across 7 active subsystems + 3 inactive contracts (gauge, swap verifier, legacy AlEth copy) with zero in-repo callers.
2. 606 test functions in 72 files, including 145 Foundry invariant functions across 6 multi-strategy invariant suites; coverage metrics blocked by stack-too-deep compilation.
3. One contract (AlchemistV3, 1,135 nSLOC, upgradeable behind a transparent proxy) holds all CDP accounting and absorbed 57 modifications plus 6 of the 8 top fix-scored commits.
4. 67.5% of source lines from one developer; 11% merge-commit rate; 0% fix-without-test rate.
5. 30 enforced guards and 29 inferred invariants catalogued; 12 inferred invariants are not enforced on-chain (lazy conservation pairs, cover-sync assumptions, inconsistent setter bounds).
