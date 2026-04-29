// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IWstETHLike {
    function balanceOf(address account) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
}
