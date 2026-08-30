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

    /// @notice Timestamp of the oldest destination debt report.
    function oldestDebtReporting() external view returns (uint256);

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
 * @notice Generic Tokemak auto vault strategy with rewarder staking.
 */
contract TokeAutoStrategy is MYTStrategy {
    using Math for uint256;

    uint256 internal constant BASIS_POINTS = 10_000;
    /// @dev Minimum shares to ensure possibleAssets > 0 in TokeAutoETH.redeem
    uint256 internal constant MIN_SHARES = 1e15;
    /// @dev Per redeem execution slippage tolerance for the direct path. This is the REAL
    /// round-trip cost of redeeming from the autoVault (queue + destination swaps), NOT the
    /// user-facing `params.slippageBPS` haircut. It bounds both the share over-redeem and the
    /// NAV-anchored output floor, so the worst-case loss on a direct deallocation is
    /// ~execToleranceBps of the NAV of the shares actually burned.
    uint256 public constant DEFAULT_EXEC_TOLERANCE_BPS = 25;
    /// @dev Hard upper bound for the configurable execution tolerance (mirrors slippage cap).
    uint256 internal constant MAX_EXEC_TOLERANCE_BPS = 650;
    /// @dev Tokemak: do not consume dest reports older than 1 day.
    uint256 public constant MAX_DEBT_REPORT_AGE = 1 days;
    /// @dev Default Deposit vs Withdraw purpose-spread ceiling. Honest is ~1 bp; PoC was ~2,720 bps.
    uint256 public constant DEFAULT_MAX_NAV_SPREAD_BPS = 100;
    /// @dev Owner can widen up to 100% to force mark-to-market if a real dest failure keeps spread elevated.
    uint256 internal constant MAX_NAV_SPREAD_BPS_CAP = BASIS_POINTS;

    IERC20 public immutable mytAsset;
    IERC4626Like public immutable autoVault;
    IMainRewarder public immutable rewarder;
    address public immutable tokeRewardsToken;
    IAutopilotRouterWithRoutes public immutable autopilotRouter;
    bool public canForceDeallocate;

    /// @notice Per-redeem execution slippage tolerance (bps) for the direct deallocation path.
    /// Set at construction and tunable by the owner via {setExecToleranceBps}.
    uint256 public execToleranceBps;
    /// @notice Max allowed |Deposit − Withdraw| / Withdraw (bps) for a report to be usable in {_totalValue}.
    /// @dev Defaults to {DEFAULT_MAX_NAV_SPREAD_BPS}; owner-tunable via {setMaxNavSpreadBps}.
    uint256 public maxNavSpreadBps;
    /// @notice Last usable Withdraw-purpose price per autoVault share, scaled by {FIXED_POINT_SCALAR}.
    /// @dev Snapshotted on allocate/deallocate while the report is usable. Fallback valuation is
    /// `shares * lastGoodSharePrice / FIXED_POINT_SCALAR` so share-count changes do not double-count idle.
    uint256 public lastGoodSharePrice;
    /// @notice Timestamp of the last {lastGoodSharePrice} write (any path). Lets ops alert on a
    /// fallback mark older than N days and see how stale a frozen valuation is.
    uint256 public lastSnapshotAt;

    event ExecToleranceBpsUpdated(uint256 newExecToleranceBps);
    event MaxNavSpreadBpsUpdated(uint256 newMaxNavSpreadBps);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    event LastGoodSharePriceUpdated(uint256 lastGoodSharePrice);
    event LastGoodSharePriceForcedDown(uint256 lastGoodSharePrice);

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
        maxNavSpreadBps = DEFAULT_MAX_NAV_SPREAD_BPS;
    }

    /// @notice Update the per redeem execution slippage tolerance for the direct deallocation path.
    function setExecToleranceBps(uint256 newExecToleranceBps) external onlyOwner {
        require(newExecToleranceBps < MAX_EXEC_TOLERANCE_BPS, "Exec tolerance too high");
        execToleranceBps = newExecToleranceBps;
        emit ExecToleranceBpsUpdated(newExecToleranceBps);
    }

    /// @notice Update the Deposit/Withdraw purpose spread ceiling used by _reportUsable.
    function setMaxNavSpreadBps(uint256 newMaxNavSpreadBps) external onlyOwner {
        require(newMaxNavSpreadBps <= MAX_NAV_SPREAD_BPS_CAP, "Nav spread too high");
        maxNavSpreadBps = newMaxNavSpreadBps;
        emit MaxNavSpreadBpsUpdated(newMaxNavSpreadBps);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    /// @notice Snapshot Withdraw PPS into {lastGoodSharePrice} while the report is usable.
    /// @dev Same write as allocate/deallocate.
    function snapshotSharePrice() external onlyOwner {
        require(_reportUsable(), "Report not usable");
        uint256 unit = _snapshotUnit();
        require(unit > 0, "No snapshot unit");
        lastGoodSharePrice = _shareValue(unit).mulDiv(FIXED_POINT_SCALAR, unit);
        lastSnapshotAt = block.timestamp;
        emit LastGoodSharePriceUpdated(lastGoodSharePrice);
    }

    /// @notice Owner override to lower {lastGoodSharePrice} 
    /// and mark to real value in case of genuine losses during an unsusable state.
    function forceMarkDown(uint256 newSharePrice) external onlyOwner {
        require(newSharePrice > 0, "Zero share price");
        require(newSharePrice <= lastGoodSharePrice, "Mark can only decrease");
        lastGoodSharePrice = newSharePrice;
        lastSnapshotAt = block.timestamp;
        emit LastGoodSharePriceForcedDown(newSharePrice);
    }

    /// @notice True when valuation consumes live Withdraw NAV; false when frozen at {lastGoodSharePrice}.
    function reportUsable() external view returns (bool) {
        return _reportUsable();
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
        _snapshotSharePrice();
        return assetsReceived;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 assetBalance = _idleAssets();
        if (assetBalance >= amount) {
            TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
            return amount;
        }
        return _deallocateFromVault(amount, assetBalance);
    }

    function _deallocateFromVault(uint256 amount, uint256 assetBalance) internal returns (uint256) {
        uint256 shortfall = amount - assetBalance;
        uint256 sharesNeeded;
        uint256 minOut;
        {
            // Over redeem only by the real execution tolerance (not the user-facing slippageBPS,
            // which is already applied once on the request side in `_previewAdjustedWithdraw`).
            uint256 tolerance = execToleranceBps;
            uint256 maxAssetIn = (shortfall * BASIS_POINTS + (BASIS_POINTS - tolerance) - 1)
                / (BASIS_POINTS - tolerance);
            uint256 totalAssetsForWithdraw = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
            uint256 totalSupply = autoVault.totalSupply();
            sharesNeeded = autoVault.convertToShares(
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
            minOut = Math.max(shortfall, expectedAssets * (BASIS_POINTS - tolerance) / BASIS_POINTS);

            if (sharesNeeded > directShares) {
                rewarder.withdraw(address(this), sharesNeeded - directShares, false);
            }
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
        _snapshotSharePrice();
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
        _snapshotSharePrice();
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        uint256 idle = _idleAssets();
        uint256 shares = rewarder.balanceOf(address(this)) + autoVault.balanceOf(address(this));
        if (shares == 0) return idle;
        if (_reportUsable()) return idle + _shareValue(shares);
        return idle + shares.mulDiv(lastGoodSharePrice, FIXED_POINT_SCALAR);
    }

    function _snapshotSharePrice() internal {
        if (!_reportUsable()) return;
        uint256 unit = _snapshotUnit();
        if (unit == 0) return;
        lastGoodSharePrice = _shareValue(unit).mulDiv(FIXED_POINT_SCALAR, unit);
        lastSnapshotAt = block.timestamp;
    }

    function _snapshotUnit() internal view returns (uint256) {
        uint256 shares = rewarder.balanceOf(address(this)) + autoVault.balanceOf(address(this));
        if (shares > 0) return shares;
        return autoVault.totalSupply() > 0 ? 1e18 : 0;
    }

    function _shareValue(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        return _redeemableAssets(shares);
    }

    function _reportUsable() internal view returns (bool) {
        uint256 oldest = autoVault.oldestDebtReporting();
        if (oldest > block.timestamp || block.timestamp - oldest > MAX_DEBT_REPORT_AGE) return false;

        uint256 depositNAV = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Deposit);
        uint256 withdrawNAV = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
        if (withdrawNAV == 0) return false;
        uint256 diff = depositNAV > withdrawNAV ? depositNAV - withdrawNAV : withdrawNAV - depositNAV;
        return diff * BASIS_POINTS / withdrawNAV <= maxNavSpreadBps;
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    /// @notice Live Withdraw purpose NAV of shares per the autoVault's own accounting.
    /// @dev Anchors redeem (execution) floors to the cached withdraw mark of the shares being burned.
    function _redeemableAssets(uint256 shares) internal view returns (uint256) {
        return autoVault.convertToAssets(
            shares,
            autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoVault.totalSupply(),
            IERC4626Like.Rounding.Down
        );
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 totalShares = rewarder.balanceOf(address(this)) + autoVault.balanceOf(address(this));
        uint256 assets;

        if (_reportUsable()) {
            uint256 withdrawNAV = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
            uint256 supply = autoVault.totalSupply();
            uint256 sharesNeeded =
                autoVault.convertToShares(amount, withdrawNAV, supply, IERC4626Like.Rounding.Up);
            if (sharesNeeded > totalShares) sharesNeeded = totalShares;
            assets = autoVault.convertToAssets(sharesNeeded, withdrawNAV, supply, IERC4626Like.Rounding.Down);
        } else if (lastGoodSharePrice == 0) {
            uint256 idle = _idleAssets();
            assets = amount < idle ? amount : idle;
        } else {
            uint256 sharesNeeded = amount.mulDiv(FIXED_POINT_SCALAR, lastGoodSharePrice, Math.Rounding.Ceil);
            if (sharesNeeded > totalShares) sharesNeeded = totalShares;
            assets = sharesNeeded.mulDiv(lastGoodSharePrice, FIXED_POINT_SCALAR);
        }

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
