# Strategy Creation and Deployment Runbook

This runbook is for developers building end-to-end Alchemix MYT strategies against the Morpho V2 `IAdapter` interface. Use it with the allocator-facing notes in `ALCHEMIST_ALLOCATOR_RUNBOOK.md`.

## Preface

### What Is A Strategy?

In this repo, a strategy is a Morpho V2 vault adapter. The MYT vault owns the vault asset, transfers assets to an adapter during allocation, asks the adapter to unwind during deallocation, and reads the adapter's current value through `realAssets()`.

Alchemix strategies inherit from `MYTStrategy`, which implements the Morpho V2 adapter surface and delegates protocol-specific behavior to internal hooks:

- `_allocate(uint256 amount)` for direct protocol deposits.
- `_allocate(uint256 amount, bytes memory callData)` for swap-based deposits.
- `_deallocate(uint256 amount)` for direct synchronous withdrawals.
- `_deallocate(uint256 amount, bytes memory callData)` for swap-based exits.
- `_deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOut)` for unwrap-then-swap-based exits.
- `_totalValue()` for `realAssets()` accounting.



### Minimum Morpho V2 Adapter Interface

Every strategy must satisfy `IAdapter`:

```solidity
function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
    external
    returns (bytes32[] memory ids, int256 change);

function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
    external
    returns (bytes32[] memory ids, int256 change);

function realAssets() external view returns (uint256 assets);
```

`MYTStrategy` already implements these external functions. Child strategies should implement only the internal hooks needed for their supported routes.

### What Morpho V2 `allocate` Expects

The vault calls `allocate(adapter, data, assets)` from an allocator. Before calling the adapter, the vault accrues interest and transfers `assets` of the vault asset to the strategy.

The adapter must:

1. Decode `data` into `IMYTStrategy.VaultAdapterParams`.
2. Deploy exactly the requested vault asset amount through the selected route.
3. Return the adapter ids and the net allocation change.
4. Keep `realAssets()` consistent with the new position value.

`MYTStrategy.allocate()` enforces `onlyVault`, nonzero assets, decodes the action, calls the correct internal `_allocate` overload, and returns `ids()` plus the difference between the previous vault allocation and `_totalValue()`.

### What Morpho V2 `deallocate` Expects

The vault calls `deallocate(adapter, data, assets)` from an allocator or sentinel. Unlike allocation, the vault does not send assets first. The strategy must make at least `assets` of the vault asset available and approve the vault to pull it.

The adapter must:

1. Decode `data` into `IMYTStrategy.VaultAdapterParams`.
2. Unwind or swap enough position value to cover the requested `assets`.
3. Approve `msg.sender` for exactly the vault asset amount the vault should pull.
4. Return ids and the allocation change.

`MYTStrategy.deallocate()` checks the requested action, rejects swap-based force deallocations, calls the correct `_deallocate` overload, requires post-deallocation value consistency, and returns the allocation delta. Child `_deallocate` implementations must end with enough idle vault asset and `TokenUtils.safeApprove(MYT.asset(), msg.sender, amount)`.

### What `realAssets()` Expects

`realAssets()` is the adapter's current value in the MYT vault asset. The Morpho vault calls it when accruing interest and summing total assets.

Good `realAssets()` implementations:

- Include idle vault asset held by the strategy.
- Include deployed position value in vault asset terms.
- Use protocol-native preview/accounting functions when the position is directly redeemable.
- Use oracle-priced value when market swaps are needed.
- Avoid reverting during normal operation; Morpho V2 liveness assumptions expect adapters not to revert on `realAssets()`.
- Stay reasonably gas bounded because the vault loops through all adapters.



## Alchemix MYT Strategy Classes



### `MYTStrategy`

`MYTStrategy` is the base adapter for all MYT strategies. It provides:

- Morpho V2 adapter functions: `allocate`, `deallocate`, `realAssets`.
- Shared strategy metadata through `StrategyParams`.
- A single adapter id: `keccak256(abi.encode("this", address(this)))`.
- The kill switch, which pauses new allocations when enabled.
- 0x AllowanceHolder swap execution through `dexSwap`.
- Owner operations for rewards, rescue, allowance holder, slippage, risk class, and withdrawal queue handling.
- Virtual hooks for protocol-specific direct, swap, unwrap, value, and preview logic.

