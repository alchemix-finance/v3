#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$ROOT"

: "${ENSO_API_KEY:?Set ENSO_API_KEY from https://developers.enso.build/}"
: "${MAINNET_RPC_URL:=https://mainnet.gateway.tenderly.co}"

DEPLOYER="0x0000000000000000000000000000000000c0ffee"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
REWARD_VAULT="0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C"
# Curve ETH+/WETH pool LP token (== rewardVault.asset())
CURVE_LP="0x2c683fAd51da2cd17793219CC86439C1875c353e"
ENSO_ROUTER="0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf"
# WETH is coin index 1 in the ETH+/WETH pool (matches StakeDAOWETHStrategy).
WETH_COIN_INDEX=1
SLIPPAGE_BPS="${SLIPPAGE_BPS:-125}"
ALLOCATE_AMOUNT="${ALLOCATE_AMOUNT:-1000000000000000000}"
DEALLOCATE_SHARE_BPS="${DEALLOCATE_SHARE_BPS:-5000}"
OUTPUT_PATH="${OUTPUT_PATH:-src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle1Eth.json}"
# Slippage for deallocate Enso route (aggregators allowed). Defaults to allocate slippage.
DEALLOCATE_SLIPPAGE_BPS="${DEALLOCATE_SLIPPAGE_BPS:-$SLIPPAGE_BPS}"
# Enso can take a while on large bundles; fail instead of hanging forever.
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-20}"
CURL_MAX_TIME="${CURL_MAX_TIME:-180}"

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

log() { echo "[enso-fetch] $*" >&2; }

log "computing strategy address from deployer=${DEPLOYER} nonce=1"
STRATEGY_ADDRESS="$(cast compute-address "$DEPLOYER" --nonce 1 | awk '{print $NF}')"

if [[ -z "$STRATEGY_ADDRESS" || ! "$STRATEGY_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Failed to compute strategy address via cast" >&2
  exit 1
fi
log "strategyAddress=${STRATEGY_ADDRESS}"

log "fetching block number from ${MAINNET_RPC_URL}"
BLOCK_NUMBER="$(cast block-number --rpc-url "$MAINNET_RPC_URL")"
log "blockNumber=${BLOCK_NUMBER}"

enso_curl() {
  # Usage: enso_curl <url> <json-body>
  local url="$1"
  local body="$2"
  local tmp status
  tmp="$(mktemp)"
  status="$(
    curl -sS \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ENSO_API_KEY}" \
      -d "$body" \
      -o "$tmp" \
      -w "%{http_code}"
  )"
  if [[ "$status" != "200" ]]; then
    echo "Enso HTTP ${status} for ${url%%\?*}" >&2
    if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <"$tmp"; then
      jq . >&2 <"$tmp" || cat "$tmp" >&2
    else
      cat "$tmp" >&2
      echo >&2
    fi
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

enso_bundle_query() {
  python3 -c '
import urllib.parse, sys
print(urllib.parse.urlencode({
  "chainId": "1",
  "fromAddress": sys.argv[1],
  "receiver": sys.argv[1],
  "spender": sys.argv[1],
  "routingStrategy": "router",
}))
' "$STRATEGY_ADDRESS"
}

# Allocate Bundle: WETH → Curve LP (enso:route) → approve → deposit(..., referrer=strategy).
# Bundle is required so Stake DAO referrer is encoded; plain Route cannot pass it.
fetch_allocate_bundle() {
  local amount_in="$1"
  local query body
  query="$(enso_bundle_query)"

  body="$(
    jq -n \
      --arg weth "$WETH" \
      --arg curveLp "$CURVE_LP" \
      --arg rewardVault "$REWARD_VAULT" \
      --arg strategy "$STRATEGY_ADDRESS" \
      --arg amountIn "$amount_in" \
      --arg slippage "$SLIPPAGE_BPS" \
      '[
        {
          protocol: "enso",
          action: "route",
          args: {
            tokenIn: $weth,
            tokenOut: $curveLp,
            amountIn: $amountIn,
            slippage: $slippage
          }
        },
        {
          protocol: "erc20",
          action: "approve",
          args: {
            token: $curveLp,
            spender: $rewardVault,
            amount: { useOutputOfCallAt: 0 }
          }
        },
        {
          protocol: "enso",
          action: "call",
          args: {
            address: $rewardVault,
            method: "deposit",
            abi: "function deposit(uint256 assets, address receiver, address referrer) external returns (uint256 shares)",
            args: [
              { useOutputOfCallAt: 0 },
              $strategy,
              $strategy
            ],
            tokenIn: $curveLp,
            tokenOut: $rewardVault
          }
        }
      ]'
  )"

  enso_curl "https://api.enso.build/api/v1/shortcuts/bundle?${query}" "$body"
}

