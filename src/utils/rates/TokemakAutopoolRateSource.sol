// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface ITokemakAutopoolLite {
    function getProfitUnlockSettings()
        external
        view
        returns (uint48 unlockPeriodInSeconds, uint48 fullProfitUnlockTime, uint48 lastProfitUnlockTime, uint256 profitUnlockRate);
    function totalSupply() external view returns (uint256);
}

/**
 * @title TokemakAutopoolRateSource
 * @notice Venue = a Tokemak autopool (autoUSD, autoETH). Debt reporting locks any
 *         rise in NAV as shares the autopool holds, and the autopool burns them
 *         evenly until `fullProfitUnlockTime` (the unlock period is one day on
 *         autoUSD). The burn lifts the share price; that lift is what a holder
 *         earns now. `profitUnlockRate` is shares per second scaled by 1e9
 *         (MAX_BPS_PROFIT; checked on autoUSD 2026-11-03: the shares the autopool
 *         still held equalled rate × time left / 1e9), and `totalSupply()` already
 *         leaves out shares unlocked so far.
 *
 *         Same shape as Yearn v3: a deposit dilutes the unlock in the same block,
 *         a withdraw concentrates it, and after the unlock time the rate is 0 until
 *         the next debt report. TOKE paid through the rewarder is not in this rate.
 */
contract TokemakAutopoolRateSource is IRateSource {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_BPS_PROFIT = 1e9;

    function supplyRate(address autopool) external view returns (uint256) {
        (, uint48 fullUnlock,, uint256 rate) = ITokemakAutopoolLite(autopool).getProfitUnlockSettings();
        if (block.timestamp >= fullUnlock) return 0;
        uint256 supply = ITokemakAutopoolLite(autopool).totalSupply();
        if (supply == 0) return 0;
        // (rate / 1e9) shares per second × YEAR × 1e18 / supply
        return rate * YEAR * (1e18 / MAX_BPS_PROFIT) / supply;
    }
}
