# Invariant Map

> Alchemix V3 | 27 guards | 19 single-contract + 7 cross-contract + 3 economic inferred | 12 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`_checkState(!depositsPaused)` · `AlchemistV3.sol:419` · Guardian emergency brake — halts new collateral inflow during incidents without touching existing positions.

#### G-2
`_checkState(!_isProtocolInBadDebt())` · `AlchemistV3.sol:420,484,503` · Blocks protocol growth (deposit/mint/mintFrom) while synthetics issued exceed backing — the solvency entry gate.

#### G-3
`_checkState(_mytSharesDeposited + amount <= depositCap)` · `AlchemistV3.sol:421` · Caps total MYT collateral, bounding protocol blast radius per chain.

#### G-4
`_checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount)` · `AlchemistV3.sol:453` · Prevents withdrawals from dipping into collateral that backs outstanding debt.

#### G-5
`_checkState(!loansPaused)` · `AlchemistV3.sol:478` · Guardian brake on new debt issuance; burn/repay deliberately remain open during pause.

#### G-6
`if (block.number == lastMintBlock) revert CannotRepayOnMintBlock()` · `AlchemistV3.sol:516,559` · Anti-round-trip: blocks burn/repay in the same block as a mint on the same position (flash-loan loop guard).

#### G-7
`if (credit > totalSyntheticsIssued - ITransmuter(transmuter).totalLocked()) revert BurnLimitExceeded(...)` · `AlchemistV3.sol:532` · Preserves enough outstanding synthetic supply to honor every open Transmuter stake (maintains X-1).

#### G-8
`if (block.number == _accounts[tokenId].lastRepayBlock) revert CannotMintOnRepayBlock()` · `AlchemistV3.sol:930` · Mirror of G-6 — blocks mint in the same block as a repay; permissionless repay makes this third-party-triggerable.

#### G-9
`if (collateralValue < required) revert Undercollateralized()` · `AlchemistV3.sol:1290` · Core LTV check in `_addDebt` — every new debt unit must be over-collateralized at `minimumCollateralization`.

#### G-10
`_checkState(_accounts[accountId].debt > 0)` · `AlchemistV3.sol:739` · Liquidation requires live debt; zero-debt positions are untouchable by liquidators.

#### G-11
`if (cumulativeEarmarked > totalDebt) { cumulativeEarmarked = totalDebt; }` · `AlchemistV3.sol:1306-1308` · Silent clamp keeping global earmarked debt within total debt after partial repayments (enforces I-3).

#### G-12
`if (totalDebt == 0) return; if (block.number <= lastEarmarkBlock) return;` · `AlchemistV3.sol:1583-1584` · Earmark idempotence — at most one earmark accrual per block, none when no debt exists.

#### G-13
`_checkArgument(fee <= BPS)` · `AlchemistV3.sol:167-169,262,270,278` · Bounds protocol/liquidator/repayment fees to 100% at initialization and every setter (write-site-complete; lifts to I-4).

#### G-14
`_checkArgument(value >= FIXED_POINT_SCALAR)` + ordering clamps/checks · `AlchemistV3.sol:301-333` · Maintains the collateralization parameter ordering chain (lifts to I-5); note the setters clamp silently rather than revert.

#### G-15
`_checkArgument(value >= IERC20(myt).balanceOf(address(this)))` · `AlchemistV3.sol:245` · Prevents setting a deposit cap below current holdings — keyed on raw balance, so direct MYT donations raise the floor.

#### G-16
`if (totalActiveLocked + syntheticDepositAmount > depositCap) revert DepositCapReached()` · `Transmuter.sol:183-185` · Caps simultaneously-staked synthetic, sizing the redemption pipeline.

#### G-17
`if (totalLocked + syntheticDepositAmount > alchemist.totalSyntheticsIssued()) revert DepositCapReached()` · `Transmuter.sol:187-189` · A stake can never promise more redemptions than synthetics exist (caller side of X-1).

#### G-18
`if (position.startBlock == block.number) revert PrematureClaim()` + `if (_requireOwned(id) != msg.sender) revert CallerNotOwner()` · `Transmuter.sol:216,225` · Same-block stake/claim round-trip block + NFT-ownership gate on claims.

#### G-19
`if (block.number < position.maturationBlock) revert PositionNotMatured(...)` + `if (!_countsTowardCap[id]) revert PositionAlreadyPoked(id)` · `Transmuter.sol:328-332` · `pokeMatured` frees cap headroom exactly once per matured position.