Default unsupported hooks revert with `ActionNotSupported()`. Only override the routes a strategy actually supports.

### `OraclePricedSwapStrategy`

`OraclePricedSwapStrategy` extends `MYTStrategy` for strategies that use 0x swaps and an oracle-priced position token. It provides:

- Swap allocation from the MYT asset into `_oracleToken()`.
- One-hop swap deallocation from `_oracleToken()` back to the MYT asset.
- Unwrap-then-swap deallocation through `_prepareIntermediateForSwap`.
- Oracle conversion helpers and max staleness checks.
- `_totalValue()` as idle vault asset plus oracle-priced position value.
- `previewAdjustedWithdraw()` that accounts for idle balance, oracle-priced position value, and strategy slippage.

Use it when at least one route needs DEX execution and the strategy can price the held or intermediate token with a reliable oracle.

## Strategy Types



### Direct

Use a direct strategy when the protocol supports native synchronous entry and exit in the MYT asset.

Required hooks:

- `_allocate(uint256 amount)`: deposit or stake the vault asset directly.
- `_deallocate(uint256 amount)`: withdraw enough vault asset synchronously and approve the vault.
- `_totalValue()`: value idle assets plus protocol position.

Optional hooks:

- `_claimRewards(...)` if the protocol emits reward tokens.
- `_previewAdjustedWithdraw(uint256 amount)` if exit fees, slippage, or rounding can reduce withdrawable assets.

Examples: `ERC4626Strategy`, `AaveStrategy`, `MoonwellStrategy`.

### DEX Swaps

Use a swap strategy when allocation or deallocation must happen through 0x calldata.

Required hooks:

- `_allocate(uint256 amount, bytes memory callData)` for swap-based entry.
- `_deallocate(uint256 amount, bytes memory callData)` for one-hop swap exit.
- Oracle/pricing hooks if inheriting from `OraclePricedSwapStrategy`.

Operational rule: all 0x quotes must be AllowanceHolder quotes with the strategy address as the taker. The strategy approves `allowanceHolder`, calls it, then clears approval.

Example: `WstETHL2Strategy` supports `WETH -> wstETH` allocation and `wstETH -> WETH` deallocation on L2.

### Direct And DEX Swaps

Use a hybrid strategy when the protocol has a native route, but market execution may be better for some conditions.

Required hooks depend on available routes:

- Direct entry: `_allocate(uint256 amount)`.
- Swap entry: `_allocate(uint256 amount, bytes memory callData)`.
- Direct exit: `_deallocate(uint256 amount)`.
- Swap exit: `_deallocate(uint256 amount, bytes memory callData)`.
- Unwrap exit: `_deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOut)`.

Examples:

- `WstETHEthereumStrategy`: direct mainnet Lido mint, optional `WETH -> wstETH` swap allocation, and `wstETH -> WETH` swap deallocation.
- `SFraxETHStrategy`: direct Frax mint, optional `WETH -> frxETH` swap allocation followed by `frxETH -> sfrxETH` deposit, and `sfrxETH -> frxETH -> WETH` unwrap-and-swap deallocation.
- `EtherfiEETHMYTStrategy`: direct Ether.fi entry/exit plus optional `weETH` market routes.



## Building Strategies



### 1. Choose The Protocol

Before writing code, document:

- The target MYT asset.
- The position or receipt token the strategy will hold.
- The protocol entry function and whether it accepts the MYT asset directly.
- The protocol exit function and whether it returns the MYT asset synchronously.
- Any async withdrawals, withdrawal NFTs, cooldowns, queues, fees, or caps.
- Any rewards tokens and whether claiming can be done safely by the owner.
- Whether the held token, intermediate token, or receipt shares have reliable pricing.



### 2. Map Available Entries And Exits

Classify every route:

- Direct entry: MYT asset goes directly into the protocol.
- Swap entry: MYT asset must be swapped into a protocol token first.
- Direct exit: the strategy can synchronously return the MYT asset.
- Swap exit: the held token can be sold directly into the MYT asset.
- Unwrap-and-swap exit: the held token must first unwrap or redeem into a sell token.
- Async exit: the protocol requires a queue or delayed claim before assets can return.

For minimal functionality, prefer direct routes when both entry and exit are synchronous and economically acceptable.

### 3. Decide The Base Class

