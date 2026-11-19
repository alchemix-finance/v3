# Strategy launcher

`StrategyLauncher` runs and reports a new strategy's launch, from the first ladder leg through the pilot allocation. The probe bot and the clip bot both call it, and a sentinel or the Safe steers it. One launcher serves every MYT on a chain.

The probe and the clip allocator for each vault are assumed to be deployed already, and to already be operators of that vault's `AlchemistAllocator`.

## Soft limits, hard limits

The launcher is a test and deployment runner and a reporting layer. Its numbers (leg sizes, `pilotTarget`, the leg pointer) only shape runs that go through it, and a sentinel can change all of them. They are soft limits.

The hard limits sit below it and only the Safe sets them:

- `ClipAllocator` grants: total budget, clip size, interval, loss bound, price guard. Every swap leg and every pilot clip spends from them.
- `StrategyProbe`: fixed leg sizes, tolerance, the one-ladder lock, the poker list.
- The vault and allocator caps: absolute, relative, and the classifier's risk caps.

So a sentinel can reopen, rewind or reset a launch, but it can never move more than the grants allow.

## Contracts and roles

| Who | Role toward the launcher | What it can do |
|---|---|---|
| `StrategyLauncher` | the runner | Runs the ladder, then pilot clips, and reports every step. Not an allocator operator. |
| `StrategyProbe` | called by the launcher | Direct-path ladder only. The launcher is its poker. |
| `ClipAllocator` | called by the launcher | Swap ladder legs and every pilot clip. The launcher is the grantee. |
| `AlchemistAllocator` | not called by the launcher | The probe and the clip allocator are its operators. |
| Safe (owner) | `owner` | Venues, keepers, sentinels, ownership. Everything a sentinel can do. Owns the probe, the clip allocator and the strategy. |
| Sentinel | `sentinels` | `registerLaunch`, `updatePlan`, `setLeg`, `resetPilot`, `abort`, `graduate`, `pause`. |
| Probe keeper | `probeKeepers` | `step`, `pause`. |
| Clip keeper | `clipKeepers` | `clip`, `pause`. |

On the mainnet USDC and ETH MYTs the Safe `0xF56D…293D` already administers the allocator, the curator and the classifier, owns the vault, and is a curator operator. Every timelock batch 1 touches is zero, so batch 1 is one Safe transaction.

## Files

```
script/DeployStrategyLauncher.s.sol      deploy the launcher, set venue, keepers and sentinel, hand to the Safe
script/launch/StrategyLaunchBase.s.sol   read a launch JSON, build batch 1 and batch 2
script/launch/StrategyLaunchBase.txt     every batch call in plain text, with the Ether.fi defaults
script/launch/<strategy>.json            one launch config
script/launch/Launch<Strategy>.s.sol     names its JSON, nothing else
script/launch/out/                       Safe Transaction Builder files written by run()
src/test/StrategyLauncher.t.sol          the launcher on a local vault, no RPC
src/test/Launch<Strategy>.t.sol          the launch replayed on a fork
```

## Once per chain: deploy the launcher

```bash
MYT=0x… PROBE=0x… CLIP=0x… SAFE=0x… DEPLOYER=0x… PROBE_KEEPER=0x… CLIP_KEEPER=0x… SENTINEL=0x… \
forge script script/DeployStrategyLauncher.s.sol --rpc-url mainnet --broadcast
```

That deploys the launcher, calls `setVenue(myt, probe, clip)`, the keeper setters and `setSentinel`, and starts the handover to the Safe. The Safe then needs:

- `launcher.acceptOwnership()`
- `probe.setPoker(launcher, true)`, and removes any other poker

Another vault on the same chain only needs `launcher.setVenue` from the Safe.

## Each new strategy

1. Deploy it with its existing deploy script. The kill switch is on and ownership goes to the Safe.
2. Fill `strategy.address` in its JSON, or pass `STRATEGY`, and fill `probe`, `clip`, `launcher`.
3. Write the batches:

