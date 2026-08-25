// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal allowance-holder stand-in: pulls `amountIn`, pushes `amountOut`.
contract MockSwapper {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        (bool pullOk,) = from.call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amountIn));
        require(pullOk, "pull failed");
        (bool pushOk,) = to.call(abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amountOut));
        require(pushOk, "push failed");
    }
}
