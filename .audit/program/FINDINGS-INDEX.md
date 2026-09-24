# Alchemix V3 — Plamen Core Audit: Complete Findings Index

**Auditor:** Plamen Core (Claude Code orchestration, ~40 agents)
**Report Date:** April 9, 2026
**Scope:** 61 contracts, ~9,144 lines of Solidity
**Repository:** github.com/alchemix-finance/v3 (main branch)

**Totals:** 9 High | 26 Medium | 57 Low | 16 Informational | 4 Refuted

---

## HIGH SEVERITY (9)

### H-01 · [DEPTH-ST-1] Phantom totalSyntheticsIssued After Liquidation — Permanent Protocol Brick
**Location:** AlchemistV3.sol (selfLiquidate, _doLiquidation, _isProtocolInBadDebt, burn)

`_mint()` increments `totalSyntheticsIssued`. Only `burn()` and `reduceSyntheticsIssued()` decrement it. All other debt-clearing paths (`selfLiquidate()`, `_doLiquidation()`, `repay()`, `_forceRepay()`) call `_subDebt()` which only decrements `totalDebt`. After all positions are liquidated, `totalDebt = 0` but `totalSyntheticsIssued > 0`, causing `_isProtocolInBadDebt()` to return true and permanently block all deposits and mints.

---

### H-02 · [B8-1] Dual Oracle Timestamp Fabrication — Staleness Bypassed
**Location:** FrxEthEthDualOracleAggregatorAdapter.sol

One oracle source in the dual oracle adapter uses `block.timestamp` as its `updatedAt` value instead of the actual oracle's timestamp. The staleness check computes `block.timestamp - updatedAt`, which equals 0 for this source, meaning stale prices are never detected.

---

### H-03 · [DEPTH-EC-3] Dual Oracle block.timestamp − block.timestamp = 0
**Location:** FrxEthEthDualOracleAggregatorAdapter.sol

Depth confirmation of H-02. The adapter literally computes `block.timestamp - block.timestamp = 0` as the staleness value for one oracle feed. Any price, no matter how old, passes the freshness check.

---

### H-04 · [DEPTH-EX-2] Stale Oracle → Inflated MYT → Overvalued Collateral Chain
**Location:** FrxEthEthDualOracleAggregatorAdapter → AlchemistV3

Full attack chain built on H-02/H-03: stale oracle inflates MYT share price → `convertYieldTokensToUnderlying()` returns inflated collateral values → borrowers appear over-collateralized → can extract more than real backing allows. Quantified at $4.5M+ phantom value at $30M TVL.

---

### H-05 · [B5-1] EtherfiEETH Missing _isProtectedToken — weETH Drainable
**Location:** EtherfiEETHStrategy.sol

`EtherfiEETHStrategy` does not override `_isProtectedToken()`. The base `MYTStrategy` only protects `asset()` (WETH), not weETH (the yield-bearing token). Admin can call `rescueTokens(weETH, amount)` and drain the strategy's entire TVL.

---

### H-06 · [DEPTH-ST-7] Retroactive LowerBound → Mass Liquidation → Permanent Brick
**Location:** AlchemistV3.sol (setCollateralizationLowerBound)

Admin can raise `collateralizationLowerBound` with no grace period or timelock. All positions instantly become liquidatable. Mass liquidation triggers H-01 (phantom totalSyntheticsIssued), permanently bricking the protocol. No market movement required.

---

### H-07 · [B7-1] PerpetualGauge executeAllocation Overflow DoS
**Location:** PerpetualGauge.sol

`executeAllocation()` computes `totalIdleAssets * cap / 10_000`. Default cap is `type(uint256).max`. This multiplication overflows in Solidity 0.8.x (reverts), permanently DoSing the gauge until cap is explicitly set to a reasonable value.

---

### H-08 · [B7-2] PerpetualGauge registerNewStrategy Unimplemented
**Location:** PerpetualGauge.sol

`registerNewStrategy()` is a no-op. `strategyList` is never populated by any code path (constructor, initialization, or otherwise). `executeAllocation()` iterates over an empty list and does nothing.

---

### H-09 · [SCA-1] Classifier Cap Semantic Mismatch — BPS vs Absolute WEI
**Location:** IStrategyClassifier.sol, PerpetualGauge.sol, AlchemistAllocator.sol

