// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IStakeDAOAccountant {
    error NoPendingRewards();

    function claim(address[] calldata gauges, bytes[] calldata harvestData, address receiver) external;

    function harvest(address[] calldata gauges, bytes[] calldata harvestData, address receiver) external;

    function accounts(address vault, address account) external view returns (uint128 balance, uint256 integral, uint256 pendingRewards);

    function vaults(address vault)
        external
        view
        returns (
            uint256 integral,
            uint128 supply,
            uint128 feeSubjectAmount,
            uint128 totalAmount,
            uint128 netCredited,
            uint128 reservedHarvestFee,
            uint128 reservedProtocolFee
        );

    function REWARD_TOKEN() external view returns (address);

    function SCALING_FACTOR() external view returns (uint128);
}

interface IStakeDAORewardVault is IERC4626 {
    function deposit(uint256 assets, address receiver, address referrer) external returns (uint256 shares);

    function claim(address[] calldata tokens, address receiver) external returns (uint256[] memory amounts);

    function ACCOUNTANT() external view returns (IStakeDAOAccountant);

    function gauge() external view returns (address);

    function getRewardTokens() external view returns (address[] memory);

    function earned(address account, address token) external view returns (uint128);

    function getRewardsDistributor(address token) external view returns (address);

    function depositRewards(address rewardToken, uint128 amount) external;
}

interface ICurveStableSwapPool is IERC20 {
    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount, address receiver) external returns (uint256);

    function remove_liquidity_one_coin(uint256 burnAmount, int128 i, uint256 minReceived, address receiver) external returns (uint256);

    function calc_token_amount(uint256[] calldata amounts, bool deposit) external view returns (uint256);

    function calc_withdraw_one_coin(uint256 tokenAmount, int128 i) external view returns (uint256);

    function get_virtual_price() external view returns (uint256);
}
