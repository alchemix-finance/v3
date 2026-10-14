// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Shared type definitions for the base strategy testing stack.
/// @dev Keep enums/interfaces used across setup, ops, handler, and strategy-specific tests here.

/// @notice Common revert selectors shared across strategy tests.
library RevertSelectors {
    /// @dev `Error(string)` revert prefix.
    bytes4 internal constant ERROR_STRING = 0x08c379a0;
}

enum RevertContext {
    HandlerAllocate,
    HandlerDeallocate,
    FuzzAllocate,
    FuzzDeallocate,
    DirectAllocate,
    DirectDeallocate
}

interface IRevertAllowlistProvider {
    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external view returns (bool);
    function isMytRevertAllowed(bytes4 selector, RevertContext context) external view returns (bool);
    function useAllocatorDeallocateSwap() external view returns (bool);
    function useAllocatorDeallocateUnwrapAndSwap() external view returns (bool);
    function allocatorDeallocateSwapData(uint256 amount) external view returns (bytes memory);
    function allocatorDeallocateMinIntermediateOut(uint256 amount) external view returns (uint256);
}