# Fallback: plain Route API (also aggregator-capable; Enso recommended for tokenIn→tokenOut).
fetch_deallocate_route() {
  local shares_in="$1"
  local slippage_bps="$2"
  enso_curl "https://api.enso.build/api/v1/shortcuts/route" "{
      \"chainId\": 1,
      \"fromAddress\": \"${STRATEGY_ADDRESS}\",
      \"receiver\": \"${STRATEGY_ADDRESS}\",
      \"spender\": \"${STRATEGY_ADDRESS}\",
      \"routingStrategy\": \"router\",
      \"tokenIn\": [\"${REWARD_VAULT}\"],
      \"tokenOut\": [\"${WETH}\"],
      \"amountIn\": [\"${shares_in}\"],
      \"slippage\": \"${slippage_bps}\"
    }"
}

# Preferred deallocate: Bundle with balance{estimate} + enso:route to WETH.
# Aggregators are allowed (best execution). Curve-only custom exits are not required
# and currently fail Enso simulation when the strategy has no live share balance.
fetch_deallocate_bundle() {
  local shares_in="$1"
  local query body expected_weth
  query="$(enso_bundle_query)"

  # Optional Curve fair-value reference for logs (RewardVault is 1:1 shares:LP).
  # cast may append a human annotation: "123 [1.23e2]" — keep the leading integer only.
  expected_weth="$(
    cast call "$CURVE_LP" \
      "calc_withdraw_one_coin(uint256,int128)(uint256)" \
      "$shares_in" \
      "$WETH_COIN_INDEX" \
      --rpc-url "$MAINNET_RPC_URL" \
      --block "$BLOCK_NUMBER" \
      | awk '{print $1}'
  )"
  log "deallocate quote shares=${shares_in} curveFairWeth≈${expected_weth} slippage=${DEALLOCATE_SLIPPAGE_BPS}"

  body="$(
    jq -n \
      --arg weth "$WETH" \
      --arg rewardVault "$REWARD_VAULT" \
      --arg sharesIn "$shares_in" \
      --arg slippage "$DEALLOCATE_SLIPPAGE_BPS" \
      '[
        {
          protocol: "enso",
          action: "balance",
          args: {
            token: $rewardVault,
            estimate: $sharesIn
          }
        },
        {
          protocol: "enso",
          action: "route",
          args: {
            tokenIn: $rewardVault,
            tokenOut: $weth,
            amountIn: { useOutputOfCallAt: 0 },
            slippage: $slippage
          }
        }
      ]'
  )"
  if enso_curl "https://api.enso.build/api/v1/shortcuts/bundle?${query}" "$body"; then
    return 0
  fi

  log "deallocate balance+route bundle failed; using Route API"
  fetch_deallocate_route "$shares_in" "$DEALLOCATE_SLIPPAGE_BPS"
}

# Route API: amountOut string/array. Bundle API: amountsOut { tokenAddress: amount }.
response_amount_out() {
  local token_out="$1"
  jq -r --arg token "$token_out" '
    def lookup($m):
      if ($m | type) != "object" then empty
      else
        ($m | with_entries(.key |= ascii_downcase) | .[$token | ascii_downcase] // empty)
      end;
    (lookup(.amountsOut) // lookup(.minAmountsOut) //
      (if (.amountOut | type) == "array" then .amountOut[0]
       elif (.amountOut | type) == "string" then .amountOut
       elif (.amountOut | type) == "number" then (.amountOut | tostring)
       else empty end) //
      "null")
  '
}

require_amount() {
  local label="$1"
  local amount="$2"
  if [[ -z "$amount" || "$amount" == "null" || ! "$amount" =~ ^[0-9]+$ ]]; then
    echo "${label}: expected numeric amountOut, got '${amount}'" >&2
    exit 1
  fi
}

log "allocateSlippage=${SLIPPAGE_BPS} deallocateSlippage=${DEALLOCATE_SLIPPAGE_BPS}"
log "requesting allocate bundle amountIn=${ALLOCATE_AMOUNT} (timeout ${CURL_MAX_TIME}s)"
ALLOCATE_RESPONSE="$(fetch_allocate_bundle "$ALLOCATE_AMOUNT")" || {
  echo "Allocate bundle request failed (Enso timeout/error). Try a smaller ALLOCATE_AMOUNT or raise CURL_MAX_TIME." >&2
  exit 1
}
if ! echo "$ALLOCATE_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Allocate bundle failed:" >&2
  echo "$ALLOCATE_RESPONSE" | jq . >&2 || echo "$ALLOCATE_RESPONSE" >&2
  exit 1
fi

SHARES_OUT="$(echo "$ALLOCATE_RESPONSE" | response_amount_out "$REWARD_VAULT")"
if [[ "$SHARES_OUT" == "null" ]]; then
  echo "Allocate bundle returned no RewardVault amount. Response keys:" >&2
  echo "$ALLOCATE_RESPONSE" | jq '{amountOut, amountsOut, minAmountsOut, gas, route: (.route|length)}' >&2 || true
  exit 1
fi
require_amount "allocate" "$SHARES_OUT"
log "allocate bundle ok amountOut=${SHARES_OUT}"

# Require the 3-arg Stake DAO deposit selector so referrer is actually encoded.
if ! echo "$ALLOCATE_RESPONSE" | jq -r '.tx.data' | grep -qi '2e2d2984'; then
  echo "Allocate bundle calldata missing deposit(uint256,address,address) selector 0x2e2d2984" >&2
  echo "$ALLOCATE_RESPONSE" | jq '{route, amountsOut, amountOut, gas}' >&2 || true
  exit 1
fi

if (( DEALLOCATE_SHARE_BPS <= 0 || DEALLOCATE_SHARE_BPS >= 10000 )); then
  echo "DEALLOCATE_SHARE_BPS must be between 1 and 9999" >&2
  exit 1
fi
DEALLOCATE_AMOUNT_IN="$(
  python3 -c 'import sys; print(int(sys.argv[1]) * int(sys.argv[2]) // 10_000)' \
    "$SHARES_OUT" "$DEALLOCATE_SHARE_BPS"
)"

