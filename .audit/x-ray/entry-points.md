# Entry Point Map

> Alchemix V3 | ~110 entry points | 20 permissionless (+9 in inactive contracts) | ~32 role-gated | ~58 admin-only

---

## Protocol Flow Paths

### Setup (Admin)

`AlchemistV3.initialize()` → `setAlchemistPositionNFT()` → `setAlchemistFeeVault()` → `Transmuter.setAlchemist()` → `AlchemistCurator.setStrategy()` → `AlchemistAllocator.allocate()`  ◄── MYT vault must list adapter via VaultV2 timelock

### Borrower Flow

`[admin setup above]` → `AlchemistV3.deposit()` → `AlchemistV3.mint()`  ◄── collateral ≥ debt × minimumCollateralization
                                       ├─→ `AlchemistV3.repay()` / `burn()`  ◄── not same block as mint
                                       ├─→ `AlchemistV3.withdraw()`  ◄── free collateral only
                                       └─→ `AlchemistV3.selfLiquidate()`  ◄── position healthy

(or one transaction via `AlchemistRouter.depositETH()/depositUnderlying()` → wraps → `IVaultV2.deposit()` → `AlchemistV3.deposit()` → `mint()`)

### Staker Flow

`[borrower mint above]` → `Transmuter.createRedemption()`  ◄── totalLocked + amount ≤ totalSyntheticsIssued
            → [timeToTransmute blocks pass] → `Transmuter.claimRedemption()` → `AlchemistV3.redeem()`
            └─→ `Transmuter.pokeMatured()`  ◄── frees deposit-cap headroom

### Liquidator Flow

`[borrower mint above]` → [MYT price falls / collateral ratio < collateralizationLowerBound] → `AlchemistV3.liquidate()` / `batchLiquidate()`

### Capital Ops (Operator)

`[curator setStrategy above]` → `AlchemistAllocator.allocate()/allocateWithSwap()` → `VaultV2.allocate()` → `MYTStrategy.allocate()` → external protocol
                                              └─→ `deallocate()/deallocateWithSwap()/deallocateWithUnwrapAndSwap()`  ◄── strategy route support varies

---

## Permissionless

Sorted by value flow (tokens-in first).

### `AlchemistV3.deposit(amount, recipient, tokenId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Any depositor (tokenId 0 mints a new position NFT; nonzero tokenId tops up *any* existing position — no ownership check) |
| Parameters | amount (user-controlled), recipient (user-controlled), tokenId (user-controlled) |
| Call chain | `→ AlchemistV3._earmark() → AlchemistV3Position.mint() → MYT.safeTransferFrom(sender → alchemist)` |
| State modified | `_accounts[id].collateralBalance`, `_mytSharesDeposited`, earmark accumulators |
| Value flow | MYT: sender → AlchemistV3 |
| Reentrancy guard | no |

### `AlchemistV3.repay(amount, recipientTokenId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone, on any position (no ownership check; sets that position's `lastRepayBlock`) |
| Parameters | amount (user-controlled), recipientTokenId (user-controlled) |
| Call chain | `→ _earmark() → _sync(id) → MYT.safeTransferFrom(sender → Transmuter) → _subEarmarkedDebt() → _subDebt() → fee to protocolFeeReceiver` |
| State modified | account debt/earmarked/collateral (fee), `totalDebt`, `cumulativeEarmarked`, `lastTransmuterTokenBalance`, `lastRepayBlock` |
| Value flow | MYT: sender → Transmuter; MYT fee: AlchemistV3 → protocolFeeReceiver |
| Reentrancy guard | no |

### `AlchemistV3.burn(amount, recipientId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone holding alAsset, on any position (limited to unearmarked debt; bounded by Transmuter `totalLocked`, G-7) |
| Parameters | amount (user-controlled), recipientId (user-controlled) |
| Call chain | `→ _earmark() → _sync(id) → debtToken.safeBurnFrom(sender) → _subDebt()` |
| State modified | account debt, `totalDebt`, `totalSyntheticsIssued`, `lastRepayBlock` |
| Value flow | alAsset: burned from sender |
| Reentrancy guard | no |

