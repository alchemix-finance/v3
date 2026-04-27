// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IWstETHLike} from "../interfaces/IWstETHLike.sol";

contract WstETHEthereumStrategy is OraclePricedSwapStrategy {
    IWstETHLike public immutable wsteth;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _wstETH,
        address _stEthEthOracle,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _stEthEthOracle, _maxOracleStaleness)
    {
        wsteth = IWstETHLike(_wstETH);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 wstETHBefore = wsteth.balanceOf(address(this));

        IWETH(MYT.asset()).withdraw(amount);
        (bool success,) = address(wsteth).call{value: amount}("");
        require(success, "wstETH deposit failed");

        uint256 wstETHReceived = wsteth.balanceOf(address(this)) - wstETHBefore;
        require(wstETHReceived > 0, "No wstETH received");

        return amount;
    }

    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 minStEthOut = _assetToOracleTokenDown((amount * (10_000 - params.slippageBPS)) / 10_000);
        if (minStEthOut == 0) minStEthOut = 1;

        uint256 minWstETHOut = _wstEthFromStEthUp(minStEthOut);
        dexSwap(address(wsteth), _asset(), amount, minWstETHOut, callData);
        return amount;
    }

    receive() external payable {}

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(wsteth);
    }

    function _oracleToken() internal view override returns (address) {
        return address(wsteth);
    }

    function _positionBalance() internal view override returns (uint256) {
        // Mainnet pricing uses a stETH/ETH oracle, so holdings are valued in stETH-equivalent units.
        return wsteth.getStETHByWstETH(wsteth.balanceOf(address(this)));
    }

    function _prepareOracleTokenForSwap(uint256 maxOracleTokenIn) internal view override returns (uint256) {
        uint256 wstETHBalance = wsteth.balanceOf(address(this));
        uint256 maxWstETHIn = wsteth.getWstETHByStETH(maxOracleTokenIn);
        return maxWstETHIn > wstETHBalance ? wstETHBalance : maxWstETHIn;
    }

    function _wstEthFromStEthUp(uint256 stETHAmount) internal view returns (uint256 wstETHAmount) {
        wstETHAmount = wsteth.getWstETHByStETH(stETHAmount);
        if (wsteth.getStETHByWstETH(wstETHAmount) < stETHAmount) {
            wstETHAmount += 1;
        }
    }
}
