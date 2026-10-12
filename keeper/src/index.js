import { Web3 } from "web3";
import { ALCHEMIST_ABI, ERC20_METADATA_ABI, POSITION_NFT_ABI } from "./abis.js";
import { loadConfig } from "./config.js";
import { evaluateCandidate, rankCandidates } from "./risk.js";
import { loadState, saveState } from "./state.js";
import { getProxyImplementation, readStoredDebt } from "./storage.js";
import { formatUnits, parseUnits } from "./units.js";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const BPS = 10_000n;

class FatalKeeperError extends Error {}

function isHexAddress(value) {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}

function log(message, fields = {}) {
  const suffix = Object.keys(fields).length
    ? ` ${Object.entries(fields).map(([key, value]) => `${key}=${value}`).join(" ")}`
    : "";
  console.log(`${new Date().toISOString()} ${message}${suffix}`);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function withRetry(label, retries, baseDelayMs, action) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await action();
    } catch (error) {
      lastError = error;
      if (attempt === retries) break;
      const backoff = baseDelayMs * 2 ** attempt;
      const jitter = Math.floor(Math.random() * baseDelayMs);
      await sleep(backoff + jitter);
    }
  }

  throw new Error(`${label} failed after ${retries + 1} attempts: ${lastError?.message}`, { cause: lastError });
}