### `Transmuter.createRedemption(syntheticDepositAmount, recipient)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Any alAsset holder |
| Parameters | syntheticDepositAmount (user-controlled), recipient (user-controlled) |
| Call chain | `→ alAsset.safeTransferFrom(sender → Transmuter) → StakingGraph.addStake() → ERC721._mint(recipient)` |
| State modified | `_positions`, `_stakingGraph`, `totalLocked`, `totalActiveLocked`, `_nonce`, `_countsTowardCap` |
| Value flow | alAsset: sender → Transmuter |
| Reentrancy guard | no |

### `AlchemistV3.liquidate(accountId)` / `batchLiquidate(accountIds[])`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Any liquidator (position must be below `collateralizationLowerBound`; `_forceRepay` of earmarked debt may run first) |
| Parameters | accountId(s) (user-controlled) |
| Call chain | `→ _earmark() → _sync(id) → _forceRepay()? → calculateLiquidation() → MYT → Transmuter + MYT fee → caller + IFeeVault.withdraw(caller)` |
| State modified | account debt/earmarked/collateral, `totalDebt`, `cumulativeEarmarked`, `_mytSharesDeposited`, `lastTransmuterTokenBalance` |
| Value flow | MYT: AlchemistV3 → Transmuter (debt) + → caller (fee); underlying: fee vault → caller (outsourced fee) |
| Reentrancy guard | no |

### `AlchemistV3.poke(tokenId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone — forces `_earmark()` + `_sync(tokenId)` on any position |
| Parameters | tokenId (user-controlled) |
| Call chain | `→ _earmark() → _sync(tokenId)` |
| State modified | global earmark accumulators; per-account debt/earmarked/collateral snapshots |
| Value flow | none |
| Reentrancy guard | no |

### `Transmuter.pokeMatured(id)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone, on any matured, un-poked position |
| Parameters | id (user-controlled) |
| Call chain | internal only |
| State modified | `_countsTowardCap[id]`, `totalActiveLocked` |
| Value flow | none |
| Reentrancy guard | no |

### `AlchemistRouter` deposit/repay family — `depositUnderlying()`, `depositETH()`, `depositMYT()`, `depositETHToVaultOnly()`, `repayUnderlying()`, `repayETH()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (ETH variants payable), nonReentrant (transient) |
| Caller | Anyone (deadline + minSharesOut slippage params on each) |
| Parameters | amounts/tokenId/borrowAmount/minSharesOut/deadline (all user-controlled) |
| Call chain | `→ WETH.deposit()? → VaultV2.deposit() → AlchemistV3.deposit() → AlchemistV3.mint()/mintFrom()?` ; repay: `→ VaultV2.deposit() → AlchemistV3.repay()` |
| State modified | downstream AlchemistV3/vault state; router holds nothing across calls |
| Value flow | underlying/ETH: sender → MYT vault; alAsset: AlchemistV3 → sender (borrow) |
| Reentrancy guard | yes (transient) |

### `AlchemistRouter.claimRedemption(positionId, minAmountOut, deadline, unwrapETH)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Transmuter-NFT holder (router pulls the NFT via `transferFrom(msg.sender)` — requires prior approval) |
| Parameters | positionId (user-controlled), minAmountOut (user-controlled), deadline (user-controlled), unwrapETH (user-controlled) |
| Call chain | `→ Transmuter NFT transferFrom → Transmuter.claimRedemption() → VaultV2.redeem() → WETH.withdraw()? → sender` |
| State modified | downstream Transmuter/Alchemist state |
| Value flow | underlying/ETH + leftover alAsset: → sender (reverts if claimYield == 0 — synthetic-only claims must go direct) |
| Reentrancy guard | yes (transient) |

### Fee vault deposits — `AlchemistETHVault.deposit()/depositWETH()/receive()`, `AlchemistTokenVault.deposit(amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external/payable, nonReentrant (ETH vault) |
| Caller | Anyone (vault accounting is raw balance — donations become liquidator-fee budget) |
| Parameters | amount (user-controlled) |
| Call chain | `→ WETH.withdraw()` (depositWETH) or direct |
| State modified | none (balance-based accounting) |
| Value flow | ETH/token: sender → vault |
| Reentrancy guard | yes (ETH vault) / no (token vault) |

