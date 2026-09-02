// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Shared validation for ERC4626 strategy deployments intended for Base.
abstract contract BaseERC4626DeploymentScript is Script {
    uint256 public constant BASE_CHAIN_ID = 8453;

    error InvalidBaseChain(uint256 actualChainId);
    error ZeroDeploymentAddress();
    error DeploymentTargetHasNoCode(address target);
    error DeploymentAssetMismatch(address target, address expectedAsset, address actualAsset);

    function _validateERC4626Deployment(address targetOwner, address myt, address targetVault, address paramsOwner) internal view returns (address asset) {
        if (block.chainid != BASE_CHAIN_ID) revert InvalidBaseChain(block.chainid);
        if (targetOwner == address(0) || myt == address(0) || targetVault == address(0) || paramsOwner == address(0)) {
            revert ZeroDeploymentAddress();
        }
        if (myt.code.length == 0) revert DeploymentTargetHasNoCode(myt);
        if (targetVault.code.length == 0) revert DeploymentTargetHasNoCode(targetVault);

        asset = IERC4626(myt).asset();
        if (asset == address(0)) revert ZeroDeploymentAddress();
        if (asset.code.length == 0) revert DeploymentTargetHasNoCode(asset);

        address targetAsset = IERC4626(targetVault).asset();
        if (targetAsset != asset) revert DeploymentAssetMismatch(targetVault, asset, targetAsset);
    }

    function _validateBaseAsset(address targetOwner, address myt, address targetVault, address paramsOwner, address expectedAsset) internal view {
        address actualAsset = _validateERC4626Deployment(targetOwner, myt, targetVault, paramsOwner);
        if (actualAsset != expectedAsset) revert DeploymentAssetMismatch(myt, expectedAsset, actualAsset);
    }
}
