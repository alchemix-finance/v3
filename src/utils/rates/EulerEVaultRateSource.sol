// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface IEulerEVaultLite {
    function interestRate() external view returns (uint256);
    function interestFee() external view returns (uint16);
    function cash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
}

/**
 * @title EulerEVaultRateSource
 * @notice Venue = an EVK vault. `interestRate()` is the borrow rate per second
 *         (1e27), recomputed at the end of every operation. Lenders get it scaled by
 *         utilization, less the vault's interest fee (CONFIG_SCALE 1e4).
 */
contract EulerEVaultRateSource is IRateSource {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant CONFIG_SCALE = 1e4;

    function supplyRate(address eVault) external view returns (uint256) {
        IEulerEVaultLite v = IEulerEVaultLite(eVault);
        uint256 borrows = v.totalBorrows();
        uint256 total = v.cash() + borrows;
        if (total == 0) return 0;
        uint256 borrowApr = v.interestRate() * YEAR / 1e9;
        return borrowApr * borrows / total * (CONFIG_SCALE - v.interestFee()) / CONFIG_SCALE;
    }
}