#### G-20
`_checkArgument(fee <= BPS)` · `Transmuter.sol:85-87,136,144` · Bounds transmutation/exit fees to 100% at constructor and both setters (write-site-complete; note retroactivity concern in x-ray.md).

#### G-21
`if (killSwitch) revert StrategyAllocationPaused(...)` + `require(!killSwitch, "emergency")` · `MYTStrategy.sol:70,168` · Strategy kill switch gates new allocations and reward claims; deallocation intentionally stays open so funds can exit.

#### G-22
`require(totalValueAfter >= assets, "inconsistent totalValue")` · `MYTStrategy.sol:116` · Post-deallocation conservation check — strategy value reported to the vault must still cover the requested assets.

#### G-23
`if (selector == FORCE_DEALLOCATE_SELECTOR && (action != ActionType.direct || !_canForceDeallocate())) revert ForceDeallocateSwapNotAllowed()` · `MYTStrategy.sol:145` · Blocks permissionless `VaultV2.forceDeallocate` from reaching attacker-supplied swap calldata (commits 07ecc24, 0749ddb).

#### G-24
`if (amountReceived < minAmountOut) revert InvalidAmount(minAmountOut, amountReceived)` · `MYTStrategy.sol:133` · `dexSwap` slippage floor measured by balance delta of the buy token.

#### G-25
`require(msg.sender == admin || operators[msg.sender], "PD")` + `require(amount <= remainingGlobal)` + `require(vault.allocation(id) + amount <= limit)` · `AlchemistAllocator.sol:33,165,174` · Role gate plus cumulative per-strategy and per-risk-class cap enforcement on every allocation.

#### G-26
`require(raw > 0 && updatedAt != 0)` + `require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS)` · `OraclePricedSwapStrategy.sol:141-142` · Oracle answer validity and freshness for all swap sizing and position valuation (see X-7 for the Frax-adapter exception).

#### G-27
`require(permissionedCalls[selector], "PD")` · `PermissionedProxy.sol:68` · Operator proxy calls are selector-whitelisted (whitelist model — switched from denylist in b273fcb).

#### G-28
`require(nft.ownerOf(tokenId) == msg.sender, "Not position owner")` · `AlchemistRouter.sol:345,367,439` · Router custody flows (withdraw/self-liquidate) only operate on positions the caller owns.

#### G-29
`require(assetsReceived >= amount * (BASIS_POINTS - params.slippageBPS) / BASIS_POINTS, "Deposit value below minimum")` · `TokeAutoStrategy.sol:82` · Allocation value floor against Tokemak share-pricing slippage.

#### G-30
`require(ethReceived >= shortfall, "Insufficient ETH redeemed")` + `require(redemptionManager.canRedeem(...))` · `EtherfiEETHStrategy.sol:110-125` · Direct deallocation only proceeds when Ether.fi instant redemption can cover the request net of exit fee.

---

## 2. Inferred Invariants (Single-Contract)

Derivation methods: Δ-pair, guard lift + write sites, state-machine edge, temporal predicate, NatSpec-stated. Categories: Conservation · Bound · Ratio · StateMachine · Temporal.

---

#### I-1

`Conservation` · On-chain: **No**

> `_mytSharesDeposited == Σ _accounts[id].collateralBalance` (global share tracker equals sum of per-position collateral)

**Derivation** — Δ-pair: `deposit()` `AlchemistV3.sol:433 ↔ 437` (+amount to both) and `_subCollateralBalance` `AlchemistV3.sol:1038 ↔ 1039` (−amount from both). Gap: `redeem()` debits the global side only (`:720,:725`) while per-account debits happen lazily in `_sync` (`:1456`); the clamp in `_subCollateralBalance` (account balance reconciled down to `_mytSharesDeposited`) exists precisely to absorb this drift.

**If violated** — Per-position collateral claims exceed shares actually held; last withdrawers absorb the gap (the reconciliation clamp concentrates losses on unsynced accounts).

---

#### I-2

`Conservation` · On-chain: **No**

> `totalDebt == Σ _accounts[id].debt`

**Derivation** — Δ-pair: `_addDebt` `AlchemistV3.sol:1292 ↔ 1293`, `_subDebt` `:1303 ↔ 1304`. Gap: `redeem()` reduces `totalDebt` globally (`:707`) while account debt is rewritten lazily from weight accumulators in `_sync` (`:1464`).

