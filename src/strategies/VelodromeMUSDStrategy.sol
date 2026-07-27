// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IVelodromeGauge, IVelodromePool, IVelodromeRouter, IVelodromeVoter} from "./interfaces/IVelodrome.sol";

/**
 * @title VelodromeMUSDStrategy
 * @notice Allocates USDC into the Velodrome V2 stable USDC/msUSD pool and stakes
 *         the resulting LP tokens in its gauge for VELO emissions.
 */
contract VelodromeMUSDStrategy is MYTStrategy {
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_PRECISION = 1e6;
    uint256 internal constant MUSD_PRECISION = 1e18;

    IERC20 public immutable usdc;
    IERC20 public immutable musd;
    IERC20 public immutable velo;
    IVelodromePool public immutable pool;
    IVelodromeGauge public immutable gauge;
    IVelodromeRouter public immutable router;
    address public immutable factory;
    uint256 public lpCostBasisUsdc;

    constructor(address _myt, StrategyParams memory _params, address _usdc, address _musd, address _pool, address _gauge, address _router, address _factory)
        MYTStrategy(_myt, _params)
    {
        require(_usdc != address(0), "Zero USDC address");
        require(_musd != address(0), "Zero msUSD address");
        require(_pool != address(0), "Zero pool address");
        require(_gauge != address(0), "Zero gauge address");
        require(_router != address(0), "Zero router address");
        require(_factory != address(0), "Zero factory address");
        require(_usdc == MYT.asset(), "Vault asset != USDC");

        IVelodromePool pool_ = IVelodromePool(_pool);
        IVelodromeGauge gauge_ = IVelodromeGauge(_gauge);
        IVelodromeRouter router_ = IVelodromeRouter(_router);

        (uint256 precision0, uint256 precision1,,, bool stable, address token0, address token1) = pool_.metadata();
        require(stable, "Pool is not stable");
        require(token0 == _usdc && token1 == _musd, "Unexpected pool tokens");
        require(precision0 == USDC_PRECISION && precision1 == MUSD_PRECISION, "Unexpected token decimals");
        require(router_.poolFor(_usdc, _musd, true, _factory) == _pool, "Router pool mismatch");
        require(gauge_.stakingToken() == _pool, "Gauge pool mismatch");
        require(IVelodromeVoter(router_.voter()).gauges(_pool) == _gauge, "Router gauge mismatch");

        address rewardToken = gauge_.rewardToken();
        require(rewardToken != address(0), "Zero reward token");

        usdc = IERC20(_usdc);
        musd = IERC20(_musd);
        velo = IERC20(rewardToken);
        pool = pool_;
        gauge = gauge_;
        router = router_;
        factory = _factory;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(address(usdc), amount);
        uint256 idleBefore = _idleAssets();
        uint256 valueBefore = _totalValue();

        uint256 ratioB = router.quoteStableLiquidityRatio(address(usdc), address(musd), factory);
        require(ratioB <= WAD, "Invalid liquidity ratio");

        uint256 amountInB = Math.mulDiv(amount, ratioB, WAD);
        uint256 amountInA = amount - amountInB;
        require(amountInA > 0 && amountInB > 0, "Allocation too small");

        (IVelodromeRouter.Route[] memory routesA, IVelodromeRouter.Route[] memory routesB) = _zapInRoutes();
        (uint256 amountOutMinA, uint256 amountOutMinB, uint256 amountAMin, uint256 amountBMin) =
            router.generateZapInParams(address(usdc), address(musd), true, factory, amountInA, amountInB, routesA, routesB);

        IVelodromeRouter.Zap memory zap = IVelodromeRouter.Zap({
            tokenA: address(usdc),
            tokenB: address(musd),
            stable: true,
            factory: factory,
            amountOutMinA: _applySlippage(amountOutMinA),
            amountOutMinB: _applySlippage(amountOutMinB),
            amountAMin: _applySlippage(amountAMin),
            amountBMin: _applySlippage(amountBMin)
        });

        uint256 gaugeBalanceBefore = gauge.balanceOf(address(this));
        TokenUtils.safeApprove(address(usdc), address(router), 0);
        TokenUtils.safeApprove(address(usdc), address(router), amount);
        uint256 liquidity = router.zapIn(address(usdc), amountInA, amountInB, zap, routesA, routesB, address(this), true);
        TokenUtils.safeApprove(address(usdc), address(router), 0);

        require(liquidity > 0, "No LP tokens received");
        require(gauge.balanceOf(address(this)) >= gaugeBalanceBefore + liquidity, "LP tokens not staked");

        uint256 idleAfter = _idleAssets();
        require(idleAfter <= idleBefore, "Unexpected USDC increase");
        lpCostBasisUsdc += idleBefore - idleAfter;
        require(_totalValue() >= valueBefore - Math.mulDiv(amount, params.slippageBPS, BASIS_POINTS), "Allocation loss");
        return amount;
    }

    function _allocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 totalLp = _lpBalance();
            uint256 positionValue = _positionValueUsdc(totalLp);
            require(positionValue > 0, "No LP value");

            uint256 bufferedShortfall = Math.mulDiv(shortfall, BASIS_POINTS, BASIS_POINTS - params.slippageBPS, Math.Rounding.Ceil);
            uint256 liquidity = Math.mulDiv(totalLp, bufferedShortfall, positionValue, Math.Rounding.Ceil);
            if (liquidity > totalLp) liquidity = totalLp;

            uint256 basisReduction = Math.mulDiv(lpCostBasisUsdc, liquidity, totalLp, Math.Rounding.Ceil);
            lpCostBasisUsdc -= basisReduction;
            _unstake(liquidity);
            _zapOut(liquidity);
        }

        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _deallocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _deallocate(uint256, bytes memory, uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _zapOut(uint256 liquidity) internal {
        (IVelodromeRouter.Route[] memory routesA, IVelodromeRouter.Route[] memory routesB) = _zapOutRoutes();
        (uint256 amountOutMinA, uint256 amountOutMinB, uint256 amountAMin, uint256 amountBMin) =
            router.generateZapOutParams(address(usdc), address(musd), true, factory, liquidity, routesA, routesB);

        IVelodromeRouter.Zap memory zap = IVelodromeRouter.Zap({
            tokenA: address(usdc),
            tokenB: address(musd),
            stable: true,
            factory: factory,
            amountOutMinA: _applySlippage(amountOutMinA),
            amountOutMinB: _applySlippage(amountOutMinB),
            amountAMin: _applySlippage(amountAMin),
            amountBMin: _applySlippage(amountBMin)
        });

        TokenUtils.safeApprove(address(pool), address(router), 0);
        TokenUtils.safeApprove(address(pool), address(router), liquidity);
        router.zapOut(address(usdc), liquidity, zap, routesA, routesB);
        TokenUtils.safeApprove(address(pool), address(router), 0);
    }

    function _unstake(uint256 liquidity) internal {
        uint256 unstakedBalance = pool.balanceOf(address(this));
        if (unstakedBalance < liquidity) {
            gauge.withdraw(liquidity - unstakedBalance);
        }
        require(pool.balanceOf(address(this)) >= liquidity, "Insufficient unstaked LP");
    }

    function _totalValue() internal view override returns (uint256) {
        return _idleAssets() + _positionValueUsdc(_lpBalance());
    }

    function _lpBalance() internal view returns (uint256) {
        return gauge.balanceOf(address(this)) + pool.balanceOf(address(this));
    }

    function _positionValueUsdc(uint256 liquidity) internal view returns (uint256) {
        uint256 fairValue = _lpFairValueUsdc(liquidity);
        return fairValue < lpCostBasisUsdc ? fairValue : lpCostBasisUsdc;
    }

    /**
     * @notice Values stable-pool LP tokens at a balanced $1/$1 reserve state.
     * @dev Velodrome's normalized stable invariant is x*y*(x^2+y^2), scaled as
     *      k = x*y*(x^2+y^2)/1e54. At x=y=r, r=((k/2)*1e54)^(1/4).
     *      Pricing from k prevents a temporary reserve imbalance from inflating NAV.
     */
    function _lpFairValueUsdc(uint256 liquidity) internal view returns (uint256) {
        if (liquidity == 0) return 0;

        (uint256 reserve0, uint256 reserve1,) = pool.getReserves();
        uint256 supply = pool.totalSupply();
        if (supply == 0) return 0;

        uint256 x = Math.mulDiv(reserve0, WAD, USDC_PRECISION);
        uint256 y = Math.mulDiv(reserve1, WAD, MUSD_PRECISION);
        uint256 a = Math.mulDiv(x, y, WAD);
        uint256 b = Math.mulDiv(x, x, WAD) + Math.mulDiv(y, y, WAD);
        uint256 k = Math.mulDiv(a, b, WAD);
        if (k == 0) return 0;

        uint256 rSquared = Math.sqrt(Math.mulDiv(k, WAD, 2)) * WAD;
        uint256 balancedReserve = Math.sqrt(rSquared);
        uint256 fairValueWad = Math.mulDiv(2 * balancedReserve, liquidity, supply);
        return fairValueWad / (WAD / USDC_PRECISION);
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount < idleBalance ? amount : idleBalance;
        if (fromIdle == amount) return amount;

        uint256 remaining = amount - fromIdle;
        uint256 positionValue = _positionValueUsdc(_lpBalance());
        uint256 fundableFromPosition = remaining < positionValue ? remaining : positionValue;
        return fromIdle + _applySlippage(fundableFromPosition);
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256 rewardsClaimed) {
        require(token == address(velo), "Invalid reward token");

        uint256 balanceBefore = velo.balanceOf(address(this));
        gauge.getReward(address(this));
        uint256 rewardsReceived = velo.balanceOf(address(this)) - balanceBefore;
        if (rewardsReceived == 0) return 0;

        emit RewardsClaimed(address(velo), rewardsReceived);
        rewardsClaimed = dexSwap(address(usdc), address(velo), rewardsReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(usdc), address(MYT), rewardsClaimed);
    }

    function _zapInRoutes() internal view returns (IVelodromeRouter.Route[] memory routesA, IVelodromeRouter.Route[] memory routesB) {
        routesA = new IVelodromeRouter.Route[](0);
        routesB = new IVelodromeRouter.Route[](1);
        routesB[0] = IVelodromeRouter.Route({from: address(usdc), to: address(musd), stable: true, factory: factory});
    }

    function _zapOutRoutes() internal view returns (IVelodromeRouter.Route[] memory routesA, IVelodromeRouter.Route[] memory routesB) {
        routesA = new IVelodromeRouter.Route[](0);
        routesB = new IVelodromeRouter.Route[](1);
        routesB[0] = IVelodromeRouter.Route({from: address(musd), to: address(usdc), stable: true, factory: factory});
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, BASIS_POINTS - params.slippageBPS, BASIS_POINTS);
    }

    function _idleAssets() internal view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == address(usdc) || token == address(musd) || token == address(pool);
    }

    function _canForceDeallocate() internal pure override returns (bool) {
        return false;
    }
}
