// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626Strategy} from "./ERC4626Strategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IYearnV3Vault {
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLoss) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256);
}

/**
 * @title YearnV3Strategy
 * @notice ERC4626Strategy for Yearn V3 vaults; deallocations tolerate up to
 *         slippageBPS of realized loss instead of reverting.
 */
contract YearnV3Strategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _vault) ERC4626Strategy(_myt, _params, _vault) {}

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            IYearnV3Vault(address(vault)).withdraw(amount - idleBalance, address(this), address(this), params.slippageBPS);

            uint256 dustGap = amount > _idleAssets() ? amount - _idleAssets() : 0;
            uint256 shares = vault.balanceOf(address(this));
            if (dustGap > 0 && shares > 0) {
                uint256 gapShares = vault.convertToShares(dustGap) + 3;
                IYearnV3Vault(address(vault)).redeem(gapShares < shares ? gapShares : shares, address(this), address(this), 10_000);
            }
        }

        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }
}
