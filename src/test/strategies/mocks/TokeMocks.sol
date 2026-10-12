// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TokeSwapRoute} from "../../../strategies/TokeAutoStrategy.sol";

/// @notice Replaces the Tokemak MainRewarder via vm.etch so that
///         getReward actually transfers TOKE tokens to the recipient.
contract MockTokeRewarder {
    IERC20 public immutable tokeToken;
    uint256 public immutable rewardAmount;
    address public immutable rewardTokenAddr;
    uint256 public immutable lockDuration;

    constructor(address _tokeToken, uint256 _rewardAmount, address _rewardTokenAddr, uint256 _lockDuration) {
        tokeToken = IERC20(_tokeToken);
        rewardAmount = _rewardAmount;
        rewardTokenAddr = _rewardTokenAddr;
        lockDuration = _lockDuration;
    }

    function allowExtraRewards() external pure returns (bool) {
        return false;
    }

    function getReward(address, address recipient, bool) external {
        tokeToken.transfer(recipient, rewardAmount);
    }

    function rewardToken() external view returns (address) {
        return rewardTokenAddr;
    }

    function tokeLockDuration() external view returns (uint256) {
        return lockDuration;
    }
}

/// @notice When used as allowanceHolder, transfers a fixed amount of token
///         to msg.sender on any call (simulates swap output).
contract MockSwapExecutor {
    IERC20 public immutable token;
    uint256 public amountToTransfer;

    constructor(address _token, uint256 _amountToTransfer) {
        token = IERC20(_token);
        amountToTransfer = _amountToTransfer;
    }

    receive() external payable {}

    fallback() external {
        token.transfer(msg.sender, amountToTransfer);
    }
}

contract MockAutopilotRouter {
    IERC20 public immutable asset;
    uint256 public redeemCalls;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function redeem(IERC4626 vault, address to, uint256 shares, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        redeemCalls++;
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);
        asset.transfer(to, minAmountOut);
        return minAmountOut;
    }

    function redeemWithRoutes(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut,
        TokeSwapRoute[] calldata
    ) external returns (uint256 amountOut) {
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);
        asset.transfer(to, minAmountOut);
        return minAmountOut;
    }
}
