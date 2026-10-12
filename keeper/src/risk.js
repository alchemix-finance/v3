import { ratioBps } from "./units.js";

export function evaluateCandidate(position, policy) {
  const storedDebt = BigInt(position.storedDebt);
  const projectedDebt = BigInt(position.projectedDebt);

  if (storedDebt === 0n || projectedDebt >= storedDebt) return null;

  const staleRedeemedDebt = storedDebt - projectedDebt;
  if (staleRedeemedDebt < policy.minStaleRedeemedDebt) return null;

  const remainingDebtBps = ratioBps(projectedDebt, storedDebt);
  if (remainingDebtBps > BigInt(policy.maxRemainingDebtBps)) return null;

  // Prioritize both absolute exposure and proximity to full redemption.
  const completionBps = 10_000n - remainingDebtBps;
  const score = staleRedeemedDebt * (10_000n + completionBps);

  return {
    ...position,
    staleRedeemedDebt,
    remainingDebtBps,
    score,
  };
}

export function rankCandidates(positions, policy) {
  return positions
    .map((position) => evaluateCandidate(position, policy))
    .filter(Boolean)
    .sort((a, b) => (a.score === b.score ? 0 : a.score > b.score ? -1 : 1));
}
