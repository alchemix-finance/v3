// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./IRateSource.sol";

interface IAaveATokenLite {
    function POOL() external view returns (address);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @title AaveV3RateSource
 * @notice Venue = the aToken. Reports the reserve's `currentLiquidityRate`, which
 *         Aave already nets of the reserve factor and rewrites on every supply and
 *         withdraw. Read through a low-level call so the same code reads every
 *         v3.x pool (`getReserveData` returns ReserveData or ReserveDataLegacy; both
 *         keep the liquidity rate in the third word).
 */
contract AaveV3RateSource is IRateSource {
    function supplyRate(address aToken) external view returns (uint256) {
        address pool = IAaveATokenLite(aToken).POOL();
        address reserve = IAaveATokenLite(aToken).UNDERLYING_ASSET_ADDRESS();
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("getReserveData(address)", reserve));
        require(ok && ret.length >= 96, "reserve");
        (,, uint256 liquidityRateRay) = abi.decode(ret, (uint256, uint256, uint256));
        return liquidityRateRay / 1e9;
    }
}