`PerpetualGauge` interprets cap values as BPS (divides by 10,000). `AlchemistAllocator._validateCaps()` treats them as absolute WEI. No single cap value works correctly for both consumers. The interface comment `// e.g. in bps or absolute` confirms the unresolved design ambiguity.

---

## MEDIUM SEVERITY (26)

### M-01 · [B1-1] _subCollateralBalance Silent Clamping
**Location:** AlchemistV3.sol

When an account's `collateralBalance` exceeds the global `_mytSharesDeposited`, `_subCollateralBalance` silently clamps to the global cap. The excess collateral is destroyed rather than distributed proportionally among all accounts. Redemptions concentrate losses on active accounts.

---

### M-02 · [B1-11] Transmuter Fee Retroactive on Locked Positions
**Location:** Transmuter.sol

Admin can set `transmutationFee` to 100% (10,000 BPS) at any time. Existing locked positions are subject to the new fee immediately on redemption. No per-position fee snapshot exists.

---

### M-03 · [B2-1] Operator Swap MEV via minIntermediateOut:0
**Location:** AlchemistAllocator.sol

`allocateWithSwap` and `deallocateWithSwap` hardcode `minIntermediateOut: 0`. The operator controls swap calldata and faces zero slippage protection, enabling sandwich extraction on every swap.

---

### M-04 · [B2-2] PermissionedProxy Arbitrary Target Calls
**Location:** PermissionedProxy.sol

`proxy()` calls any vault with arbitrary calldata, gated only by a 4-byte function selector whitelist. There is no target address validation. Any approved selector can be called on any address.

---

### M-05 · [B2-4] Curator Adds/Removes Strategies Without Timelock
**Location:** AlchemistCurator.sol

The curator can add or remove strategies instantly. No timelock or delay mechanism exists, allowing immediate strategy manipulation.

---

### M-06 · [B2-7] setLiquidityAdapter No Validation
**Location:** AlchemistAllocator.sol

`setLiquidityAdapter()` accepts any address without validation. The operator can redirect liquidity operations to a malicious adapter contract.

---

### M-07 · [B2-10] setAllowanceHolder No Event, No Timelock
**Location:** MYTStrategy.sol

`setAllowanceHolder()` changes who can spend strategy tokens. No event is emitted and no timelock applies, making changes invisible to monitors.

---

### M-08 · [B3-5] Collateralization Parameters Retroactive — Mass Liquidation Risk
**Location:** AlchemistV3.sol

Admin can change `minimumCollateralization`, `globalMinimumCollateralization`, `collateralizationLowerBound`, and `liquidationTargetCollateralization` with no timelock or grace period. Positions that were healthy become instantly liquidatable without any market movement.

---

### M-09 · [B6-1] calculateLiquidation Drains Fee Vault on Insolvent Positions
**Location:** AlchemistV3.sol

When `debt >= collateral` (insolvent position), `calculateLiquidation` returns `outsourcedFee = debt * feeBps / BPS`. This fee is paid from the shared fee vault funded by all users, not from the position's insufficient collateral. Mass insolvency drains the vault.

---

### M-10 · [B6-2] batchLiquidate Unbounded Loop Gas DoS
**Location:** AlchemistV3.sol

`batchLiquidate()` iterates over an array of tokenIds with no maximum length check. Each iteration costs ~100-115K gas. Large arrays cause out-of-gas reverts, blocking liquidation of many positions in a single transaction.

---

### M-11 · [B6-5] selfLiquidate Does Not Reduce totalSyntheticsIssued
**Location:** AlchemistV3.sol

`selfLiquidate()` calls `_subDebt()` which only decrements `totalDebt`. `totalSyntheticsIssued` is untouched, contributing to phantom issuance (root cause of H-01).

---

### M-12 · [B6-6] _doLiquidation Does Not Reduce totalSyntheticsIssued
**Location:** AlchemistV3.sol

Same issue as M-11 for the external liquidation path. `_doLiquidation()` → `_subDebt()` leaves `totalSyntheticsIssued` unchanged.

---

### M-13 · [B6-10] Phantom totalSyntheticsIssued Blocks Deposits
**Location:** AlchemistV3.sol

After phantom issuance accumulates via M-11 and M-12, `_isProtocolInBadDebt()` returns true. `deposit()` and `mint()` check this condition and permanently revert.

---

### M-14 · [B7-3] PerpetualGauge Vote Weight Desync
**Location:** PerpetualGauge.sol

Vote weights desynchronize from actual allocations over time. Balance changes after voting do not update weight tracking, causing phantom weight inflation.

