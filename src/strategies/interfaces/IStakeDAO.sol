// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IStakeDAORewardVault is IERC4626 {
    function deposit(uint256 assets, address receiver, address referrer) external returns (uint256 shares);

    function claim(address[] calldata tokens, address receiver) external returns (uint256[] memory amounts);

    function getRewardTokens() external view returns (address[] memory);
}

interface ICurveStableSwapPool is IERC20 {
    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount, address receiver)
        external
        returns (uint256);

    function remove_liquidity_one_coin(uint256 burnAmount, int128 i, uint256 minReceived, address receiver)
        external
        returns (uint256);

    function calc_token_amount(uint256[] calldata amounts, bool deposit) external view returns (uint256);

    function calc_withdraw_one_coin(uint256 tokenAmount, int128 i) external view returns (uint256);
}
