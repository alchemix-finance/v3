# StakeDAO Enso Offchain Fixtures

Fork tests in `StakeDAOWETHOffchainRoutes.t.sol` replay pinned Enso route calldata from:

`src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle1Eth.json`

## Why the strategy address is pinned

Enso routes are generated for a specific `fromAddress` / `spender` / `receiver`. The offchain test deploys `StakeDAOWETHStrategy` from a fixed deployer (`0x...C0FFEE`) with the same constructor args as the fixture generator, so the strategy address in the JSON matches the deployed contract.

If strategy bytecode or constructor args change, regenerate the fixture.

## Regenerate fixture

1. Create an Enso API key at https://developers.enso.build/
2. Export it and a mainnet RPC URL:

```bash
export ENSO_API_KEY=...
export MAINNET_RPC_URL=...
```

3. Run the fetch script:

```bash
bash src/test/strategies/utils/offchain/fetch-stakedao-enso-routes.sh
```

Optional overrides:

```bash
ALLOCATE_AMOUNT=1000000000000000000 \
DEALLOCATE_AMOUNT_OUT=500000000000000000 \
SLIPPAGE_BPS=125 \
bash src/test/strategies/utils/offchain/fetch-stakedao-enso-routes.sh
```

4. Run fork tests:

```bash
forge test --match-contract StakeDAOWETHOffchainRoutesTest -vvv
```

## Allocator usage

`AlchemistAllocator.allocateWithSwap` / `deallocateWithSwap` take raw Enso `tx.data` bytes (not `VaultAdapterParams`):

```ts
import { encodeFunctionData } from "viem";

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
] as const;

// route = await ensoClient.getRouteData({ ... routingStrategy: "delegate" })
await walletClient.writeContract({
  address: allocator,
  abi: allocatorAbi,
  functionName: "allocateWithSwap",
  args: [strategyAddress, amountIn, route.tx.data],
});
```

For deallocate, fetch a RewardVault -> WETH route using the strategy's full RewardVault share balance as `amountIn`.

## TypeScript route generation (reference)

```ts
import { EnsoClient } from "@ensofinance/sdk";

const ensoClient = new EnsoClient({ apiKey: process.env.ENSO_API_KEY! });

const allocateRoute = await ensoClient.getRouteData({
  fromAddress: strategyAddress,
  receiver: strategyAddress,
  spender: strategyAddress,
  chainId: 1,
  tokenIn: ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"],
  tokenOut: ["0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C"],
  amountIn: ["1000000000000000000"],
  slippage: "125",
  routingStrategy: "delegate",
});

// Pass allocateRoute.tx.data to allocateWithSwap / strategy allocate swapParams.txData
```

This calls the Enso router directly. It is not the StakeDAO Permit2 router `execute([permitCall, depositCall])` flow.
