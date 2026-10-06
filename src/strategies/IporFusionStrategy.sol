// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Strategy} from "./ERC4626Strategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @dev Minimal surface of the IPOR Fusion WithdrawManager used for synchronous exits.
interface IIporWithdrawManager {
    function getWithdrawFee() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function getPlasmaVaultAddress() external view returns (address);
}

/**
 * @title IporFusionStrategy
 * @notice ERC4626 strategy for IPOR Fusion PlasmaVaults, synchronous deposit/redeem only.
 * @dev PlasmaVault deviates from vanilla ERC4626 in ways that break `ERC4626Strategy`:
 *      - `withdraw(assets)` delivers `assets * (1 - withdrawFee)` instead of `assets`.
 *      - `previewWithdraw(assets)` is not fee-consistent on deployed vaults.
 *      - Synchronous exits are only served from the asset balance idle in the PlasmaVault
 *        (no instant-withdrawal fuses); anything beyond that must go through the async
 *        WithdrawManager request flow, which this version does not implement.
 *      This strategy therefore exits via `redeem`, grosses shares up by the live withdraw fee,
 *      and caps previews at the PlasmaVault's available synchronous liquidity.
 *      `previewRedeem` on PlasmaVault already nets the withdraw fee, so `_totalValue` from the
 *      base contract is conservative and correct without changes.
 */
contract IporFusionStrategy is ERC4626Strategy {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    IIporWithdrawManager public withdrawManager;

    /// @notice Highest PlasmaVault withdraw fee (WAD) this strategy will exit through synchronously.
    uint256 public maxWithdrawFee;

    /// @notice Extra shares (bps of the gross amount) redeemed to absorb rounding and the
    ///         management fee the PlasmaVault realizes before computing redemption output.
    ///         Any excess stays idle in the strategy and is counted by `_totalValue`.
    uint256 public redeemBufferBps;

    error ZeroAddress();
    error WithdrawManagerVaultMismatch(address expected, address actual);
    error WithdrawFeeTooHigh(uint256 fee, uint256 maxFee);
    error InvalidBps(uint256 value);
    error InsufficientSyncLiquidity(uint256 requested, uint256 available);

    event WithdrawManagerUpdated(address indexed withdrawManager);
    event MaxWithdrawFeeUpdated(uint256 maxWithdrawFee);
    event RedeemBufferBpsUpdated(uint256 redeemBufferBps);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _vault,
        address _withdrawManager,
        uint256 _maxWithdrawFee,
        uint256 _redeemBufferBps
    ) ERC4626Strategy(_myt, _params, _vault) {
        _setWithdrawManager(_withdrawManager);
        _setMaxWithdrawFee(_maxWithdrawFee);
        _setRedeemBufferBps(_redeemBufferBps);
    }

    /* ========== ADMIN ========== */

    function setWithdrawManager(address _withdrawManager) external onlyOwner {
        _setWithdrawManager(_withdrawManager);
    }

    function setMaxWithdrawFee(uint256 _maxWithdrawFee) external onlyOwner {
        _setMaxWithdrawFee(_maxWithdrawFee);
    }

    function setRedeemBufferBps(uint256 _redeemBufferBps) external onlyOwner {
        _setRedeemBufferBps(_redeemBufferBps);
    }

    function _setWithdrawManager(address _withdrawManager) internal {
        if (_withdrawManager == address(0)) revert ZeroAddress();
        address wmVault = IIporWithdrawManager(_withdrawManager).getPlasmaVaultAddress();
        if (wmVault != address(vault)) revert WithdrawManagerVaultMismatch(address(vault), wmVault);
        withdrawManager = IIporWithdrawManager(_withdrawManager);
        emit WithdrawManagerUpdated(_withdrawManager);
    }

    function _setMaxWithdrawFee(uint256 _maxWithdrawFee) internal {
        if (_maxWithdrawFee >= WAD) revert InvalidBps(_maxWithdrawFee);
        maxWithdrawFee = _maxWithdrawFee;
        emit MaxWithdrawFeeUpdated(_maxWithdrawFee);
    }

    function _setRedeemBufferBps(uint256 _redeemBufferBps) internal {
        if (_redeemBufferBps >= BPS) revert InvalidBps(_redeemBufferBps);
        redeemBufferBps = _redeemBufferBps;
        emit RedeemBufferBpsUpdated(_redeemBufferBps);
    }

    /* ========== VIEWS ========== */

    /// @notice Current PlasmaVault withdraw fee (WAD).
    function currentWithdrawFee() public view returns (uint256) {
        return withdrawManager.getWithdrawFee();
    }

    /// @notice Asset amount the PlasmaVault can serve synchronously right now, net of shares
    ///         already released for async requests.
    function availableSyncLiquidity() public view returns (uint256) {
        uint256 idleInVault = TokenUtils.safeBalanceOf(address(mytAsset), address(vault));
        uint256 reservedShares = withdrawManager.getSharesToRelease();
        if (reservedShares == 0) return idleInVault;
        uint256 reservedAssets = vault.convertToAssets(reservedShares);
        return idleInVault > reservedAssets ? idleInVault - reservedAssets : 0;
    }

    /// @notice Gross asset value of this strategy's PlasmaVault shares, before the withdraw fee.
    function grossVaultAssets() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /* ========== CORE ========== */

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;

            uint256 fee = currentWithdrawFee();
            if (fee > maxWithdrawFee) revert WithdrawFeeTooHigh(fee, maxWithdrawFee);

            // Gross up so that net output after the withdraw fee covers the shortfall,
            // then add a small buffer for rounding / management fee realization.
            uint256 grossAssets = _mulDivUp(shortfall, WAD, WAD - fee);
            grossAssets = _mulDivUp(grossAssets, BPS + redeemBufferBps, BPS);

            uint256 liquidity = availableSyncLiquidity();
            if (grossAssets > liquidity) revert InsufficientSyncLiquidity(grossAssets, liquidity);

            uint256 shares = vault.convertToShares(grossAssets);
            uint256 shareBalance = vault.balanceOf(address(this));
            if (shares > shareBalance) shares = shareBalance;
            require(shares > 0, "No shares to redeem");

            vault.redeem(shares, address(this), address(this));
        }

        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    /// @dev Returns the net asset amount that can be deallocated synchronously when asking for
    ///      `amount` of strategy value, after the withdraw fee, liquidity cap and slippage tolerance.
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) return amount;

        uint256 fee = currentWithdrawFee();
        if (fee > maxWithdrawFee) return idleBalance;

        uint256 shortfall = amount - idleBalance;

        uint256 grossAvailable = grossVaultAssets();
        uint256 liquidity = availableSyncLiquidity();
        if (grossAvailable > liquidity) grossAvailable = liquidity;

        uint256 grossToRedeem = shortfall < grossAvailable ? shortfall : grossAvailable;
        if (grossToRedeem == 0) return idleBalance;

        uint256 shares = vault.convertToShares(grossToRedeem);
        uint256 net = vault.previewRedeem(shares);

        // Undo the redeem buffer so the gross-up in `_deallocate` fits within `grossToRedeem`.
        net = net * BPS / (BPS + redeemBufferBps);
        net = net * (BPS - params.slippageBPS) / BPS;

        return idleBalance + net;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
