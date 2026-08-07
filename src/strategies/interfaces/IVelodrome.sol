// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVelodromePool is IERC20 {
    function metadata()
        external
        view
        returns (uint256 decimals0, uint256 decimals1, uint256 reserve0, uint256 reserve1, bool stable, address token0, address token1);

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    /// @notice TWAP quote over `granularity` pool observation periods (30 minutes each).
    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256 amountOut);

    /// @notice Spot output amount for swapping `amountIn` of `tokenIn` at current reserves.
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);
}

interface IVelodromeGauge {
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 amount, address recipient) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external;
    function rewardToken() external view returns (address);
    function stakingToken() external view returns (address);
}

interface IVelodromeVoter {
    function gauges(address pool) external view returns (address gauge);
}

interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool);

    function voter() external view returns (address);

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address factory,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function quoteStableLiquidityRatio(address tokenA, address tokenB, address factory) external view returns (uint256 ratio);

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, address factory, uint256 liquidity)
        external
        view
        returns (uint256 amountA, uint256 amountB);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}
