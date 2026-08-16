# `AlchemistAllocator` Runbook

This note documents the practical caller rules for every allocation and deallocation entrypoint on `AlchemistAllocator`:

1. `deallocate()`
2. `deallocateWithSwap()`
3. `deallocateWithUnwrapAndSwap()`
4. `allocate()`
5. `allocateWithSwap()`

## Shared Rules

1. `amount` is always the vault asset amount you want back from the strategy.
   For the ETH strategies in this repo, that means the requested `WETH` out.

2. The allocator only wraps parameters and forwards the request to the vault.
   The real path taken after that depends on the strategy and the `ActionType` encoded into the allocator call.

3. `deallocate()` should only be used when the strategy supports a direct unwind into the vault asset without DEX calldata.
   Example: a strategy that can redeem or withdraw back into `WETH` directly.

4. `deallocateWithSwap()` should only be used when the strategy can sell its oracle token directly into the vault asset.
   Example: `WstethStrategy` can sell `wstETH -> WETH` in one swap.

5. `deallocateWithUnwrapAndSwap()` should be used when the held position token is not the same token that must be sold to the DEX.
   Example: `SFraxETHStrategy` holds `sfrxETH`, unwraps to `frxETH`, then sells `frxETH -> WETH`.

6. For any swap-based deallocation, `txData` must be a 0x allowance-holder quote built for the strategy address as the taker.
   The strategy approves the allowance holder and then executes `allowanceHolder.call(txData)`.

7. For any swap-based allocation, `txData` must also be a 0x allowance-holder quote built for the strategy address as the taker.
   The strategy receives vault assets first, approves the allowance holder, and then executes the quote inside the strategy.

## `allocate()`

### What the caller provides

- `adapter`
- `amount`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.direct`
- no swap calldata
- no intermediate output requirement

### End-to-end flow

1. `AlchemistAllocator.allocate(adapter, amount)`
2. Allocator validates vault caps and strategy classifier caps
3. `vault.allocate(adapter, data, amount)`
4. `MYTStrategy.allocate(...)`
5. Strategy handles the direct path in `_allocate(uint256 amount)`

### Practical rule

Use this only when the strategy can deploy the vault asset directly into its target position without needing a DEX quote.

## `allocateWithSwap()`

### What the caller provides

- `adapter`
- `amount`
- `txData`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.swap`
- `swapParams.txData = txData`
- `swapParams.minIntermediateOut = 0`

### End-to-end flow

1. `AlchemistAllocator.allocateWithSwap(adapter, amount, txData)`
2. Allocator validates vault caps and strategy classifier caps
3. `vault.allocate(adapter, data, amount)`
4. `MYTStrategy.allocate(...)`
5. Strategy handles the swap path in `_allocate(uint256 amount, bytes memory txData)`
6. Strategy executes the DEX quote and continues any post-swap position setup

### Practical rules

1. `txData` must describe the swap from the vault asset into the token the strategy expects on its swap path.

2. This path should be used when the strategy either cannot allocate directly or when market execution is intentionally preferred over protocol-native minting.

## `deallocate()`

### What the caller provides

- `adapter`
- `amount`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.direct`
- no swap calldata
- no intermediate output requirement

### End-to-end flow

1. `AlchemistAllocator.deallocate(adapter, amount)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. Strategy handles the direct path in `_deallocate(uint256 amount)`
5. Strategy approves the vault asset back to the vault
6. The vault pulls the asset

### Practical rule

Use this only when the strategy itself can unwind back into the vault asset with no swap quote.

## `deallocateWithSwap()`

### What the caller provides

- `adapter`
- `amount`
- `txData`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.swap`
- `swapParams.txData = txData`
- `swapParams.minIntermediateOut = 0`

### End-to-end flow

1. `AlchemistAllocator.deallocateWithSwap(adapter, amount, txData)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. `OraclePricedSwapStrategy._deallocateViaOracleTokenSwap(...)`
5. Strategy prepares how much oracle token can be sold
6. Strategy executes one swap from oracle token into the vault asset
7. Strategy approves the vault asset back to the vault
8. The vault pulls the asset

### Practical rules

1. `txData` must describe the oracle token swap.
   For `WstethStrategy`, that means `wstETH -> WETH`.

2. This path only works when the token the strategy sells to the DEX is the same token used by the strategy's oracle math.

