#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$ROOT"

: "${ENSO_API_KEY:?Set ENSO_API_KEY from https://developers.enso.build/}"
: "${MAINNET_RPC_URL:=https://mainnet.gateway.tenderly.co}"

DEPLOYER="0x0000000000000000000000000000000000c0ffee"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
REWARD_VAULT="0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-125}"
ALLOCATE_AMOUNT="${ALLOCATE_AMOUNT:-1000000000000000000}"
DEALLOCATE_SHARE_BPS="${DEALLOCATE_SHARE_BPS:-5000}"
OUTPUT_PATH="${OUTPUT_PATH:-src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle1Eth.json}"

if ! command -v cast >/dev/null 2>&1; then
  echo "cast is required (foundry)" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

forge build --quiet

STRATEGY_ADDRESS="$(cast compute-address "$DEPLOYER" --nonce 1 | awk '{print $NF}')"

if [[ -z "$STRATEGY_ADDRESS" || ! "$STRATEGY_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Failed to compute strategy address via cast" >&2
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
      \"routingStrategy\": \"router\",
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

SHARES_OUT="$(echo "$ALLOCATE_RESPONSE" | jq -r 'if (.amountOut | type) == "array" then .amountOut[0] else .amountOut end')"
if (( DEALLOCATE_SHARE_BPS <= 0 || DEALLOCATE_SHARE_BPS >= 10000 )); then
  echo "DEALLOCATE_SHARE_BPS must be between 1 and 9999" >&2
  exit 1
fi
DEALLOCATE_AMOUNT_IN="$(
  python3 -c 'import sys; print(int(sys.argv[1]) * int(sys.argv[2]) // 10_000)' \
    "$SHARES_OUT" "$DEALLOCATE_SHARE_BPS"
)"

DEALLOCATE_PARTIAL_RESPONSE="$(fetch_route "$REWARD_VAULT" "$WETH" "$DEALLOCATE_AMOUNT_IN")"
if ! echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Partial deallocate route failed:" >&2
  echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq . >&2 || echo "$DEALLOCATE_PARTIAL_RESPONSE" >&2
  exit 1
fi
DEALLOCATE_AMOUNT_OUT="$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -r 'if (.amountOut | type) == "array" then .amountOut[0] else .amountOut end')"

DEALLOCATE_FULL_RESPONSE="$(fetch_route "$REWARD_VAULT" "$WETH" "$SHARES_OUT")"
if ! echo "$DEALLOCATE_FULL_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Full deallocate route failed:" >&2
  echo "$DEALLOCATE_FULL_RESPONSE" | jq . >&2 || echo "$DEALLOCATE_FULL_RESPONSE" >&2
  exit 1
fi
DEALLOCATE_FULL_AMOUNT_OUT="$(
  echo "$DEALLOCATE_FULL_RESPONSE" | jq -r 'if (.amountOut | type) == "array" then .amountOut[0] else .amountOut end'
)"

ALLOCATE_ROUTER="$(echo "$ALLOCATE_RESPONSE" | jq -r '.tx.to')"
DEALLOCATE_PARTIAL_ROUTER="$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -r '.tx.to')"
DEALLOCATE_FULL_ROUTER="$(echo "$DEALLOCATE_FULL_RESPONSE" | jq -r '.tx.to')"
if [[ "$ALLOCATE_ROUTER" != "$DEALLOCATE_PARTIAL_ROUTER" || "$ALLOCATE_ROUTER" != "$DEALLOCATE_FULL_ROUTER" ]]; then
  echo "Enso routes use different routers: allocate=$ALLOCATE_ROUTER partial=$DEALLOCATE_PARTIAL_ROUTER full=$DEALLOCATE_FULL_ROUTER" >&2
  exit 1
fi
ENSO_ROUTER="$ALLOCATE_ROUTER"

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
  --arg deallocateTxTo "$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -r '.tx.to')" \
  --arg deallocateTxData "$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -r '.tx.data')" \
  --arg deallocateFullAmountIn "$SHARES_OUT" \
  --arg deallocateFullAmountOut "$DEALLOCATE_FULL_AMOUNT_OUT" \
  --arg deallocateFullTxTo "$(echo "$DEALLOCATE_FULL_RESPONSE" | jq -r '.tx.to')" \
  --arg deallocateFullTxData "$(echo "$DEALLOCATE_FULL_RESPONSE" | jq -r '.tx.data')" \
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
    },
    deallocateFull: {
      tokenIn: $rewardVault,
      tokenOut: $weth,
      amountIn: $deallocateFullAmountIn,
      amountOut: $deallocateFullAmountOut,
      tx: { to: $deallocateFullTxTo, data: $deallocateFullTxData }
    }
  }' > "$OUTPUT_PATH"

echo "Wrote fixture to $OUTPUT_PATH"
echo "strategyAddress=$STRATEGY_ADDRESS blockNumber=$BLOCK_NUMBER"