**If violated** — Global solvency math (`_isProtocolInBadDebt`, global collateralization in liquidation) diverges from the sum of positions until every account is poked.

---

#### I-3

`Bound` · On-chain: **Yes**

> `cumulativeEarmarked <= totalDebt`

**Derivation** — guard-lift: clamp at `AlchemistV3.sol:1306-1308` (G-11); earmark increments are computed against unearmarked debt in `_earmark` (`:1637`). Write sites of `cumulativeEarmarked`: `_earmark` (+, bounded), `_subEarmarkedDebt` (−), `redeem` (rewrites to `remainingEarmarked` `:706`).

**If violated** — Redemption pipeline would earmark debt that doesn't exist, underflowing `_subDebt`/`_earmark` weight math.

---

#### I-4

`Bound` · On-chain: **Yes**

> `protocolFee, liquidatorFee, repaymentFee ∈ [0, BPS]`

**Derivation** — guard-lift: `_checkArgument(fee <= BPS)` at all write sites — `initialize` `AlchemistV3.sol:167-169`, `setProtocolFee:262`, `setLiquidatorFee:270`, `setRepaymentFee:278`.

**If violated** — Fee deductions exceed principal in repay/liquidation paths.

---

#### I-5

`Bound` · On-chain: **Yes**

> `1e18 <= collateralizationLowerBound < minimumCollateralization <= min(globalMinimumCollateralization, liquidationTargetCollateralization)` and `liquidationTargetCollateralization <= 2e18`

**Derivation** — guard-lift across all write sites: `initialize` `AlchemistV3.sol:170`, `setMinimumCollateralization:301-310` (clamps to global min and liquidation target), `setGlobalMinimumCollateralization:315`, `setCollateralizationLowerBound:322-323`, `setLiquidationTargetCollateralization:330-333`. Note `setMinimumCollateralization` silently clamps instead of reverting (event now emits stored value, bc94cf2).

**If violated** — Positions could mint at or below the liquidation threshold (instantly liquidatable mints) or liquidation targets below the borrow threshold.

---

#### I-6

`Bound` · On-chain: **Yes**

> `_mytSharesDeposited <= depositCap` on the growth path

**Derivation** — guard-lift: G-3 at `AlchemistV3.sol:421` — the only write site that increases `_mytSharesDeposited` is `deposit()`. `setDepositCap:245` floors the cap at the current raw MYT balance (donation-sensitive, see G-15).

**If violated** — Per-chain exposure exceeds the governance-set ceiling.

---

#### I-7

`StateMachine` · On-chain: **Yes**

> `alchemistPositionNFT` is a one-shot latch: `address(0) → nft`, never re-settable

**Derivation** — edge: `address(0)@AlchemistV3.sol:205 → nft@209` (`setAlchemistPositionNFT` reverts if already set).

**If violated** — Admin could swap the NFT contract, re-keying ownership of every CDP.

---

#### I-8

`StateMachine` · On-chain: **Yes**

> Admin handover is two-step everywhere: `pendingAdmin` set, then accepted by the pending address itself

**Derivation** — edge: `pendingAdmin != 0@AlchemistV3.sol:230 → admin=pendingAdmin; pendingAdmin=0@236-237`; same pattern `Transmuter.sol:106-113`, `PermissionedProxy.sol:44-49`, `AlchemistStrategyClassifier.sol:52-57`. No write site rejects `pendingAdmin = address(0)` — nominating zero is a (recoverable) cancel, but nominating a wrong address is only recoverable while the current admin retains the seat.

**If violated** — Single-transaction admin transfer to an unverified address.

---

#### I-9

`Temporal` · On-chain: **Yes**

> A position cannot mint and repay/burn in the same block (in either order)

**Derivation** — temporal: `block.number == lastMintBlock → revert` `AlchemistV3.sol:516,559`; `block.number == lastRepayBlock → revert` `:930`; markers set at `:938` (mint), `:541` (burn), `:593` (repay). Keyed per position on `block.number` — and `repay`/`burn` are callable by anyone on any tokenId, so third parties can set `lastRepayBlock`.

**If violated** — Single-block mint/repay round trips re-enable flash-loan-shaped manipulation of earmark/fee accounting.

---

#### I-10

`Temporal` · On-chain: **Yes**

