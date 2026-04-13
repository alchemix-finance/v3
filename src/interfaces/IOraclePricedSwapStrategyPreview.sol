// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Preview interface for strategies that size swap-based deallocations using oracle pricing.
interface IOraclePricedSwapStrategyPreview {
    /// @notice Returns the direct swap input token and amount needed to target `assetAmountOut`.
    /// @dev Intended for strategies that use `deallocateWithSwap()`.
    /// @param assetAmountOut The vault asset amount desired back from the strategy.
    /// @return sellToken The token that should be quoted as the DEX sell token.
    /// @return sellAmount The amount of `sellToken` to quote as swap input.
    function previewSwapInput(uint256 assetAmountOut)
        external
        view
        returns (address sellToken, uint256 sellAmount);

    /// @notice Returns the intermediate swap token and unwrap target needed to target `assetAmountOut`.
    /// @dev Intended for strategies that use `deallocateWithUnwrapAndSwap()`.
    /// @param assetAmountOut The vault asset amount desired back from the strategy.
    /// @return sellToken The intermediate token that should be quoted as the DEX sell token.
    /// @return sellAmount The amount of `sellToken` to quote as swap input.
    /// @return minIntermediateOut The minimum intermediate amount to pass to the allocator unwrap call.
    function previewUnwrapAndSwapInput(uint256 assetAmountOut)
        external
        view
        returns (address sellToken, uint256 sellAmount, uint256 minIntermediateOut);
}
