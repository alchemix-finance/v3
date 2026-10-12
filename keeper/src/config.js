import "dotenv/config";
import path from "node:path";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

function integer(name, fallback, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = process.env[name] ?? String(fallback);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return value;
}

function decimal(name, fallback) {
  const value = process.env[name] ?? String(fallback);
  if (!/^\d+(\.\d+)?$/.test(value)) throw new Error(`${name} must be a non-negative decimal`);
  return value;
}

function boolean(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (/^(1|true|yes)$/i.test(raw)) return true;
  if (/^(0|false|no)$/i.test(raw)) return false;
  throw new Error(`${name} must be true or false`);
}

export function loadConfig(argv = process.argv.slice(2)) {
  const execute = boolean("EXECUTE", false);
  const expectedImplementation = process.env.EXPECTED_IMPLEMENTATION?.trim();
  const privateKey = process.env.KEEPER_PRIVATE_KEY?.trim();

  if (execute && !privateKey) throw new Error("KEEPER_PRIVATE_KEY is required when EXECUTE=true");
  if (execute && !expectedImplementation) {
    throw new Error("EXPECTED_IMPLEMENTATION is required when EXECUTE=true");
  }

  return {
    rpcUrl: required("RPC_URL"),
    chainId: BigInt(process.env.CHAIN_ID ?? "1"),
    alchemistAddress: required("ALCHEMIST_ADDRESS"),
    expectedImplementation,
    accountMappingSlot: BigInt(process.env.ACCOUNT_MAPPING_SLOT ?? "33"),
    minStaleRedeemedDebt: decimal("MIN_STALE_REDEEMED_DEBT", "25000"),
    maxRemainingDebtBps: integer("MAX_REMAINING_DEBT_BPS", 1000, { min: 0, max: 10_000 }),
    maxPokesPerScan: integer("MAX_POKES_PER_SCAN", 3, { min: 0, max: 100 }),
    pollIntervalMs: integer("POLL_INTERVAL_MS", 15_000, { min: 1000 }),
    confirmations: integer("CONFIRMATIONS", 2, { min: 0, max: 100 }),
    rpcConcurrency: integer("RPC_CONCURRENCY", 12, { min: 1, max: 100 }),
    rpcRetries: integer("RPC_RETRIES", 4, { min: 0, max: 10 }),
    rpcRetryDelayMs: integer("RPC_RETRY_DELAY_MS", 750, { min: 50, max: 60_000 }),
    maxLogRange: integer("MAX_LOG_RANGE", 2000, { min: 1 }),
    scanOnStart: boolean("SCAN_ON_START", true),
    stateFile: path.resolve(process.env.STATE_FILE ?? "./data/state.json"),
    execute,
    privateKey,
    maxFeeGwei: decimal("MAX_FEE_GWEI", "40"),
    priorityFeeGwei: decimal("PRIORITY_FEE_GWEI", "1.5"),
    maxTxCostEth: decimal("MAX_TX_COST_ETH", "0.015"),
    gasLimitMultiplierBps: integer("GAS_LIMIT_MULTIPLIER_BPS", 12_000, { min: 10_000, max: 30_000 }),
    runOnce: argv.includes("--once"),
  };
}
