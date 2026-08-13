# StakeDAO Enso Offchain Fixtures

Fork tests in `StakeDAOWETHOffchainRoutes.t.sol` replay pinned Enso `tx.data` from:

- `quotes/stakeDaoWethLifecycle1Eth.json`
- `quotes/stakeDaoWethLifecycle300Weth.json`

Production allocators use the same Enso shapes: Bundle allocate (with Stake DAO referrer) and Route/Bundle deallocate (aggregator-capable).

## Enso approach (recommended)

| Direction | API | Why |
| --- | --- | --- |
| Allocate | `/shortcuts/bundle` | Need a custom `deposit(assets, receiver, referrer)` call. Plain Route cannot pass Stake DAO’s referrer. |
| Deallocate | `/shortcuts/bundle` with `enso:balance{estimate}` → `enso:route`, or `/shortcuts/route` | Standard `tokenIn → tokenOut` exit. Enso may use aggregators for best execution — that is intentional. |

Always use `routingStrategy: "router"` so calldata matches `ensoRouter.call(...)` inside `StakeDAOWETHStrategy` / `allocateWithSwap` / `deallocateWithSwap`.

Do **not** force a Curve-only Enso exit to “avoid MEV.” Aggregator multi-hops are normal for Enso Route. Execution safety comes from:

1. Enso slippage / `minAmountOut` baked into `tx.data`
2. Strategy checks: `_ensoRoute` min out, Curve LP floors (`minCurveLpPerWeth` / `minWethPerCurveLp`)
3. Fresh quotes at execution time (fixtures are for fork tests only)

Enso’s top-level `referralCode` is **unrelated** to Stake DAO’s `referrer` argument.

## Stake DAO referrer

Direct and Enso allocate both attribute referrals to the **strategy**:

- Direct: `rewardVault.deposit(lp, address(this), address(this))`
- Enso Bundle final hop: `deposit(assets, strategy, strategy)` — selector `0x2e2d2984`

Confirm allocate fixtures contain `0x2e2d2984` and `referrer == strategyAddress`.

## Why the strategy address is pinned

Enso builds calldata for a specific `fromAddress` / `spender` / `receiver`. Offchain tests deploy `StakeDAOWETHStrategy` from `0x…C0FFEE` (nonce 1) with the same constructor args as the fetch script so addresses match.

If strategy bytecode or constructor args change, regenerate fixtures.

Deallocate Bundle uses `enso:balance{estimate: sharesIn}` because that predicted address has **no** RewardVault shares on live mainnet at quote time; without the estimate, Enso simulation returns HTTP 400.

## Allocator usage

`AlchemistAllocator.allocateWithSwap` / `deallocateWithSwap` take raw Enso `tx.data` (not encoded `VaultAdapterParams`):

```ts
import { encodeFunctionData } from "viem";
import { EnsoClient } from "@ensofinance/sdk";

const ensoClient = new EnsoClient({ apiKey: process.env.ENSO_API_KEY! });

const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const CURVE_LP = "0x2c683fAd51da2cd17793219CC86439C1875c353e";
const REWARD_VAULT = "0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C";

const allocatorAbi = [
  {
    type: "function",
    name: "allocateWithSwap",
    inputs: [
      { name: "adapter", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "txData", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "deallocateWithSwap",
    inputs: [
      { name: "adapter", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "txData", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// Allocate — Bundle so Stake DAO referrer = strategy
const allocateBundle = await ensoClient.getBundleData(
  {
    fromAddress: strategyAddress,
    receiver: strategyAddress,
    spender: strategyAddress,
    chainId: 1,
    routingStrategy: "router",
  },
  [
    {
      protocol: "enso",
      action: "route",
      args: {
        tokenIn: WETH,
        tokenOut: CURVE_LP,
        amountIn: amountInWei,
        slippage: "125",
      },
    },
    {
      protocol: "erc20",
      action: "approve",
      args: {
        token: CURVE_LP,
        spender: REWARD_VAULT,
        amount: { useOutputOfCallAt: 0 },
      },
    },
    {
      protocol: "enso",
      action: "call",
      args: {
        address: REWARD_VAULT,
        method: "deposit",
        abi: "function deposit(uint256 assets, address receiver, address referrer) external returns (uint256 shares)",
        args: [{ useOutputOfCallAt: 0 }, strategyAddress, strategyAddress],
        tokenIn: CURVE_LP,
        tokenOut: REWARD_VAULT,
      },
    },
  ],
);

await walletClient.writeContract({
  address: allocator,
  abi: allocatorAbi,
  functionName: "allocateWithSwap",
  args: [strategyAddress, amountInWei, allocateBundle.tx.data],
});

// Deallocate — balance estimate + route (aggregators allowed)
const shareBalance = await readRewardVaultBalance(strategyAddress);
const deallocateBundle = await ensoClient.getBundleData(
  {
    fromAddress: strategyAddress,
    receiver: strategyAddress,
    spender: strategyAddress,
    chainId: 1,
    routingStrategy: "router",
  },
  [
    {
      protocol: "enso",
      action: "balance",
      args: {
        token: REWARD_VAULT,
        estimate: shareBalance.toString(),
      },
    },
    {
      protocol: "enso",
      action: "route",
      args: {
        tokenIn: REWARD_VAULT,
        tokenOut: WETH,
        amountIn: { useOutputOfCallAt: 0 },
        slippage: "125",
      },
    },
  ],
);

await walletClient.writeContract({
  address: allocator,
  abi: allocatorAbi,
  functionName: "deallocateWithSwap",
  args: [strategyAddress, wethAmountOut, deallocateBundle.tx.data],
});
```

Notes for keepers/allocators:

- Quote **at execution time**; do not reuse stale fixture calldata on mainnet.
- `amount` passed to `allocateWithSwap` / `deallocateWithSwap` is the vault/strategy WETH amount (shortfall on exit), not necessarily Enso’s `amountIn` for shares.
- For deallocate, use the strategy’s **current** RewardVault share balance as the Enso `estimate` / route `amountIn`.
- Prefer private/builder submission for large size if public-mempool sandwich risk matters; that is orthogonal to Enso vs aggregators.

This is not the Stake DAO Permit2 router `execute([permitCall, depositCall])` flow.

## Regenerate fixtures

1. Create an Enso API key at https://developers.enso.build/
2. Export credentials:

```bash
export ENSO_API_KEY=...
export MAINNET_RPC_URL=...
```

3. Fetch:

```bash
bash src/test/strategies/utils/offchain/fetch-stakedao-enso-routes.sh

ALLOCATE_AMOUNT=300000000000000000000 \
OUTPUT_PATH=src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle300Weth.json \
CURL_MAX_TIME=300 \
bash src/test/strategies/utils/offchain/fetch-stakedao-enso-routes.sh
```

The script logs `[enso-fetch] ...` progress. Large allocate Bundles can take 1–3 minutes; raise `CURL_MAX_TIME` if needed.

4. Test:

```bash
forge test --match-contract StakeDAOWETHOffchainRoutesTest -vvv
forge test --match-contract StakeDAOWETH300WETHOffchainRoutesTest -vvv
```
