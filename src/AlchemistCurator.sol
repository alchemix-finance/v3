// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";
import {IAlchemistCurator} from "./interfaces/IAlchemistCurator.sol";

/**
 * @title AlchemistCurator
 * @notice This contract is used to update MYT caps and add/remove strategies to the MYT
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 */

interface IMYTStrategyMinimal {
    function getIdData() external returns (bytes memory);
}
contract AlchemistCurator is IAlchemistCurator, PermissionedProxy {
    // map of myt adapter(strategy) address to myt address
    mapping(address => address) public adapterToMYT;

    constructor(address _admin, address _operator) PermissionedProxy(_admin, _operator) {
        
    }

    function submitSetStrategy(address adapter, address myt) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(myt != address(0), "INVALID_ADDRESS");
        _submitSetStrategy(adapter, myt);
    }

    function setStrategy(address adapter, address myt) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(myt != address(0), "INVALID_ADDRESS");
        _addStrategy(adapter, myt);
    }
   function submitRemoveStrategy(address adapter, address myt) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(myt != address(0), "INVALID_ADDRESS");
        _submitRemoveStrategy(adapter, myt);
    }
   
    function removeStrategy(address adapter, address myt) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(myt != address(0), "INVALID_ADDRESS");
        _removeStrategy(adapter, myt); // remove
    }

    function _submitSetStrategy(address adapter, address myt) internal {
        IVaultV2 vault = IVaultV2(myt);
        bytes memory data = abi.encodeCall(IVaultV2.addAdapter, adapter);
        vault.submit(data);
        emit SubmitSetStrategy(adapter, myt);
    }

    function _submitRemoveStrategy(address adapter, address myt) internal {
        IVaultV2 vault = IVaultV2(myt);
        bytes memory data = abi.encodeCall(IVaultV2.removeAdapter, adapter);
        vault.submit(data);
        emit SubmitRemoveStrategy(adapter, myt);
    }

    function _addStrategy(address adapter, address myt) internal {
        adapterToMYT[adapter] = myt;
        IVaultV2 vault = _vault(adapter);
        vault.addAdapter(adapter);
        emit StrategyAdded(adapter, myt);
    }

    function _removeStrategy(address adapter, address myt) internal {
        IVaultV2 vault = _vault(adapter);
        vault.removeAdapter(adapter);
        delete adapterToMYT[adapter];
        emit StrategyRemoved(adapter, myt);
    }

    function decreaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _decreaseAbsoluteCap(adapter, id, amount);
    }

    function decreaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _decreaseRelativeCap(adapter, id, amount);
    }


    function _decreaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.decreaseRelativeCap(id, amount);
        emit DecreaseRelativeCap(adapter, amount, id);
    }

    function _decreaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.decreaseAbsoluteCap(id, amount);
        emit DecreaseAbsoluteCap(adapter, amount, id);
    }

    function increaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _increaseAbsoluteCap(adapter, id, amount);
    }

    function increaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _increaseRelativeCap(adapter, id, amount);
    }

    function submitIncreaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _submitIncreaseAbsoluteCap(adapter, id, amount);
    }

    function submitIncreaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = IMYTStrategyMinimal(adapter).getIdData();
        _submitIncreaseRelativeCap(adapter, id, amount);
    }

    function _increaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.increaseAbsoluteCap(id, amount);
        emit IncreaseAbsoluteCap(adapter, amount, id);
    }

    function _increaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.increaseRelativeCap(id, amount);
        emit IncreaseRelativeCap(adapter, amount, id);
    }

    function _submitIncreaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitIncreaseAbsoluteCap(adapter, amount, id);
    }

    function _submitIncreaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseRelativeCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitIncreaseRelativeCap(adapter, amount, id);
    }

    function submitSetAllocator(address myt, address allocator, bool v) external onlyAdmin {
        bytes memory data = abi.encodeCall(IVaultV2.setIsAllocator, (allocator, v));
        IVaultV2(myt).submit(data);
        emit SubmitSetAllocator(allocator, v);
    }

    function submitSetForceDeallocatePenalty(address adapter, address myt, uint256 penalty) external onlyAdmin {
        bytes memory data = abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (adapter, penalty));
        IVaultV2(myt).submit(data);
        emit SubmitSetForceDeallocatePenalty(adapter, myt, penalty);
    }

    function submitSetPerformanceFeeRecipient(address myt, address recipient) external onlyAdmin {
        bytes memory data = abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (recipient));
        IVaultV2(myt).submit(data);
        emit SubmitSetPerformanceFeeRecipient(myt, recipient);
    }

    function submitSetPerformanceFee(address myt, uint256 fee) external onlyAdmin {
        bytes memory data = abi.encodeCall(IVaultV2.setPerformanceFee, (fee));
        IVaultV2(myt).submit(data);
        emit SubmitSetPerformanceFee(myt, fee);
    }

    function _vaultSubmit(address adapter, bytes memory data) internal {
        IVaultV2 vault = _vault(adapter);
        vault.submit(data);
    }

    function _vault(address adapter) internal view returns (IVaultV2) {
        require(adapterToMYT[adapter] != address(0), "INVALID_ADDRESS");
        return IVaultV2(adapterToMYT[adapter]);
    }
}
