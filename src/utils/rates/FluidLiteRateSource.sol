// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface IFluidLiteVaultLite {
    function asset() external view returns (address);
    function getExchangePrice() external view returns (uint256);
    function getEffectiveExchangePrice() external view returns (uint256);
    function getFixedRate() external view returns (uint256);
    function getRewardAmountPerYear() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IERC20DecimalsLite {
    function decimals() external view returns (uint8);
}

/**
 * @title FluidLiteRateSource
 * @notice Venue = a Fluid Lite vault (Lite V3, e.g. fLiteUSD). It has no rate curve.
 *         The share price accrues, from the last checkpoint, at whichever of two
 *         settings of its strategy handler pays more:
 *
 *           fixed:   exchangePrice × fixedRate / 1e4 per year
 *           reward:  rewardAmountPerYear of the asset, spread over every share
 *
 *         so the rate is max(fixedRate, rewardAmountPerYear / totalAssets). The
 *         reward part falls as the vault grows: a deposit lowers it in the same
 *         block, a withdraw raises it. It applies only from 100 shares of supply.
 *
 *         Not in the rate: the withdrawal fee (5 bps at launch, at most 50), which a
 *         pair's maxLossBps and minSpreadBps must cover, and the strategy handler's
 *         reconciliation step `updateExchangePrice` (up to +2% a call, never down).
 *         The vault counts a year as 365.25 days; this source reports on 365.
 */
contract FluidLiteRateSource is IRateSource {
    uint256 internal constant RATE_PRECISION = 1e4;
    uint256 internal constant MIN_TOTAL_SUPPLY_FOR_REWARDS = 100e18;
    uint256 internal constant DAYS_X100 = 36_500;               // our year
    uint256 internal constant VAULT_DAYS_X100 = 36_525;         // the vault's year

    function supplyRate(address vault) external view returns (uint256) {
        IFluidLiteVaultLite v = IFluidLiteVaultLite(vault);
        uint256 price = v.getEffectiveExchangePrice();
        if (price == 0) return 0;
        // price rise per vault year, 1e18 precision, as the vault computes it
        uint256 slope = v.getExchangePrice() * v.getFixedRate() / RATE_PRECISION;
        uint256 reward = v.getRewardAmountPerYear();
        uint256 supply = v.totalSupply();
        if (reward > 0 && supply >= MIN_TOTAL_SUPPLY_FOR_REWARDS) {
            // shares carry 18 decimals, the reward the asset's
            uint256 offset = 10 ** (18 - IERC20DecimalsLite(v.asset()).decimals());
            uint256 rewardSlope = reward * offset * 1e18 / supply;
            if (rewardSlope > slope) slope = rewardSlope;
        }
        // relative to the price a depositor pays now, per 365-day year
        return slope * 1e18 * DAYS_X100 / (price * VAULT_DAYS_X100);
    }
}
