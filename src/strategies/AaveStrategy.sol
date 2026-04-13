// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPoolAddressProvider {
    function getPool() external view returns (address);
}

interface IAaveAToken {
    function balanceOf(address) external view returns (uint256);
}

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title AaveStrategy
 * @notice Generic deployable strategy for Aave v3 integrations.
 */
contract AaveStrategy is MYTStrategy {
    IERC20 public immutable mytAsset;
    IPoolAddressProvider public immutable poolProvider;
    IAaveAToken public immutable aToken;
    IRewardsController public immutable rewardsController;
    IERC20 public immutable rewardToken;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _mytAsset,
        address _aToken,
        address _poolProvider,
        address _rewardsController,
        address _rewardToken
    ) MYTStrategy(_myt, _params) {
        mytAsset = IERC20(_mytAsset);
        aToken = IAaveAToken(_aToken);
        poolProvider = IPoolAddressProvider(_poolProvider);
        rewardsController = IRewardsController(_rewardsController);
        rewardToken = IERC20(_rewardToken);
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);
        
        IAavePool pool = IAavePool(poolProvider.getPool());
        TokenUtils.safeApprove(address(mytAsset), address(pool), amount);
        pool.supply(address(mytAsset), amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        IAavePool pool = IAavePool(poolProvider.getPool());
        uint256 idleBalance = _idleAssets();
        uint256 withdrawnAmount = amount;
        
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 balanceBefore = TokenUtils.safeBalanceOf(address(mytAsset), address(this));
            withdrawnAmount = pool.withdraw(address(mytAsset), shortfall, address(this));
            uint256 balanceAfter = TokenUtils.safeBalanceOf(address(mytAsset), address(this));
            
            if (withdrawnAmount < shortfall) revert InvalidAmount(shortfall, withdrawnAmount);
            if (balanceAfter < balanceBefore + shortfall) revert InsufficientBalance(balanceBefore + shortfall, balanceAfter);
        }
        
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return withdrawnAmount;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        // Aave doesn't charge withdrawal fees, so we just apply slippage.
        return amount - (amount * params.slippageBPS / 10_000);
    }

    function positionToken() public view virtual override returns (address) {
        return address(aToken);
    }

    function _totalValue() internal view virtual override returns (uint256) {
        // aToken balance reflects principal + interest in underlying units.
        return aToken.balanceOf(address(this)) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual override returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = token;

        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        rewardsController.claimAllRewardsToSelf(assets);
        uint256 rewardReceived = rewardToken.balanceOf(address(this)) - rewardBefore;
        if (rewardReceived == 0) return 0;

        emit RewardsClaimed(address(rewardToken), rewardReceived);

        uint256 assetsReceived = dexSwap(address(MYT.asset()), address(rewardToken), rewardReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), assetsReceived);
        return assetsReceived;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == MYT.asset() || token == address(aToken);
    }

    /// @notice Admin only function to perform a DEX swap via the 0x AllowanceHolder.
    /// @param to The target token address (token to buy).
    /// @param from The source token address (token to sell).
    /// @param amount The amount of `from` tokens to swap.
    /// @param minAmountOut The minimum amount of `to` tokens expected.
    /// @param callData The calldata for the 0x interaction.
    /// @return amountReceived The amount of `to` tokens received.
    function adminDexSwap(
        address to, 
        address from, 
        uint256 amount, 
        uint256 minAmountOut, 
        bytes calldata callData
    ) external onlyOwner returns (uint256) {
        return dexSwap(to, from, amount, minAmountOut, callData);
    }
}