```bash
STRATEGY=0x… forge script script/launch/LaunchEtherfiEETHStrategy.s.sol
```

4. Load `script/launch/out/<name>.batch1.json` into the Safe Transaction Builder and execute it.
5. The bots take over: the penalty execution, then the ladder, then the pilot.
6. After you review the pilot, execute `<name>.batch2.json`.

A new strategy needs its own JSON and a three line `Launch<Strategy>.s.sol` that returns the JSON path. Copy the Ether.fi fork test to replay it.

## Config

Amounts are decimal strings. Small integers (`riskClass`, `minIntervalBlocks`, `maxLossBps`) are numbers.

| Section | Used for |
|---|---|
| `contracts` | the Safe, the vault, curator, classifier, allocator, probe, clip, launcher, liquidity adapter |
| `strategy` | address, risk class, `allocate` and `deallocate` path, `useProbe` |
| `caps` | pilot absolute cap, relative cap, force deallocate penalty. The absolute cap is the hard ceiling for the pilot and any retry round |
| `probe` | must match the deployed probe's legs, tolerance and buffer |
| `swapLadder` | leg sizes when `useProbe` is false |
| `pilot` | `target` is the launcher's `pilotTarget`. `grantHeadroom` is extra allocate grant so a sentinel can retry or reset without the Safe. Plus clip size, interval, price guard, loss bound |
| `liquidityGrant` | the launcher's deallocate grant on the liquidity adapter, for idle raises. Size it for the ladder, the pilot and the headroom. `mode` is `grant` or `topUp` |
| `scale` | batch 2 cap and manual allocation |

Paths are `direct`, `swap`, or `unwrapAndSwap`. A probe launch must be `direct` both ways.

The launcher stores `keccak256(abi.encode(plan))` with this field order: `myt`, `useProbe`, `allocMode`, `deallocMode`, `smallLeg`, `largeLeg`, `exitBufferBps`, `pilotTarget`. Modes are `None = 0`, `Direct = 1`, `Swap = 2`, `UnwrapAndSwap = 3`. `run()` prints the same hash, and `LaunchRegistered` and `PlanUpdated` emit it.

## Safe batches

Batch 1, built by `batch1`:

1. `curator.submitSetStrategy`, `curator.setStrategy`
2. `curator.submitIncreaseAbsoluteCap`, `curator.increaseAbsoluteCap` at `caps.absoluteCap`
3. The same pair for the relative cap
4. `curator.submitSetForceDeallocatePenalty`
5. `classifier.assignStrategyRiskLevel`
6. `strategy.setKillSwitch(false)`
7. `clip.grantAllocate(launcher, strategy, …)` for `pilot.target + pilot.grantHeadroom`. A swap ladder adds both allocate legs.
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

`None`, then `Ladder`, `Pilot`, `PilotComplete`, and either `Graduated` or `Aborted`. Each `registerLaunch` on an adapter starts a new `attempt`, and every event carries it.

`nextStep(adapter)` returns the phase, the leg, the mode, the amount, whether a quote is required, and `readyBlock`, the first block the clip allocator accepts the call. In Pilot the amount is one clip: what remains under `pilotTarget`, at most the grant's `maxClip`.

- Ladder: `step(adapter, "", 0)` when no quote is needed. Otherwise quote the amount with the strategy as taker and pass `txData`. `minIntermediateOut` is only for `unwrapAndSwap`.
- Pilot: `clip(adapter, amount, txData)`.
- Any keeper or sentinel can call `pause(myt)`. It pauses the probe and, while the launcher holds clip budget, the clip allocator. Only the Safe unpauses.

`report(adapter)` returns everything in one call: the launch record (phase, attempt, plan hash, leg, `held`, clip count, `pilotAllocated`, `pilotTarget`, last success block), the next step, the launcher's remaining allocate and deallocate grant, the clip allocator and probe pause state, the probe's leg and lock, the strategy's `realAssets` and the vault's booked allocation.