Use `MYTStrategy` directly when:

- The strategy can allocate and deallocate through direct protocol calls.
- The position can be valued through protocol previews or balances.
- No 0x route is required for core operation.

Use `OraclePricedSwapStrategy` when:

- A route needs 0x calldata.
- 0x shows strong liquidity for the required token pair.
- The strategy has a reliable oracle for the token used in swap/value math.
- You can implement `_oracleToken()`, `_positionBalance()`, and `_prepareOracleTokenForSwap()` or `_prepareIntermediateForSwap()`.

If no direct path exists for entry or exit, only use a swap route when the 0x API has deep enough liquidity under expected allocation sizes and stress conditions.

### 4. Implement The Strategy

For every strategy:

1. Store immutable protocol addresses.
2. Validate nonzero external addresses in the constructor.
3. Keep `params.owner` as the deployer during deployment, then transfer to the multisig.
4. Override only supported internal hooks.
5. Protect the MYT asset and all position/receipt/intermediate tokens in `_isProtectedToken`.
6. Include idle MYT asset in `_totalValue()`.
7. Use `TokenUtils.safeApprove` and clear approvals when interacting with external spenders where appropriate.
8. Ensure every deallocation route ends with enough idle MYT asset and approval to the vault.
9. Revert unsupported action routes explicitly.
10. Keep reward claiming owner-only and disabled while the kill switch is active.



### 5. DEX And Oracle Best Practices

For 0x routes:

- Build quotes with `taker = address(strategy)`.
- Use AllowanceHolder calldata, not a router path intended for another spender model.
- Match quote sell token to the actual token the strategy will approve.
- Match quote buy token to the token the strategy expects to receive next.
- For unwrap-and-swap exits, `txData` is for the intermediate token, not the wrapped position token.
- Pass `minIntermediateOut` as the amount the strategy must unwrap before executing the swap.

For oracle routes:

- Set a conservative `MAX_ORACLE_STALENESS`.
- Check oracle decimals and units against the strategy's `_positionBalance()` units.
- Use `params.slippageBPS` to bound swap input or output against oracle value.
- Add strategy-specific guards when the oracle token and held token are not the same unit.



### 6. Test Checklist

Add focused tests before deployment:

- Constructor stores every address and strategy param.
- Unsupported routes revert with `ActionNotSupported()`.
- Direct allocation increases position value and returns the requested amount.
- Swap allocation uses expected sell and buy tokens and respects oracle/slippage minimums.
- Direct deallocation returns and approves the exact requested MYT asset amount.
- Swap deallocation covers shortfall from idle balance plus position sale.
- Unwrap-and-swap uses the correct intermediate token and `minIntermediateOut`.
- `realAssets()` includes idle assets and position value.
- `previewAdjustedWithdraw()` is conservative for fees, slippage, and rounding.
- `killSwitch = true` prevents allocation.
- Protected tokens cannot be rescued.
- Deployment script test verifies owner, kill switch, curator registration, caps, and force-deallocation penalty.



## Deployment



### Required Deployment Inputs

Collect these values before writing the script:

- Deployer EOA.
- MYT vault address.
- `AlchemistCurator` address.
- Final multisig owner.
- Strategy-specific protocol addresses.
- Oracle address and max oracle staleness, if applicable.
- `StrategyParams`: owner, name, protocol, risk class, cap, global cap, estimated yield, additional incentives flag, and slippage.
- Force-deallocation penalty. Use `0.02e18` for 2%, which is Morpho V2's maximum allowed penalty in this repo.



### Minimal Deployment Flow

Every production strategy deployment script should include:

1. Strategy deployment with correct constructor params.
2. Strategy initialization and safety setup.
3. `strategy.setKillSwitch(true)` before ownership transfer.
4. Ownership transfer to the multisig.
5. Console output of the deployed strategy address.

The deployer is not expected to be the MYT curator, so deployment scripts should not attempt curator registration, cap updates, or vault penalty configuration. Those steps happen after deployment from the curator-controlled address or proxy.

### Minimal Script Template

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {NewStrategy} from "../src/strategies/NewStrategy.sol";

