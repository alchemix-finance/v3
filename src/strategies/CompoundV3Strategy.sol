// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IComet {
    function baseToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
}

interface ICometRewards {
    function rewardConfig(address comet) external view returns (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier);
    function claim(address comet, address src, bool shouldAccrue) external;
}

/// @notice Generic strategy for supplying an MYT's asset to a Compound III Comet market.
/// @dev Deploy once per Comet. Set both rewards addresses to zero for a market without rewards.
contract CompoundV3Strategy is MYTStrategy {
    using Math for uint256;

    IERC20 public immutable mytAsset;
    IComet public immutable comet;
    ICometRewards public immutable rewards;
    IERC20 public immutable rewardToken;
    bool public canForceDeallocate;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);

    error CompoundV3BaseAssetMismatch(address mytAsset, address cometBaseToken);
    error CompoundV3InvalidRewardsConfiguration();
    error CompoundV3RewardsNotConfigured();
    error CompoundV3InvalidRewardToken(address expected, address actual);
    error CompoundV3InvalidContract(address target);
    error CompoundV3RewardTokenMismatch(address expected, address actual);
    error CompoundV3BorrowNotAllowed(uint256 requested, uint256 supplied);
    error CompoundV3DebtDetected(uint256 debt);

    constructor(address _myt, StrategyParams memory _params, address _comet, address _rewards, address _rewardToken) MYTStrategy(_myt, _params) {
        if (_comet.code.length == 0) revert CompoundV3InvalidContract(_comet);

        address asset = MYT.asset();
        address cometBaseToken = IComet(_comet).baseToken();
        if (cometBaseToken != asset) revert CompoundV3BaseAssetMismatch(asset, cometBaseToken);
        if ((_rewards == address(0)) != (_rewardToken == address(0))) {
            revert CompoundV3InvalidRewardsConfiguration();
        }
        if (_rewards != address(0)) {
            if (_rewards.code.length == 0) revert CompoundV3InvalidContract(_rewards);
            if (_rewardToken.code.length == 0) revert CompoundV3InvalidContract(_rewardToken);
            (address configuredRewardToken,,,) = ICometRewards(_rewards).rewardConfig(_comet);
            if (configuredRewardToken != _rewardToken) {
                revert CompoundV3RewardTokenMismatch(_rewardToken, configuredRewardToken);
            }
        }

        mytAsset = IERC20(asset);
        comet = IComet(_comet);
        rewards = ICometRewards(_rewards);
        rewardToken = IERC20(_rewardToken);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), address(comet), amount);
        comet.supply(address(mytAsset), amount);
        return amount;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 supplied = comet.balanceOf(address(this));
            if (shortfall > supplied) revert CompoundV3BorrowNotAllowed(shortfall, supplied);
            comet.withdraw(address(mytAsset), shortfall);
            uint256 debt = comet.borrowBalanceOf(address(this));
            if (debt != 0) revert CompoundV3DebtDetected(debt);
            uint256 balanceAfter = _idleAssets();
            if (balanceAfter < idleBalance + shortfall) {
                revert InsufficientBalance(idleBalance + shortfall, balanceAfter);
            }
        }

        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        uint256 debt = comet.borrowBalanceOf(address(this));
        if (debt != 0) revert CompoundV3DebtDetected(debt);
        return comet.balanceOf(address(this)) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 withdrawable = Math.min(amount, _totalValue());
        uint256 slippage = Math.ceilDiv(withdrawable * params.slippageBPS, 10_000);
        return withdrawable > slippage ? withdrawable - slippage : 0;
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual override returns (uint256) {
        if (address(rewards) == address(0)) revert CompoundV3RewardsNotConfigured();
        if (token != address(rewardToken)) {
            revert CompoundV3InvalidRewardToken(address(rewardToken), token);
        }

        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        rewards.claim(address(comet), address(this), true);
        uint256 rewardReceived = rewardToken.balanceOf(address(this)) - rewardBefore;
        if (rewardReceived == 0) return 0;

        emit RewardsClaimed(address(rewardToken), rewardReceived);

        uint256 assetsReceived = rewardReceived;
        if (address(rewardToken) != address(mytAsset)) {
            assetsReceived = dexSwap(address(mytAsset), address(rewardToken), rewardReceived, minAmountOut, quote);
        }
        TokenUtils.safeTransfer(address(mytAsset), address(MYT), assetsReceived);
        return assetsReceived;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == address(mytAsset) || token == address(comet);
    }

    function _canForceDeallocate() internal view virtual override returns (bool) {
        return canForceDeallocate;
    }
}