## When a step fails

A failed `step` or `clip` reverts the whole transaction, so the phase, `pilotAllocated`, the grants, their interval clock and the position are unchanged. A retry is the same call with a new quote, and it does not wait an interval.

Every probe or clip allocator revert comes back as one error:

```solidity
error StepFailed(address adapter, Phase phase, uint8 step, Venue venue, Mode mode, bool isAllocate, uint256 amount, bytes reason);
```

`step` is the ladder leg (1 to 4) or the clip number in Pilot. `venue` is `Probe = 0` or `Clip = 1`. `reason` is the venue's own revert data, untouched, so its selector names the check that failed:

| `reason` | Raised by | Meaning | Bot action |
|---|---|---|---|
| `CounterfeitSettler(allowanceHolder)` | strategy | The swap call failed: expired quote, wrong taker, wrong sell amount. | Requote and resend. |
| `InvalidAmount(min, received)` | strategy | The swap paid under the oracle price less `slippageBPS` (125 for Ether.fi), or an exit leg returned less than it asked for. | Requote and resend. Repeated: pause and review. |
| `LossExceedsLimit` | clip allocator | The swap cleared the strategy floor but lost more than `pilot.maxLossBps` (50). | Requote and resend. Repeated: pause and review. |
| `TooSoon(readyAt)` | clip allocator | Before `readyBlock`. | Wait. Not a failure. |
| `GrantExhausted(remaining, requested)` | clip allocator | The grant is spent. The hard limit, not the launcher's. | Ask the Safe for a top up. |
| `ClipTooLarge`, `NoGrant` | clip allocator | The clip is above the grant's `maxClip`, or there is no grant. | Clip `nextStep`'s amount, or ask the Safe. |
| `MoverPaused` | clip allocator | The vault's clip allocator is paused. | Stop. The Safe unpauses. |
| `ProbePaused`, `LadderAlreadyCompleted` | probe | The probe is paused, or already ran this adapter. | The Safe unpauses or calls `probe.reset`. |
| `RateOutsideLimit` | clip allocator | Only with a price guard in `pilot.priceToken`. | Wait, or ask the Safe to change the grant. |

The launcher's own checks revert unwrapped, because they mean the bot sent the wrong call: `WrongPhase`, `PilotExceeded`, `QuoteRequired`, `UnexpectedQuote`.

Suggested bot policy: retry a quote failure up to three times with fresh quotes, a block or more apart. If all three fail, call `launcher.pause(myt)` and alert. `pause` stops every grant on that vault's clip allocator, not only this launch.

## Retry tools

A sentinel or the Safe picks one. None of these move funds or change a grant.

| Call | Effect |
|---|---|
| `updatePlan(adapter, plan)` | New leg sizes, modes, buffer or `pilotTarget`, progress kept. Lowering the target to what landed completes the pilot, raising it reopens it. |
| `setLeg(adapter, leg, held)` | Swap ladders: go to leg 1 to 4, with `held` as what the next exit leg takes out. Leg 5 skips to the pilot, for probe launches too. |
| `resetPilot(adapter)` | Count the pilot from zero again. What landed stays in the strategy. |
| `registerLaunch(adapter, plan)` | Open the next attempt at leg 1 from any phase, including `Aborted` or `Graduated`. |
| `abort(adapter)` | Close the attempt. Funds stay in the strategy. |

What still needs the Safe:

- More budget: `clip.topUpAllocate` or `topUpDeallocate`, or a new grant with another `maxClip` or `maxLossBps`. `grantHeadroom` in the JSON avoids this for a first retry.
- Rerunning a probe ladder: `probe.reset(adapter)`.
- Unpausing: `clip.setPaused(false)`, `probe.setPaused(false)`.
- Unwinding: `clip.revokeAllocate(launcher, strategy)`, `strategy.setKillSwitch(true)`, then `allocator.deallocateWithSwap(strategy, amount, txData)`. The kill switch does not block deallocation. Leave a small buffer (50 bps in the test) so rounding cannot fail the exit. Ether.fi direct redemption had no liquidity at the fork block, so the test exits by swap.

