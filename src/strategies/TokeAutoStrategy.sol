// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {IMainRewarder} from "./interfaces/ITokemac.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC4626Like is IERC4626 {
    function convertToShares(uint256 assets, uint256 totalAssetsForPurpose, uint256 supply, Rounding rounding)
        external
        view
        returns (uint256 shares);

    function convertToAssets(uint256 shares, uint256 totalAssetsForPurpose, uint256 supply, Rounding rounding)
        external
        view
        returns (uint256 assets);

    function totalAssets(TotalAssetPurpose purpose) external view returns (uint256);

    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    enum TotalAssetPurpose {
        Global,
        Deposit,
        Withdraw
    }
}

/**
 * @title TokeAutoStrategy
 * @notice Generic Tokemak auto-vault strategy with rewarder staking.
 */
contract TokeAutoStrategy is MYTStrategy {
    using Math for uint256;

    uint256 internal constant BASIS_POINTS = 10_000;
    /// @dev Minimum shares to ensure possibleAssets > 0 in TokeAutoETH.redeem
    uint256 internal constant MIN_SHARES = 1e15;

    IERC20 public immutable mytAsset;
    IERC4626Like public immutable autoVault;
    IMainRewarder public immutable rewarder;
    address public immutable tokeRewardsToken;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _asset,
        address _autoVault,
        address _rewarder,
        address _tokeRewardsToken
    ) MYTStrategy(_myt, _params) {
        require(_asset == MYT.asset(), "Vault asset != MYT asset");
        require(_tokeRewardsToken != address(0), "Invalid rewards token");

        mytAsset = IERC20(_asset);
        autoVault = IERC4626Like(_autoVault);
        rewarder = IMainRewarder(_rewarder);
        tokeRewardsToken = _tokeRewardsToken;
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);

        TokenUtils.safeApprove(address(mytAsset), address(autoVault), amount);
        uint256 shares = autoVault.deposit(amount, address(this));

        uint256 assetsReceived = autoVault.convertToAssets(
            shares,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        require(assetsReceived >= amount * (BASIS_POINTS - params.slippageBPS) / BASIS_POINTS, "Deposit value below minimum");

        TokenUtils.safeApprove(address(autoVault), address(rewarder), shares);
        rewarder.stake(address(this), shares);
        return assetsReceived;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 assetBalance = _idleAssets();

        if (assetBalance < amount) {
            uint256 shortfall = amount - assetBalance;
            uint256 totalPulled;

            // Iteratively redeem until we've pulled enough assets.
            // TokeAutoETH.redeem may return fewer assets than convertToAssets suggests due to slippage/recoup.
            for (totalPulled = 0; totalPulled < shortfall;) {
                uint256 totalAssetsForWithdraw = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
                uint256 totalSupply = autoVault.totalSupply();

                uint256 sharesNeeded = autoVault.convertToShares(
                    shortfall - totalPulled,
                    totalAssetsForWithdraw,
                    totalSupply,
                    IERC4626Like.Rounding.Up
                );

                // Ensure minimum shares and cap to available
                uint256 directShares = autoVault.balanceOf(address(this));
                uint256 totalSharesAvailable = directShares + rewarder.balanceOf(address(this));
                sharesNeeded = Math.max(sharesNeeded, MIN_SHARES);
                if (sharesNeeded > totalSharesAvailable) sharesNeeded = totalSharesAvailable;

                // Break if no shares or would result in zero possibleAssets
                if (sharesNeeded == 0) break;
                if (autoVault.convertToAssets(sharesNeeded, totalAssetsForWithdraw, totalSupply, IERC4626Like.Rounding.Down) == 0) break;

                // Unstake if needed
                if (sharesNeeded > directShares) {
                    rewarder.withdraw(address(this), sharesNeeded - directShares, false);
                }

                uint256 balanceBefore = TokenUtils.safeBalanceOf(address(mytAsset), address(this));
                autoVault.redeem(sharesNeeded, address(this), address(this));
                uint256 pulled = TokenUtils.safeBalanceOf(address(mytAsset), address(this)) - balanceBefore;

                if (pulled == 0) break;
                totalPulled += pulled;
            }
        }

        require(TokenUtils.safeBalanceOf(address(mytAsset), address(this)) >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }
        
    function _totalValue() internal view virtual override returns (uint256) {
        uint256 shares = rewarder.balanceOf(address(this)) + autoVault.balanceOf(address(this));
        if (shares == 0) return _idleAssets();

        uint256 assets = autoVault.convertToAssets(
            shares,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return _idleAssets() + assets;
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 sharesNeeded = autoVault.convertToShares(
            amount,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Up
        );
        uint256 totalShares = rewarder.balanceOf(address(this)) + autoVault.balanceOf(address(this));
        if (sharesNeeded > totalShares) sharesNeeded = totalShares;

        uint256 assets = autoVault.convertToAssets(
            sharesNeeded,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return assets - (assets * params.slippageBPS / BASIS_POINTS);
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut)
        internal
        virtual
        override
        returns (uint256 rewardsClaimed)
    {
        require(token == tokeRewardsToken && quote.length > 0, "params");
        uint256 rewardsBalanceBefore = TokenUtils.safeBalanceOf(token, address(this));
        bool claimExtra = rewarder.allowExtraRewards();
        rewarder.getReward(address(this), address(this), claimExtra);
        uint256 rewardsReceived = TokenUtils.safeBalanceOf(token, address(this)) - rewardsBalanceBefore;
        if (rewardsReceived == 0) return 0;

        bool stakingDisabled = rewarder.rewardToken() != tokeRewardsToken || rewarder.tokeLockDuration() == 0;
        if (!stakingDisabled) return 0;

        emit RewardsClaimed(address(token), rewardsReceived);
        uint256 amountOut = dexSwap(MYT.asset(), token, IERC20(token).balanceOf(address(this)), minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), amountOut);
        return amountOut;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == MYT.asset() || token == address(autoVault);
    }


}