3. Do not use this path for `SFraxETHStrategy`.
   `SFraxETHStrategy` intentionally rejects the plain swap route so callers do not accidentally skip the unwrap step.

## `deallocateWithUnwrapAndSwap()`

### What the caller provides

- `adapter`
- `amount`
- `txData`
- `minIntermediateOut`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.unwrapAndSwap`
- `swapParams.txData = txData`
- `swapParams.minIntermediateOut = minIntermediateOut`

### End-to-end flow

For `SFraxETHStrategy`, the call path is:

1. `AlchemistAllocator.deallocateWithUnwrapAndSwap(adapter, amount, txData, minIntermediateOut)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. `OraclePricedSwapStrategy._deallocateViaUnwrapAndSwap(...)`
5. `SFraxETHStrategy._prepareIntermediateForSwap(maxOracleTokenIn, minIntermediateOut)`
6. `sfrxETH.withdraw(minIntermediateOut, strategy, strategy)`
7. `dexSwap(WETH, frxETH, minIntermediateOut, shortfall, txData)`
8. The strategy approves `WETH` back to the vault and the vault pulls it

### Practical rules

1. `txData` must describe the intermediate token swap, not the held position token swap.
   For `SFraxETHStrategy`, the swap is `frxETH -> WETH`, not `sfrxETH -> WETH`.

2. `minIntermediateOut` should match the quote `sellAmount`.
   For `SFraxETHStrategy`, this is the exact `frxETH` amount the strategy must unwrap before it calls 0x.

3. `minIntermediateOut` must be fundable by the strategy's oracle-token amount after oracle and slippage checks.
   For `SFraxETHStrategy`, the oracle prices `frxETH`, and the strategy converts `sfrxETH` shares into `frxETH` via ERC-4626 math before swapping.

### Example scenario

Assume:

- The vault wants `4 WETH` back
- The strategy already holds `10 sfrxETH`
- The oracle prices `1 frxETH = 1 ETH`
- Strategy slippage is `1%`
- A 0x quote says selling `4 frxETH` returns at least `4 WETH`

The caller should prepare:

- `adapter = address(sfraxEthStrategy)`
- `amount = 4e18`
- `minIntermediateOut = 4e18`
- `txData = 0x allowance-holder quote for frxETH -> WETH with taker = address(sfraxEthStrategy)`

The strategy then:

1. Computes the `WETH` shortfall that must be covered.
2. Converts that shortfall into a maximum permitted `frxETH` input using the oracle and slippage math.
3. Calls `sfrxETH.withdraw(4e18, address(this), address(this))` to unwrap exactly `4 frxETH`.
4. Executes the DEX swap from `4 frxETH` into `WETH`.
5. Approves `4 WETH` to the vault so the vault can pull the assets.

If the quote requires more intermediate output than the oracle-priced position can support, the transaction reverts instead of partially deallocating.

## Strategy Notes

This section collects the allocator-facing examples for specific strategies so operators can quickly choose the correct entrypoint.

### `WstETHEthereumStrategy`

Supported allocator paths:

- `allocate()`
- `allocateWithSwap()`
- `deallocateWithSwap()`

Notes:

1. `allocate()` uses the native Lido mint path.
   The strategy unwraps `WETH` into native `ETH` and deposits directly into `wstETH`.

2. `allocateWithSwap()` buys `wstETH` on the market and enforces an oracle-based minimum output.

3. The direct path mints at protocol par, but the strategy values the position using the `stETH / ETH` oracle.
   If the oracle reports `stETH < ETH`, the freshly minted `wstETH` can be marked below the `WETH` spent immediately after allocation.

4. When the market already reflects a `stETH` discount, `allocateWithSwap()` can acquire more `wstETH` per `WETH` than the direct mint path and avoid the same entry markdown.

5. Operationally:
   direct allocation is simpler under normal conditions,
   `allocateWithSwap()` is usually preferable when `stETH` is materially below par,
   and direct allocation is generally better when `stETH` trades at a premium.

6. On exit, use `deallocateWithSwap()` with `txData` for `wstETH -> WETH`.

### `WstETHL2Strategy`

Supported allocator paths:

- `allocateWithSwap()`
- `deallocateWithSwap()`

Notes:

1. Direct allocation is not supported.
   The strategy cannot mint `wstETH` natively on L2, so `allocate()` reverts.

2. `allocateWithSwap()` should use a quote for `WETH -> wstETH`.

3. `deallocateWithSwap()` should use a quote for `wstETH -> WETH`.