---

### M-15 · [B7-4] No __gap on Upgradeable Proxy
**Location:** AlchemistV3.sol

AlchemistV3 uses TransparentUpgradeableProxy but has no `__gap` reserved storage slots in its inheritance chain. Adding new storage variables in an upgrade would corrupt the layout of existing position data.

---

### M-16 · [B8-2] MAX_ORACLE_STALENESS Set to 7 Days
**Location:** OraclePricedSwapStrategy.sol

The oracle staleness window is 7 days. For DeFi pricing, this is far too long. Prices can deviate significantly within hours, let alone days.

---

### M-17 · [B8-5] No Spread Validation in Dual Oracle
**Location:** FrxEthEthDualOracleAggregatorAdapter.sol

The dual oracle adapter combines two price sources but never validates the spread between them. A compromised or malfunctioning oracle could feed wildly different prices without detection.

---

### M-18 · [B8-6] No L2 Sequencer Uptime Check
**Location:** OraclePricedSwapStrategy.sol

Oracle contracts do not check L2 sequencer status. During sequencer downtime, stale prices would be accepted without any freshness validation.

---

### M-19 · [DEPTH-ST-6] _sync() Skips Non-Earmarked Accounts — Wealth Transfer
**Location:** AlchemistV3.sol (_sync)

Accounts with zero earmarked balance are skipped during debt synchronization. When Transmuter redeems, only earmarked accounts receive debt reduction benefits. This creates a systematic wealth transfer from earmarked to non-earmarked accounts.

---

### M-20 · [DEPTH-EX-1] ZeroXSwapVerifier Never Called — Arbitrary Calldata
**Location:** MYTStrategy.sol (dexSwap), ZeroXSwapVerifier.sol

`dexSwap()` executes `allowanceHolder.call(callData)` with operator-supplied calldata. `ZeroXSwapVerifier.sol` is fully implemented but has zero import sites. Without verification, operator can supply arbitrary calldata against the strategy's approvals.

---

### M-21 · [DEPTH-EX-7] Stale Oracle + Operator Calldata Compound Extraction
**Location:** FrxEthEthDualOracleAggregatorAdapter + AlchemistAllocator

Combines H-02 (stale oracle inflates collateral valuation) with M-03 (operator controls swap calldata with zero slippage protection). The compound effect allows operator to extract value while collateral appears healthy.

---

### M-22 · [DA-1] Swap Guard Unit Mismatch — No Valid minAllocationOutBps
**Location:** AlchemistAllocator.sol (_allocationSwapGuard)

The guard computes output in underlying asset units (WETH) but actual swap output is in oracle token units (wstETH, weETH). For premium tokens like wstETH (~1.2x WETH), any `minAllocationOutBps > 0` causes all swaps to revert. Setting it to 0 disables the guard entirely.

---

### M-23 · [SGI-4] timeToTransmute=1 Causes Fenwick DELTA_MAX Overflow
**Location:** Transmuter.sol (addStake, Fenwick tree)

When `timeToTransmute` is set to 1 block, per-block earmark rate equals `depositAmount * 1e8`. Fenwick `DELTA_MAX = 2^111-1`. Overflow occurs at ~26M alETH TVL. Admin has no minimum validation on `timeToTransmute`.

---

### M-24 · [DEPTH-ST-2] Transmuter Fee Retroactivity — No Per-Position Snapshot
**Location:** Transmuter.sol

The `StakingPosition` struct has no fee snapshot field. `claimRedemption()` uses the current global `transmutationFee` rather than the fee at lock time. Admin fee changes apply retroactively to all locked positions.

---

### M-25 · [DEPTH-EX-3] Multi-Chain Sequencer Downtime — No Check
**Location:** OraclePricedSwapStrategy.sol

Confirmed across multiple chain deployment configurations. No L2 sequencer uptime feed is checked anywhere in the oracle pipeline. Duplicate confirmation of M-18 from depth analysis.

---

### M-26 · [DEPTH-EX-5] Selector-Only Keying Depth Confirmation
**Location:** PermissionedProxy.sol

Depth confirmation of M-04. The proxy gates calls by 4-byte function selector only. Selector collision between unrelated functions is feasible, expanding the attack surface beyond intentional permission grants.

---

## LOW SEVERITY (57)

### L-01 · [B1-2] Anti-Round-Trip Check Per-TokenId — Cross-Position Bypass
**Location:** AlchemistV3.sol

