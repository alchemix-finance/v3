// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {IWstETHLike} from "../interfaces/IWstETHLike.sol";

contract WstETHL2Strategy is OraclePricedSwapStrategy {
    IWstETHLike public immutable wsteth;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _wstETH,
        address _wstEthEthOracle,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _wstEthEthOracle, _maxOracleStaleness)
    {
        wsteth = IWstETHLike(_wstETH);
    }

    function _allocate(uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(wsteth);
    }

    function _oracleToken() internal view override returns (address) {
        return address(wsteth);
    }

    function _positionBalance() internal view override returns (uint256) {
        return wsteth.balanceOf(address(this));
    }

    function _prepareOracleTokenForSwap(uint256 maxOracleTokenIn) internal view override returns (uint256) {
        uint256 wstETHBalance = wsteth.balanceOf(address(this));
        return maxOracleTokenIn > wstETHBalance ? wstETHBalance : maxOracleTokenIn;
    }
}
