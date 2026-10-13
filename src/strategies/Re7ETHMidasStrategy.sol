// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @notice Midas `DataFeed` — returns the mToken/asset rate scaled to 1e18.
interface IMidasDataFeed {
    function getDataInBase18() external view returns (uint256);
}

/// @notice Midas `DepositVault` — mints mTokens against a payment token at oracle NAV.
interface IMidasDepositVault {
    function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId) external;
    function minAmount() external view returns (uint256);
}

/// @notice Midas `RedemptionVault` — burns mTokens for a payment token at oracle NAV.
interface IMidasRedemptionVault {
    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;
    function tokensConfig(address token) external view returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
    function instantFee() external view returns (uint256);
    function instantDailyLimit() external view returns (uint256);
    function dailyLimits(uint256 day) external view returns (uint256);
    function minAmount() external view returns (uint256);
}

/**
 * @title Re7ETHMidasStrategy
 * @notice Allocates WETH into the Re7ETH tokenized fund (Midas) on Optimism.
 *
 * Only the instant mint / instant redeem paths are supported. 
 */
contract Re7ETHMidasStrategy is MYTStrategy {
    uint256 internal constant MIDAS_ONE_HUNDRED_PERCENT = 10_000;
    uint256 internal constant WAD = 1e18;

    address public immutable weth;
    address public immutable re7ETH;
    IMidasDepositVault public immutable depositVault;
    IMidasRedemptionVault public immutable redemptionVault;
    IMidasDataFeed public immutable dataFeed;

    bool public canForceDeallocate;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);

    constructor(address _myt, StrategyParams memory _params, address _re7ETH, address _depositVault, address _redemptionVault, address _dataFeed)
        MYTStrategy(_myt, _params)
    {
        require(_re7ETH != address(0), "Zero Re7ETH address");
        require(_depositVault != address(0), "Zero deposit vault address");
        require(_redemptionVault != address(0), "Zero redemption vault address");
        require(_dataFeed != address(0), "Zero data feed address");

        weth = MYT.asset();
        re7ETH = _re7ETH;
        depositVault = IMidasDepositVault(_depositVault);
        redemptionVault = IMidasRedemptionVault(_redemptionVault);
        dataFeed = IMidasDataFeed(_dataFeed);

        // Sanity check the feed is live and that WETH is an accepted redemption token.
        require(dataFeed.getDataInBase18() > 0, "Invalid NAV");
        (address wethFeed,,,) = redemptionVault.tokensConfig(weth);
        require(wethFeed != address(0), "WETH not redeemable");
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    /// @dev Amounts that would mint fewer mTokens than the Midas minimum are held idle instead of reverting
    ///      they remain part of `_totalValue()` and are served first on deallocation.
    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(weth, amount);

        if (_assetToMTokenDown(amount) < depositVault.minAmount()) return amount;

        uint256 minAssetsOut = (amount * (MIDAS_ONE_HUNDRED_PERCENT - params.slippageBPS)) / MIDAS_ONE_HUNDRED_PERCENT;
        uint256 minMTokenOut = _assetToMTokenDown(minAssetsOut);
        if (minMTokenOut == 0) minMTokenOut = 1;

        uint256 mTokenBefore = _positionBalance();
        TokenUtils.safeApprove(weth, address(depositVault), amount);
        depositVault.depositInstant(weth, amount, minMTokenOut, bytes32(0));
        TokenUtils.safeApprove(weth, address(depositVault), 0);
        require(_positionBalance() > mTokenBefore, "No Re7ETH received");

        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;

            uint256 mTokenIn = _mTokenInForAssetsOut(shortfall);
            uint256 minRedeem = redemptionVault.minAmount();
            if (mTokenIn < minRedeem) mTokenIn = minRedeem;

            uint256 mTokenBalance = _positionBalance();
            if (mTokenIn > mTokenBalance) revert InsufficientBalance(mTokenIn, mTokenBalance);

            TokenUtils.safeApprove(re7ETH, address(redemptionVault), mTokenIn);
            redemptionVault.redeemInstant(weth, mTokenIn, shortfall);
            TokenUtils.safeApprove(re7ETH, address(redemptionVault), 0);

            idleBalance = _idleAssets();
            if (idleBalance < amount) revert InsufficientBalance(amount, idleBalance);
        }

        TokenUtils.safeApprove(weth, msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 mTokenBalance = _positionBalance();
        if (mTokenBalance == 0) return _idleAssets();
        return _idleAssets() + _mTokenToAsset(mTokenBalance);
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(weth, address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) return amount;

        uint256 remaining = amount - idleBalance;
        uint256 available = _instantRedeemableAssets();
        uint256 fundable = remaining < available ? remaining : available;

        return idleBalance + (fundable * (MIDAS_ONE_HUNDRED_PERCENT - params.slippageBPS)) / MIDAS_ONE_HUNDRED_PERCENT;
    }

    /// @notice WETH that can be pulled right now via `redeemInstant`, net of Midas fees and bounded by
    ///         the redemption vault's liquidity, daily limit and per token allowance.
    /// @dev Every redeem sends at least `minAmount` gross mTokens (see `_deallocate`), so any cap that cannot
    ///      absorb a minimum size redeem makes the position non withdrawable right now.
    function _instantRedeemableAssets() internal view returns (uint256) {
        uint256 minRedeem = redemptionVault.minAmount();
        uint256 mTokenBalance = _positionBalance();
        if (mTokenBalance < minRedeem) return 0;

        uint256 feeBps = _redeemFeeBps();
        uint256 fromPosition = _netAssetsForGrossMToken(mTokenBalance, feeBps);

        // Daily limit is consumed in gross mTokens.
        uint256 dailyLimit = redemptionVault.instantDailyLimit();
        if (dailyLimit != type(uint256).max) {
            uint256 dailyUsed = redemptionVault.dailyLimits(block.timestamp / 1 days);
            if (dailyUsed >= dailyLimit || dailyLimit - dailyUsed < minRedeem) return 0;
            uint256 headroomAssets = _netAssetsForGrossMToken(dailyLimit - dailyUsed, feeBps);
            if (headroomAssets < fromPosition) fromPosition = headroomAssets;
        }

        // Per token allowance is consumed in gross WETH (before fee).
        (,, uint256 tokenAllowance,) = redemptionVault.tokensConfig(weth);
        if (tokenAllowance != type(uint256).max) {
            if (tokenAllowance < _mTokenToAsset(minRedeem)) return 0;
            uint256 allowanceNet = tokenAllowance - (tokenAllowance * feeBps) / MIDAS_ONE_HUNDRED_PERCENT;
            if (allowanceNet < fromPosition) fromPosition = allowanceNet;
        }

        // Instant redemptions are paid from the redemption vault's own WETH balance.
        uint256 vaultLiquidity = TokenUtils.safeBalanceOf(weth, address(redemptionVault));
        if (vaultLiquidity < _netAssetsForGrossMToken(minRedeem, feeBps)) return 0;
        if (vaultLiquidity < fromPosition) fromPosition = vaultLiquidity;

        return fromPosition;
    }

    function _netAssetsForGrossMToken(uint256 grossMToken, uint256 feeBps) internal view returns (uint256) {
        uint256 netMToken = grossMToken - (grossMToken * feeBps) / MIDAS_ONE_HUNDRED_PERCENT;
        return _mTokenToAsset(netMToken);
    }

    function _positionBalance() internal view returns (uint256) {
        return TokenUtils.safeBalanceOf(re7ETH, address(this));
    }

    function _nav() internal view returns (uint256) {
        return dataFeed.getDataInBase18();
    }

    function _redeemFeeBps() internal view returns (uint256 feeBps) {
        (, uint256 tokenFee,,) = redemptionVault.tokensConfig(weth);
        feeBps = tokenFee + redemptionVault.instantFee();
        if (feeBps > MIDAS_ONE_HUNDRED_PERCENT) feeBps = MIDAS_ONE_HUNDRED_PERCENT;
    }

    function _mTokenToAsset(uint256 mTokenAmount) internal view returns (uint256) {
        return (mTokenAmount * _nav()) / WAD;
    }

    function _assetToMTokenDown(uint256 assetAmount) internal view returns (uint256) {
        return (assetAmount * WAD) / _nav();
    }

    function _assetToMTokenUp(uint256 assetAmount) internal view returns (uint256) {
        uint256 nav = _nav();
        return (assetAmount * WAD + nav - 1) / nav;
    }

    /// @dev Gross mTokens to send to `redeemInstant` so that, after Midas fees, at least `assetsOut` WETH is paid.
    function _mTokenInForAssetsOut(uint256 assetsOut) internal view returns (uint256) {
        uint256 netMToken = _assetToMTokenUp(assetsOut);
        uint256 feeBps = _redeemFeeBps();
        if (feeBps == 0) return netMToken;
        uint256 denominator = MIDAS_ONE_HUNDRED_PERCENT - feeBps;
        return (netMToken * MIDAS_ONE_HUNDRED_PERCENT + denominator - 1) / denominator;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == weth || token == re7ETH;
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }
}
