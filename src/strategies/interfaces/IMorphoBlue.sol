// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Morpho Blue market definition. `keccak256(abi.encode(params))` is the market id.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue market accounting snapshot as of `lastUpdate`.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @notice Morpho Blue user position in one market.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Subset of the Morpho Blue singleton used by lending strategies.
interface IMorphoBlue {
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function accrueInterest(MarketParams memory marketParams) external;

    function market(bytes32 id) external view returns (Market memory);

    function position(bytes32 id, address user) external view returns (Position memory);

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @notice Morpho Blue interest rate model view used to project pending interest.
interface IMorphoIrm {
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256);
}
