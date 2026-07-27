// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVelodromePool is IERC20 {
    function metadata()
        external
        view
        returns (uint256 decimals0, uint256 decimals1, uint256 reserve0, uint256 reserve1, bool stable, address token0, address token1);

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
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

    struct Zap {
        address tokenA;
        address tokenB;
        bool stable;
        address factory;
        uint256 amountOutMinA;
        uint256 amountOutMinB;
        uint256 amountAMin;
        uint256 amountBMin;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool);

    function voter() external view returns (address);

    function quoteStableLiquidityRatio(address tokenA, address tokenB, address factory) external view returns (uint256 ratio);

    function generateZapInParams(
        address tokenA,
        address tokenB,
        bool stable,
        address factory,
        uint256 amountInA,
        uint256 amountInB,
        Route[] calldata routesA,
        Route[] calldata routesB
    ) external view returns (uint256 amountOutMinA, uint256 amountOutMinB, uint256 amountAMin, uint256 amountBMin);

    function generateZapOutParams(
        address tokenA,
        address tokenB,
        bool stable,
        address factory,
        uint256 liquidity,
        Route[] calldata routesA,
        Route[] calldata routesB
    ) external view returns (uint256 amountOutMinA, uint256 amountOutMinB, uint256 amountAMin, uint256 amountBMin);

    function zapIn(
        address tokenIn,
        uint256 amountInA,
        uint256 amountInB,
        Zap calldata zapInPool,
        Route[] calldata routesA,
        Route[] calldata routesB,
        address to,
        bool stake
    ) external payable returns (uint256 liquidity);

    function zapOut(address tokenOut, uint256 liquidity, Zap calldata zapOutPool, Route[] calldata routesA, Route[] calldata routesB) external;
}
