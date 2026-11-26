// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface IFluidFTokenLite {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function getData()
        external
        view
        returns (
            address liquidity,
            address lendingFactory,
            address lendingRewardsRateModel,
            address permit2,
            address rebalancer,
            bool rewardsActive,
            uint256 liquidityBalance,
            uint256 liquidityExchangePrice,
            uint256 tokenExchangePrice
        );
}

interface IFluidLiquidityLite {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

interface IFluidRewardsRateModelLite {
    function getRate(uint256 totalAssets) external view returns (uint256 rate, bool ended, uint256 startTime);
}

/**
 * @title FluidFTokenRateSource
 * @notice Venue = a Fluid fToken. Fluid stores each token's borrow rate packed in
 *         the Liquidity layer and rewrites it only when utilization moves more than
 *         the token's `updateOnStorageThreshold` (0.1% for USDC on Base). A small
 *         deposit can leave the stored rate stale, so this source recomputes the
 *         rate from the live total amounts and the rate curve:
 *
 *           utilization = (borrowWithInterest + borrowInterestFree) / (supplyWithInterest + supplyInterestFree)
 *           borrow APR  = rate curve (version 1: one kink, version 2: two kinks) at utilization
 *           supply APR  = borrow APR × borrowWithInterest / supplyWithInterest × (1 − fee)
 *                       + the fToken's rewards rate while rewards are active
 *
 *         Raw with-interest amounts convert at the stored exchange prices (1e12).
 *         Storage layout and bit positions follow Fluid's LiquiditySlotsLink. It reads
 *         the core Liquidity contract only, never a periphery resolver.
 */
contract FluidFTokenRateSource is IRateSource {
    // LiquiditySlotsLink: mapping slots in the Liquidity layer
    uint256 internal constant EXCHANGE_PRICES_SLOT = 5;
    uint256 internal constant RATE_DATA_SLOT = 6;
    uint256 internal constant TOTAL_AMOUNTS_SLOT = 7;

    uint256 internal constant X14 = 0x3fff;
    uint256 internal constant X16 = 0xffff;
    uint256 internal constant X64 = 0xffffffffffffffff;
    uint256 internal constant EXCHANGE_PRICES_PRECISION = 1e12;
    uint256 internal constant FOUR_DECIMALS = 1e4;   // 1e4 = 100% for utilization, fee and rates
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TO_WAD = 1e14;         // 1e4 = 100% → 1e18 = 100%

    error UnknownRateVersion(uint256 version);

    function supplyRate(address fToken) external view returns (uint256) {
        (address liquidity,, address rewardsModel,,, bool rewardsActive,,,) = IFluidFTokenLite(fToken).getData();
        uint256 rate = lendingRate(liquidity, IFluidFTokenLite(fToken).asset());
        if (rewardsActive) rate += _rewardsRate(fToken, rewardsModel);
        return rate;
    }

    /// @notice Supply APR (WAD) of `token` on the Liquidity layer, recomputed from live totals.
    function lendingRate(address liquidity, address token) public view returns (uint256) {
        IFluidLiquidityLite l = IFluidLiquidityLite(liquidity);
        uint256 prices = l.readFromStorage(_slot(EXCHANGE_PRICES_SLOT, token));
        uint256 amounts = l.readFromStorage(_slot(TOTAL_AMOUNTS_SLOT, token));
        uint256 supplyWithInterest = _bigNumber(amounts & X64) * ((prices >> 91) & X64) / EXCHANGE_PRICES_PRECISION;
        if (supplyWithInterest == 0) return 0;
        uint256 borrowWithInterest = _bigNumber((amounts >> 128) & X64) * ((prices >> 155) & X64) / EXCHANGE_PRICES_PRECISION;
        uint256 utilization = (borrowWithInterest + _bigNumber((amounts >> 192) & X64)) * WAD
            / (supplyWithInterest + _bigNumber((amounts >> 64) & X64));
        uint256 borrowApr = _borrowRate(l.readFromStorage(_slot(RATE_DATA_SLOT, token)), utilization);
        uint256 fee = (prices >> 16) & X14;
        return borrowApr * borrowWithInterest / supplyWithInterest * (FOUR_DECIMALS - fee) / FOUR_DECIMALS;
    }

    /// @dev Rewards rate: 1e12 = 1% per year (the fToken adds rate × elapsed / YEAR
    ///      on a 1e14 = 100% scale), so × 1e4 gives WAD.
    function _rewardsRate(address fToken, address model) internal view returns (uint256) {
        (uint256 r, bool ended,) = IFluidRewardsRateModelLite(model).getRate(IFluidFTokenLite(fToken).totalAssets());
        return ended ? 0 : r * 1e4;
    }

    function _slot(uint256 mappingSlot, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingSlot));
    }

    /// @dev Fluid BigMath: 56-bit coefficient, 8-bit exponent → coefficient << exponent.
    function _bigNumber(uint256 packed) internal pure returns (uint256) {
        return (packed >> 8) << (packed & 0xff);
    }

    /// @dev Piecewise linear borrow curve. Points are on the 1e4 = 100% scale;
    ///      `utilization` and the result are WAD.
    function _borrowRate(uint256 data, uint256 utilization) internal pure returns (uint256) {
        uint256 version = data & 0xf;
        uint256[4] memory u;
        uint256[4] memory r;
        uint256 points;
        if (version == 1) {
            (u[0], r[0]) = (0, (data >> 4) & X16);
            (u[1], r[1]) = ((data >> 20) & X16, (data >> 36) & X16);
            (u[2], r[2]) = (FOUR_DECIMALS, (data >> 52) & X16);
            points = 3;
        } else if (version == 2) {
            (u[0], r[0]) = (0, (data >> 4) & X16);
            (u[1], r[1]) = ((data >> 20) & X16, (data >> 36) & X16);
            (u[2], r[2]) = ((data >> 52) & X16, (data >> 68) & X16);
            (u[3], r[3]) = (FOUR_DECIMALS, (data >> 84) & X16);
            points = 4;
        } else {
            revert UnknownRateVersion(version);
        }
        if (utilization >= WAD) return r[points - 1] * TO_WAD;
        for (uint256 i = 1; i < points; i++) {
            uint256 u1 = u[i] * TO_WAD;
            if (utilization <= u1) {
                uint256 u0 = u[i - 1] * TO_WAD;
                uint256 r0 = r[i - 1] * TO_WAD;
                uint256 r1 = r[i] * TO_WAD;
                if (u1 == u0) return r1;
                return r1 >= r0
                    ? r0 + (r1 - r0) * (utilization - u0) / (u1 - u0)
                    : r0 - (r0 - r1) * (utilization - u0) / (u1 - u0);
            }
        }
        return r[points - 1] * TO_WAD;
    }
}
