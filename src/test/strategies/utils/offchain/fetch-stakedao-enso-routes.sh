#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$ROOT"

: "${ENSO_API_KEY:?Set ENSO_API_KEY from https://developers.enso.build/}"
: "${MAINNET_RPC_URL:=https://mainnet.gateway.tenderly.co}"

DEPLOYER="0x0000000000000000000000000000000000c0ffee"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
REWARD_VAULT="0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C"
ENSO_ROUTER="0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-125}"
ALLOCATE_AMOUNT="${ALLOCATE_AMOUNT:-1000000000000000000}"
DEALLOCATE_AMOUNT_OUT="${DEALLOCATE_AMOUNT_OUT:-500000000000000000}"
OUTPUT_PATH="${OUTPUT_PATH:-src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle1Eth.json}"

if ! command -v cast >/dev/null 2>&1; then
  echo "cast is required (foundry)" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

forge build --quiet

STRATEGY_ADDRESS="$(cast compute-address "$DEPLOYER" --nonce 1)"

if [[ -z "$STRATEGY_ADDRESS" || ! "$STRATEGY_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Failed to compute strategy address via forge script" >&2
  exit 1
fi

BLOCK_NUMBER="$(cast block-number --rpc-url "$MAINNET_RPC_URL")"

fetch_route() {
  local token_in="$1"
  local token_out="$2"
  local amount_in="$3"

  curl -sS -X POST "https://api.enso.build/api/v1/shortcuts/route" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ENSO_API_KEY}" \
    -d "{
      \"chainId\": 1,
      \"fromAddress\": \"${STRATEGY_ADDRESS}\",
      \"receiver\": \"${STRATEGY_ADDRESS}\",
      \"spender\": \"${STRATEGY_ADDRESS}\",
      \"routingStrategy\": \"delegate\",
      \"tokenIn\": [\"${token_in}\"],
      \"tokenOut\": [\"${token_out}\"],
      \"amountIn\": [\"${amount_in}\"],
      \"slippage\": \"${SLIPPAGE_BPS}\"
    }"
}

ALLOCATE_RESPONSE="$(fetch_route "$WETH" "$REWARD_VAULT" "$ALLOCATE_AMOUNT")"
if ! echo "$ALLOCATE_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Allocate route failed:" >&2
  echo "$ALLOCATE_RESPONSE" | jq . >&2 || echo "$ALLOCATE_RESPONSE" >&2
  exit 1
fi

SHARES_OUT="$(echo "$ALLOCATE_RESPONSE" | jq -r '.amountOut[0] // .amountOut')"
DEALLOCATE_AMOUNT_IN="$(echo "$ALLOCATE_RESPONSE" | jq -r '.amountOut[0] // .amountOut')"

DEALLOCATE_RESPONSE="$(fetch_route "$REWARD_VAULT" "$WETH" "$DEALLOCATE_AMOUNT_IN")"
if ! echo "$DEALLOCATE_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Deallocate route failed:" >&2
  echo "$DEALLOCATE_RESPONSE" | jq . >&2 || echo "$DEALLOCATE_RESPONSE" >&2
  exit 1
fi

jq -n \
  --arg chainId "1" \
  --arg blockNumber "$BLOCK_NUMBER" \
  --arg rpcUrl "$MAINNET_RPC_URL" \
  --arg strategyAddress "$STRATEGY_ADDRESS" \
  --arg weth "$WETH" \
  --arg rewardVault "$REWARD_VAULT" \
  --arg ensoRouter "$ENSO_ROUTER" \
  --argjson slippageBps "$SLIPPAGE_BPS" \
  --arg allocateAmountIn "$ALLOCATE_AMOUNT" \
  --arg allocateAmountOut "$SHARES_OUT" \
  --arg allocateTxTo "$(echo "$ALLOCATE_RESPONSE" | jq -r '.tx.to')" \
  --arg allocateTxData "$(echo "$ALLOCATE_RESPONSE" | jq -r '.tx.data')" \
  --arg deallocateAmountIn "$DEALLOCATE_AMOUNT_IN" \
  --arg deallocateAmountOut "$DEALLOCATE_AMOUNT_OUT" \
  --arg deallocateTxTo "$(echo "$DEALLOCATE_RESPONSE" | jq -r '.tx.to')" \
  --arg deallocateTxData "$(echo "$DEALLOCATE_RESPONSE" | jq -r '.tx.data')" \
  '{
    generated: true,
    chainId: $chainId,
    blockNumber: $blockNumber,
    rpcUrl: $rpcUrl,
    strategyAddress: $strategyAddress,
    weth: $weth,
    rewardVault: $rewardVault,
    ensoRouter: $ensoRouter,
    slippageBps: $slippageBps,
    allocate: {
      tokenIn: $weth,
      tokenOut: $rewardVault,
      amountIn: $allocateAmountIn,
      amountOut: $allocateAmountOut,
      tx: { to: $allocateTxTo, data: $allocateTxData }
    },
    deallocate: {
      tokenIn: $rewardVault,
      tokenOut: $weth,
      amountIn: $deallocateAmountIn,
      amountOut: $deallocateAmountOut,
      tx: { to: $deallocateTxTo, data: $deallocateTxData }
    }
  }' > "$OUTPUT_PATH"

echo "Wrote fixture to $OUTPUT_PATH"
echo "strategyAddress=$STRATEGY_ADDRESS blockNumber=$BLOCK_NUMBER"