async function mapLimit(items, limit, mapper) {
  const results = new Array(items.length);
  let cursor = 0;

  async function worker() {
    while (true) {
      const index = cursor++;
      if (index >= items.length) return;
      results[index] = await mapper(items[index], index);
    }
  }

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

function min(a, b) {
  return a < b ? a : b;
}

class RedemptionSyncKeeper {
  constructor(config) {
    this.config = config;
    this.web3 = new Web3(config.rpcUrl);
    this.alchemist = null;
    this.positionNft = null;
    this.signer = null;
    this.debtDecimals = 18;
    this.debtSymbol = "debt";
    this.policy = null;
    this.maxFeeWei = parseUnits(config.maxFeeGwei, 9);
    this.priorityFeeWei = parseUnits(config.priorityFeeGwei, 9);
    this.maxTxCostWei = parseUnits(config.maxTxCostEth, 18);
    this.cachedTokenSupply = null;
    this.cachedTokenIds = null;
    this.cachedTokenBlock = null;
    this.stopping = false;
  }

  async assertImplementation() {
    const implementation = await withRetry(
      "proxy implementation read",
      this.config.rpcRetries,
      this.config.rpcRetryDelayMs,
      () => getProxyImplementation(this.web3, this.config.alchemistAddress),
    );
    if (
      this.config.expectedImplementation &&
      implementation.toLowerCase() !== this.config.expectedImplementation.toLowerCase()
    ) {
      throw new FatalKeeperError(
        `Proxy implementation mismatch: expected ${this.config.expectedImplementation}, found ${implementation}`,
      );
    }
    return implementation;
  }

  async initialize() {
    if (
      !isHexAddress(this.config.alchemistAddress) ||
      this.config.alchemistAddress.toLowerCase() === ZERO_ADDRESS
    ) {
      throw new Error("ALCHEMIST_ADDRESS must be a non-zero address");
    }

    const actualChainId = BigInt(await this.web3.eth.getChainId());
    if (actualChainId !== this.config.chainId) {
      throw new Error(`Chain ID mismatch: configured ${this.config.chainId}, RPC returned ${actualChainId}`);
    }

    if (this.config.expectedImplementation && !isHexAddress(this.config.expectedImplementation)) {
      throw new Error("EXPECTED_IMPLEMENTATION is not a valid address");
    }
    const implementation = await this.assertImplementation();
    if (!this.config.expectedImplementation) {
      log("WARNING: implementation is not pinned; execution remains disabled unless it is configured");
    }

    this.alchemist = new this.web3.eth.Contract(ALCHEMIST_ABI, this.config.alchemistAddress);
    const [nftAddress, debtTokenAddress] = await Promise.all([
      this.alchemist.methods.alchemistPositionNFT().call(),
      this.alchemist.methods.debtToken().call(),
    ]);

    this.positionNft = new this.web3.eth.Contract(POSITION_NFT_ABI, nftAddress);
    const debtToken = new this.web3.eth.Contract(ERC20_METADATA_ABI, debtTokenAddress);
    this.debtDecimals = Number(await debtToken.methods.decimals().call());
    try {
      this.debtSymbol = await debtToken.methods.symbol().call();
    } catch {
      this.debtSymbol = "debt";
    }

    this.policy = {
      minStaleRedeemedDebt: parseUnits(this.config.minStaleRedeemedDebt, this.debtDecimals),
      maxRemainingDebtBps: this.config.maxRemainingDebtBps,
    };

    if (this.config.execute) {
      const privateKey = this.config.privateKey.startsWith("0x")
        ? this.config.privateKey
        : `0x${this.config.privateKey}`;
      this.signer = this.web3.eth.accounts.privateKeyToAccount(privateKey);
    }

    log("keeper initialized", {
      mode: this.config.execute ? "EXECUTE" : "DRY_RUN",
      chainId: actualChainId,
      alchemist: this.config.alchemistAddress,
      implementation,
      nft: nftAddress,
      minStale: `${this.config.minStaleRedeemedDebt}_${this.debtSymbol}`,
      maxRemainingBps: this.config.maxRemainingDebtBps,
      signer: this.signer?.address ?? "none",
    });
  }

  async positionTransferEvents(fromBlock, toBlock) {
    const events = [];
    let cursor = fromBlock;
    while (cursor <= toBlock) {
      const end = min(cursor + BigInt(this.config.maxLogRange) - 1n, toBlock);
      const page = await withRetry(
        `position Transfer logs ${cursor}-${end}`,
        this.config.rpcRetries,
        this.config.rpcRetryDelayMs,
        () => this.positionNft.getPastEvents("Transfer", { fromBlock: cursor, toBlock: end }),
      );
      events.push(...page);
      cursor = end + 1n;
    }
    return events;
  }

  async tokenIdsAt(blockNumber) {
    const supply = BigInt(
      await withRetry("position totalSupply", this.config.rpcRetries, this.config.rpcRetryDelayMs, () =>
        this.positionNft.methods.totalSupply().call({}, blockNumber),
      ),
    );
    if (supply > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("NFT supply exceeds safe enumeration range");

    if (this.cachedTokenIds !== null && this.cachedTokenBlock !== null && blockNumber >= this.cachedTokenBlock) {
      const tokenIds = new Set(this.cachedTokenIds.map(String));
      if (blockNumber > this.cachedTokenBlock) {
        const transfers = await this.positionTransferEvents(this.cachedTokenBlock + 1n, blockNumber);
        for (const event of transfers) {
          const tokenId = String(event.returnValues.tokenId ?? event.returnValues[2]);
          const from = String(event.returnValues.from ?? event.returnValues[0]).toLowerCase();
          const to = String(event.returnValues.to ?? event.returnValues[1]).toLowerCase();
          if (from === ZERO_ADDRESS) tokenIds.add(tokenId);
          if (to === ZERO_ADDRESS) tokenIds.delete(tokenId);
        }
      }

      if (BigInt(tokenIds.size) === supply) {
        this.cachedTokenSupply = supply;
        this.cachedTokenIds = [...tokenIds].map(BigInt).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
        this.cachedTokenBlock = blockNumber;
        return this.cachedTokenIds;
      }

      log("position cache mismatch; rebuilding enumeration", {
        cachedCount: tokenIds.size,
        expectedCount: supply,
      });
    }

    const indexes = Array.from({ length: Number(supply) }, (_, index) => BigInt(index));
    const tokenIds = await mapLimit(indexes, this.config.rpcConcurrency, async (index) =>
      BigInt(
        await withRetry(`tokenByIndex(${index})`, this.config.rpcRetries, this.config.rpcRetryDelayMs, () =>
          this.positionNft.methods.tokenByIndex(index).call({}, blockNumber),
        ),
      ),
    );
    this.cachedTokenSupply = supply;
    this.cachedTokenIds = tokenIds;
    this.cachedTokenBlock = blockNumber;
    return tokenIds;
  }

  async readPosition(tokenId, blockNumber) {
    const storedDebt = await withRetry(
      `stored debt for token ${tokenId}`,
      this.config.rpcRetries,
      this.config.rpcRetryDelayMs,
      () =>
        readStoredDebt(
          this.web3,
          this.config.alchemistAddress,
          tokenId,
          this.config.accountMappingSlot,
          blockNumber,
        ),
    );
    if (storedDebt < this.policy.minStaleRedeemedDebt) return null;

    const cdp = await withRetry(
      `getCDP(${tokenId})`,
      this.config.rpcRetries,
      this.config.rpcRetryDelayMs,
      () => this.alchemist.methods.getCDP(tokenId).call({}, blockNumber),
    );
    return {
      tokenId,
      storedDebt,
      projectedCollateral: BigInt(cdp.collateral ?? cdp[0]),
      projectedDebt: BigInt(cdp.debt ?? cdp[1]),
      projectedEarmarked: BigInt(cdp.earmarked ?? cdp[2]),
    };
  }

  async scan(blockNumber) {
    await this.assertImplementation();
    const tokenIds = await this.tokenIdsAt(blockNumber);
    log("scanning positions", { block: blockNumber, count: tokenIds.length });

    let positions;
    try {
      positions = (
        await mapLimit(tokenIds, this.config.rpcConcurrency, (tokenId) => this.readPosition(tokenId, blockNumber))
      ).filter(Boolean);
    } catch (error) {
      this.cachedTokenSupply = null;
      this.cachedTokenIds = null;
      this.cachedTokenBlock = null;
      throw error;
    }
    const candidates = rankCandidates(positions, this.policy);
    const reportCount = Math.min(candidates.length, Math.max(10, this.config.maxPokesPerScan));

    if (candidates.length === 0) {
      log("scan complete: no positions meet policy");
      return false;
    }

    log("scan complete: candidates found", { count: candidates.length });
    for (const candidate of candidates.slice(0, reportCount)) {
      log("candidate", {
        tokenId: candidate.tokenId,
        staleRedeemed: formatUnits(candidate.staleRedeemedDebt, this.debtDecimals),
        remainingDebt: formatUnits(candidate.projectedDebt, this.debtDecimals),
        remainingBps: candidate.remainingDebtBps,
        collateralShares: candidate.projectedCollateral,
      });
    }

    if (!this.config.execute) {
      log("dry run: no transactions submitted");
      return false;
    }

    const selected = candidates.slice(0, this.config.maxPokesPerScan);
    let pendingRescan = selected.length < candidates.length;
    for (const candidate of selected) {
      if (!(await this.executePoke(candidate.tokenId))) pendingRescan = true;
    }

    if (pendingRescan) log("eligible positions remain queued for the next poll");
    return pendingRescan;
  }

  async currentCandidate(tokenId) {
    const blockNumber = await this.web3.eth.getBlockNumber();
    const position = await this.readPosition(tokenId, blockNumber);
    return position ? evaluateCandidate(position, this.policy) : null;
  }

  async executePoke(tokenId) {
    await this.assertImplementation();
    const candidate = await this.currentCandidate(tokenId);
    if (!candidate) {
      log("candidate no longer meets policy", { tokenId });
      return true;
    }

    const method = this.alchemist.methods.poke(tokenId);
    try {
      await method.call({ from: this.signer.address });
    } catch (error) {
      log("poke simulation failed", { tokenId, error: error.shortMessage ?? error.message });
      return false;
    }

    let estimatedGas;
    try {
      estimatedGas = BigInt(await method.estimateGas({ from: this.signer.address }));
    } catch (error) {
      log("poke gas estimation failed", { tokenId, error: error.shortMessage ?? error.message });
      return false;
    }

    const gas = (estimatedGas * BigInt(this.config.gasLimitMultiplierBps) + BPS - 1n) / BPS;
    const pendingBlock = await this.web3.eth.getBlock("pending");
    const feeFields = {};

    let transactionGasPrice;
    if (pendingBlock.baseFeePerGas !== undefined && pendingBlock.baseFeePerGas !== null) {
      const baseFee = BigInt(pendingBlock.baseFeePerGas);
      if (baseFee + this.priorityFeeWei > this.maxFeeWei) {
        log("gas cap exceeded", {
          tokenId,
          baseFeeGwei: formatUnits(baseFee, 9),
          capGwei: this.config.maxFeeGwei,
        });
        return false;
      }
      transactionGasPrice = min(baseFee * 2n + this.priorityFeeWei, this.maxFeeWei);
      feeFields.maxFeePerGas = transactionGasPrice.toString();
      feeFields.maxPriorityFeePerGas = this.priorityFeeWei.toString();
      feeFields.type = "0x2";
    } else {
      transactionGasPrice = BigInt(await this.web3.eth.getGasPrice());
      if (transactionGasPrice > this.maxFeeWei) {
        log("legacy gas cap exceeded", { tokenId, gasPriceGwei: formatUnits(transactionGasPrice, 9) });
        return false;
      }
      feeFields.gasPrice = transactionGasPrice.toString();
    }

    const maximumCost = gas * transactionGasPrice;
    if (maximumCost > this.maxTxCostWei) {
      log("transaction cost cap exceeded", {
        tokenId,
        maximumCostEth: formatUnits(maximumCost, 18, 6),
        capEth: this.config.maxTxCostEth,
      });
      return false;
    }

    const balance = BigInt(await this.web3.eth.getBalance(this.signer.address));
    if (balance < maximumCost) {
      log("keeper balance too low", {
        tokenId,
        balanceEth: formatUnits(balance, 18, 6),
        requiredEth: formatUnits(maximumCost, 18, 6),
      });
      return false;
    }

    const [owner, maxWithdrawable, nonce] = await Promise.all([
      this.positionNft.methods.ownerOf(tokenId).call(),
      this.alchemist.methods.getMaxWithdrawable(tokenId).call(),
      this.web3.eth.getTransactionCount(this.signer.address, "pending"),
    ]);

    const signed = await this.signer.signTransaction({
      chainId: this.config.chainId.toString(),
      nonce: nonce.toString(),
      to: this.config.alchemistAddress,
      data: method.encodeABI(),
      gas: gas.toString(),
      ...feeFields,
    });

    log("submitting poke", {
      tokenId,
      owner,
      staleRedeemed: formatUnits(candidate.staleRedeemedDebt, this.debtDecimals),
      maxWithdrawableShares: maxWithdrawable,
      maximumCostEth: formatUnits(maximumCost, 18, 6),
    });

    const receipt = await this.web3.eth.sendSignedTransaction(signed.rawTransaction);
    log("poke confirmed", {
      tokenId,
      transactionHash: receipt.transactionHash,
      block: receipt.blockNumber,
      gasUsed: receipt.gasUsed,
    });
    return true;
  }

  async processNewBlocks(state) {
    const latest = BigInt(await this.web3.eth.getBlockNumber());
    const confirmations = BigInt(this.config.confirmations);
    const safeBlock = latest > confirmations ? latest - confirmations : 0n;

    if (state.lastProcessedBlock === null) {
      const pendingScan = this.config.scanOnStart ? await this.scan(safeBlock) : false;
      state.lastProcessedBlock = safeBlock;
      state.pendingScan = pendingScan;
      await saveState(this.config.stateFile, state);
      return;
    }

    if (state.pendingScan) {
      state.pendingScan = await this.scan(safeBlock);
      await saveState(this.config.stateFile, state);
      if (state.pendingScan) return;
    }

    while (state.lastProcessedBlock < safeBlock) {
      const fromBlock = state.lastProcessedBlock + 1n;
      const toBlock = min(fromBlock + BigInt(this.config.maxLogRange) - 1n, safeBlock);
      const events = await this.alchemist.getPastEvents("Redemption", { fromBlock, toBlock });
      const positiveRedemptions = events.filter((event) => BigInt(event.returnValues.amount ?? event.returnValues[0]) > 0n);

      if (positiveRedemptions.length > 0) {
        log("redemption events detected", {
          fromBlock,
          toBlock,
          count: positiveRedemptions.length,
        });
        state.pendingScan = await this.scan(safeBlock);
      }

      state.lastProcessedBlock = toBlock;
      await saveState(this.config.stateFile, state);
      if (state.pendingScan) return;
    }
  }

  async run() {
    await this.initialize();

    if (this.config.runOnce) {
      const latest = BigInt(await this.web3.eth.getBlockNumber());
      const confirmations = BigInt(this.config.confirmations);
      await this.scan(latest > confirmations ? latest - confirmations : 0n);
      return;
    }

    const state = await loadState(this.config.stateFile);
    process.on("SIGINT", () => {
      this.stopping = true;
    });
    process.on("SIGTERM", () => {
      this.stopping = true;
    });

    while (!this.stopping) {
      try {
        await this.processNewBlocks(state);
      } catch (error) {
        if (error instanceof FatalKeeperError) throw error;
        log("poll failed", { error: error.shortMessage ?? error.message });
      }
      if (!this.stopping) await sleep(this.config.pollIntervalMs);
    }

    log("keeper stopped");
  }
}

const keeper = new RedemptionSyncKeeper(loadConfig());
keeper.run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

