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

struct TokeSwapRoute {
    address fromToken;
    address toToken;
    address target;
    bytes data;
}

struct TokeRedeemParams {
    uint256 minAmountOut;
    TokeSwapRoute[] customRoutes;
}

interface IAutopilotRouterWithRoutes {
    function redeem(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut
    ) external payable returns (uint256 amountOut);

    function redeemWithRoutes(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut,
        TokeSwapRoute[] calldata customRoutes
    ) external payable returns (uint256 amountOut);
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
    /// @dev Per-redeem execution slippage tolerance for the direct path. This is the REAL
    /// round-trip cost of redeeming from the autoVault (queue + destination swaps), NOT the
    /// user-facing `params.slippageBPS` haircut. It bounds both the share over-redeem and the
    /// NAV-anchored output floor, so the worst-case loss on a direct deallocation is
    /// ~execToleranceBps of the NAV of the shares actually burned.
    /// @dev Empirical basis (wstETH-backed autoETH autopool, mainnet): honest direct redeems cost
    /// ~0–4.5 bps for sizes up to 1,500 WETH across ~4 weeks of blocks; 25 bps gives ~5x headroom.
    /// Re-validate before reusing on a thinner or less tightly-pegged autopool.
    uint256 public constant DEFAULT_EXEC_TOLERANCE_BPS = 25;
    /// @dev Hard upper bound for the configurable execution tolerance (mirrors slippage cap).
    uint256 internal constant MAX_EXEC_TOLERANCE_BPS = 650;

    IERC20 public immutable mytAsset;
    IERC4626Like public immutable autoVault;
    IMainRewarder public immutable rewarder;
    address public immutable tokeRewardsToken;
    IAutopilotRouterWithRoutes public immutable autopilotRouter;
    bool public canForceDeallocate;

    /// @notice Per-redeem execution slippage tolerance (bps) for the direct deallocation path.
    /// Set at construction and tunable by the owner via {setExecToleranceBps}.
    uint256 public execToleranceBps;