## Tests

```bash
forge test --match-contract StrategyLauncherTest
forge test --match-contract LaunchEtherfiEETHStrategyTest
```

`StrategyLauncherTest` runs on a local vault with mock strategies: probe and clip ladders, `StepFailed` from each venue, sentinel reopen, `updatePlan`, `resetPilot`, `setLeg` limits, and every role check.

`LaunchEtherfiEETHStrategyTest` forks mainnet at block 26,450,000 against the live ETH MYT. It deploys a probe, a clip allocator and the launcher, makes the Safe their owner and the first two allocator operators, then deploys a fresh strategy with `DeployEtherfiEETHStrategy.s.sol`. It uses a fresh one because the live strategy is already registered.

Only the swap is stubbed. The Safe points the strategy's allowance holder at a `StubSwapper` that pays whatever the calldata names, so each test chooses a fair quote, a thin one, or dead calldata. The vault, the allocator, the caps, the Yearn liquidity adapter, the strategy and the weETH/ETH oracle are the live ones. Real 0x quotes are not exercised. Failures are decoded the way a bot would: a low level call, then `abi.decode` of the `StepFailed` fields and the inner reason.

| Test | Shows |
|---|---|
| `test_deployedStrategy_waitsForTheSafe` | A fresh deploy is owned by the Safe, kill switch on, not yet an adapter. |
| `test_batch1_configuresTheSwapLaunch` | Caps, risk class, the three grants and the registered plan match the JSON. |
| `test_ladder_fourSwapLegsOpenThePilot` | A clip before the ladder reverts. Four swap legs (1 and 10 WETH, in and out) open the pilot. |
| `test_ladder_rejectedLegStaysOnThatLeg` | A thin exit quote fails leg 2 with `InvalidAmount`. The leg and amount hold, and a fair quote runs it. |
| `test_pilot_fourSwapClipsComplete` | Four 10 WETH clips reach `PilotComplete` at 40 WETH, leaving the 20 WETH headroom. A fifth reverts. |
| `test_pilot_clipAfterSuccessWaitsTheInterval` | `readyBlock` is 300 blocks out. A clip before it fails with `TooSoon`. |
| `test_pilot_strategyRejectsQuoteBelowFloor_thenRetry` | Quote 200 bps short: `InvalidAmount`, with the floor and the paid amount decoded. No state change, same-block retry lands, pilot completes. |
| `test_pilot_clipAllocatorRejectsLoss_thenRetry` | Quote 80 bps short: `LossExceedsLimit`. Same outcome. |
| `test_pilot_deadQuote_thenRetry` | Dead calldata: `CounterfeitSettler`. Same outcome. |
| `test_pilot_keeperPauses_safeResumes` | Keeper pause shows in `report` and fails clips with `MoverPaused`. The keeper cannot unpause, the Safe resumes. |
| `test_pilot_safeAbortsAndUnwinds` | Abort, revoke, kill switch, swap the pilot back to the vault. |
| `test_sentinel_reopensAfterAbort` | The sentinel aborts, opens attempt 2 on the same address, skips the ladder, and the leftover grant funds a full second pilot. |
| `test_sentinel_rerunsTheLargeLegs` | `setLeg(3)` reruns leg 3. Leg 4 fails with `GrantExhausted` until the Safe tops up the exit grant. |
| `test_sentinel_resetPilot_spendsHeadroomThenTheGrantStops` | After a reset the headroom funds two more clips, then `GrantExhausted` stops the third. |
| `test_report_snapshotsTheLaunch` | `report` matches the launch, the grant, the next clip and its ready block, and the position. |
| `test_batch2_raisesTheCapAndGraduates` | Batch 2 raises the cap to 5,000 WETH and graduates, with no manual allocation. |