### `AlTokenV3.burn(amount)` / `burnFrom(account, amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Any holder / approved spender (xERC20 bridge burn limits applied when caller is a registered bridge) |
| Parameters | amount, account (user-controlled) |
| Call chain | `→ _burn()` (note: `burnFrom` decrements even infinite allowances) |
| State modified | ERC20 balances/allowances, bridge limits |
| Value flow | alAsset burned |
| Reentrancy guard | no |

### Inactive-contract permissionless surface *(see x-ray.md §1 — no in-repo callers)*

`PerpetualGauge.vote()/clearVote()/registerNewStrategy()/executeAllocation()` (gauge unused; `strategyList` never populated) and `AlEth.setWhitelist()/pauseAlchemist()/setCeiling()/burn()/burnFrom()` (unwired local copy; setters have **no access control**).

---

## Role-Gated

### Position NFT owner (per-tokenId, checked via `ownerOf`)

| Contract | Function | Notes |
|----------|----------|-------|
| AlchemistV3 | `withdraw(amount, recipient, tokenId)` | free collateral only (G-4); MYT → recipient |
| AlchemistV3 | `mint(tokenId, amount, recipient)` | LTV check G-9; blocked same block as repay (G-8); alAsset → recipient |
| AlchemistV3 | `selfLiquidate(accountId, recipient)` | position must be healthy; MYT → Transmuter + recipient |
| AlchemistV3 | `approveMint(tokenId, spender, amount)` | versioned allowance map |
| AlchemistV3 | `resetMintAllowances(tokenId)` | owner or Position NFT contract (transfer hook) |
| Transmuter | `claimRedemption(id)` | NFT owner; matured or pro-rata w/ exit fee; triggers `alchemist.redeem` |
| AlchemistRouter | `withdrawUnderlying/withdrawETH/selfLiquidateToUnderlying/selfLiquidateToETH` | `ownerOf == msg.sender` + NFT custody round-trip (wipes mint allowances, X-6) |

### Mint allowance holder

| Contract | Function | Notes |
|----------|----------|-------|
| AlchemistV3 | `mintFrom(tokenId, amount, recipient)` | decrements versioned allowance; same checks as `mint` |

### Transmuter-only (`onlyTransmuter`)

| Contract | Function | Notes |
|----------|----------|-------|
| AlchemistV3 | `redeem(amount)` | pulls earmarked debt + collateral to Transmuter |
| AlchemistV3 | `reduceSyntheticsIssued(amount)` | pairs with claim-side synthetic burn (X-4) |
| AlchemistV3 | `setTransmuterTokenBalance(amount)` | re-syncs cover accounting (X-2) |

### Vault-only (`onlyVault`, per strategy)

| Contract | Function | Notes |
|----------|----------|-------|
| MYTStrategy (all 10 strategies) | `allocate(data, assets, selector, sender)` | killSwitch-gated (G-21); routes by ActionType |
| MYTStrategy (all 10 strategies) | `deallocate(data, assets, selector, sender)` | forceDeallocate restricted to direct route (G-23); value check G-22 |

### Operator (`onlyOperator` / admin-or-operator)

| Contract | Function | Notes |
|----------|----------|-------|
| AlchemistAllocator | `allocate/deallocate/allocateWithSwap/deallocateWithSwap/deallocateWithUnwrapAndSwap` | cap-checked (G-25); operator swap txData is 0x calldata, `minIntermediateOut` 0 on swap paths *(per runbook)* |
| AlchemistAllocator | `setLiquidityAdapter(adapter, data)` | redirects vault liquidity adapter |
| AlchemistCurator | `submitSetStrategy/setStrategy/submitRemoveStrategy/removeStrategy` | adds/removes vault adapters (add via VaultV2 timelock `submit`) |
| PermissionedProxy | `proxy(vault, data)` | selector-whitelisted raw call (G-27) |

### Pending-admin acceptors

`AlchemistV3.acceptAdmin()`, `Transmuter.acceptAdmin()`, `PermissionedProxy.acceptAdminOwnership()`, `AlchemistStrategyClassifier.acceptOwnership()` — each restricted to the nominated `pendingAdmin` (I-8).