log "requesting partial deallocate bundle amountIn=${DEALLOCATE_AMOUNT_IN}"
DEALLOCATE_PARTIAL_RESPONSE="$(fetch_deallocate_bundle "$DEALLOCATE_AMOUNT_IN")" || {
  echo "Partial deallocate bundle request failed" >&2
  exit 1
}
if ! echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Partial deallocate bundle failed:" >&2
  echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq . >&2 || echo "$DEALLOCATE_PARTIAL_RESPONSE" >&2
  exit 1
fi
DEALLOCATE_AMOUNT_OUT="$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | response_amount_out "$WETH")"
require_amount "partial deallocate" "$DEALLOCATE_AMOUNT_OUT"
log "partial deallocate ok amountOut=${DEALLOCATE_AMOUNT_OUT}"

log "requesting full deallocate bundle amountIn=${SHARES_OUT}"
DEALLOCATE_FULL_RESPONSE="$(fetch_deallocate_bundle "$SHARES_OUT")" || {
  echo "Full deallocate bundle request failed" >&2
  exit 1
}
if ! echo "$DEALLOCATE_FULL_RESPONSE" | jq -e '.tx.data' >/dev/null; then
  echo "Full deallocate bundle failed:" >&2
  echo "$DEALLOCATE_FULL_RESPONSE" | jq . >&2 || echo "$DEALLOCATE_FULL_RESPONSE" >&2
  exit 1
fi
DEALLOCATE_FULL_AMOUNT_OUT="$(echo "$DEALLOCATE_FULL_RESPONSE" | response_amount_out "$WETH")"
require_amount "full deallocate" "$DEALLOCATE_FULL_AMOUNT_OUT"
log "full deallocate ok amountOut=${DEALLOCATE_FULL_AMOUNT_OUT}"

ALLOCATE_ROUTER="$(echo "$ALLOCATE_RESPONSE" | jq -r '.tx.to')"
DEALLOCATE_PARTIAL_ROUTER="$(echo "$DEALLOCATE_PARTIAL_RESPONSE" | jq -r '.tx.to')"
DEALLOCATE_FULL_ROUTER="$(echo "$DEALLOCATE_FULL_RESPONSE" | jq -r '.tx.to')"
if [[ "$ALLOCATE_ROUTER" != "$ENSO_ROUTER" || "$DEALLOCATE_PARTIAL_ROUTER" != "$ENSO_ROUTER" || "$DEALLOCATE_FULL_ROUTER" != "$ENSO_ROUTER" ]]; then
  echo "Unexpected Enso router: expected=$ENSO_ROUTER allocate=$ALLOCATE_ROUTER partial=$DEALLOCATE_PARTIAL_ROUTER full=$DEALLOCATE_FULL_ROUTER" >&2
  exit 1
fi

jq -n \
  --arg chainId "1" \
  --arg blockNumber "$BLOCK_NUMBER" \
  --arg rpcUrl "$MAINNET_RPC_URL" \
  --arg strategyAddress "$STRATEGY_ADDRESS" \
  --arg referrer "$STRATEGY_ADDRESS" \
  --arg weth "$WETH" \
  --arg curveLp "$CURVE_LP" \
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
    referrer: $referrer,
    weth: $weth,
    curveLp: $curveLp,
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

log "Wrote fixture to $OUTPUT_PATH"
log "strategyAddress=$STRATEGY_ADDRESS referrer=$STRATEGY_ADDRESS blockNumber=$BLOCK_NUMBER"
