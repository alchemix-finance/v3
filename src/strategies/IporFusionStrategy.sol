// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626Strategy} from "./ERC4626Strategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @dev Snapshot of one account's withdrawal request at the IPOR Fusion WithdrawManager.
struct IporWithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @dev Minimal surface of the IPOR Fusion WithdrawManager used for synchronous and scheduled exits.
interface IIporWithdrawManager {
    function getWithdrawFee() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function getPlasmaVaultAddress() external view returns (address);
    function requestShares(uint256 shares) external;
    function requestInfo(address account) external view returns (IporWithdrawRequestInfo memory);
    function getRequestFee() external view returns (uint256);
    function getWithdrawWindow() external view returns (uint256);
}

/// @dev PlasmaVault entry point for redeeming a released withdrawal request. No withdraw fee.
interface IIporPlasmaVaultRequests {
    function redeemFromRequest(uint256 shares, address receiver, address owner) external returns (uint256);
}

/// @notice IPOR Fusion PlasmaVault strategy: fee aware sync redeem, 
/// WithdrawManager exit requests, and a share price band around the last accepted anchor.
contract IporFusionStrategy is ERC4626Strategy {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev `acceptPrice` redeems `shareUnit / REALIZE_SHARES_DIVISOR` shares so the PlasmaVault realizes fees first.
    uint256 internal constant REALIZE_SHARES_DIVISOR = 100_000;

    IIporWithdrawManager public withdrawManager;

    /// @notice Highest PlasmaVault withdraw fee (WAD) this strategy will exit through synchronously.
    uint256 public maxWithdrawFee;

    /// @notice Extra shares (bps) redeemed to absorb rounding and realized management fee; excess stays idle.
    uint256 public redeemBufferBps;

    /// @notice One share, in PlasmaVault share decimals. Share prices are `previewRedeem` of this unit.
    uint256 public immutable shareUnit;

    /// @notice Last accepted assets per `shareUnit`.
    uint256 public anchorPps;

    /// @notice Timestamp of the last anchor update. The travel budget accrues from here.
    uint256 public anchorTimestamp;

    /// @notice Minimum room around the anchor in bps, open at any elapsed time; the anchor never moves by it.
    uint256 public baseBps;

    /// @notice How fast the anchor may rise, in bps of the anchor per day.
    uint256 public upBpsPerDay;

    /// @notice How fast the anchor may fall, in bps of the anchor per day.
    uint256 public downBpsPerDay;

    /// @notice Largest rise one update may book, however long the anchor has been sitting.
    uint256 public maxUpBps;

    /// @notice Largest fall one update may book, however long the anchor has been sitting.
    uint256 public maxDownBps;

    /// @notice Authorized caller (besides the owner) for `requestExit`.
    address public keeper;

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
    error PriceOutsideAcceptBounds(uint256 livePps, uint256 minPps, uint256 maxPps);
    error NotKeeper(address caller);
    error NoClaimableExit();
    error ClaimableExitPending(uint256 shares);

    event WithdrawManagerUpdated(address indexed withdrawManager);
    event MaxWithdrawFeeUpdated(uint256 maxWithdrawFee);
    event RedeemBufferBpsUpdated(uint256 redeemBufferBps);
    event PriceGuardUpdated(uint256 baseBps, uint256 upBpsPerDay, uint256 downBpsPerDay, uint256 maxUpBps, uint256 maxDownBps);
    event AnchorUpdated(uint256 anchorPps, uint256 anchorTimestamp);
    event KeeperUpdated(address indexed keeper);
    /// @dev `sharesPending` is what the WithdrawManager recorded, net of any request fee.
    event ExitRequested(uint256 sharesRequested, uint256 sharesPending, uint256 windowEnd);
    event ExitClaimed(uint256 shares, uint256 assets);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper(msg.sender);
        _;
    }

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

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    /// @notice Book the realized live price as the anchor if it lands inside `[minPps, maxPps]`, a band the owner reads off-chain.
    function acceptPrice(uint256 minPps, uint256 maxPps) external onlyOwner {
        _realizeVaultPrice();
        uint256 live = _liveSharePrice();
        if (live < minPps || live > maxPps) revert PriceOutsideAcceptBounds(live, minPps, maxPps);
        _acceptLivePrice();
    }

    /// @notice Move the anchor toward the live price by at most the accrued travel budget.
    function poke() external {
        _moveAnchor();
    }

    /// @notice Schedule an exit worth about `wethAmount` at the WithdrawManager; replaces an unreleased request, refuses to overwrite a claimable one.
    function requestExit(uint256 wethAmount) external onlyKeeperOrOwner {
        if (wethAmount == 0) revert InvalidAmount(1, 0);
        IporWithdrawRequestInfo memory current = withdrawManager.requestInfo(address(this));
        if (current.canWithdraw && current.shares > 0) revert ClaimableExitPending(current.shares);

        uint256 shares = vault.convertToShares(wethAmount);
        shares = _mulDivUp(shares, BPS + redeemBufferBps, BPS);
        uint256 shareBalance = vault.balanceOf(address(this));
        if (shares > shareBalance) shares = shareBalance;
        require(shares > 0, "No shares to request");

        withdrawManager.requestShares(shares);

        IporWithdrawRequestInfo memory info = withdrawManager.requestInfo(address(this));
        emit ExitRequested(shares, info.shares, info.endWithdrawWindowTimestamp);
    }

    /// @notice Redeem the released request into idle balance; permissionless, and floor checked like any exit that realizes value.
    function claimExit() external returns (uint256 assets) {
        IporWithdrawRequestInfo memory info = withdrawManager.requestInfo(address(this));
        if (!info.canWithdraw || info.shares == 0) revert NoClaimableExit();
        assets = IIporPlasmaVaultRequests(address(vault)).redeemFromRequest(info.shares, address(this), address(this));
        _requireAboveFloor();
        _moveAnchor();
        emit ExitClaimed(info.shares, assets);
    }

    /// @dev Tolerant claim of a released request for `_deallocate`, which runs its own floor check after.
    function _settleClaimableExit() internal {
        IporWithdrawRequestInfo memory info = withdrawManager.requestInfo(address(this));
        if (!info.canWithdraw || info.shares == 0) return;
        try IIporPlasmaVaultRequests(address(vault)).redeemFromRequest(info.shares, address(this), address(this)) returns (uint256 assets) {
            emit ExitClaimed(info.shares, assets);
        } catch {}
    }

    /// @notice Shares in this strategy's current withdrawal request, released or not.
    function pendingExitShares() external view returns (uint256) {
        return withdrawManager.requestInfo(address(this)).shares;
    }

    /// @notice Last timestamp the current request can be claimed, zero when there is none.
    function exitWindowEnd() external view returns (uint256) {
        IporWithdrawRequestInfo memory info = withdrawManager.requestInfo(address(this));
        return info.shares == 0 ? 0 : info.endWithdrawWindowTimestamp;
    }

    /// @notice Assets a claim would return right now, else zero.
    function claimableExit() external view returns (uint256) {
        IporWithdrawRequestInfo memory info = withdrawManager.requestInfo(address(this));
        if (!info.canWithdraw || info.shares == 0) return 0;
        return vault.convertToAssets(info.shares);
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

    /// @dev Dust redeem so the PlasmaVault realizes fees and refreshes its cache. on revert the snap uses the cached price.
    function _realizeVaultPrice() internal {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        uint256 shares = shareUnit / REALIZE_SHARES_DIVISOR;
        if (shares > bal) shares = bal;
        if (shares == 0) return;
        try vault.redeem(shares, address(this), address(this)) {} catch {}
    }

    function _acceptLivePrice() internal {
        uint256 live = _liveSharePrice();
        if (live == 0) revert ZeroSharePrice();
        anchorPps = live;
        anchorTimestamp = block.timestamp;
        emit AnchorUpdated(live, block.timestamp);
    }

    /// @dev Move the anchor toward the live price within the time budget. `baseBps` is excluded so repeats cannot walk it.
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

    /// @notice Assets the PlasmaVault can serve synchronously now, net of shares already released for requests.
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

    function _allocate(uint256 amount) internal override returns (uint256) {
        uint256 allocated = super._allocate(amount);

        // Checked after the deposit so it reads the realized price; a revert undoes the deposit.
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower || live > upper) revert PriceOutsideRoom(live, lower, upper);

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
        _settleClaimableExit();
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;

            uint256 fee = currentWithdrawFee();
            if (fee > maxWithdrawFee) revert WithdrawFeeTooHigh(fee, maxWithdrawFee);

            // Gross up for the withdraw fee, then add the redeem buffer for rounding and fee realization.
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

        _requireAboveFloor();
        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        _moveAnchor();
        return amount;
    }

    /// @dev Run after a vault call that realizes value, so it reads the realized price and a revert undoes the call.
    function _requireAboveFloor() internal view {
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower) revert PriceOutsideRoom(live, lower, upper);
    }

    /// @dev Net amount a sync exit of `amount` returns after fee, liquidity cap and slippage; an unclaimed release is not counted.
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

    /// @dev Band `_totalValue` reports inside and `allocate`/`deallocate` check against. at least `baseBps` wide.
    function _reportingBounds() internal view returns (uint256 lower, uint256 upper) {
        return _boundsWithMinRoom(baseBps);
    }

    /// @dev Band the anchor may move into
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