Anti-round-trip checks are applied per-tokenId. Same-block deposit-then-withdraw across different positions for the same account bypasses the protection.

---

### L-02 · [B1-3] setMinimumCollateralization Silent Clamping
**Location:** AlchemistV3.sol

`setMinimumCollateralization()` silently clamps the value without reverting or emitting an event when the requested value would violate constraints.

---

### L-03 · [B1-4] setGlobalMinimumCollateralization Missing Upper Bound
**Location:** AlchemistV3.sol

No upper bound validation on `globalMinimumCollateralization`. Admin could set it to an unreasonably high value, effectively blocking all new borrows.

---

### L-04 · [B1-6] redeem() Protocol Fee Skipped When _mytSharesDeposited Insufficient
**Location:** AlchemistV3.sol

When global `_mytSharesDeposited` is insufficient to cover the fee, `redeem()` skips the protocol fee entirely rather than reverting. This creates permanent accounting drift.

---

### L-05 · [B1-9] setDepositCap Validates Against balanceOf — Donation Lock
**Location:** AlchemistV3.sol

`setDepositCap()` validates the new cap against `balanceOf()`. A donation that pushes balance above the cap makes it impossible to set a cap below current balance, even if that's the desired limit.

---

### L-06 · [B1-10] AlchemistV3 Fees Retroactive on Existing Positions
**Location:** AlchemistV3.sol

Fee parameter changes apply immediately to all existing positions. No grandfathering or per-position fee snapshot.

---

### L-07 · [B1-12] Earmark Cover Shares Inflatable by MYT Donation
**Location:** AlchemistV3.sol

`_earmark` cover shares can be inflated by donating MYT tokens directly to the contract. This dilutes existing position holders' proportional claims.

---

### L-08 · [B2-3] Guardian Can Both Pause and Unpause — Bidirectional
**Location:** AlchemistV3.sol

The guardian role can both pause and unpause protocol operations. Typically these would be separated (pause = emergency, unpause = governance) to prevent premature unpause during incidents.

---

### L-09 · [B2-8] assignStrategyRiskLevel No Event
**Location:** AlchemistStrategyClassifier.sol

Changing a strategy's risk level emits no event, making monitoring and detection of risk reclassification impossible off-chain.

---

### L-10 · [B2-9] Default Risk Caps Set to type(uint256).max
**Location:** AlchemistStrategyClassifier.sol

Default risk caps are set to `type(uint256).max`, meaning the risk framework is effectively disabled until explicitly configured. No safe default exists.

---

### L-11 · [B2-11] setSlippageBPS Setter Regression (50% → 99.98%)
**Location:** MYTStrategy.sol

The slippage BPS setter allows values up to 9,998 (99.98%) where the previous limit was 5,000 (50%). This is a regression that allows near-zero slippage protection.

---

### L-12 · [B3-4] setTransmutationTime Front-Running Opportunity
**Location:** Transmuter.sol

Admin changing `transmutationTime` creates a front-running window where observers can adjust their positions before the new time takes effect.

---

### L-13 · [B3-6] Protocol Fee Retroactive on Earmarked Debt
**Location:** AlchemistV3.sol

Fee changes apply retroactively to already-earmarked debt. Positions that were profitable under old fee terms become unprofitable under new ones.

---

### L-14 · [B3-7] burn() Floor Uses Stale totalLocked — Temporary Burn DoS
**Location:** AlchemistV3.sol

`burn()` uses a floor based on `totalLocked` which can be stale. During certain state transitions, this causes temporary DoS of burn operations.

---

### L-15 · [B3-9] ERC-4626 Withdrawal Limits Not Handled — High Utilization Blocks Deallocation
**Location:** ERC4626Strategy.sol

`_deallocate()` calls `vault.withdraw()` without checking `maxWithdraw()` first. Under high utilization, the withdrawal reverts and the strategy cannot deallocate.

---

### L-16 · [B4-4] Fee Vaults Use Raw Balance — Donations Become Liquidator Fees
**Location:** AlchemistTokenVault.sol

Fee vaults use raw `balanceOf` rather than tracking accrued fees. Any token donation to the vault becomes available for liquidators to claim.

---

### L-17 · [B4-7] Bridge Rate Limits Could Block Minting
**Location:** AlTokenV3.sol

Rate limits on the bridge could block minting operations during periods of high activity, preventing users from accessing their synthetic tokens.

