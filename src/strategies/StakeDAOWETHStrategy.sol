// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IStakeDAORewardVault, ICurveStableSwapPool} from "./interfaces/IStakeDAO.sol";

/**
 * @title StakeDAOWETHStrategy
 * @notice Allocates WETH into Stake DAO RewardVault shares and exits back to WETH.
 * @dev Direct path: WETH -> Curve LP -> RewardVault shares / reverse on exit.
 *      Swap path: single Enso route each way via `ActionType.swap`.
 */
contract StakeDAOWETHStrategy is MYTStrategy {
    uint256 public constant MAX_WITHDRAW_BUFFER_BPS = 650;
    int128 internal constant WETH_COIN_INDEX = 1;

    IERC20 public immutable weth;
    IStakeDAORewardVault public immutable rewardVault;
    ICurveStableSwapPool public immutable curvePool;
    address public immutable ensoRouter;
    uint256 public withdrawBufferBps;
    bool public canForceDeallocate;

    event WithdrawBufferBpsUpdated(uint256 newWithdrawBufferBps);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _rewardVault,
        address _curvePool,
        address _ensoRouter,
        uint256 _withdrawBufferBps
    ) MYTStrategy(_myt, _params) {
        require(_rewardVault != address(0), "Zero reward vault");
        require(_curvePool != address(0), "Zero curve pool");
        require(_ensoRouter != address(0), "Zero enso router");
        require(_withdrawBufferBps < MAX_WITHDRAW_BUFFER_BPS, "Withdraw buffer too high");

        weth = IERC20(MYT.asset());
        rewardVault = IStakeDAORewardVault(_rewardVault);
        curvePool = ICurveStableSwapPool(_curvePool);
        ensoRouter = _ensoRouter;
        withdrawBufferBps = _withdrawBufferBps;

        require(rewardVault.asset() == _curvePool, "Vault asset != curve LP");
    }

    function setWithdrawBufferBps(uint256 newWithdrawBufferBps) external onlyOwner {
        require(newWithdrawBufferBps < MAX_WITHDRAW_BUFFER_BPS, "Withdraw buffer too high");
        withdrawBufferBps = newWithdrawBufferBps;
        emit WithdrawBufferBpsUpdated(newWithdrawBufferBps);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(address(weth), amount);

        uint256 sharesBefore = rewardVault.balanceOf(address(this));

        uint256[] memory amounts = new uint256[](2);
        amounts[uint256(uint128(WETH_COIN_INDEX))] = amount;
        uint256 expectedLp = curvePool.calc_token_amount(amounts, true);
        uint256 minLpOut = _minAmountAfterSlippage(expectedLp);

        TokenUtils.safeApprove(address(weth), address(curvePool), amount);
        uint256 lpMinted = curvePool.add_liquidity(amounts, minLpOut, address(this));
        TokenUtils.safeApprove(address(weth), address(curvePool), 0);

        TokenUtils.safeApprove(address(curvePool), address(rewardVault), lpMinted);
        rewardVault.deposit(lpMinted, address(this), address(0));
        TokenUtils.safeApprove(address(curvePool), address(rewardVault), 0);

        uint256 sharesReceived = rewardVault.balanceOf(address(this)) - sharesBefore;
        uint256 wethValueReceived = _sharesToWeth(sharesReceived);
        uint256 minWethValue = _minWethAfterSlippage(amount);
        if (wethValueReceived < minWethValue) revert InvalidAmount(minWethValue, wethValueReceived);

        return amount;
    }

    function _allocate(uint256 amount, bytes memory ensoCalldata) internal override returns (uint256) {
        _ensureIdleBalance(address(weth), amount);

        uint256 sharesBefore = rewardVault.balanceOf(address(this));
        uint256 minSharesOut = _minSharesForWethIn(amount);

        TokenUtils.safeApprove(address(weth), ensoRouter, amount);
        _ensoRoute(address(rewardVault), minSharesOut, ensoCalldata);
        TokenUtils.safeApprove(address(weth), ensoRouter, 0);

        uint256 sharesReceived = rewardVault.balanceOf(address(this)) - sharesBefore;
        uint256 wethValueReceived = _sharesToWeth(sharesReceived);
        uint256 minWethValue = _sharesToWeth(minSharesOut);
        if (wethValueReceived < minWethValue) revert InvalidAmount(minWethValue, wethValueReceived);

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

        uint256 lpRedeemed = rewardVault.redeem(sharesToRedeem, address(this), address(this));

        TokenUtils.safeApprove(address(curvePool), address(curvePool), lpRedeemed);
        curvePool.remove_liquidity_one_coin(lpRedeemed, WETH_COIN_INDEX, shortfall, address(this));
        TokenUtils.safeApprove(address(curvePool), address(curvePool), 0);

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

        TokenUtils.safeApprove(address(rewardVault), ensoRouter, shares);
        _ensoRoute(address(weth), shortfall, ensoCalldata);
        TokenUtils.safeApprove(address(rewardVault), ensoRouter, 0);

        require(_idleAssets() >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        return _idleAssets() + _sharesToWeth(rewardVault.balanceOf(address(this)));
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(weth), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;
        uint256 maxWethFromShares = _sharesToWeth(rewardVault.balanceOf(address(this)));
        uint256 fundableFromPosition = remaining <= maxWethFromShares ? remaining : maxWethFromShares;
        return fromIdle + (fundableFromPosition * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut)
        internal
        override
        returns (uint256 rewardsClaimed)
    {
        if (rewardVault.earned(address(this), token) == 0) return 0;
        require(quote.length > 0, "params");

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = token;
        uint256 balanceBefore = TokenUtils.safeBalanceOf(token, address(this));

        rewardVault.claim(rewardTokens, address(this));

        uint256 rewardsReceived = TokenUtils.safeBalanceOf(token, address(this)) - balanceBefore;
        if (rewardsReceived == 0) return 0;
        emit RewardsClaimed(token, rewardsReceived);
        uint256 amountOut = dexSwap(MYT.asset(), token, IERC20(token).balanceOf(address(this)), minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), amountOut);
        return amountOut;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == address(weth);
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function _sharesToWeth(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        return curvePool.calc_withdraw_one_coin(rewardVault.convertToAssets(shares), WETH_COIN_INDEX);
    }

    function _minWethAfterSlippage(uint256 wethAmount) internal view returns (uint256) {
        return _minAmountAfterSlippage(wethAmount);
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
        uint256 buffered =
            (estimated * 10_000 + (10_000 - withdrawBufferBps) - 1) / (10_000 - withdrawBufferBps);
        if (buffered > maxLp) return maxLp;
        return buffered == 0 ? 1 : buffered;
    }

    function _ensoRoute(address outputToken, uint256 minOut, bytes memory ensoCalldata) internal {
        require(ensoCalldata.length > 0, "Empty Enso calldata");

        uint256 balanceBefore = TokenUtils.safeBalanceOf(outputToken, address(this));
        (bool success,) = ensoRouter.call(ensoCalldata);
        require(success, "Enso route failed");

        uint256 received = TokenUtils.safeBalanceOf(outputToken, address(this)) - balanceBefore;
        if (received < minOut) revert InvalidAmount(minOut, received);
    }
}
