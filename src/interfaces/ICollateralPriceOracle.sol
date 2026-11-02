// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Prices collateral underlying tokens in units of the debt reference token.
interface ICollateralPriceOracle {
    /// @notice The collateral underlying token being priced.
    function baseToken() external view returns (address);

    /// @notice The reference token in which debt is denominated.
    function quoteToken() external view returns (address);

    /// @notice Returns quote tokens per whole base token, scaled by 1e18 and rounded down.
    /// @dev Implementations must revert when a reliable price is unavailable.
    function price() external view returns (uint256);
}