---

### L-18 · [B5-2] rescueTokens Uses Unsafe Raw Transfer
**Location:** MYTStrategy.sol

`rescueTokens()` uses a raw `transfer()` instead of `safeTransfer()`. For tokens that return no value or revert on failure, this can silently fail or revert unexpectedly.

---

### L-19 · [B5-5] TokeAuto claimRewards Swaps Full Balance
**Location:** TokeAutoStrategy.sol

`claimRewards()` swaps the full token balance rather than only the claimed reward amount. Any pre-existing tokens in the contract get swept into the swap.

---

### L-20 · [B6-3] Health Check Gap Zone — Position Stuck Untouchable
**Location:** AlchemistV3.sol

There is a gap zone between `collateralizationLowerBound` and `minimumCollateralization`. Positions in this zone are neither healthy enough to operate nor unhealthy enough to liquidate. They are stuck and untouchable.

---

### L-21 · [B6-7] No Reentrancy Guard on Liquidation Paths
**Location:** AlchemistV3.sol

Liquidation paths lack explicit reentrancy guards. While the current call flow may be safe due to state ordering, future modifications could introduce reentrancy vectors.

---

### L-22 · [B6-9] Silent Fee Shortfall in _forceRepay
**Location:** AlchemistV3.sol

`_forceRepay()` silently accepts fee shortfalls without reverting. When the fee vault has insufficient funds, the shortfall is absorbed rather than reported as an error.

---

### L-23 · [B7-5] clearVote Leaves voterIndex Stale
**Location:** PerpetualGauge.sol

`clearVote()` removes vote data but leaves `voterIndex` in a stale state. Subsequent vote operations may reference incorrect indices.

---

### L-24 · [B7-6] executeAllocation Global Cap Underflow
**Location:** PerpetualGauge.sol

Under certain conditions, the global cap calculation in `executeAllocation()` can underflow, causing unexpected behavior or reverts.

---

### L-25 · [B8-3] Missing answeredInRound >= roundId Check
**Location:** OraclePricedSwapStrategy.sol

Oracle price feeds should validate `answeredInRound >= roundId` to ensure the returned data is from the current round. This check is missing.

---

### L-26 · [B8-4] No Oracle Price Bounds Check
**Location:** OraclePricedSwapStrategy.sol

No validation that the returned oracle price is within reasonable bounds. A zero price or extreme outlier would be accepted without question.

---

### L-27 · [B8-7] Oracle Revert Causes Complete Strategy DoS
**Location:** OraclePricedSwapStrategy.sol

If the oracle call reverts (feed deactivated, aggregator removed), the entire strategy becomes unusable. There is no fallback or graceful degradation.

---

### L-28 · [B9-3] _isProtocolInBadDebt Uses Raw Transmuter Balance
**Location:** AlchemistV3.sol

`_isProtocolInBadDebt()` uses the raw Transmuter balance as backing. Donations to the Transmuter inflate the apparent backing, masking actual bad debt.

---

### L-29 · [INJ-1] calculateLiquidation Insolvent Path Drains Fee Vault
**Location:** AlchemistV3.sol

On insolvent positions, `calculateLiquidation` requests fees proportional to the full debt from the shared fee vault. During mass insolvency, this drains the vault at `totalInsolventDebt * feeBps / BPS`.

---

### L-30 · [SC-1] transferAdminOwnership(address(0)) Permanent Lockout
**Location:** PermissionedProxy.sol

Calling `transferAdminOwnership(address(0))` sets `pendingAdmin = address(0)`, making `acceptAdminOwnership()` permanently unreachable. Affects AlchemistAllocator and AlchemistCurator.

---

### L-31 · [SC-2] transferOwnership(address(0)) Risk Management Inaccessible
**Location:** AlchemistStrategyClassifier.sol

Same pattern as L-30 for the strategy classifier. `transferOwnership(address(0))` permanently locks risk management functions.

---

### L-32 · [EC-1] BatchLiquidated Event Never Wired
**Location:** AlchemistV3.sol

The `BatchLiquidated` event is defined in the interface but never emitted in the implementation. Off-chain monitors cannot track batch liquidation operations.

---

### L-33 · [EC-2] setAlchemistPositionNFT No Event
**Location:** AlchemistV3.sol

`setAlchemistPositionNFT()` changes the NFT contract reference without emitting an event.

---

### L-34 · [EC-3] NFT Position Admin Setters Missing Events
**Location:** AlchemistV3Position.sol