4. Because the oracle already prices `wstETH` directly on L2, there is no mainnet-style mint-versus-oracle mismatch to manage here.

### `SFraxETHStrategy`

Supported allocator paths:

- `allocate()`
- `allocateWithSwap()`
- `deallocateWithUnwrapAndSwap()`

Notes:

1. `allocate()` uses Frax's native path.
   The strategy unwraps `WETH`, mints into the Frax flow, and receives `sfrxETH`.

2. `allocateWithSwap()` first acquires `frxETH` on the market, then deposits that `frxETH` into `sfrxETH`.
   The quote should therefore be for `WETH -> frxETH`, not `WETH -> sfrxETH`.

3. `deallocateWithSwap()` is intentionally unsupported.
   The strategy holds `sfrxETH`, but the sell token for the DEX leg is `frxETH`.

4. `deallocateWithUnwrapAndSwap()` is the correct exit path.
   Use `minIntermediateOut` as the exact `frxETH` amount that must be produced before the `frxETH -> WETH` swap executes.

### `SiUSDStrategy`

Supported allocator paths:

- `allocate()`
- `deallocate()`
- `deallocateWithUnwrapAndSwap()`

Notes:

1. `allocate()` is the only allocation path.
   The strategy mints and stakes directly through the InfiniFi gateway, so `allocateWithSwap()` is not supported.

2. `deallocate()` is the preferred direct exit when the strategy can unstake `siUSD`, receive `iUSD`, and redeem back to `USDC` through the gateway.

3. `deallocateWithSwap()` is not supported.
   The swap-based fallback is the unwrap path because the strategy must first move from `siUSD` into `iUSD`.

4. `deallocateWithUnwrapAndSwap()` should use a quote for `iUSD -> USDC`, not `siUSD -> USDC`.
   `minIntermediateOut` is the `iUSD` amount the strategy must have available before calling the DEX.

### `EtherfiEETHMYTStrategy`

Supported allocator paths:

- `allocate()`
- `allocateWithSwap()`
- `deallocate()`
- `deallocateWithSwap()`

Async unwind operations (keeper/owner, outside the allocator):

- `requestExits(uint256 wethAmount)` — unwrap `weETH` and enter the Ether.fi
  native withdrawal queue (`LiquidityPool.requestWithdraw`), holding the minted
  `WithdrawRequestNFT`. Callable by the owner or the configured `keeper`.
- `claimExits(uint256[] tokenIds)` — permissionless settlement of finalized
  requests; claimed ETH is wrapped into idle WETH for later deallocation or
  `withdrawToVault()`.
- `removeInvalidExits(uint256[] tokenIds)` — owner cleanup for requests the
  protocol has invalidated/seized; realizes the loss in `realAssets()`.

Notes:

1. `allocate()` uses the Ether.fi deposit adapter and directly mints into `weETH`.

2. `allocateWithSwap()` can be used when buying `weETH` on the market is preferable to the native mint path.
   The quote should be for `WETH -> weETH`. Pricing is oracle-free: minimum outputs are
   floored by the canonical `weETH -> eETH` rate (`getEETHByWeETH`), not a Chainlink feed.

3. `deallocate()` cascades through instant liquidity: idle WETH, then Ether.fi instant
   redemption, then a LiquidityPool instant withdraw (bounds-checked, permission failures
   tolerated). It reverts with "Insufficient WETH available" only when all instant legs
   are exhausted; the async queue refills idle WETH over subsequent days.

4. `deallocateWithSwap()` remains useful as the market exit path when the operator prefers to sell `weETH -> WETH` rather than rely on the redemption manager.

5. Pending queue exits are valued inside `realAssets()` (unfinalized: share value minus
   `pendingHaircutBps`; finalized: exact `getClaimableAmount`), so the vault never
   registers a phantom loss during the unwind window. `previewAdjustedWithdraw` counts
   instant capacity only.

6. A canonical-rate circuit breaker trips the kill switch when the eETH-per-weETH rate
   drops more than `maxRateDropBps` below the last allocation checkpoint. Allocation
   blocks; deallocation stays open.

7. Keeper runbook: monitor idle WETH + RedemptionManager capacity against the target
   buffer; when low, call `requestExits(refill)`. After Ether.fi finalizes (watch
   `lastFinalizedRequestId` on the WithdrawRequestNFT), anyone calls `claimExits`; the
   allocator then rebalances the recovered WETH.
