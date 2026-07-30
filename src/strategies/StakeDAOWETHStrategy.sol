// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IStakeDAOAccountant, IStakeDAORewardVault, ICurveStableSwapPool} from "./interfaces/IStakeDAO.sol";

/**
 * @title StakeDAOWETHStrategy
 * @notice Allocates WETH into Stake DAO RewardVault shares and exits back to WETH.
 * @dev Direct path: WETH -> Curve LP -> RewardVault shares / reverse on exit.
 *      Swap path: single Enso route each way via `ActionType.swap`.
 */
contract StakeDAOWETHStrategy is MYTStrategy {
    uint256 public constant MAX_WITHDRAW_BUFFER_BPS = 650;
    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant LP_ROUNDING_TOLERANCE = 1e6; // 1e-12 LP
    int128 internal constant WETH_COIN_INDEX = 1;

    IERC20 public immutable weth;
    IStakeDAORewardVault public immutable rewardVault;
    ICurveStableSwapPool public immutable curvePool;
    IStakeDAOAccountant public immutable accountant;
    address public immutable mainRewardToken;
    address public immutable gauge;
    address public immutable ensoRouter;
    uint256 public withdrawBufferBps;
    uint256 public minWethPerCurveLp;
    uint256 public minCurveLpPerWeth;
    bool public canForceDeallocate;

    event WithdrawBufferBpsUpdated(uint256 newWithdrawBufferBps);
    event MinWethPerCurveLpUpdated(uint256 newMinWethPerCurveLp);
    event MinCurveLpPerWethUpdated(uint256 newMinCurveLpPerWeth);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    error CurveLpPriceBelowFloor(uint256 lpAmount, uint256 maxLpAmount);
    error CurveLpOutputBelowFloor(uint256 lpReceived, uint256 minLpReceived);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _rewardVault,
        address _curvePool,
        address _ensoRouter,
        uint256 _withdrawBufferBps,
        uint256 _minWethPerCurveLp,
        uint256 _minCurveLpPerWeth
    ) MYTStrategy(_myt, _params) {
        require(_rewardVault != address(0), "Zero reward vault");
        require(_curvePool != address(0), "Zero curve pool");
        require(_ensoRouter != address(0), "Zero enso router");
        require(_withdrawBufferBps < MAX_WITHDRAW_BUFFER_BPS, "Withdraw buffer too high");
        require(_minWethPerCurveLp > 0, "Zero Curve LP floor");
        require(_minCurveLpPerWeth > 0, "Zero allocation floor");

        weth = IERC20(MYT.asset());
        rewardVault = IStakeDAORewardVault(_rewardVault);
        curvePool = ICurveStableSwapPool(_curvePool);
        accountant = rewardVault.ACCOUNTANT();
        mainRewardToken = accountant.REWARD_TOKEN();
        gauge = rewardVault.gauge();
        ensoRouter = _ensoRouter;
        withdrawBufferBps = _withdrawBufferBps;
        minWethPerCurveLp = _minWethPerCurveLp;
        minCurveLpPerWeth = _minCurveLpPerWeth;

        require(rewardVault.asset() == _curvePool, "Vault asset != curve LP");
    }

    function setWithdrawBufferBps(uint256 newWithdrawBufferBps) external onlyOwner {
        require(newWithdrawBufferBps < MAX_WITHDRAW_BUFFER_BPS, "Withdraw buffer too high");
        withdrawBufferBps = newWithdrawBufferBps;
        emit WithdrawBufferBpsUpdated(newWithdrawBufferBps);
    }

    function setMinWethPerCurveLp(uint256 newMinWethPerCurveLp) external onlyOwner {
        require(newMinWethPerCurveLp > 0, "Zero Curve LP floor");
        minWethPerCurveLp = newMinWethPerCurveLp;
        emit MinWethPerCurveLpUpdated(newMinWethPerCurveLp);
    }

    function setMinCurveLpPerWeth(uint256 newMinCurveLpPerWeth) external onlyOwner {
        require(newMinCurveLpPerWeth > 0, "Zero allocation floor");
        minCurveLpPerWeth = newMinCurveLpPerWeth;
        emit MinCurveLpPerWethUpdated(newMinCurveLpPerWeth);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(address(weth), amount);

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(WETH_COIN_INDEX))] = amount;
        uint256 expectedLp = curvePool.calc_token_amount(amounts, true);
        uint256 minLpOut = _minAmountAfterSlippage(expectedLp);
        uint256 floorLpOut = _effectiveMinLpForWeth(amount);
        if (floorLpOut > minLpOut) minLpOut = floorLpOut;

        TokenUtils.safeApprove(address(weth), address(curvePool), amount);
        uint256 lpMinted = curvePool.add_liquidity(amounts, minLpOut, address(this));
        TokenUtils.safeApprove(address(weth), address(curvePool), 0);
        if (lpMinted < floorLpOut) revert CurveLpOutputBelowFloor(lpMinted, floorLpOut);

        TokenUtils.safeApprove(address(curvePool), address(rewardVault), lpMinted);
        rewardVault.deposit(lpMinted, address(this), address(0));
        TokenUtils.safeApprove(address(curvePool), address(rewardVault), 0);

        return amount;
    }

    function _allocate(uint256 amount, bytes memory ensoCalldata) internal override returns (uint256) {
        _ensureIdleBalance(address(weth), amount);

        uint256 wethBefore = _idleAssets();
        uint256 sharesBefore = rewardVault.balanceOf(address(this));
        uint256 minSharesOut = _minSharesForWethIn(amount);

        TokenUtils.safeApprove(address(weth), ensoRouter, amount);
        _ensoRoute(address(rewardVault), minSharesOut, ensoCalldata);
        TokenUtils.safeApprove(address(weth), ensoRouter, 0);

        uint256 sharesReceived = rewardVault.balanceOf(address(this)) - sharesBefore;
        uint256 wethSpent = wethBefore - _idleAssets();
        uint256 lpReceived = rewardVault.convertToAssets(sharesReceived);
        uint256 floorLpOut = _effectiveMinLpForWeth(wethSpent);
        if (lpReceived < floorLpOut) revert CurveLpOutputBelowFloor(lpReceived, floorLpOut);

        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 shares = rewardVault.balanceOf(address(this));
        require(shares > 0, "No RewardVault shares");

        uint256 lpToExit = _lpRequiredForWeth(shortfall, shares);

        uint256 sharesToRedeem = rewardVault.previewWithdraw(lpToExit);
        if (sharesToRedeem > shares) sharesToRedeem = shares;

        uint256 wethBefore = _idleAssets();
        uint256 lpRedeemed = rewardVault.redeem(sharesToRedeem, address(this), address(this));

        TokenUtils.safeApprove(address(curvePool), address(curvePool), lpRedeemed);
        curvePool.remove_liquidity_one_coin(lpRedeemed, WETH_COIN_INDEX, shortfall, address(this));
        TokenUtils.safeApprove(address(curvePool), address(curvePool), 0);

        uint256 wethReceived = _idleAssets() - wethBefore;
        uint256 maxLpToExit = _effectiveMaxLpForWeth(wethReceived);
        if (lpRedeemed > maxLpToExit) revert CurveLpPriceBelowFloor(lpRedeemed, maxLpToExit);

        require(_idleAssets() >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _deallocate(uint256 amount, bytes memory ensoCalldata) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 shares = rewardVault.balanceOf(address(this));
        require(shares > 0, "No RewardVault shares");
        uint256 lpValueBefore = rewardVault.convertToAssets(shares);

        uint256 maxWethOut = Math.mulDiv(shortfall, 10_000, 10_000 - params.slippageBPS, Math.Rounding.Ceil);
        uint256 maxSharesToSpend = rewardVault.previewWithdraw(_maxLpForWeth(maxWethOut));
        if (maxSharesToSpend > shares) maxSharesToSpend = shares;
        TokenUtils.safeApprove(address(rewardVault), ensoRouter, maxSharesToSpend);
        uint256 wethReceived = _ensoRoute(address(weth), shortfall, ensoCalldata);
        TokenUtils.safeApprove(address(rewardVault), ensoRouter, 0);

        uint256 sharesSpent = shares - rewardVault.balanceOf(address(this));
        uint256 lpSpent = Math.mulDiv(sharesSpent, lpValueBefore, shares, Math.Rounding.Ceil);
        uint256 maxLpToSpend = _effectiveMaxLpForWeth(wethReceived);
        if (lpSpent > maxLpToSpend) revert CurveLpPriceBelowFloor(lpSpent, maxLpToSpend);

        require(_idleAssets() >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 lpAssets = rewardVault.convertToAssets(rewardVault.balanceOf(address(this)));
        uint256 lpValue = Math.mulDiv(lpAssets, curvePool.get_virtual_price(), PRICE_SCALE);
        return _idleAssets() + lpValue;
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(weth), address(this));
    }

    /// @dev Floor-priced capacity only; callers must quote route-specific liquidity and price impact.
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;
        uint256 lpAssets = rewardVault.convertToAssets(rewardVault.balanceOf(address(this)));
        uint256 maxWethFromShares = Math.mulDiv(lpAssets, minWethPerCurveLp, PRICE_SCALE);
        uint256 fundableFromPosition = remaining <= maxWethFromShares ? remaining : maxWethFromShares;
        return fromIdle + (fundableFromPosition * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256 rewardsClaimed) {
        require(quote.length > 0, "params");
        uint256 balanceBefore = TokenUtils.safeBalanceOf(token, address(this));

        if (token == mainRewardToken) {
            address[] memory gauges = new address[](1);
            gauges[0] = gauge;
            bytes[] memory harvestData = new bytes[](1);
            harvestData[0] = "";

            try accountant.claim(gauges, harvestData, address(this)) {}
            catch (bytes memory reason) {
                if (reason.length >= 4 && bytes4(reason) == IStakeDAOAccountant.NoPendingRewards.selector) return 0;
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        } else {
            if (rewardVault.earned(address(this), token) == 0) return 0;

            address[] memory rewardTokens = new address[](1);
            rewardTokens[0] = token;
            rewardVault.claim(rewardTokens, address(this));
        }

        uint256 rewardsReceived = TokenUtils.safeBalanceOf(token, address(this)) - balanceBefore;
        if (rewardsReceived == 0) return 0;
        emit RewardsClaimed(token, rewardsReceived);
        uint256 amountOut = dexSwap(MYT.asset(), token, IERC20(token).balanceOf(address(this)), minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), amountOut);
        return amountOut;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == address(weth) || token == address(rewardVault) || token == address(curvePool);
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function _minAmountAfterSlippage(uint256 amount) internal view returns (uint256) {
        uint256 minAmount = amount * (10_000 - params.slippageBPS) / 10_000;
        return minAmount == 0 ? 1 : minAmount;
    }

    /// @dev Lower bound on RewardVault shares expected from the quoted Curve LP deposit.
    function _minSharesForWethIn(uint256 wethAmount) internal view returns (uint256) {
        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(WETH_COIN_INDEX))] = wethAmount;
        uint256 expectedLp = curvePool.calc_token_amount(amounts, true);
        return _minAmountAfterSlippage(rewardVault.previewDeposit(expectedLp));
    }

    /// @dev LP estimate from the full-position Curve quote, rounded up.
    function _lpRequiredForWeth(uint256 wethOut, uint256 maxShares) internal view returns (uint256) {
        if (maxShares == 0 || wethOut == 0) return 0;

        uint256 maxLp = rewardVault.convertToAssets(maxShares);
        uint256 maxWeth = curvePool.calc_withdraw_one_coin(maxLp, WETH_COIN_INDEX);
        if (wethOut >= maxWeth) return maxLp;

        uint256 estimated = (wethOut * maxLp + maxWeth - 1) / maxWeth;
        uint256 buffered = (estimated * 10_000 + (10_000 - withdrawBufferBps) - 1) / (10_000 - withdrawBufferBps);
        if (buffered > maxLp) return maxLp;
        return buffered == 0 ? 1 : buffered;
    }

    /// @dev The larger minimum binds: the absolute circuit breaker or the virtual-price bound.
    function _effectiveMinLpForWeth(uint256 wethAmount) internal view returns (uint256) {
        uint256 absoluteFloor = _minLpForWeth(wethAmount);
        uint256 virtualPriceFloor = _minLpForWethVP(wethAmount);
        return absoluteFloor > virtualPriceFloor ? absoluteFloor : virtualPriceFloor;
    }

    /// @dev The smaller maximum binds: the absolute circuit breaker or the virtual-price bound.
    function _effectiveMaxLpForWeth(uint256 wethAmount) internal view returns (uint256) {
        uint256 absoluteMax = _maxLpForWeth(wethAmount);
        uint256 virtualPriceMax = _maxLpForWethVP(wethAmount);
        return absoluteMax < virtualPriceMax ? absoluteMax : virtualPriceMax;
    }

    function _maxLpForWeth(uint256 wethAmount) internal view returns (uint256) {
        return Math.mulDiv(wethAmount, PRICE_SCALE, minWethPerCurveLp, Math.Rounding.Ceil) + LP_ROUNDING_TOLERANCE;
    }

    function _minLpForWeth(uint256 wethAmount) internal view returns (uint256) {
        return Math.mulDiv(wethAmount, minCurveLpPerWeth, PRICE_SCALE, Math.Rounding.Ceil);
    }

    /// @dev Swap-resistant allocation floor using the existing strategy slippage tolerance.
    function _minLpForWethVP(uint256 wethAmount) internal view returns (uint256) {
        uint256 virtualPrice = curvePool.get_virtual_price();
        require(virtualPrice > 0, "Zero virtual price");
        return Math.mulDiv(wethAmount, PRICE_SCALE * (10_000 - params.slippageBPS), virtualPrice * 10_000);
    }

    /// @dev Swap-resistant deallocation ceiling using the existing strategy slippage tolerance.
    function _maxLpForWethVP(uint256 wethAmount) internal view returns (uint256) {
        uint256 virtualPrice = curvePool.get_virtual_price();
        require(virtualPrice > 0, "Zero virtual price");
        return Math.mulDiv(wethAmount, PRICE_SCALE * 10_000, virtualPrice * (10_000 - params.slippageBPS), Math.Rounding.Ceil) + LP_ROUNDING_TOLERANCE;
    }

    function _ensoRoute(address outputToken, uint256 minOut, bytes memory ensoCalldata) internal returns (uint256 received) {
        require(ensoCalldata.length > 0, "Empty Enso calldata");

        uint256 balanceBefore = TokenUtils.safeBalanceOf(outputToken, address(this));
        (bool success,) = ensoRouter.call(ensoCalldata);
        require(success, "Enso route failed");

        received = TokenUtils.safeBalanceOf(outputToken, address(this)) - balanceBefore;
        if (received < minOut) revert InvalidAmount(minOut, received);
    }
}
