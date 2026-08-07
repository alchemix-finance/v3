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
 * @dev Allocate: USDC→msUSD swap + addLiquidity + gauge.deposit
 *      Deallocate: gauge.withdraw + removeLiquidity + msUSD→USDC swap
 */
contract VelodromeMUSDStrategy is MYTStrategy {
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_PRECISION = 1e6;
    uint256 internal constant MUSD_PRECISION = 1e18;
    /// @dev Velodrome observation period is 30 minutes; 2 ≈ 1 hour TWAP window.
    uint256 internal constant TWAP_GRANULARITY = 2;

    IERC20 public immutable usdc;
    IERC20 public immutable musd;
    IERC20 public immutable velo;
    IVelodromePool public immutable pool;
    IVelodromeGauge public immutable gauge;
    IVelodromeRouter public immutable router;
    address public immutable factory;
    uint256 public lpCostBasisUsdc;
    /// @notice Execution tolerance (BPS) for router mins and end-to-end floors on swaps,
    ///         addLiquidity/removeLiquidity legs, and the exit fair-value floor.
    ///         Independent of `params.slippageBPS`, which drives withdraw previews and
    ///         LP burn sizing (`previewAdjustedWithdraw` semantics).
    uint256 public swapSlippageBPS;

    event SwapSlippageBPSUpdated(uint256 newSwapSlippageBPS);

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
        swapSlippageBPS = _params.slippageBPS;
    }

    /// @notice Update the execution tolerance applied to router mins and exit floors.
    function setSwapSlippageBPS(uint256 newSwapSlippageBPS) external onlyOwner {
        require(newSwapSlippageBPS < 5000, "Slippage too high");
        swapSlippageBPS = newSwapSlippageBPS;
        emit SwapSlippageBPSUpdated(newSwapSlippageBPS);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(address(usdc), amount);
        uint256 idleBefore = _idleAssets();
        uint256 valueBefore = _totalValue();
        uint256 musdBefore = musd.balanceOf(address(this));

        (uint256 amountInA, uint256 amountInB) = _splitForStableDeposit(amount);

        IVelodromeRouter.Route[] memory swapRoutes = new IVelodromeRouter.Route[](1);
        swapRoutes[0] = IVelodromeRouter.Route({from: address(usdc), to: address(musd), stable: true, factory: factory});

        uint256 minMusdOut = _minSwapOut(address(usdc), amountInB);

        TokenUtils.safeApprove(address(usdc), address(router), 0);
        TokenUtils.safeApprove(address(usdc), address(router), amount);

        uint256[] memory swapAmounts = router.swapExactTokensForTokens(amountInB, minMusdOut, swapRoutes, address(this), block.timestamp);
        uint256 musdReceived = swapAmounts[swapAmounts.length - 1];
        require(musdReceived > 0, "No msUSD received");

        uint256 musdForLp = musd.balanceOf(address(this)) - musdBefore;
        require(musdForLp >= musdReceived, "msUSD balance mismatch");

        // Re-quote after the swap moves reserves; mins must track optimal deposit amounts.
        (uint256 amountAMin, uint256 amountBMin,) = router.quoteAddLiquidity(address(usdc), address(musd), true, factory, amountInA, musdForLp);
        amountAMin = _applySlippage(amountAMin);
        amountBMin = _applySlippage(amountBMin);

        TokenUtils.safeApprove(address(musd), address(router), 0);
        TokenUtils.safeApprove(address(musd), address(router), musdForLp);

        (,, uint256 liquidity) =
            router.addLiquidity(address(usdc), address(musd), true, amountInA, musdForLp, amountAMin, amountBMin, address(this), block.timestamp);

        TokenUtils.safeApprove(address(usdc), address(router), 0);
        TokenUtils.safeApprove(address(musd), address(router), 0);

        require(liquidity > 0, "No LP tokens received");
        uint256 gaugeBalanceBefore = gauge.balanceOf(address(this));
        TokenUtils.safeApprove(address(pool), address(gauge), 0);
        TokenUtils.safeApprove(address(pool), address(gauge), liquidity);
        gauge.deposit(liquidity, address(this));
        TokenUtils.safeApprove(address(pool), address(gauge), 0);
        require(gauge.balanceOf(address(this)) >= gaugeBalanceBefore + liquidity, "LP tokens not staked");

        _sweepMusdToUsdc(musd.balanceOf(address(this)) - musdBefore);
        _finalizeAllocateAccounting(amount, idleBefore, valueBefore);
        return amount;
    }

    /// @dev Swap leftover msUSD from imperfect LP deposits back to USDC so idle NAV stays single-asset.
    function _sweepMusdToUsdc(uint256 musdAmount) internal {
        // Skip dust that cannot clear Velodrome's min-output checks after slippage.
        if (musdAmount < MUSD_PRECISION / USDC_PRECISION) return;

        uint256 minUsdcOut = _minSwapOut(address(musd), musdAmount);
        if (minUsdcOut == 0) return;

        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: address(musd), to: address(usdc), stable: true, factory: factory});

        TokenUtils.safeApprove(address(musd), address(router), 0);
        TokenUtils.safeApprove(address(musd), address(router), musdAmount);
        router.swapExactTokensForTokens(musdAmount, minUsdcOut, routes, address(this), block.timestamp);
        TokenUtils.safeApprove(address(musd), address(router), 0);
    }

    /// @dev Swap floor from pool TWAP (not same-block spot), then slippageBPS.
    ///      USDC→msUSD also enforces a 1:1 peg floor so we never buy msUSD at a premium.
    ///      msUSD→USDC uses TWAP only: a peg floor would brick residual sweeps / exits under
    ///      normal stable-pool impact even when the peg is intact.
    function _minSwapOut(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        uint256 twapOut = pool.quote(tokenIn, amountIn, TWAP_GRANULARITY);
        uint256 floor = twapOut;
        if (tokenIn == address(usdc)) {
            uint256 pegOut = amountIn * (MUSD_PRECISION / USDC_PRECISION);
            if (pegOut > floor) floor = pegOut;
        } else {
            require(tokenIn == address(musd), "Invalid swap token");
        }
        return _applySlippage(floor);
    }

    function _finalizeAllocateAccounting(uint256 amount, uint256 idleUsdcBefore, uint256 valueBefore) internal {
        uint256 idleUsdcAfter = _idleAssets();
        require(idleUsdcAfter <= idleUsdcBefore, "Unexpected USDC increase");

        lpCostBasisUsdc += idleUsdcBefore - idleUsdcAfter;
        require(_totalValue() >= valueBefore - Math.mulDiv(amount, swapSlippageBPS, BASIS_POINTS), "Allocation loss");
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
            _removeLiquidityAndSwap(liquidity, basisReduction);
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

    /// @dev Exit LP to USDC and enforce an end-to-end floor that cannot be lowered by
    ///      same-block reserve skew: min(invariant fair value, pro-rata cost basis).
    function _removeLiquidityAndSwap(uint256 liquidity, uint256 basisShareUsdc) internal {
        uint256 fairValue = _lpFairValueUsdc(liquidity);
        uint256 floor = fairValue < basisShareUsdc ? fairValue : basisShareUsdc;
        uint256 minUsdcOut = _applySlippage(floor);
        uint256 usdcBefore = _idleAssets();

        (uint256 amountAMin, uint256 amountBMin) = router.quoteRemoveLiquidity(address(usdc), address(musd), true, factory, liquidity);
        amountAMin = _applySlippage(amountAMin);
        amountBMin = _applySlippage(amountBMin);

        uint256 musdBefore = musd.balanceOf(address(this));

        TokenUtils.safeApprove(address(pool), address(router), 0);
        TokenUtils.safeApprove(address(pool), address(router), liquidity);
        router.removeLiquidity(address(usdc), address(musd), true, liquidity, amountAMin, amountBMin, address(this), block.timestamp);
        TokenUtils.safeApprove(address(pool), address(router), 0);

        _sweepMusdToUsdc(musd.balanceOf(address(this)) - musdBefore);

        require(_idleAssets() - usdcBefore >= minUsdcOut, "Exit below fair value");
    }

    function _unstake(uint256 liquidity) internal {
        uint256 unstakedBalance = pool.balanceOf(address(this));
        if (unstakedBalance < liquidity) {
            gauge.withdraw(liquidity - unstakedBalance);
        }
        require(pool.balanceOf(address(this)) >= liquidity, "Insufficient unstaked LP");
    }

    function _totalValue() internal view override returns (uint256) {
        // Idle msUSD dust (e.g. after addLiquidity) valued at a $1 peg.
        uint256 idleMusdUsdc = Math.mulDiv(musd.balanceOf(address(this)), USDC_PRECISION, MUSD_PRECISION);
        return _idleAssets() + idleMusdUsdc + _positionValueUsdc(_lpBalance());
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
        return fromIdle + _applyWithdrawHaircut(fundableFromPosition);
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

    /// @dev `quoteStableLiquidityRatio` returns B/(A+B); amountInB is swapped to msUSD, amountInA stays USDC.
    function _splitForStableDeposit(uint256 amount) internal view returns (uint256 amountInA, uint256 amountInB) {
        uint256 ratioB = router.quoteStableLiquidityRatio(address(usdc), address(musd), factory);
        require(ratioB <= WAD, "Invalid liquidity ratio");

        amountInB = Math.mulDiv(amount, ratioB, WAD);
        amountInA = amount - amountInB;
        require(amountInA > 0 && amountInB > 0, "Allocation too small");
    }

    /// @dev Execution tolerance on router mins and end-to-end floors (swapSlippageBPS).
    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, BASIS_POINTS - swapSlippageBPS, BASIS_POINTS);
    }

    /// @dev Expected exit efficiency haircut for withdraw previews and LP burn sizing
    ///      (params.slippageBPS, owner-updatable via setSlippageBPS).
    function _applyWithdrawHaircut(uint256 amount) internal view returns (uint256) {
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
