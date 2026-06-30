// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IDepositAdapter {
    function depositWETHForWeETH(uint256 amount, address referral) external returns (uint256);
}

interface IRedemptionManager {
    struct RedemptionLimit {
        uint64 capacity;
        uint64 remaining;
        uint64 lastRefill;
        uint64 refillRate;
    }

    function canRedeem(uint256 amount, address token) external view returns (bool);
    function liquidityPool() external view returns (address);
    function previewRedeem(uint256 shares, address token) external view returns (uint256);
    function tokenToRedemptionInfo(address token)
        external
        view
        returns (RedemptionLimit memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl);
    function redeemWeEth(uint256 amount, address receiver, address outputToken) external;
}

interface ILiquidityPoolLike {
    function amountForShare(uint256 shares) external view returns (uint256);
    function sharesForAmount(uint256 amount) external view returns (uint256);
    function sharesForWithdrawalAmount(uint256 amount) external view returns (uint256);
}

interface IWeETH {
    function balanceOf(address account) external view returns (uint256);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256);
}

/**
 * @title EtherfiEETHMYTStrategy
 * @notice Allocates WETH into weETH via Ether.fi DepositAdapter and supports
 *         deallocation via Ether.fi instant redemption.
 *         instant redemption through the RedemptionManager.
 *         Also supports dex swaps for both allocation and deallocation.
 *
 */
contract EtherfiEETHMYTStrategy is OraclePricedSwapStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_GROSS_REDEEM_AMOUNT_BUFFER = 1e18;

    IDepositAdapter public immutable depositAdapter;
    IRedemptionManager public immutable redemptionManager;
    IWeETH public immutable weETH;
    IERC20 public immutable eETH;
    // address used to request native ETH instead of an ERC20 token.
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bool public canForceDeallocate = false;
    uint256 public grossRedeemAmountBuffer = 1;

    event GrossRedeemAmountBufferUpdated(uint256 grossRedeemAmountBuffer);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);


    constructor(
        address _myt,
        StrategyParams memory _params,
        address _eETH,
        address _weETH,
        address _depositAdapter,
        address _redemptionManager,
        address _weEthEthOracle,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _weEthEthOracle, _maxOracleStaleness) {
        require(_eETH != address(0), "Zero eETH address");
        require(_weETH != address(0), "Zero weETH address");
        require(_depositAdapter != address(0), "Zero deposit adapter address");
        require(_redemptionManager != address(0), "Zero redemption manager address");

        eETH = IERC20(_eETH);
        weETH = IWeETH(_weETH);
        depositAdapter = IDepositAdapter(_depositAdapter);
        redemptionManager = IRedemptionManager(_redemptionManager);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);
        TokenUtils.safeApprove(_asset(), address(depositAdapter), amount);
        depositAdapter.depositWETHForWeETH(amount, address(0));
        TokenUtils.safeApprove(_asset(), address(depositAdapter), 0);
        return amount;
    }

    /// @notice Deallocate via Ether.fi instant redemption (no queue delay).
    /// @dev This path is liquidity-dependent and reverts when `canRedeem(amount, ETH)` is false.
    /// @param amount WETH amount expected to be returned to vault.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        (, uint16 exitFeeInBps,) = _redemptionInfo();
        require(exitFeeInBps < BPS, "Invalid exit fee");
        uint256 weETHBalance = weETH.balanceOf(address(this));
        require(weETHBalance > 0, "No weETH available");

        uint256 weETHToRedeem = _weETHForNetShortfall(shortfall, exitFeeInBps, weETHBalance);
        uint256 grossRedeemAmount = weETH.getEETHByWeETH(weETHToRedeem);
        require(
            redemptionManager.canRedeem(grossRedeemAmount, ETH),
            "Cannot redeem. Instant redemption path is not available."
        );

        require(weETHToRedeem > 0, "No weETH to redeem");

        TokenUtils.safeApprove(address(weETH), address(redemptionManager), weETHToRedeem);
        uint256 ethBefore = address(this).balance;
        redemptionManager.redeemWeEth(weETHToRedeem, address(this), ETH);
        uint256 ethReceived = address(this).balance - ethBefore;
        TokenUtils.safeApprove(address(weETH), address(redemptionManager), 0);

        require(ethReceived >= shortfall, "Insufficient ETH redeemed");
        IWETH(MYT.asset()).deposit{value: ethReceived}();
        require(_idleAssets() >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _redemptionInfo() internal view returns (uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl) {
        (, exitFeeSplitToTreasuryInBps, exitFeeInBps, lowWatermarkInBpsOfTvl) = redemptionManager.tokenToRedemptionInfo(ETH);
    }

    function _weETHForGrossRedeem(uint256 grossRedeemAmount, uint256 weETHBalance) internal view returns (uint256) {
        uint256 weETHToRedeem = weETH.getWeETHByeETH(grossRedeemAmount);
        if (weETHToRedeem < weETHBalance && weETH.getEETHByWeETH(weETHToRedeem) < grossRedeemAmount) {
            weETHToRedeem += 1;
        }
        return weETHToRedeem;
    }

    function _weETHForNetShortfall(uint256 shortfall, uint256 exitFeeInBps, uint256 weETHBalance) internal view returns (uint256) {
        ILiquidityPoolLike liquidityPool = ILiquidityPoolLike(redemptionManager.liquidityPool());
        uint256 requiredNetShares = liquidityPool.sharesForWithdrawalAmount(shortfall);
        uint256 requiredGrossShares = Math.mulDiv(requiredNetShares, BPS, BPS - exitFeeInBps, Math.Rounding.Ceil);
        uint256 grossRedeemAmount = liquidityPool.amountForShare(requiredGrossShares);
        if (liquidityPool.sharesForAmount(grossRedeemAmount) < requiredGrossShares) {
            grossRedeemAmount += grossRedeemAmountBuffer;
        }

        uint256 weETHToRedeem = _weETHForGrossRedeem(grossRedeemAmount, weETHBalance);
        return weETHToRedeem;
    }

    function _previewNetEthFromWeETH(uint256 weETHAmount) internal view returns (uint256) {
        uint256 eETHAmount = weETH.getEETHByWeETH(weETHAmount);
        uint256 shares = ILiquidityPoolLike(redemptionManager.liquidityPool()).sharesForAmount(eETHAmount);
        return redemptionManager.previewRedeem(shares, ETH);
    }

    function _oracleToken() internal view override returns (address) {
        return address(weETH);
    }

    function _positionBalance() internal view override returns (uint256) {
        return weETH.balanceOf(address(this));
    }

    function _prepareOracleTokenForSwap(uint256 maxOracleTokenIn) internal override returns (uint256) {
        uint256 weETHBalance = weETH.balanceOf(address(this));
        return maxOracleTokenIn > weETHBalance ? weETHBalance : maxOracleTokenIn;
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function setGrossRedeemAmountBuffer(uint256 grossRedeemAmountBuffer_) external onlyOwner {
        require(grossRedeemAmountBuffer_ <= MAX_GROSS_REDEEM_AMOUNT_BUFFER, "Buffer too large");
        grossRedeemAmountBuffer = grossRedeemAmountBuffer_;
        emit GrossRedeemAmountBufferUpdated(grossRedeemAmountBuffer_);
    }

    receive() external payable {}
}