### Authorized fee-vault spenders (`onlyAuthorized`)

`AlchemistETHVault.withdraw(recipient, amount)`, `AlchemistTokenVault.withdraw(recipient, amount)` — alchemist + owner authorized at construction; pays outsourced liquidator fees.

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| AlchemistV3 | `setAlchemistPositionNFT` | nft | one-shot latch (I-7) |
| AlchemistV3 | `setAlchemistFeeVault` / `setProtocolFeeReceiver` / `setTokenAdapter` | address | fee routing (tokenAdapter is vestigial — never read) |
| AlchemistV3 | `setPendingAdmin` / `setGuardian` | address, bool | admin handover; guardian set |
| AlchemistV3 | `setDepositCap` | value ≥ current balance | `depositCap` |
| AlchemistV3 | `setProtocolFee` / `setLiquidatorFee` / `setRepaymentFee` | fee ≤ BPS | fees (retroactive to existing positions) |
| AlchemistV3 | `setMinimumCollateralization` / `setGlobalMinimumCollateralization` / `setCollateralizationLowerBound` / `setLiquidationTargetCollateralization` | 18-dec ratios, ordering I-5 | collateralization params (instant, no grace period) |
| AlchemistV3 | `pauseDeposits` / `pauseLoans` (admin **or guardian**) | bool | pause flags (bidirectional) |
| Transmuter | `setAlchemist` / `setDepositCap` / `setTransmutationFee` / `setExitFee` / `setTransmutationTime` / `setProtocolFeeReceiver` / `setPendingAdmin` | various | redemption params (fee/time apply to open positions; cap floor unenforced, I-11) |
| AlchemistV3Position | `setMetadataRenderer` / `setAdmin` | address | NFT metadata/admin |
| MYTStrategy (×10) | `setKillSwitch` / `setSlippageBPS` / `setAllowanceHolder` / `setRiskClass` / `setAdditionalIncentives` / `rescueTokens` / `withdrawToVault` / `claimRewards` / `claimWithdrawalQueue` | various | strategy ops (slippage setter bound looser than constructor, I-12) |
| AaveStrategy | `adminDexSwap` | swap params | owner-driven 0x swap |
| EtherfiEETHStrategy | `setCanForceDeallocate` | bool | force-deallocate gate |
| SFraxETHStrategy | `setMinFrxEthOutBps` | bps ≤ 10000 | allocation floor |
| OraclePricedSwapStrategy (×5 children) | `setPricedTokenOracle` / `setMaxOracleStaleness` | oracle, seconds > 0 | oracle wiring (replaceable post-f1f2dff) |
| AlchemistAllocator | `setMaxRate` | rate | VaultV2 max rate |
| AlchemistCurator | `increase/decreaseAbsoluteCap`, `increase/decreaseRelativeCap`, `submitIncrease*`, `submitSetAllocator`, `submitSetForceDeallocatePenalty`, `submitSetPerformanceFee(Recipient)` | adapter, amounts | vault caps & config (increases via VaultV2 timelock `submit`; decreases instant) |
| PermissionedProxy | `transferAdminOwnerShip` / `setOperator` / `setPermissionedCall` | address/selector, bool | proxy roles & selector whitelist |
| AlchemistStrategyClassifier | `transferOwnership` / `setRiskClass` / `assignStrategyRiskLevel` | classId, WAD caps | risk classes (no input validation beyond admin) |
| AlchemistGate | `setAuthorization` | vault, to, bool | authorization map (no in-repo consumers) |
| Whitelist | `add` / `remove` / `disable` | address | whitelist set (disable is one-way) |
| AbstractFeeVault (both vaults) | `setAuthorization` | account, bool | withdrawal authorization |

---

## Initialization

| Contract | Function | Notes |
|----------|----------|-------|
| AlchemistV3 | `initialize(params)` | `initializer`-gated; deployed behind TransparentUpgradeableProxy; `alchemistPositionNFT` and fee vault are set post-init (configuration window) |
| AlTokenV3 | `initialize(name, symbol)` | `initializer`-gated; constructor also `initializer` (implementation self-locks) |