`setMetadataRenderer()` and `setAdmin()` on the position NFT contract do not emit events.

---

### L-35 · [EC-4] Pending Admin Nomination Events Missing
**Location:** PermissionedProxy.sol, AlchemistStrategyClassifier.sol

Admin nomination/transfer workflows do not emit events for pending changes.

---

### L-36 · [EC-9] AlchemistAllocator Zero Event Emissions
**Location:** AlchemistAllocator.sol

AlchemistAllocator emits no events across any of its functions. All state changes are invisible to off-chain monitoring.

---

### L-37 · [MS-1] repay() No Ownership Check — Victim Fee Deduction
**Location:** AlchemistV3.sol

`repay()` accepts any `tokenId` without checking that the caller owns it. An attacker can repay someone else's debt, deducting fees from the victim's collateral and setting `lastRepayBlock` to block the victim's same-block mint.

---

### L-38 · [MS-2] deposit() No Ownership Check When tokenId != 0
**Location:** AlchemistV3.sol

When depositing into an existing position (`tokenId != 0`), there is no ownership validation. Anyone can deposit collateral into another user's position.

---

### L-39 · [MS-3] Router NFT Round-Trip Wipes approveMint Allowances
**Location:** AlchemistV3.sol, AlchemistV3Position.sol

Router NFT round-trip (approve → transfer → approve back) triggers `resetMintAllowances` twice, wiping all `approveMint` allowances.

---

### L-40 · [MS-4] deallocate() totalValueBefore Unused — No Conservation Check
**Location:** MYTStrategy.sol

`deallocate()` computes `totalValueBefore` but never uses it. There is no conservation check to verify that value is preserved across the deallocation.

---

### L-41 · [DA-2] collateralInUnderlying Holds Debt Units — 1e12 Maintenance Risk
**Location:** AlchemistV3.sol

`collateralInUnderlying` internally holds values in debt token units rather than underlying units. For USDC (6 decimals) vs debt (18 decimals), this creates a 1e12 maintenance hazard for future developers.

---

### L-42 · [DA-3] underlyingConversionFactor uint8 Subtraction Panic at Init
**Location:** AlchemistV3.sol (initialize)

`underlyingConversionFactor` is computed using `uint8(18 - underlyingDecimals)`. If `underlyingDecimals > 18`, this subtraction panics and initialization reverts. No input validation prevents this.

---

### L-43 · [SCA-2] vote() Weights Array No Overflow Guard
**Location:** PerpetualGauge.sol

The `vote()` function's weights array has no overflow guard. Malicious or accidental large values could corrupt the weight distribution.

---

### L-44 · [SCA-3] setRiskClass() No Input Validation
**Location:** AlchemistStrategyClassifier.sol

`setRiskClass()` accepts any input without validation. Invalid or contradictory risk class configurations can be set.

---

### L-45 · [SCA-4] Bad-Debt Normalization Divergence Between Contracts
**Location:** Transmuter.sol + AlchemistV3.sol

Transmuter and AlchemistV3 normalize bad debt using different conventions, creating potential divergence in accounting between the two contracts.

---

### L-46 · [SB-1] deposit() CEI Violation — _mytSharesDeposited After Transfer
**Location:** AlchemistV3.sol

`deposit()` updates `_mytSharesDeposited` after `safeTransferFrom`. This violates Checks-Effects-Interactions, though the practical impact depends on reentrancy possibilities of the MYT token.

---

### L-47 · [SB-3] createRedemption() CEI Violation — totalLocked After Transfer
**Location:** Transmuter.sol

`createRedemption()` updates `totalLocked` after `safeTransferFrom`. Same CEI pattern as L-46.

---

### L-48 · [SB-4] deposit() New Position Doesn't Validate tokenId != 0
**Location:** AlchemistV3.sol

When creating a new position, `deposit()` does not validate that the provided `tokenId != 0`. Token ID 0 may have special meaning or conflict with existing state.

---

### L-49 · [SB-5] deposit() ERC-721 Mint Before _earmark/_sync — Callback in Partial State
**Location:** AlchemistV3.sol

The ERC-721 mint happens before `_earmark` and `_sync` are complete. A callback during minting would see the position in a partially-initialized state.

---

### L-50 · [DEPTH-EX-4] _deallocate() Calls vault.withdraw() Without maxWithdraw() Check
**Location:** ERC4626Strategy.sol

