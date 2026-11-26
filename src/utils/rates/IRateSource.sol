// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A view that reports what a depositor into one venue earns right now.
///         One source per protocol type; it reads everything from the venue address,
///         so one deployment serves every venue of that type on a chain.
interface IRateSource {
    /// @notice Supply APR a depositor into `venue` earns now, after the venue's own fees.
    ///         WAD, simple (not compounded): 1e18 = 100% per year.
    function supplyRate(address venue) external view returns (uint256 aprWad);
}