    event ExecToleranceBpsUpdated(uint256 newExecToleranceBps);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _asset,
        address _autoVault,
        address _rewarder,
        address _tokeRewardsToken,
        address _autopilotRouter,
        uint256 _execToleranceBps
    ) MYTStrategy(_myt, _params) {
        require(_asset == MYT.asset(), "Vault asset != MYT asset");
        require(_tokeRewardsToken != address(0), "Invalid rewards token");
        require(_autopilotRouter != address(0), "Zero autopilot router");
        require(_execToleranceBps < MAX_EXEC_TOLERANCE_BPS, "Exec tolerance too high");

        mytAsset = IERC20(_asset);
        autoVault = IERC4626Like(_autoVault);
        rewarder = IMainRewarder(_rewarder);
        tokeRewardsToken = _tokeRewardsToken;
        autopilotRouter = IAutopilotRouterWithRoutes(_autopilotRouter);
        execToleranceBps = _execToleranceBps;
    }

    /// @notice Update the per-redeem execution slippage tolerance for the direct deallocation path.
    function setExecToleranceBps(uint256 newExecToleranceBps) external onlyOwner {
        require(newExecToleranceBps < MAX_EXEC_TOLERANCE_BPS, "Exec tolerance too high");
        execToleranceBps = newExecToleranceBps;
        emit ExecToleranceBpsUpdated(newExecToleranceBps);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
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
        if (assetBalance >= amount) {
            TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - assetBalance;
        // Over-redeem only by the real execution tolerance (not the user-facing slippageBPS,
        // which is already applied once on the request side in `_previewAdjustedWithdraw`).
        uint256 tolerance = execToleranceBps;
        uint256 maxAssetIn = (shortfall * BASIS_POINTS + (BASIS_POINTS - tolerance) - 1)
            / (BASIS_POINTS - tolerance);
        uint256 totalAssetsForWithdraw = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
        uint256 totalSupply = autoVault.totalSupply();
        uint256 sharesNeeded = autoVault.convertToShares(
            maxAssetIn,
            totalAssetsForWithdraw,
            totalSupply,
            IERC4626Like.Rounding.Up
        );

        uint256 directShares = autoVault.balanceOf(address(this));
        uint256 totalSharesAvailable = directShares + rewarder.balanceOf(address(this));
        sharesNeeded = Math.max(sharesNeeded, MIN_SHARES);
        if (sharesNeeded > totalSharesAvailable) sharesNeeded = totalSharesAvailable;
        require(sharesNeeded > 0, "No shares available");

        // Anchor the redeem floor to the NAV of the shares actually being burned, minus the
        // execution tolerance. This bounds the worst-case loss to ~EXEC_TOLERANCE_BPS of NAV,
        // regardless of how much `shortfall` differs from that NAV.
        uint256 expectedAssets = _redeemableAssets(sharesNeeded);
        require(expectedAssets > 0, "Zero redeemable assets");
        uint256 minOut = Math.max(shortfall, expectedAssets * (BASIS_POINTS - tolerance) / BASIS_POINTS);

        if (sharesNeeded > directShares) {
            rewarder.withdraw(address(this), sharesNeeded - directShares, false);
        }

        require(autoVault.balanceOf(address(this)) >= sharesNeeded, "Insufficient unstaked shares");

        TokenUtils.safeApprove(address(autoVault), address(autopilotRouter), sharesNeeded);
        uint256 balanceBefore = TokenUtils.safeBalanceOf(address(mytAsset), address(this));
        autopilotRouter.redeem(IERC4626(address(autoVault)), address(this), sharesNeeded, minOut);
        uint256 pulled = TokenUtils.safeBalanceOf(address(mytAsset), address(this)) - balanceBefore;
        TokenUtils.safeApprove(address(autoVault), address(autopilotRouter), 0);

        require(pulled >= shortfall, "Insufficient redeem output");
        require(TokenUtils.safeBalanceOf(address(mytAsset), address(this)) >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _deallocate(uint256 amount, bytes memory data) internal virtual override returns (uint256) {
        uint256 assetBalance = _idleAssets();
        if (assetBalance >= amount) {
            TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
            return amount;
        }

        require(address(autopilotRouter) != address(0), "Zero autopilot router");
        TokeRedeemParams memory redeemParams = abi.decode(data, (TokeRedeemParams));

        uint256 shortfall = amount - assetBalance;
        require(redeemParams.minAmountOut >= shortfall, "Min out below shortfall");

        uint256 totalAssetsForWithdraw = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
        uint256 totalSupply = autoVault.totalSupply();
        uint256 sharesNeeded = autoVault.convertToShares(
            shortfall,
            totalAssetsForWithdraw,
            totalSupply,
            IERC4626Like.Rounding.Up
        );

        uint256 directShares = autoVault.balanceOf(address(this));
        uint256 totalSharesAvailable = directShares + rewarder.balanceOf(address(this));
        sharesNeeded = Math.max(sharesNeeded, MIN_SHARES);
        if (sharesNeeded > totalSharesAvailable) sharesNeeded = totalSharesAvailable;

        require(sharesNeeded > 0, "No shares available");
        require(
            autoVault.convertToAssets(sharesNeeded, totalAssetsForWithdraw, totalSupply, IERC4626Like.Rounding.Down) > 0,
            "Zero redeemable assets"
        );

        if (sharesNeeded > directShares) {
            rewarder.withdraw(address(this), sharesNeeded - directShares, false);
        }

        require(autoVault.balanceOf(address(this)) >= sharesNeeded, "Insufficient unstaked shares");

        TokenUtils.safeApprove(address(autoVault), address(autopilotRouter), sharesNeeded);
        uint256 balanceBefore = TokenUtils.safeBalanceOf(address(mytAsset), address(this));
        autopilotRouter.redeemWithRoutes(
            IERC4626(address(autoVault)),
            address(this),
            sharesNeeded,
            redeemParams.minAmountOut,
            redeemParams.customRoutes
        );
        uint256 received = TokenUtils.safeBalanceOf(address(mytAsset), address(this)) - balanceBefore;
        TokenUtils.safeApprove(address(autoVault), address(autopilotRouter), 0);

        require(received >= shortfall, "Insufficient redeem output");
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

    /// @notice Withdraw-purpose NAV of `shares` per the autoVault's own accounting.
    /// @dev Used to anchor redeem floors to the fair value of the shares being burned,
    /// rather than to the caller-requested amount. The Withdraw purpose uses Tokemak's
    /// conservative (floor) valuation, which is not moved by spot-AMM manipulation.
    function _redeemableAssets(uint256 shares) internal view returns (uint256) {
        return autoVault.convertToAssets(
            shares,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Down
        );
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

    function _canForceDeallocate() internal view virtual override returns (bool) {
        return canForceDeallocate;
    }
}