> A Transmuter position pays full yield only at/after `maturationBlock` fixed at creation; cap headroom is released exactly once per position

**Derivation** — temporal: `maturationBlock = block.number + timeToTransmute` at creation `Transmuter.sol:193`; `pokeMatured` requires `block.number >= maturationBlock` `:328-330`; one-shot `_countsTowardCap[id] true→false` edges at `:299-301` and `:332-334`.

**If violated** — Early claimants extract full value before the redemption pipeline earmarked it, or cap headroom is double-released.

---

#### I-11

`Bound` · On-chain: **No**

> `depositCap >= totalActiveLocked` (Transmuter cap should never be set below already-locked synthetic)

**Derivation** — NatSpec: `ITransmuter.sol:97` — *"`cap` must be greater or equal to current synths locked in the transmuter"*. Structural check of the write site: `setDepositCap` `Transmuter.sol:127-130` validates only `cap <= int256.max` — the NatSpec-stated floor is not enforced.

**If violated** — Cap below locked total is tolerated by `createRedemption` math (it compares sums), but the documented admin precondition is unenforced — an admin can strand the cap below current locks.

---

#### I-12

`Bound` · On-chain: **No**

> `params.slippageBPS < 5000` (constructor intent: max 50% slippage tolerance)

**Derivation** — guard-lift with inconsistent write sites: constructor `require(_params.slippageBPS < 5000)` `MYTStrategy.sol:55` vs setter `require(newSlippageBPS < 9999)` `MYTStrategy.sol:221-222`. The setter admits values the constructor forbids.

**If violated** — Owner can raise effective slippage tolerance to 99.98%, hollowing out every strategy's swap floor (G-24, G-29).

---

#### I-13

`Ratio` · On-chain: **No**

> Fenwick graph stake rate symmetry: the negative stake removed at claim equals the positive stake rate added at creation

**Derivation** — Ratio: create adds `+amount * BLOCK_SCALING_FACTOR / timeToTransmute` (value of `timeToTransmute` *at creation*) `Transmuter.sol:196`; claim removes `−position.amount * BLOCK_SCALING_FACTOR / transmutationTime` (value *at claim time*) `Transmuter.sol:283`. The two rates reference the same storage variable at different times; `setTransmutationTime` (`:151-154`) can change it while positions are open.

**If violated** — Residual phantom (or missing) stake persists in the graph after early claims, skewing `queryGraph` and therefore earmark sizing in `AlchemistV3._earmark`.

---

#### I-14

`Conservation` · On-chain: **Yes**

> `totalLocked == Σ open positions' amount`

**Derivation** — Δ-pair: `createRedemption` `Transmuter.sol:193 ↔ 198` (+amount to position and totalLocked); `claimRedemption` `:304 ↔ 308` (−amount and delete).

**If violated** — Burn limit G-7 and create-side cap G-17 operate on wrong totals.

---

#### I-15

`Conservation` · On-chain: **No**

> `totalSyntheticsIssued >= totalDebt` (synthetic supply attributed to this alchemist always covers live debt)

**Derivation** — Δ-pair analysis across write sites: `_mint` increments both equally (`AlchemistV3.sol:933` + `:1293`); `burn` decrements both equally (`:543` + `:1303-1304`); `repay`/`liquidate`/`redeem` decrement `totalDebt` only; `reduceSyntheticsIssued` (`:822`, transmuter-only) decrements `totalSyntheticsIssued` only. The invariant holds only if cumulative `reduceSyntheticsIssued` never exceeds cumulative debt-only decrements — no on-chain check ties the two.

**If violated** — `_isProtocolInBadDebt` compares a stale-high or over-reduced `totalSyntheticsIssued` against backing: too high falsely gates deposits/mints; too low masks genuine bad debt.

---

#### I-16

`Bound` · On-chain: **No**

> AlEth: `hasMinted[minter] <= ceiling[minter]` *(inactive contract — see x-ray.md §1 backwards-compatibility)*

**Derivation** — guard-lift: `mint` `AlEth.sol:55-57` increments `hasMinted` with no read of `ceiling`; `ceiling` written at `:82` is never checked. Additionally `setWhitelist:65`, `pauseAlchemist:73`, `setCeiling:81` have no access control.

**If violated** — N/A in production if unwired (zero in-repo callers), but any deployment of this file as-is allows unbounded whitelisting and minting.

---

#### I-17

`StateMachine` · On-chain: **No**

