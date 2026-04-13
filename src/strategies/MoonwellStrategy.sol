// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function accrueInterest() external returns (uint);
}

interface IComptroller {
    function claimReward() external;
}

interface IWETH {
    function deposit() external payable;
}

/**
 * @title MoonwellStrategy
 * @notice Generic deployable strategy for Moonwell mToken integrations.
 */
contract MoonwellStrategy is MYTStrategy {
    using Math for uint256;

    IERC20 public immutable mytAsset;
    IMToken public immutable mToken;
    IERC20 public immutable rewardToken;
    IComptroller public immutable comptroller;
    bool public immutable usePostRedeemETHWrap;

    error MoonwellStrategyMintFailed(uint256 errorCode);
    error MoonwellStrategyRedeemFailed(uint256 errorCode);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _mytAsset,
        address _mToken,
        address _comptroller,
        address _rewardToken,
        bool _usePostRedeemETHWrap
    ) MYTStrategy(_myt, _params) {
        mytAsset = IERC20(_mytAsset);
        mToken = IMToken(_mToken);
        comptroller = IComptroller(_comptroller);
        rewardToken = IERC20(_rewardToken);
        usePostRedeemETHWrap = _usePostRedeemETHWrap;
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);
        
        TokenUtils.safeApprove(address(mytAsset), address(mToken), amount);
        uint256 mTokenBalanceBefore = mToken.balanceOf(address(this));
        uint256 errorCode = mToken.mint(amount);
        if (errorCode != 0) revert MoonwellStrategyMintFailed(errorCode);
        
        uint256 mTokensMinted = mToken.balanceOf(address(this)) - mTokenBalanceBefore;
        return (mTokensMinted * mToken.exchangeRateStored()) / 1e18;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        require(mToken.accrueInterest() == uint(0), "interest"); // 0 is Error.NO_ERROR
        uint256 idleBalance = _idleAssets();
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 mTokensNeeded = (shortfall * 1e18).ceilDiv(mToken.exchangeRateStored());
            uint256 errorCode = mToken.redeem(mTokensNeeded);
            if (errorCode != 0) revert MoonwellStrategyRedeemFailed(errorCode);
        }

        _afterRedeem();

        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _afterRedeem() internal virtual {
        // Moonwell WETH can return native ETH. Wrap it to MYT asset (WETH) when enabled.
        if (usePostRedeemETHWrap && address(this).balance > 0) {
            IWETH(address(mytAsset)).deposit{value: address(this).balance}();
        }
    }

    function positionToken() public view virtual override returns (address) {
        return address(mToken);
    }

    function _rate() internal view returns (uint256) {
        return mToken.exchangeRateStored();
    }

    function _totalValue() internal view virtual override returns (uint256) {
        uint256 idleUnderlying = _idleAssets();
        uint256 mTokenBalance = mToken.balanceOf(address(this));
        if (mTokenBalance == 0) return idleUnderlying;
        return idleUnderlying + (mTokenBalance * _rate()) / 1e18;
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 rate = _rate();
        uint256 sharesNoFee = (amount * 1e18) / rate;
        uint256 sharesWithFee = (amount * 1e18).ceilDiv(rate);
        
        uint256 feeShares = sharesWithFee > sharesNoFee ? sharesWithFee - sharesNoFee : 0;
        uint256 feeAssets = (feeShares * rate) / 1e18;
        uint256 netAssets = amount > feeAssets ? amount - feeAssets : 0;
        
        uint256 slippage = Math.ceilDiv(netAssets * params.slippageBPS, 10_000);
        return netAssets > slippage ? netAssets - slippage : 0;
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual override returns (uint256) {
        require(token == address(rewardToken), "Invalid Token");
        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        comptroller.claimReward();
        uint256 rewardReceived = rewardToken.balanceOf(address(this)) - rewardBefore;
        if (rewardReceived == 0) return 0;
        emit RewardsClaimed(address(rewardToken), rewardReceived);
        uint256 assetsReceived = dexSwap(address(MYT.asset()), address(rewardToken), rewardReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), assetsReceived);
        return assetsReceived;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == MYT.asset() || token == address(mToken);
    }

    receive() external payable {}
}
