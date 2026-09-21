// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IComet {
    function baseToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
}

interface ICometRewards {
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

    constructor(address _myt, StrategyParams memory _params, address _comet, address _rewards, address _rewardToken) MYTStrategy(_myt, _params) {
        require(_comet != address(0), "Invalid Comet");

        address asset = MYT.asset();
        address cometBaseToken = IComet(_comet).baseToken();
        if (cometBaseToken != asset) revert CompoundV3BaseAssetMismatch(asset, cometBaseToken);
        if ((_rewards == address(0)) != (_rewardToken == address(0))) {
            revert CompoundV3InvalidRewardsConfiguration();
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
            comet.withdraw(address(mytAsset), shortfall);
            uint256 balanceAfter = _idleAssets();
            if (balanceAfter < idleBalance + shortfall) {
                revert InsufficientBalance(idleBalance + shortfall, balanceAfter);
            }
        }

        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        return comet.balanceOf(address(this)) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 slippage = Math.ceilDiv(amount * params.slippageBPS, 10_000);
        return amount > slippage ? amount - slippage : 0;
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
