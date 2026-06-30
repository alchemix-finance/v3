# Tokemak Offchain Deallocation Helpers

The frontend path for Tokemak deallocation swaps is different from normal 0x swap paths:

- Call `AlchemistAllocator.deallocateWithSwap(adapter, amount, txData)`.
- Set `adapter` to the deployed `TokeAutoStrategy`.
- Set `amount` to the vault asset amount requested back from the strategy.
- Set `txData` to ABI-encoded `TokeRedeemParams`.
- Do not encode `VaultAdapterParams`; the allocator wraps `txData` into `ActionType.swap`.

For AutoUSD, `amount` and `minAmountOut` are USDC base units. For AutoETH, they are WETH wei.

## Why This Shape

`AlchemistAllocator.deallocateWithSwap` wraps the supplied bytes into:

```solidity
IMYTStrategy.VaultAdapterParams({
    action: IMYTStrategy.ActionType.swap,
    swapParams: IMYTStrategy.SwapParams({
        txData: txData,
        minIntermediateOut: 0
    })
});
```

`TokeAutoStrategy` then decodes `swapParams.txData` as:

```solidity
struct TokeSwapRoute {
    address fromToken;
    address toToken;
    address target;
    bytes data;
}

struct TokeRedeemParams {
    uint256 minAmountOut;
    TokeSwapRoute[] customRoutes;
}
```

The strategy calls Tokemak's `AutopilotRouter.redeemWithRoutes(...)` with those fields.

## Minimal Viem Helpers

```ts
import {
  encodeAbiParameters,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

const allocatorAbi = [
  {
    type: "function",
    name: "deallocateWithSwap",
    stateMutability: "nonpayable",
    inputs: [
      { name: "adapter", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "txData", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

type TokeRoute = {
  fromToken: Address;
  toToken: Address;
  target: Address;
  data: Hex;
};

type BuildTokeDeallocateArgs = {
  strategy: Address;
  amountToDeallocate: bigint;
  expectedAmountOut: bigint;
  idleAssetBalance?: bigint;
  slippageBps: bigint;
  routes: TokeRoute[];
};

/**
 * The strategy requires redeemParams.minAmountOut >= shortfall.
 *
 * shortfall = amountToDeallocate - idle assets already held by the strategy.
 *
 * If the frontend does not read strategy idle balance, omit idleAssetBalance.
 * That makes shortfall equal amountToDeallocate, which is the conservative
 * no-idle assumption.
 */
export function calculateTokeMinAmountOut({
  amountToDeallocate,
  expectedAmountOut,
  idleAssetBalance = 0n,
  slippageBps,
}: {
  amountToDeallocate: bigint;
  expectedAmountOut: bigint;
  idleAssetBalance?: bigint;
  slippageBps: bigint;
}) {
  const shortfall =
    idleAssetBalance >= amountToDeallocate
      ? 0n
      : amountToDeallocate - idleAssetBalance;

  const slippageAdjustedOut =
    (expectedAmountOut * (10_000n - slippageBps)) / 10_000n;

  // Never pass a minAmountOut below shortfall, or the strategy reverts with
  // "Min out below shortfall".
  return slippageAdjustedOut > shortfall ? slippageAdjustedOut : shortfall;
}

/**
 * This produces the exact bytes payload passed to allocator.deallocateWithSwap.
 * Do not encode VaultAdapterParams here.
 */
export function encodeTokeRedeemParams({
  minAmountOut,
  routes,
}: {
  minAmountOut: bigint;
  routes: TokeRoute[];
}) {
  return encodeAbiParameters(
    parseAbiParameters(
      "tuple(uint256 minAmountOut, tuple(address fromToken, address toToken, address target, bytes data)[] customRoutes)"
    ),
    [
      {
        minAmountOut,
        customRoutes: routes,
      },
    ]
  );
}

export function buildTokeDeallocateWithSwapArgs({
  strategy,
  amountToDeallocate,
  expectedAmountOut,
  idleAssetBalance = 0n,
  slippageBps,
  routes,
}: BuildTokeDeallocateArgs) {
  const minAmountOut = calculateTokeMinAmountOut({
    amountToDeallocate,
    expectedAmountOut,
    idleAssetBalance,
    slippageBps,
  });

  const txData = encodeTokeRedeemParams({
    minAmountOut,
    routes,
  });

  return {
    functionName: "deallocateWithSwap" as const,
    args: [strategy, amountToDeallocate, txData] as const,
    minAmountOut,
  };
}
```

## Example Call

```ts
const { args, minAmountOut } = buildTokeDeallocateWithSwapArgs({
  strategy: TOKE_AUTO_STRATEGY,
  amountToDeallocate,
  expectedAmountOut,
  slippageBps: 25n,
  routes: quote.customRoutes,
});

await walletClient.writeContract({
  address: ALLOCATOR,
  abi: allocatorAbi,
  functionName: "deallocateWithSwap",
  args,
  account,
});
```

## Input Rules

- `amountToDeallocate` is the vault asset amount requested back from the strategy.
- `expectedAmountOut` should come from the Tokemak offchain quote for the route.
- `slippageBps` should be the caller's route tolerance, applied to `expectedAmountOut`.
- `minAmountOut` must be at least the strategy shortfall.
- `routes` must match Tokemak's `redeemWithRoutes` custom route tuple.
- The caller must be the allocator admin or an approved allocator operator.

If the frontend can cheaply read strategy idle assets, pass that value as `idleAssetBalance`. If not, omit it and the helper will use the conservative no-idle assumption.