`_deallocate()` calls `vault.withdraw()` without first checking `maxWithdraw()`. Under high vault utilization, this call reverts and blocks deallocation. Same root as L-15, confirmed by depth analysis.

---

### L-51 · [DEPTH-EX-6] deallocateWithSwap SFraxETH Always Reverts
**Location:** AlchemistAllocator.sol

`deallocateWithSwap` for SFraxETH always reverts at `require(minIntermediateOut > 0)` because the parameter is hardcoded to 0 for this strategy.

---

### L-52 · [DEPTH-EC-4] weETH != WETH — Etherfi Drain Confirmation
**Location:** EtherfiEETHStrategy.sol

Depth quantification of H-05. Confirmed that `weETH == WETH` returns false, so the base `_isProtectedToken` does not cover the yield-bearing token.

---

### L-53 · [DEPTH-EC-6] Gap Zone Between Bounds — Positions Untouchable
**Location:** AlchemistV3.sol

Depth confirmation of L-20. Positions between `collateralizationLowerBound` and `minimumCollateralization` are neither liquidatable nor operable.

---

### L-54 · [DEPTH-ST-5] redeem() Fee Skip → Permanent Accounting Drift
**Location:** AlchemistV3.sol

Depth confirmation of L-04. When the fee is skipped, the accounting discrepancy becomes permanent and grows with each skipped redemption.

---

### L-55 · [DEPTH-ST-4] setCollateralizationLowerBound No Grace Period
**Location:** AlchemistV3.sol

Depth confirmation of M-08 for `collateralizationLowerBound` specifically. The setter has no grace period, enabling instant mass liquidation.

---

### L-56 · [DEPTH-ST-8] _subEarmarkedDebt Stale Decrement
**Location:** AlchemistV3.sol

`_subEarmarkedDebt` has a local/global stale decrement pattern. Currently unreachable with existing callers, but flagged as a latent risk for future code paths.

---

### L-57 · [DEPTH-EC-5] batchLiquidate Gas Per Iteration Quantified
**Location:** AlchemistV3.sol

Depth quantification of M-10. Each iteration costs ~100-115K gas, confirming the ~260-300 position limit per block.

---

### L-58 · [SGI-5] _survivalAccumulator Theoretical Overflow
**Location:** AlchemistV3.sol

`_survivalAccumulator` has a theoretical overflow at 1.3e31 on a year-plus timescale. Not practically reachable at current TVL but flagged for future scale.

---

### L-59 · [BLIND-A2] mintFrom Recipient Not Validated — alAsset Stranded
**Location:** AlchemistV3.sol

`mintFrom()` does not validate the `recipient` parameter. If `recipient` is set to a contract address (e.g., a router), the minted alAssets may be permanently stranded.

---

## INFORMATIONAL (16)

### I-01 · [B1-8] normalizeDebtTokensToUnderlying Dust Truncation
**Location:** AlchemistV3.sol

Dust amounts can be truncated to zero during normalization between debt and underlying token decimals. Not a security issue but can cause small accounting discrepancies.

---

### I-02 · [B2-5] No Cap Validation on Deallocations
**Location:** AlchemistAllocator.sol

Deallocations do not validate against caps. This is by design (you should always be able to withdraw), but worth noting for completeness.

---

### I-03 · [B2-6] minIntermediateOut:0 Unused Field — Future Risk
**Location:** AlchemistAllocator.sol

The `minIntermediateOut` parameter is hardcoded to 0 and unused. If activated in the future without proper validation, it could introduce the MEV risk described in M-03.

---

### I-04 · [B4-6] redeem() Fee All-or-Nothing Skip
**Location:** AlchemistV3.sol

`redeem()` either charges the full fee or skips it entirely. There is no partial fee mechanism. This is a design choice, not a bug.

---

### I-05 · [B5-6] Cross-Strategy Loss Propagation
**Location:** AlchemistV3.sol

Losses in one strategy can propagate to affect positions using other strategies, because collateral is shared at the vault level. This is by design but may surprise users.

---

### I-06 · [INJ-2] repay() Doesn't Decrement _mytSharesDeposited — Deposit Cap Not Freed
**Location:** AlchemistV3.sol

`repay()` reduces debt but does not decrement `_mytSharesDeposited`. Repayments do not free up deposit cap space. Users must fully withdraw to reclaim cap room.

---

### I-07 · [SB-2] pauseLoans Doesn't Gate burn/repay
**Location:** AlchemistV3.sol

