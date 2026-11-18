# Strategy launcher

`StrategyLauncher` is the entry point for a new strategy, from the first probe leg through the pilot allocation. The probe bot and the clip bot both call it. One launcher serves every MYT on a chain.

The probe and the clip allocator for each vault are assumed to be deployed already, and to already be operators of that vault's `AlchemistAllocator`.

## Contracts

| Contract | Role toward the launcher | What it can do |
|---|---|---|
| `StrategyLauncher` | the entry point | Runs the ladder, then pilot clips, and records every launch. Not an allocator operator. |
| `StrategyProbe` | called by the launcher | Direct-path ladder only. The launcher is its poker. Leg sizes are fixed in the probe. |
| `ClipAllocator` | called by the launcher | Swap ladder legs and every pilot clip. The launcher is the grantee. The grant is the ceiling. |
| `AlchemistAllocator` | not called by the launcher | The probe and the clip allocator are its operators. They are the only ones that reach it. |
| Safe | owns the launcher, the probe, the clip allocator, the strategy | Executes the two launch batches. Graduates or aborts. |
| Probe keeper | `probeKeepers` | Calls `step`. One bot for every strategy. |
| Clip keeper | `clipKeepers` | Calls `clip` once the launch is in Pilot. |
| MYT vault | not called by the launcher | Caps still bound the allocator. The pilot absolute cap is the ceiling for every operator, not just the launcher. |

The launcher cannot deallocate outside a swap ladder, and it cannot allocate past `pilotMax`.

On mainnet USDC the Safe `0xF56D…293D` already administers the allocator, the curator and the classifier, owns the vault, and is a curator operator. Every timelock batch 1 touches is zero, so batch 1 is one Safe transaction.

## Files

```
script/DeployStrategyLauncher.s.sol      deploy the launcher, set venue and keepers, hand to the Safe
script/launch/StrategyLaunchBase.s.sol   read a launch JSON, build batch 1 and batch 2
script/launch/<strategy>.json            one launch config
script/launch/Launch<Strategy>.s.sol     names its JSON, nothing else
script/launch/out/                       Safe Transaction Builder files written by run()
src/test/StrategyLauncher.t.sol          state machine on a local vault, no RPC
src/test/Launch<Strategy>.t.sol          the launch replayed on a fork
```

## Once per chain: deploy the launcher

```bash
MYT=0x… PROBE=0x… CLIP=0x… SAFE=0x… DEPLOYER=0x… PROBE_KEEPER=0x… CLIP_KEEPER=0x… \
forge script script/DeployStrategyLauncher.s.sol --rpc-url mainnet --broadcast
```

That deploys the launcher, calls `setVenue(myt, probe, clip)` and the keeper setters, and starts the handover to the Safe. The Safe then needs:

- `launcher.acceptOwnership()`
- `probe.setPoker(launcher, true)`, and removes any other poker

Another vault on the same chain only needs `launcher.setVenue` from the Safe.

## Each new strategy

1. Deploy it with its existing deploy script. The kill switch is on and ownership goes to the Safe.
2. Fill `strategy.address` in its JSON, or pass `STRATEGY`, and fill `probe`, `clip`, `launcher`.
3. Write the batches:

```bash
STRATEGY=0x… forge script script/launch/LaunchSiUSDStrategy.s.sol
```

4. Load `script/launch/out/<name>.batch1.json` into the Safe Transaction Builder and execute it.
5. The bots take over: the penalty execution, then the ladder, then the pilot.
6. After you review the pilot, execute `<name>.batch2.json`.

A new strategy needs its own JSON and a three line `Launch<Strategy>.s.sol` that returns the JSON path. Copy the SiUSD fork test to replay it.

## Config

Amounts are decimal strings. Small integers (`riskClass`, `minIntervalBlocks`, `maxLossBps`) are numbers.

