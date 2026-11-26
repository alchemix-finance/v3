// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

struct MorphoMarketParamsLite {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoMarketLite {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorphoLite {
    function idToMarketParams(bytes32 id) external view returns (MorphoMarketParamsLite memory);
    function market(bytes32 id) external view returns (MorphoMarketLite memory);
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

interface IMorphoIrmLite {
    function borrowRateView(MorphoMarketParamsLite memory marketParams, MorphoMarketLite memory market) external view returns (uint256);
}

interface IMarketAdapterLite {
    function morpho() external view returns (address);
    function marketIdsLength() external view returns (uint256);
    function marketIds(uint256 index) external view returns (bytes32);
}

interface IVaultV2RatesLite {
    function adaptersLength() external view returns (uint256);
    function adapters(uint256 index) external view returns (address);
    function totalAssets() external view returns (uint256);
    function performanceFee() external view returns (uint256);
    function managementFee() external view returns (uint256);
    function maxRate() external view returns (uint256);
}

/**
 * @title MorphoVaultV2RateSource
 * @notice Venue = a Morpho VaultV2 whose adapters are all Morpho market adapters
 *         (`MorphoMarketV1AdapterV2`: `morpho()` plus a `marketIds` list). For each
 *         market the adapter supplies to:
 *
 *           market supply APR = borrowRateView × YEAR × totalBorrow / totalSupply × (1 − market fee)
 *
 *         weighted by the adapter's supply assets over the vault's totalAssets (idle
 *         earns 0), then net of the vault's fees and capped by its maxRate:
 *
 *           apr = min(gross × (1 − performanceFee) − managementFee × YEAR, maxRate × YEAR)
 *
 *         A deposit or withdraw goes through the vault's liquidity market, which
 *         Morpho accrues and re-prices in the same call, so the rate moves in the
 *         same block. Any other adapter kind reverts `UnknownAdapter`: a curator who
 *         adds one stops every move that reads this vault until the source is
 *         extended. More than MAX_MARKETS markets reverts too, bounding the gas.
 */
contract MorphoVaultV2RateSource is IRateSource {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;   // Morpho Blue SharesMathLib
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 public constant MAX_MARKETS = 64;

    error UnknownAdapter(address adapter);
    error TooManyMarkets(uint256 markets, uint256 max);

    function supplyRate(address vault) external view returns (uint256) {
        IVaultV2RatesLite v = IVaultV2RatesLite(vault);
        uint256 total = v.totalAssets();
        if (total == 0) return 0;

        uint256 weighted;   // Σ supply assets × market supply APR (WAD)
        uint256 markets;
        uint256 n = v.adaptersLength();
        for (uint256 i = 0; i < n; i++) {
            address adapter = v.adapters(i);
            uint256 len;
            try IMarketAdapterLite(adapter).marketIdsLength() returns (uint256 l) {
                len = l;
            } catch {
                revert UnknownAdapter(adapter);
            }
            markets += len;
            if (markets > MAX_MARKETS) revert TooManyMarkets(markets, MAX_MARKETS);
            IMorphoLite morpho = IMorphoLite(IMarketAdapterLite(adapter).morpho());
            for (uint256 j = 0; j < len; j++) {
                weighted += _weighted(morpho, IMarketAdapterLite(adapter).marketIds(j), adapter);
            }
        }

        uint256 apr = weighted / total * (WAD - v.performanceFee()) / WAD;
        uint256 mgmt = v.managementFee() * YEAR;
        apr = apr > mgmt ? apr - mgmt : 0;
        uint256 cap = v.maxRate() * YEAR;
        return apr < cap ? apr : cap;
    }

    function _weighted(IMorphoLite morpho, bytes32 id, address adapter) internal view returns (uint256) {
        (uint256 supplyShares,,) = morpho.position(id, adapter);
        if (supplyShares == 0) return 0;
        MorphoMarketLite memory m = morpho.market(id);
        if (m.totalBorrowAssets == 0 || m.totalSupplyAssets == 0) return 0;
        MorphoMarketParamsLite memory p = morpho.idToMarketParams(id);
        if (p.irm == address(0)) return 0;
        uint256 assets = supplyShares * (uint256(m.totalSupplyAssets) + VIRTUAL_ASSETS) / (uint256(m.totalSupplyShares) + VIRTUAL_SHARES);
        uint256 borrowApr = IMorphoIrmLite(p.irm).borrowRateView(p, m) * YEAR;
        uint256 supplyApr = borrowApr * m.totalBorrowAssets / m.totalSupplyAssets * (WAD - m.fee) / WAD;
        return assets * supplyApr;
    }
}
