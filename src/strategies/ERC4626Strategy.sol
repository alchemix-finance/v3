// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/**
 * @title ERC4626Strategy
 * @notice Generic deployable strategy for vanilla ERC4626 vault integrations.
 */
contract ERC4626Strategy is MYTStrategy {
    IERC20 public immutable mytAsset;
    IERC4626 public immutable vault;

    constructor(address _myt, StrategyParams memory _params, address _vault)
        MYTStrategy(_myt, _params)
    {
        mytAsset = IERC20(MYT.asset());
        vault = IERC4626(_vault);
        require(vault.asset() == MYT.asset(), "Vault asset != MYT asset");
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);
        
        TokenUtils.safeApprove(address(mytAsset), address(vault), amount);
        vault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            vault.withdraw(shortfall, address(this), address(this));
        }

        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return _idleAssets();
        return vault.previewRedeem(shares) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 sharesNoFee = vault.convertToShares(amount);
        uint256 sharesWithFee = vault.previewWithdraw(amount);
        uint256 feeShares = sharesWithFee > sharesNoFee ? sharesWithFee - sharesNoFee : 0;
        uint256 feeAssets = vault.previewRedeem(feeShares);
        uint256 netAssets = amount - feeAssets;
        return netAssets * (10_000 - params.slippageBPS) / 10_000;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == MYT.asset() || token == address(vault);
    }
}
