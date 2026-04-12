// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";
import {IAllocator} from "./interfaces/IAllocator.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
import {IStrategyClassifier} from "./interfaces/IStrategyClassifier.sol";

/**
 * @title AlchemistAllocator
 * @notice This contract is used to allocate and deallocate funds to and from MYT strategies
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 */
contract AlchemistAllocator is PermissionedProxy, IAllocator {
    IVaultV2 immutable public vault;
    IStrategyClassifier immutable public strategyClassifier;

    constructor(address _vault, address _admin, address _operator, address _classifier) PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        require(_classifier != address(0), "IC");
        vault = IVaultV2(_vault);
        strategyClassifier = IStrategyClassifier(_classifier);
    }

    /**
    * @notice Allocate (uses ActionType.direct)
    * @param adapter The strategy adapter address
    * @param amount The amount to allocate
     */
    function allocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        _validateCaps(adapter, amount);
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        bytes memory data = abi.encode(params);
        vault.allocate(adapter, data, amount);

    }

    /**
    * @notice Deallocate (uses ActionType.direct)
    * @param adapter The strategy adapter address
    * @param amount The amount to deallocate
     */

    function deallocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        bytes memory data = abi.encode(params);
        vault.deallocate(adapter, data, amount);
    }

    /**
    * @notice Allocate with swap (uses ActionType.swap)
    * @param adapter The strategy adapter address
    * @param amount The amount to allocate
    * @param txData The 0x swap calldata
     */
    function allocateWithSwap(address adapter, uint256 amount, bytes memory txData) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        _validateCaps(adapter, amount);
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: txData, 
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        bytes memory data = abi.encode(params);
        vault.allocate(adapter, data, amount);
    }


    /**
    * @notice Deallocate with dex swap (uses ActionType.swap)
    * @param adapter The strategy adapter address
    * @param amount The amount to deallocate
    * @param txData The 0x swap calldata
     */
    function deallocateWithSwap(address adapter, uint256 amount, bytes memory txData) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: txData, 
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        bytes memory data = abi.encode(params);
        vault.deallocate(adapter, data, amount);
    }

    /**
    * @notice Deallocate with unwrap + dex swap (uses ActionType.unwrapAndSwap)
    * @param adapter The strategy adapter address
    * @param amount The amount to deallocate  
    * @param txData The 0x swap calldata
    * @param minIntermediateOut The intermediate asset to produce from unwrap (use quote's sellAmount)
    */
    function deallocateWithUnwrapAndSwap(address adapter, uint256 amount, bytes memory txData, uint256 minIntermediateOut) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: txData, 
            minIntermediateOut: minIntermediateOut
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: swapParams});

        bytes memory data = abi.encode(params);
        vault.deallocate(adapter, data, amount);
    }

    /// @notice Set the vault liquidity adapter and calldata used by deposit/withdraw flows.
    function setLiquidityAdapter(address adapter, bytes memory data) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        vault.setLiquidityAdapterAndData(adapter, data);
    }

    /**
    * @notice Validate the caps for the given adapter and amount
    * @param adapter The strategy adapter address
    * @param amount The amount to validate
     */
    function _validateCaps(address adapter, uint256 amount) internal view {
        bytes32 id = IMYTStrategy(adapter).adapterId();
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        
        // get risk caps
        uint256 strategyId = uint256(id);
        uint8 riskLevel = strategyClassifier.getStrategyRiskLevel(strategyId);
        uint256 globalRiskCapPct = strategyClassifier.getGlobalCap(riskLevel);
        uint256 localRiskCapPct = strategyClassifier.getIndividualCap(strategyId);

        // Convert relativeCap (WAD) to absolute value (WEI)
        uint256 totalAssets = vault.totalAssets();
        uint256 absoluteValueOfRelativeCap = (totalAssets * relativeCap) / 1e18;

        // Convert risk caps from WAD percentages to absolute values
        uint256 globalRiskCap = (totalAssets * globalRiskCapPct) / 1e18;
        uint256 localRiskCap = (totalAssets * localRiskCapPct) / 1e18;

        // Calculate limit cap as the minimum of vault caps
        uint256 limit = absoluteCap < absoluteValueOfRelativeCap ? absoluteCap : absoluteValueOfRelativeCap;

        // Enforce global risk cap (aggregate across all strategies in this risk class)
        uint256 currentRiskAllocation = 0;
        uint256 len = vault.adaptersLength();
        for (uint256 i = 0; i < len; i++) {
            address stratAdapter = vault.adapters(i);
            bytes32 stratId = IMYTStrategy(stratAdapter).adapterId();
            
            // Check if the strategy belongs to the same risk level
            if (strategyClassifier.getStrategyRiskLevel(uint256(stratId)) == riskLevel) {
                currentRiskAllocation += vault.allocation(stratId);
            }
        }
        
        // Check if the proposed allocation exceeds the remaining capacity of the global risk cap
        uint256 remainingGlobal = currentRiskAllocation < globalRiskCap ? globalRiskCap - currentRiskAllocation : 0;
        require(amount <= remainingGlobal, EffectiveCap(amount, remainingGlobal));

        // Apply local risk cap constraint for operators
        if (msg.sender != admin) {
            // caller is operator, further constrain by local risk cap
            limit = limit < localRiskCap ? limit : localRiskCap;
        }

        // Ensure the requested amount does not exceed the calculated individual strategy limit
        require(vault.allocation(id) + amount <= limit, EffectiveCap(amount, limit));
    }

    function setMaxRate(uint256 rate) external onlyAdmin {
        vault.setMaxRate(rate);
    }
}