> PerpetualGauge: `executeAllocation` operates over registered strategies *(inactive subsystem)*

**Derivation** — negative scan: `strategyList` (`PerpetualGauge.sol:175`) has no write site anywhere; `registerNewStrategy:110-112` only stamps `lastStrategyAddedAt` (TODO at `:112`). `getCurrentAllocations`/`executeAllocation` iterate an always-empty list.

**If violated** — N/A — the subsystem cannot act; recorded so auditors don't model gauge-driven allocation as live.

---

#### I-18

`Bound` · On-chain: **Yes**

> After any deallocation, strategy `_totalValue() >= assets` requested

**Derivation** — guard-lift: single choke-point write path — every deallocation routes through `MYTStrategy.deallocate` which enforces `require(totalValueAfter >= assets)` `MYTStrategy.sol:116` (G-22).

**If violated** — Strategy reports less value than the vault is about to pull, desynchronizing VaultV2 allocation accounting.

---

#### I-19

`Temporal` · On-chain: **Yes**

> Every oracle answer used for swap sizing/valuation is positive and no older than `MAX_ORACLE_STALENESS`

**Derivation** — temporal: `OraclePricedSwapStrategy.sol:141-142` (G-26); `MAX_ORACLE_STALENESS` write sites: constructor + `setMaxOracleStaleness:170-171` (`> 0` enforced). Exception documented in X-7.

**If violated** — Stale prices size swaps and value `realAssets()`, mispricing MYT shares vault-wide.

---

**Categories:** Conservation (Δ-pairs), Bound (lifted guards), Ratio (formula-defined storage), StateMachine (guarded one-way edges), Temporal (block/timestamp predicates).

---

## 3. Inferred Invariants (Cross-Contract)

---

#### X-1

On-chain: **Yes**

> `AlchemistV3.totalSyntheticsIssued >= Transmuter.totalLocked` — every staked synthetic remains redeemable against issued supply

**Caller side** — `Transmuter.sol:187-189` — `createRedemption` refuses stakes that would exceed `alchemist.totalSyntheticsIssued()`.

**Callee side** — `AlchemistV3.sol:532-534` — `burn()` refuses to reduce `totalSyntheticsIssued` below `transmuter.totalLocked()`; `reduceSyntheticsIssued:822` is transmuter-only and paired with its own claim-side burns (`Transmuter.sol:292-293`).

**If violated** — Open Transmuter stakes could not all be honored; claims would be scaled or revert.

---

#### X-2

On-chain: **No**

> Every MYT balance change of the Transmuter is observed by AlchemistV3's cover accounting (`lastTransmuterTokenBalance` / `_pendingCoverShares`)

**Caller side** — `AlchemistV3.sol:1586-1607` — `_earmark` derives `_pendingCoverShares` from the delta `safeBalanceOf(myt, transmuter) − lastTransmuterTokenBalance` and spends it as redemption cover; `setTransmuterTokenBalance:826-847` (transmuter-only) re-syncs after claims.

**Callee side** — In-scope writers of that balance: `repay` `AlchemistV3.sol:584` (synced via `_syncEarmarkedTransmuterTransfer:856`), `redeem:~713` transfers, self-liquidation/liquidation transfers to the transmuter, `Transmuter.claimRedemption` outflows (`Transmuter.sol:285-289`). Unguarded path: any direct MYT ERC20 transfer to the transmuter address changes the balance without a sync hook.

**If violated** — Cover/earmark suppression or inflation: untracked inflows are misread as redemption cover (or pending cover is double-counted), shifting redemption burden between earmarked and non-earmarked positions.

---

#### X-3

On-chain: **No**

> The bad-debt gate's "backing" reflects only protocol-controlled value

**Caller side** — `AlchemistV3.sol` `_isProtocolInBadDebt()` — `backingUnderlying = _getTotalLockedUnderlyingValue() + convertYieldTokensToUnderlying(safeBalanceOf(myt, transmuter))`, gating deposit/mint at `:420,484,503`.

**Callee side** — The transmuter MYT balance term is a raw `balanceOf` — written by in-scope flows (repay, redeem, liquidations, claims) *and* by anyone via plain ERC20 transfer.

**If violated** — Donations raise apparent backing (masking bad debt past the gate) and their withdrawal-equivalent (claims) lowers it; the gate's threshold is externally movable at donation cost.

---

#### X-4

On-chain: **Yes**