`pauseLoans` blocks new borrows and deposits but does not prevent `burn()` or `repay()`. This is by design (users should always be able to reduce debt).

---

### I-08 · [SB-6] initialize() Doesn't Set alchemistPositionNFT
**Location:** AlchemistV3.sol

`initialize()` does not set `alchemistPositionNFT`, creating a post-initialization window where the contract is partially configured.

---

### I-09 · [SC-3] setPendingAdmin Accepts Zero Address
**Location:** AlchemistV3.sol

`setPendingAdmin(address(0))` is accepted without explicit cancellation logic. The intent is unclear (cancel nomination vs accident).

---

### I-10 · [EC-5] setOperator Event Missing Bool Value
**Location:** PermissionedProxy.sol

`setOperator` event does not include the boolean value being set, making it impossible to determine from logs alone whether the operator was added or removed.

---

### I-11 · [EC-6] Redemption Event Missing Fields
**Location:** Transmuter.sol

The `Redemption` event is missing `collRedeemed`, `feeCollateral`, and fee skip flag fields, reducing observability of redemption operations.

---

### I-12 · [EC-7] setAuthorization No Event
**Location:** AlchemistGate.sol

`setAuthorization()` changes authorization status without emitting an event.

---

### I-13 · [EC-8] claimRedemption Event Missing Fee Details
**Location:** Transmuter.sol

The `claimRedemption` event is missing `feeYield`, `syntheticFee`, and position ID fields.

---

### I-14 · [SCA-5] BPS Magic Number 1e4 Undocumented
**Location:** PerpetualGauge.sol, AlchemistV3.sol, Transmuter.sol

PerpetualGauge uses raw `1e4` for BPS while other contracts use a named `BPS` constant. Inconsistency creates maintenance risk.

---

### I-15 · [MS-6] batchLiquidate Permissionless — By Design
**Location:** AlchemistV3.sol

`batchLiquidate()` is permissionless, allowing anyone to liquidate any eligible position. This is by design for decentralized liquidation markets.

---

### I-16 · [MS-7] mintFrom Recipient Parameter — By Design
**Location:** AlchemistV3.sol

`mintFrom()` accepts a `recipient` parameter, allowing minting to any address. This is by design for composability with other protocols.

---

## REFUTED (4)

### R-01 · [B5-7] deallocate totalValue Check Incorrect — REFUTED
**Location:** MYTStrategy.sol

**Original claim:** `deallocate()` totalValue check was incorrect. **Refuted:** The check is correct. Total value is properly validated before and after deallocation.

---

### R-02 · [B5-3] Strategy Donation Inflates _totalValue — REFUTED
**Location:** All strategy _totalValue()

**Original claim:** Donating tokens to a strategy inflates `_totalValue()`. **Refuted:** While donation does inflate the reported value, Morpho V2's accounting prevents actual extraction of the inflated value.

---

### R-03 · [B1-5] setTransmutationTime Retroactive — REFUTED
**Location:** Transmuter.sol

**Original claim:** Changing `transmutationTime` affects existing positions retroactively. **Refuted:** Fenwick tree entries are baked at position creation time. Time changes only affect new positions.

---

### R-04 · [SC-4] VaultV2 Flash Loan — REFUTED
**Location:** VaultV2

**Original claim:** Flash loan vulnerability in VaultV2. **Refuted:** No flash loan function exists in VaultV2. The attack vector is not possible.

---

## Attack Chain Summary

Several findings link together into compound attack chains:

**Chain 1 — Permanent Protocol Brick:**
H-06 (retroactive lowerBound) → Mass liquidation → H-01 (phantom totalSyntheticsIssued) → M-13 (deposits blocked forever)

**Chain 2 — Oracle Exploitation:**
H-02/H-03 (timestamp fabrication) → H-04 (inflated MYT price) → M-21 (operator extraction) → overvalued collateral

**Chain 3 — Operator MEV:**
M-03 (zero slippage) + M-20 (unverified calldata) + M-06 (redirectable adapter) = operator can extract value through swap operations

**Chain 4 — Transmuter Griefing:**
M-02 (retroactive fees up to 100%) + M-24 (no fee snapshot) = existing locked positions can be fully taxed

---

*Generated by Jean (OpenClaw) from Plamen Core audit findings inventory.*
*PoC verification: 30 Foundry tests, 0 failures, covering all HIGH and MEDIUM findings.*