contract DeployNewStrategyScript is Script {
    address public deployer = address(0);
    address public myt = address(0);
    address public multisig = address(0);

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployer,
            name: "Strategy Name",
            protocol: "Protocol",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 0,
            globalCap: 0,
            estimatedYield: 0,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployStrategy() public returns (address strategyAddr) {
        IMYTStrategy.StrategyParams memory params = defaultParams();

        // Replace this constructor call with the concrete strategy's required protocol and oracle args.
        NewStrategy strategy = new NewStrategy(myt, params);
        strategyAddr = address(strategy);

        // Keep allocations paused until post-deploy verification and governance are complete.
        MYTStrategy(strategyAddr).setKillSwitch(true);

        MYTStrategy(strategyAddr).transferOwnership(multisig);
    }

    function run() public returns (address strategyAddr) {
        vm.startBroadcast(deployer);
        strategyAddr = deployStrategy();
        vm.stopBroadcast();

        console.log("NewStrategy deployed at:", strategyAddr);
    }
}
```



### Post-Deployment Steps

After the deployer broadcasts the strategy, the curator must register and configure it:

1. Submit and execute strategy registration with the target MYT:
  `curator.submitSetStrategy(strategy, myt)` and `curator.setStrategy(strategy, myt)`.
2. Submit and execute the absolute cap:
  `curator.submitIncreaseAbsoluteCap(strategy, cap)` and `curator.increaseAbsoluteCap(strategy, cap)`.
3. Submit and execute the relative cap:
  `curator.submitIncreaseRelativeCap(strategy, globalCap)` and `curator.increaseRelativeCap(strategy, globalCap)`.
4. Submit and execute the force-deallocation penalty:
  `curator.submitSetForceDeallocatePenalty(strategy, myt, 0.02e18)`.
5. Then execute `IVaultV2.setForceDeallocatePenalty(strategy, 0.02e18)`, which is a direct call on the myt. Note : `setForceDeallocatePenalty` can be called by anyone. This is not a permissiioned fuction. It is recommended to `not` include this transaction in the same bundle as submitSetForceDeallocatePenalty.
6. From the Alchemist strategy classifier admin, assign the strategy's enforced risk class:
  `classifier.assignStrategyRiskLevel(uint256(IMYTStrategy(strategy).adapterId()), uint8(riskClass))`.
   This should match the strategy metadata `params.riskClass`; allocator cap enforcement reads from `AlchemistStrategyClassifier`, not from the strategy metadata.
   Note : This multisig action can also be done via the official dashboard `https://control.alchemix.fi/` via : "vault" tab -> selected vault -> "Strategies" section -> specific strategy -> "Controls" section -> "Classifier Risk" section. You may also adjust the strategy metadata before any respective classifier update in the paired "Param Risk" section.
7. After registration, cap, penalty, classifier assignment, ownership, source verification, and smoke-test checks are complete, the myt owner should call `strategy.setKillSwitch(false)`.

For live deployments with nonzero timelocks, split submission and execution into separate transactions after the timelock expires. If the vault curator is the `AlchemistCurator` proxy, allowlist `IVaultV2.setForceDeallocatePenalty.selector` and execute the penalty call with `curator.proxy(...)`.

### Post-Deployment Verification

After broadcasting, verify:

- Strategy address is registered as an adapter on the MYT.
- `adapterToMYT(strategy) == myt` on `AlchemistCurator`.
- `strategy.owner() == multisig`.
- `strategy.getIdData()` maps to the expected cap entries.
- MYT absolute and relative caps match the intended values.
- `forceDeallocatePenalty(strategy) == 0.02e18`.
- `classifier.getStrategyRiskLevel(uint256(IMYTStrategy(strategy).adapterId()))` matches the strategy metadata risk class.
- `realAssets()` returns the expected value before any allocation.
- The strategy source is verified on the target explorer.
- `strategy.killSwitch() == false` after the multisig enables allocation.

Only disable the kill switch after registration, caps, penalty, ownership, source verification, and a small allocation/deallocation smoke test are complete.

### Allocation/Deallocation Verification

Please start with small amounts to verify allocations and deallocations are functioning as expected. 

- Basic functionality test : Allocate and deallocate with 1k USDC / 1 ETH
- Slippage test : Allocate and deallocate with 10k USDC / 10 ETH  
Tester should confirm the losses, if any, associated with each allocate and deallocate action.
Note : Allocation/deallocation amounts for the USDC MYT is `6 decimals`, ETH MYT is `18 decimals`.

