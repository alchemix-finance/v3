// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IMintController {
    function assetToReceipt(uint256 assetAmount) external view returns (uint256);
}

interface ISIUSD {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

interface IRedeemController {
    function receiptToAsset(uint256 receiptAmount) external view returns (uint256);
}

interface IInfiniFiGateway {
    function mintAndStake(address to, uint256 amount) external returns (uint256);
    function unstake(address to, uint256 stakedTokens) external returns (uint256);
    function redeem(address to, uint256 amount, uint256 minAssetsOut) external returns (uint256);
}

/**
 * @title SiUSDStrategy
 * @notice Allocates USDC into staked InfiniFi siUSD shares and supports:
 *         1. direct deallocation via siUSD -> iUSD -> USDC redeem
 *         2. unwrap-and-swap fallback via siUSD -> iUSD -> USDC swap
 */
contract SiUSDStrategy is OraclePricedSwapStrategy {
    uint256 internal constant DIRECT_PREVIEW_BUFFER = 100;

    IERC20 public immutable usdc;
    IERC20 public immutable iUSD;
    ISIUSD public immutable siUSD;
    IMintController public immutable mintController;
    IRedeemController public immutable redeemController;
    IInfiniFiGateway public immutable gateway;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _usdc,
        address _iUSD,
        address _siUSD,
        address _gateway,
        address _mintController,
        address _redeemController,
        address _pricedTokenEthOracle,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _pricedTokenEthOracle, _maxOracleStaleness) {
        require(_usdc != address(0), "Zero USDC address");
        require(_iUSD != address(0), "Zero iUSD address");
        require(_siUSD != address(0), "Zero siUSD address");
        require(_gateway != address(0), "Zero gateway address");
        require(_mintController != address(0), "Zero mint controller address");
        require(_redeemController != address(0), "Zero redeem controller address");
        require(_usdc == MYT.asset(), "Vault asset != MYT asset");

        usdc = IERC20(_usdc);
        iUSD = IERC20(_iUSD);
        siUSD = ISIUSD(_siUSD);
        mintController = IMintController(_mintController);
        redeemController = IRedeemController(_redeemController);
        gateway = IInfiniFiGateway(_gateway);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        TokenUtils.safeApprove(_asset(), address(gateway), 0);
        TokenUtils.safeApprove(_asset(), address(gateway), amount);
        uint256 sharesReceived = gateway.mintAndStake(address(this), amount);
        TokenUtils.safeApprove(_asset(), address(gateway), 0);
        require(sharesReceived > 0, "No siUSD received");
        return amount;
    }

    function _allocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 iUsdNeeded = mintController.assetToReceipt(shortfall);

            uint256 sharesToUnstake = siUSD.previewWithdraw(iUsdNeeded);
            uint256 siUsdBalance = siUSD.balanceOf(address(this));
            if (sharesToUnstake > siUsdBalance) sharesToUnstake = siUsdBalance;
            require(sharesToUnstake > 0, "No siUSD to unstake");

            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);
            TokenUtils.safeApprove(address(siUSD), address(gateway), sharesToUnstake);
            gateway.unstake(address(this), sharesToUnstake);
            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);

            uint256 iUsdBalance = TokenUtils.safeBalanceOf(address(iUSD), address(this));
            uint256 iUsdToRedeem = iUsdNeeded > iUsdBalance ? iUsdBalance : iUsdNeeded;
            require(iUsdToRedeem > 0, "No iUSD to redeem");

            TokenUtils.safeApprove(address(iUSD), address(gateway), 0);
            TokenUtils.safeApprove(address(iUSD), address(gateway), iUsdToRedeem);
            gateway.redeem(address(this), iUsdToRedeem, shortfall);
            TokenUtils.safeApprove(address(iUSD), address(gateway), 0);

            idleBalance = _idleAssets();
            if (idleBalance < amount) revert InsufficientBalance(amount, idleBalance);
        }

        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }


    function _deallocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _oracleToken() internal view override returns (address) {
        return address(iUSD);
    }

    function _positionBalance() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(iUSD), address(this)) + siUSD.convertToAssets(siUSD.balanceOf(address(this)));
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 idleUsdc = _idleAssets();
        uint256 totalReceiptBalance = _positionBalance();
        if (totalReceiptBalance == 0) return idleUsdc;
        return idleUsdc + redeemController.receiptToAsset(totalReceiptBalance);
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) return amount;

        uint256 availableReceipts = _positionBalance();
        if (availableReceipts == 0) return idleBalance;

        uint256 shortfall = amount - idleBalance;
        uint256 receiptsNeeded = mintController.assetToReceipt(shortfall);
        uint256 receiptsToRedeem = receiptsNeeded < availableReceipts ? receiptsNeeded : availableReceipts;
        if (receiptsToRedeem == 0) return idleBalance;

        uint256 redeemableAssets = _applyDirectPreviewDiscount(redeemController.receiptToAsset(receiptsToRedeem));
        uint256 totalAvailable = idleBalance + redeemableAssets;
        uint256 maxPreview = amount > DIRECT_PREVIEW_BUFFER + 1 ? amount - DIRECT_PREVIEW_BUFFER - 1 : idleBalance;
        return totalAvailable < maxPreview ? totalAvailable : maxPreview;
    }

    function _applyDirectPreviewDiscount(uint256 assetAmount) internal view returns (uint256) {
        uint256 discounted = assetAmount - (assetAmount * params.slippageBPS / 10_000);
        if (discounted <= DIRECT_PREVIEW_BUFFER + 1) return 0;
        return discounted - DIRECT_PREVIEW_BUFFER - 1;
    }

    function _prepareOracleTokenForSwap(uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _prepareIntermediateForSwap(uint256 maxOracleTokenIn, uint256 minIntermediateOutAmount)
        internal
        override
        returns (address sellToken, uint256 sellAmount)
    {
        if (minIntermediateOutAmount == 0) {
            sellToken = address(iUSD);
            return (sellToken, 0);
        }

        require(minIntermediateOutAmount <= maxOracleTokenIn, "Intermediate exceeds max oracle token in");

        uint256 iUsdBalance = TokenUtils.safeBalanceOf(address(iUSD), address(this));
        sellAmount = iUsdBalance;

        if (sellAmount < minIntermediateOutAmount) {
            uint256 missingIUsd = minIntermediateOutAmount - sellAmount;
            uint256 sharesNeeded = siUSD.previewWithdraw(missingIUsd);
            uint256 sharesBalance = siUSD.balanceOf(address(this));
            require(sharesNeeded > 0, "No siUSD to unstake");
            require(sharesNeeded <= sharesBalance, "Insufficient siUSD balance");

            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);
            TokenUtils.safeApprove(address(siUSD), address(gateway), sharesNeeded);
            gateway.unstake(address(this), sharesNeeded);
            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);

            sellAmount = TokenUtils.safeBalanceOf(address(iUSD), address(this));
        }

        require(sellAmount >= minIntermediateOutAmount, "Insufficient intermediate out");
        sellToken = address(iUSD);
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(iUSD) || token == address(siUSD);
    }
}