| Section | Used for |
|---|---|
| `contracts` | the Safe, the vault, curator, classifier, allocator, probe, clip, launcher, liquidity adapter |
| `strategy` | address, risk class, `allocate` and `deallocate` path, `useProbe` |
| `caps` | pilot absolute cap, relative cap, force deallocate penalty |
| `probe` | must match the deployed probe's legs, tolerance and buffer |
| `swapLadder` | leg sizes when `useProbe` is false |
| `pilot` | the launcher's allocate grant: `maxAllocate` is `pilotMax`, plus clip size, interval, price guard, loss bound |
| `liquidityGrant` | the launcher's deallocate grant on the liquidity adapter, for idle raises. `mode` is `grant` or `topUp` |
| `scale` | batch 2 cap and manual allocation |

Paths are `direct`, `swap`, or `unwrapAndSwap`. A probe launch must be `direct` both ways.

The launcher stores `keccak256(abi.encode(plan))` with this field order: `myt`, `useProbe`, `allocMode`, `deallocMode`, `smallLeg`, `largeLeg`, `exitBufferBps`, `pilotMax`. Modes are `None = 0`, `Direct = 1`, `Swap = 2`, `UnwrapAndSwap = 3`. `run()` prints the same hash, and `LaunchRegistered` emits it.

## Safe batches

Batch 1, built by `batch1`:

1. `curator.submitSetStrategy`, `curator.setStrategy`
2. `curator.submitIncreaseAbsoluteCap`, `curator.increaseAbsoluteCap` at `caps.absoluteCap`
3. The same pair for the relative cap
4. `curator.submitSetForceDeallocatePenalty`
5. `classifier.assignStrategyRiskLevel`
6. `strategy.setKillSwitch(false)`
7. `clip.grantAllocate(launcher, strategy, …)` for `pilot.maxAllocate`. A swap ladder adds both allocate legs.
8. Swap ladder only: `clip.grantDeallocate(launcher, strategy, …)` for both legs
9. `clip.grantDeallocate` or `topUpDeallocate` for the launcher on the liquidity adapter
10. `launcher.registerLaunch(strategy, plan)`

After it lands, anyone executes `vault.setForceDeallocatePenalty(strategy, penalty)`. The bot does it first.

Batch 2, built by `batch2`:

1. `curator.submitIncreaseAbsoluteCap`, `curator.increaseAbsoluteCap` at `scale.absoluteCap`
2. `clip.revokeAllocate(launcher, strategy)`
3. Direct strategies: `allocator.deallocate(liquidityAdapter, amount)`, then `allocator.allocate(strategy, amount)`
4. `launcher.graduate(strategy)`

Swap strategies skip step 3, because a quote will not last through signing. The Safe tops up a keeper grant instead.

## Phases and the keeper loop

`None`, then `Ladder`, `Pilot`, `PilotComplete`, and either `Graduated` or `Aborted`.

`nextStep(adapter)` returns the phase, the leg, the mode, the amount, and whether a quote is required. In Pilot the amount is what remains under `pilotMax`, so the bot clips at most `pilot.maxClip` of it, then waits `pilot.minIntervalBlocks`.

- Ladder: `step(adapter, "", 0)` when no quote is needed. Otherwise quote the amount with the strategy as taker and pass `txData`. `minIntermediateOut` is only for `unwrapAndSwap`.
- Pilot: `clip(adapter, amount, txData)`. Leg 4 must have run first.
- Either keeper can call `pause(myt)`. It pauses the probe and, while the launcher holds clip budget, the clip allocator. Only the Safe unpauses.

## Tests

```bash
forge test --match-contract StrategyLauncherTest
forge test --match-contract LaunchSiUSDStrategyTest
```

`LaunchSiUSDStrategyTest` forks mainnet at block 26,437,000 against the live USDC MYT. It deploys a probe, a clip allocator and the launcher, makes the Safe their owner and the first two allocator operators, then deploys a fresh SiUSD with `DeploySiUSDStrategies.s.sol`. It executes batch 1 as the Safe, runs the ladder and four 2,500 USDC pilot clips, then batch 2. It uses a fresh SiUSD because the live one already holds 3.28M USDC against a 40% relative cap, so pilot clips on it would fail the cap check.
