// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
 *      `previewRedeem` nets the withdraw fee. `_totalValue` prices shares at that rate, clamped
 *      to a band around the last accepted share price so a stale or pushed snapshot cannot
 *      reprice the MYT faster than the configured budget.
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

    /// @notice One share, in PlasmaVault share decimals. Share prices are `previewRedeem` of this unit.
    uint256 public immutable shareUnit;

    /// @notice Last accepted assets per `shareUnit`.
    uint256 public anchorPps;

    /// @notice Timestamp of the last anchor update. The travel budget accrues from here.
    uint256 public anchorTimestamp;

    /// @notice Minimum room around the anchor, in bps, open regardless of elapsed time so rounding
    ///         and fee dust do not block allocates. The anchor itself never moves by this amount.
    uint256 public baseBps;

    /// @notice How fast the anchor may rise, in bps of the anchor per day.
    uint256 public upBpsPerDay;

    /// @notice How fast the anchor may fall, in bps of the anchor per day.
    uint256 public downBpsPerDay;

    /// @notice Largest rise one update may book, however long the anchor has been sitting.
    uint256 public maxUpBps;

    /// @notice Largest fall one update may book, however long the anchor has been sitting.
    uint256 public maxDownBps;

    struct PriceGuardParams {
        uint256 baseBps;
        uint256 upBpsPerDay;
        uint256 downBpsPerDay;
        uint256 maxUpBps;
        uint256 maxDownBps;
    }

    error ZeroAddress();
    error WithdrawManagerVaultMismatch(address expected, address actual);
    error WithdrawFeeTooHigh(uint256 fee, uint256 maxFee);
    error InvalidBps(uint256 value);
    error InsufficientSyncLiquidity(uint256 requested, uint256 available);
    error ZeroSharePrice();
    error PriceOutsideRoom(uint256 livePps, uint256 lower, uint256 upper);

    event WithdrawManagerUpdated(address indexed withdrawManager);
    event MaxWithdrawFeeUpdated(uint256 maxWithdrawFee);
    event RedeemBufferBpsUpdated(uint256 redeemBufferBps);
    event PriceGuardUpdated(uint256 baseBps, uint256 upBpsPerDay, uint256 downBpsPerDay, uint256 maxUpBps, uint256 maxDownBps);
    event AnchorUpdated(uint256 anchorPps, uint256 anchorTimestamp);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _vault,
        address _withdrawManager,
        uint256 _maxWithdrawFee,
        uint256 _redeemBufferBps,
        PriceGuardParams memory _guard
    ) ERC4626Strategy(_myt, _params, _vault) {
        shareUnit = 10 ** vault.decimals();
        _setWithdrawManager(_withdrawManager);
        _setMaxWithdrawFee(_maxWithdrawFee);
        _setRedeemBufferBps(_redeemBufferBps);
        _setPriceGuard(_guard);
        _acceptLivePrice();
    }

    function setWithdrawManager(address _withdrawManager) external onlyOwner {
        _setWithdrawManager(_withdrawManager);
    }

    function setMaxWithdrawFee(uint256 _maxWithdrawFee) external onlyOwner {
        _setMaxWithdrawFee(_maxWithdrawFee);
    }

    function setRedeemBufferBps(uint256 _redeemBufferBps) external onlyOwner {
        _setRedeemBufferBps(_redeemBufferBps);
    }

    function setPriceGuard(PriceGuardParams calldata _guard) external onlyOwner {
        _setPriceGuard(_guard);
    }

    /// @notice Book the live share price as the anchor, including a print outside the room.
    function acceptPrice() external onlyOwner {
        _acceptLivePrice();
    }

    /// @notice Move the anchor toward the live price by at most the accrued travel budget.
    ///         A second call in the same timestamp cannot move it again: the budget excludes
    ///         `baseBps`, and a zero move does not reset the clock.
    function poke() external {
        _moveAnchor();
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

    function _setPriceGuard(PriceGuardParams memory _guard) internal {
        _requireBps(_guard.baseBps);
        _requireBps(_guard.upBpsPerDay);
        _requireBps(_guard.downBpsPerDay);
        _requireBps(_guard.maxUpBps);
        _requireBps(_guard.maxDownBps);
        baseBps = _guard.baseBps;
        upBpsPerDay = _guard.upBpsPerDay;
        downBpsPerDay = _guard.downBpsPerDay;
        maxUpBps = _guard.maxUpBps;
        maxDownBps = _guard.maxDownBps;
        emit PriceGuardUpdated(_guard.baseBps, _guard.upBpsPerDay, _guard.downBpsPerDay, _guard.maxUpBps, _guard.maxDownBps);
    }

    function _requireBps(uint256 value) internal pure {
        if (value >= BPS) revert InvalidBps(value);
    }

    function _acceptLivePrice() internal {
        uint256 live = _liveSharePrice();
        if (live == 0) revert ZeroSharePrice();
        anchorPps = live;
        anchorTimestamp = block.timestamp;
        emit AnchorUpdated(live, block.timestamp);
    }

    /// @dev Move the anchor toward the live share price, only as far as the time budget allows.
    ///      `baseBps` is excluded so repeating this call cannot step the anchor by that amount.
    function _moveAnchor() internal {
        uint256 livePps = _liveSharePrice();
        if (livePps == 0) return;
        (uint256 lower, uint256 upper) = _anchorMoveBounds();
        uint256 nextAnchorPps = livePps;
        if (nextAnchorPps > upper) nextAnchorPps = upper;
        if (nextAnchorPps < lower) nextAnchorPps = lower;
        if (nextAnchorPps == anchorPps) return;
        anchorPps = nextAnchorPps;
        anchorTimestamp = block.timestamp;
        emit AnchorUpdated(nextAnchorPps, block.timestamp);
    }

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

    /// @notice Live assets per `shareUnit`, net of the PlasmaVault withdraw fee.
    function liveSharePrice() public view returns (uint256) {
        return _liveSharePrice();
    }

    /// @notice Floor and ceiling `_totalValue` will report, and the band `allocate` must sit inside.
    function priceBounds() public view returns (uint256 lower, uint256 upper) {
        return _reportingBounds();
    }

    /* ========== CORE ========== */

    function _allocate(uint256 amount) internal override returns (uint256) {
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower || live > upper) revert PriceOutsideRoom(live, lower, upper);

        uint256 allocated = super._allocate(amount);
        _moveAnchor();
        return allocated;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 idle = _idleAssets();
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return idle;

        uint256 live = _liveSharePrice();
        if (live == 0) return idle;

        uint256 raw = vault.previewRedeem(shares);
        if (raw == 0) return idle;

        (uint256 lower, uint256 upper) = _reportingBounds();
        uint256 clamped = live;
        if (clamped > upper) clamped = upper;
        if (clamped < lower) clamped = lower;
        return idle + raw * clamped / live;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower) revert PriceOutsideRoom(live, lower, upper);

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
        _moveAnchor();
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

    function _liveSharePrice() internal view returns (uint256) {
        return vault.previewRedeem(shareUnit);
    }

    /// @dev Band `_totalValue` reports inside and `allocate`/`deallocate` check against.
    ///      Always at least `baseBps` wide, so rounding and fee dust never block a call.
    function _reportingBounds() internal view returns (uint256 lower, uint256 upper) {
        return _boundsWithMinRoom(baseBps);
    }

    /// @dev Band the anchor may move into on `poke`, `allocate`, or `deallocate`.
    ///      Opens only with elapsed time, so repeated calls cannot walk the anchor by `baseBps` each time.
    function _anchorMoveBounds() internal view returns (uint256 lower, uint256 upper) {
        return _boundsWithMinRoom(0);
    }

    /// @param minRoomBps Room that is open regardless of elapsed time.
    function _boundsWithMinRoom(uint256 minRoomBps) internal view returns (uint256 lower, uint256 upper) {
        uint256 elapsed = block.timestamp > anchorTimestamp ? block.timestamp - anchorTimestamp : 0;
        uint256 upRoom = _room(upBpsPerDay, maxUpBps, elapsed, minRoomBps);
        uint256 downRoom = _room(downBpsPerDay, maxDownBps, elapsed, minRoomBps);
        upper = anchorPps * (BPS + upRoom) / BPS;
        lower = anchorPps * (BPS - downRoom) / BPS;
    }

    /// @dev Room in bps: `min(cap, minRoom + perDay * elapsed / 1 day)`.
    function _room(uint256 perDay, uint256 cap, uint256 elapsed, uint256 minRoomBps) internal pure returns (uint256) {
        uint256 room = minRoomBps + perDay * elapsed / 1 days;
        return room > cap ? cap : room;
    }
}
