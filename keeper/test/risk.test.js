import assert from "node:assert/strict";
import test from "node:test";
import { evaluateCandidate, rankCandidates } from "../src/risk.js";

const policy = {
  minStaleRedeemedDebt: 25_000n,
  maxRemainingDebtBps: 1000,
};

test("selects a large position that is almost fully redeemed", () => {
  const result = evaluateCandidate({ tokenId: 1n, storedDebt: 100_000n, projectedDebt: 5_000n }, policy);
  assert.equal(result.staleRedeemedDebt, 95_000n);
  assert.equal(result.remainingDebtBps, 500n);
});

test("catches the one-unit residual-debt bypass", () => {
  const result = evaluateCandidate({ tokenId: 2n, storedDebt: 100_000n, projectedDebt: 1n }, policy);
  assert.equal(result.staleRedeemedDebt, 99_999n);
  assert.equal(result.remainingDebtBps, 0n);
});

test("does not select a position with too much debt remaining", () => {
  const result = evaluateCandidate({ tokenId: 3n, storedDebt: 100_000n, projectedDebt: 20_000n }, policy);
  assert.equal(result, null);
});

test("does not select small stale exposure", () => {
  const result = evaluateCandidate({ tokenId: 4n, storedDebt: 30_000n, projectedDebt: 10_000n }, policy);
  assert.equal(result, null);
});

test("ranks larger stale exposure first", () => {
  const ranked = rankCandidates(
    [
      { tokenId: 1n, storedDebt: 100_000n, projectedDebt: 5_000n },
      { tokenId: 2n, storedDebt: 200_000n, projectedDebt: 5_000n },
    ],
    policy,
  );
  assert.deepEqual(ranked.map(({ tokenId }) => tokenId), [2n, 1n]);
});