> A Transmuter claim's redemption pull, synthetic burn, and issuance reduction stay synchronized

**Caller side** — `Transmuter.sol:257-296` — `claimRedemption` calls `alchemist.redeem(amountToRedeem)`, burns the transmuted synthetic (`safeBurn:292`), calls `alchemist.reduceSyntheticsIssued(burnAmountDebt):293`, then `alchemist.setTransmuterTokenBalance(...):296`.

**Callee side** — `AlchemistV3.redeem:655-727` (onlyTransmuter) moves collateral and reduces `totalDebt`; `reduceSyntheticsIssued:821-823` and `setTransmuterTokenBalance:826-847` are `onlyTransmuter`, so no third party can desynchronize the trio.

**If violated** — Debt retired without synthetic burned (or vice versa) — the I-15 ledger drifts.

---

#### X-5

On-chain: **Yes**

> Risk-cap semantics agree between classifier and allocator: caps are WAD fractions of `vault.totalAssets()`

**Caller side** — `AlchemistAllocator.sol:135-174` — `_validateCaps` multiplies classifier caps against `vault.totalAssets()` and checks cumulative `vault.allocation(id) + amount`.

**Callee side** — `AlchemistStrategyClassifier.sol:16-23,38-40` — caps documented and defaulted as WAD (1e18 = 100%); admin-only `setRiskClass:61-65` writes them.

**If violated** — Unit mismatch (the pre-f6f9edc WEI/WAD bug class) silently disables or over-tightens risk caps.

---

#### X-6

On-chain: **Yes**

> Every position NFT transfer invalidates all outstanding mint allowances for that position

**Caller side** — `AlchemistV3Position.sol:137` — `_update` hook calls `IAlchemistV3(alchemist).resetMintAllowances(tokenId)` on every non-mint transfer.

**Callee side** — `AlchemistV3.sol:880-890` — `resetMintAllowances` (callable only by NFT contract or owner) bumps `allowancesVersion`, voiding the `mintAllowances` map for prior versions.

**If violated** — A buyer of a position would inherit the seller's delegated minters. Side effect to note: benign custody round-trips (e.g., router withdraw flows) also wipe allowances.

---

#### X-7

On-chain: **No**

> Oracle freshness guard G-26 assumes `updatedAt` is the price's publication time

**Caller side** — `OraclePricedSwapStrategy.sol:142` — staleness computed as `block.timestamp - updatedAt`.

**Callee side** — `FrxEthEthDualOracleAggregatorAdapter.sol:36` — returns `updatedAt = block.timestamp` (synthesized; documented at `:9-11` because the Frax dual oracle exposes no publication time). For this source the staleness check always evaluates to zero; freshness rests on the dual oracle's own `isBadData` flag (`:30`) and swap slippage floors.

**If violated** — A wedged-but-not-flagged Frax price is accepted indefinitely for SFraxETHStrategy sizing and valuation.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **No**

> Global solvency: `totalSyntheticsIssued <= normalizeUnderlyingTokensToDebt(lockedCollateralValue + transmuterMYTValue)` at all times

**Follows from** — I-15 + X-3 (+ G-2 as the enforcement point)

**If violated** — The protocol is in bad debt. Enforcement is entry-only (G-2 blocks deposit/mint); withdraw, redeem, and claim paths do not re-check it, and the backing term is donation-movable (X-3), so the invariant is a monitored property, not a machine guarantee.

---

#### E-2

On-chain: **No**

> Continuous position solvency: every position satisfies `collateralValue >= debt × minimumCollateralization`

**Follows from** — G-9 + G-4 (action-time enforcement) + I-5 (threshold ordering)

**If violated** — Enforced only at mint/withdraw time; between actions, MYT share-price moves can push positions into the band between `collateralizationLowerBound` and `minimumCollateralization` where they are neither operable nor liquidatable — liquidation (G-10 + health checks) is the backstop, not a guarantee.

---

#### E-3

On-chain: **No**

> Transmuter promise: a matured stake of `X` alAsset claims MYT worth `X` in debt units, scaled down only by the bad-debt ratio and `transmutationFee`

**Follows from** — I-10 + I-13 + I-14 + X-2 + X-4

**If violated** — Claims are silently underpaid (earmark under-sizing via I-13/X-2 gaps) or overpaid (cover double-count), redistributing value between stakers and CDP holders; the bad-debt scaling itself is explicitly best-effort per protocol docs *(per spec)*.
