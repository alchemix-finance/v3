# Alchemist V3 Redemption Sync Keeper

This service reduces exposure to cross-window redemption-rate blending by checkpointing only large CDPs whose stored debt has been mostly redeemed.

It is an operational mitigation, not a protocol fix. It cannot repair historical mispricing, guarantee transaction ordering, or cover accounts outside its configured thresholds.

## Selection policy

For each position, the keeper reads:

- Raw stored account debt from the proxy's `_accounts` mapping.
- Projected debt from `getCDP(tokenId)`.

Their difference is redemption debt that has not yet been checkpointed:

```text
staleRedeemedDebt = storedDebt - projectedDebt
remainingDebtBps  = projectedDebt / storedDebt
```

A position is eligible only when:

- `staleRedeemedDebt >= MIN_STALE_REDEEMED_DEBT`; and
- `remainingDebtBps <= MAX_REMAINING_DEBT_BPS`.

This catches fully redeemed positions and dust residuals without paying to poke every account.

## Storage-layout safety

The deployed layout currently places `_accounts` at slot 33 and `Account.debt` at member slot 1. Execution mode requires `EXPECTED_IMPLEMENTATION`; the process halts if the EIP-1967 proxy implementation does not match.

Reconfirm `ACCOUNT_MAPPING_SLOT` from the exact implementation's storage layout before operating another deployment.

## Setup

Requires Node.js 20 or newer.

Use a dedicated production RPC endpoint. A full initial scan reads every position's storage, and public endpoints commonly rate-limit that workload. RPC reads are retried, but any position that remains unreadable fails the entire scan closed; an incomplete scan never submits transactions or advances the processed-block checkpoint.

```bash
cd keeper
npm install
```

Populate `.env` from `.env.example` with the target proxy and RPC. Use one process and state file per market.

Start with a one-time dry-run scan:

```bash
npm run scan
```

Then run the event watcher:

```bash
npm run keeper
```

Transactions remain disabled unless `EXECUTE=true`. In execution mode, use a dedicated low-balance key and configure conservative gas and transaction-count caps.

## Event flow

1. Poll confirmed blocks for `Redemption` events.
2. Enumerate position NFTs once, then maintain the set from confirmed NFT `Transfer` events.
3. Rank eligible positions by stale redeemed debt and redemption completion.
4. Re-read and simulate each selected position at latest state.
5. Enforce implementation, gas-price, transaction-cost, and per-scan count caps.
6. Submit `poke(tokenId)` sequentially.

The local state file stores the last processed block and whether eligible work remains. Transaction caps and temporary gas deferrals are retried on later polls. Deleting the file causes a fresh startup scan but does not affect protocol state.

## Recommended rollout

1. Run dry for at least one redemption window and review selected positions.
2. Compare the raw stored debt and projected debt for every candidate.
3. Begin with a high debt threshold and one transaction per scan.
4. Add independent balance, liveness, and implementation-change alerts.
5. Keep enough ETH for the configured maximum transactions, but do not fund the keeper key materially beyond its operating budget.

Run checks with:

```bash
npm test
npm run check
```

