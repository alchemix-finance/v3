// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface IAllocator {
    /// @notice Allocate with direct allocation (uses ActionType.direct)
    function allocate(address adapter, uint256 amount) external;
    /// @notice Deallocate with direct allocation (uses ActionType.direct)
    function deallocate(address adapter, uint256 amount) external;
    /// @notice Allocate with swap (uses ActionType.swap)
    function allocateWithSwap(address adapter, uint256 amount, bytes memory txData) external;
    /// @notice Deallocate with direct swap (uses ActionType.swap)
    function deallocateWithSwap(address adapter, uint256 amount, bytes memory txData) external;
    /// @notice Deallocate with unwrap + swap (uses ActionType.unwrapAndSwap)
    function deallocateWithUnwrapAndSwap(address adapter, uint256 amount, bytes memory txData, uint256 minIntermediateOut) external;
    /// @notice Set the vault liquidity adapter used on deposit/withdraw paths
    function setLiquidityAdapter(address adapter, bytes memory data) external;
    /// @notice Thrown when the effectice cap is exceeded during allocation
    error EffectiveCap(uint256 amount, uint256 limit);
}
