// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface IYearnV3VaultLite {
    function profitUnlockingRate() external view returns (uint256);
    function fullProfitUnlockDate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title YearnV3RateSource
 * @notice Venue = a Yearn v3 vault (3.0.x). A report locks the profit as shares
 *         the vault holds, and the vault burns them evenly until
 *         `fullProfitUnlockDate`. The burn lifts the share price; that lift is what
 *         a holder earns now. `profitUnlockingRate` is shares per second scaled by
 *         MAX_BPS_EXTENDED (1e12), and `totalSupply()` already leaves out shares
 *         unlocked so far. Fees are taken at report time, so the unlock is net.
 *
 *         A deposit mints shares and dilutes the unlock in the same block; a
 *         withdraw concentrates it. After the unlock date nothing is unlocking and
 *         the rate is 0 until the next report.
 */
contract YearnV3RateSource is IRateSource {
    uint256 internal constant YEAR = 365 days;

    function supplyRate(address vault) external view returns (uint256) {
        IYearnV3VaultLite v = IYearnV3VaultLite(vault);
        if (block.timestamp >= v.fullProfitUnlockDate()) return 0;
        uint256 supply = v.totalSupply();
        if (supply == 0) return 0;
        // (rate / 1e12) shares per second × YEAR × 1e18 / supply
        return v.profitUnlockingRate() * YEAR * 1e6 / supply;
    }
}
