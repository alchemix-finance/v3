// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IFluidLiteETHVault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function withdrawalFeePercentage() external view returns (uint256);
    function withdrawFeeAbsoluteMin() external view returns (uint256);
    function getWithdrawFee(uint256 stETHAmount) external view returns (uint256);
}

interface IStETH is IERC20 {
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function requestWithdrawals(uint256[] calldata amounts, address owner) external returns (uint256[] memory requestIds);
    function getWithdrawalStatus(uint256[] calldata requestIds) external view returns (WithdrawalRequestStatus[] memory statuses);
    function getLastCheckpointIndex() external view returns (uint256);
    function findCheckpointHints(uint256[] calldata requestIds, uint256 firstIndex, uint256 lastIndex) external view returns (uint256[] memory hintIds);
    function getClaimableEther(uint256[] calldata requestIds, uint256[] calldata hints) external view returns (uint256[] memory claimableEthValues);
    function claimWithdrawal(uint256 requestId) external;
}

/// @notice WETH -> stETH (dex) -> iETHv2. Sync exit sells stETH. Async exit withdraws stETH, then queues it with Lido.
/// iETHv2 share price is reported and checked inside a band around the last accepted anchor.
contract FluidLiteETHStrategy is MYTStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_SCALE = 1e6;
    uint256 internal constant STETH_ROUNDING_BUFFER = 2;

    IFluidLiteETHVault public immutable iETH;
    IStETH public immutable stETH;
    ILidoWithdrawalQueue public immutable withdrawalQueue;
    bool public canForceDeallocate = false;

    address public keeper;

    /// @notice One iETHv2 share. Share prices are `previewRedeem` of this unit, in stETH.
    uint256 public immutable shareUnit;

    /// @notice Last accepted stETH per `shareUnit`.
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

    struct PriceGuardParams {
        uint256 baseBps;
        uint256 upBpsPerDay;
        uint256 downBpsPerDay;
        uint256 maxUpBps;
        uint256 maxDownBps;
    }

    struct PendingExit {
        uint256 tokenId;
    }
    PendingExit internal _pendingExit;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    event KeeperUpdated(address indexed keeper);
    event PriceGuardUpdated(uint256 baseBps, uint256 upBpsPerDay, uint256 downBpsPerDay, uint256 maxUpBps, uint256 maxDownBps);
    event AnchorUpdated(uint256 anchorPps, uint256 anchorTimestamp);
    event ExitRequested(uint256 indexed tokenId, uint256 stEthAmount);
    event ExitClaimed(uint256 indexed tokenId, uint256 ethClaimed);

    error NoPendingExit();
    error ExitPending(uint256 tokenId);
    error UnknownExit(uint256 tokenId);
    error NotKeeper(address caller);
    error InvalidBps(uint256 value);
    error ZeroSharePrice();
    error PriceOutsideRoom(uint256 livePps, uint256 lower, uint256 upper);
    error PriceOutsideAcceptBounds(uint256 livePps, uint256 minPps, uint256 maxPps);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper(msg.sender);
        _;
    }

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _iETH,
        address _stETH,
        address _withdrawalQueue,
        PriceGuardParams memory _guard
    ) MYTStrategy(_myt, _params) {
        require(_iETH != address(0), "Zero iETH address");
        require(_stETH != address(0), "Zero stETH address");
        require(_withdrawalQueue != address(0), "Zero withdrawal queue address");
        require(IFluidLiteETHVault(_iETH).asset() == _stETH, "iETH asset != stETH");

        iETH = IFluidLiteETHVault(_iETH);
        stETH = IStETH(_stETH);
        withdrawalQueue = ILidoWithdrawalQueue(_withdrawalQueue);
        shareUnit = 10 ** IFluidLiteETHVault(_iETH).decimals();

        _setPriceGuard(_guard);
        _acceptLivePrice();
    }

    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 minStEthOut = (amount * (BPS - params.slippageBPS)) / BPS;
        if (minStEthOut == 0) minStEthOut = 1;

        uint256 stEthReceived = dexSwap(address(stETH), _asset(), amount, minStEthOut, callData);
        require(stEthReceived > 0, "No stETH received");

        _depositIntoVault(stEthReceived);

        // Checked after the deposit so it reads the realized price; a revert undoes the deposit.
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower || live > upper) revert PriceOutsideRoom(live, lower, upper);

        _moveAnchor();
        return amount;
    }

    function _depositIntoVault(uint256 stEthAmount) internal {
        TokenUtils.safeApprove(address(stETH), address(iETH), stEthAmount);
        uint256 sharesReceived = iETH.deposit(stEthAmount, address(this));
        TokenUtils.safeApprove(address(stETH), address(iETH), 0);
        require(sharesReceived > 0, "No iETHv2 received");
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        _settleMaturedExit();
        uint256 idleBalance = _idleAssets();
        require(idleBalance >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount) internal override returns (uint256) {
        _settleMaturedExit();
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }
        uint256 shortfall = amount - idleBalance;

        uint256 maxStEthIn = _roundUpMulDiv(shortfall, BPS, BPS - params.slippageBPS);
        require(minIntermediateOutAmount <= maxStEthIn, "Intermediate exceeds max stETH in");

        uint256 stEthBalance = stETH.balanceOf(address(this));
        if (stEthBalance < maxStEthIn) {
            _withdrawFromVault(maxStEthIn - stEthBalance);
            _requireAboveFloor();
        }

        uint256 stEthToSwap = stETH.balanceOf(address(this));
        if (stEthToSwap > maxStEthIn) stEthToSwap = maxStEthIn;
        require(stEthToSwap > 0, "No stETH to swap");
        require(stEthToSwap >= minIntermediateOutAmount, "Insufficient intermediate out");

        dexSwap(_asset(), address(stETH), stEthToSwap, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        _moveAnchor();
        return amount;
    }

    function _withdrawFromVault(uint256 netStEth) internal {
        uint256 gross = _grossUpForWithdrawFee(netStEth) + STETH_ROUNDING_BUFFER;
        uint256 maxFromVault = iETH.maxWithdraw(address(this));
        uint256 vaultIdle = stETH.balanceOf(address(iETH));
        if (gross > maxFromVault) gross = maxFromVault;
        if (gross > vaultIdle) gross = vaultIdle;
        require(gross > 0, "No iETHv2 available");
        iETH.withdraw(gross, address(this), address(this));
    }

    function _grossUpForWithdrawFee(uint256 net) internal view returns (uint256 gross) {
        uint256 feePct = iETH.withdrawalFeePercentage();
        require(feePct < FEE_SCALE, "Invalid withdraw fee");

        gross = (net * FEE_SCALE + (FEE_SCALE - feePct) - 1) / (FEE_SCALE - feePct);

        uint256 withAbsoluteMin = net + iETH.withdrawFeeAbsoluteMin();
        if (withAbsoluteMin > gross) gross = withAbsoluteMin;

        require(gross - iETH.getWithdrawFee(gross) >= net, "Withdraw fee gross-up failed");
    }

    function withdrawFromVault(uint256 netStEth) external onlyKeeperOrOwner returns (uint256 stEthReceived) {
        if (netStEth == 0) revert InvalidAmount(1, 0);

        uint256 balanceBefore = stETH.balanceOf(address(this));
        _withdrawFromVault(netStEth);
        stEthReceived = stETH.balanceOf(address(this)) - balanceBefore;
        require(stEthReceived >= netStEth, "Insufficient stETH withdrawn");

        _requireAboveFloor();
        _moveAnchor();
    }

    function requestExits(uint256 stEthAmount) external onlyKeeperOrOwner returns (uint256 tokenId) {
        if (stEthAmount == 0) revert InvalidAmount(1, 0);
        _settleMaturedExit();
        if (_pendingExit.tokenId != 0) revert ExitPending(_pendingExit.tokenId);

        require(stETH.balanceOf(address(this)) >= stEthAmount, "Insufficient stETH");
        require(stEthAmount >= withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT(), "Below queue minimum");
        require(stEthAmount <= withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT(), "Amount exceeds queue limits");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = stEthAmount;
        TokenUtils.safeApprove(address(stETH), address(withdrawalQueue), stEthAmount);
        tokenId = withdrawalQueue.requestWithdrawals(amounts, address(this))[0];
        TokenUtils.safeApprove(address(stETH), address(withdrawalQueue), 0);

        _pendingExit = PendingExit({tokenId: tokenId});

        emit ExitRequested(tokenId, stEthAmount);
    }

    function claimExits() external returns (uint256 ethClaimed) {
        return _claimExit(false);
    }

    /// @dev tolerant decides whether a failed Lido claim aborts the caller or is ignored.
    /// In the case of `_settleMaturedExit`, the claim is a side task there, 
    /// so a failure returns 0 and the main action continues.
    function _claimExit(bool tolerant) internal returns (uint256 ethClaimed) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) revert NoPendingExit();

        uint256 ethBefore = address(this).balance;
        if (tolerant) {
            try withdrawalQueue.claimWithdrawal(tokenId) {} catch { return 0; }
        } else {
            withdrawalQueue.claimWithdrawal(tokenId);
        }
        ethClaimed = address(this).balance - ethBefore;

        delete _pendingExit;
        if (ethClaimed > 0) IWETH(_asset()).deposit{value: ethClaimed}();
        emit ExitClaimed(tokenId, ethClaimed);
    }

    function _settleMaturedExit() internal {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _requestStatus(tokenId);
        if (status.isClaimed || !status.isFinalized) return;
        _claimExit(true);
    }

    function _claimWithdrawalQueue(uint256 positionId) internal override returns (uint256) {
        if (positionId != _pendingExit.tokenId) revert UnknownExit(positionId);
        return _claimExit(false);
    }

    /// @dev The iETHv2 leg is reported at the live price clamped into the band, so a share price move
    ///      reaches the MYT only as fast as the anchor is allowed to travel, or when the owner accepts it.
    function _totalValue() internal view override returns (uint256) {
        uint256 unclamped = _idleAssets() + stETH.balanceOf(address(this)) + _pendingExitValue();

        uint256 shares = iETH.balanceOf(address(this));
        if (shares == 0) return unclamped;

        uint256 live = _liveSharePrice();
        uint256 raw = iETH.previewRedeem(shares);
        if (live == 0 || raw == 0) return unclamped;

        (uint256 lower, uint256 upper) = _reportingBounds();
        uint256 clamped = live;
        if (clamped > upper) clamped = upper;
        if (clamped < lower) clamped = lower;
        return unclamped + (raw * clamped) / live;
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(_asset(), address(this));
    }

    function _pendingExitValue() internal view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _requestStatus(tokenId);
        if (status.isClaimed) return 0;
        if (status.isFinalized) return _claimableEther(tokenId);

        uint256 current = stETH.getPooledEthByShares(status.amountOfShares);
        return current < status.amountOfStETH ? current : status.amountOfStETH;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;

        uint256 vaultValue = iETH.previewRedeem(iETH.balanceOf(address(this)));
        uint256 vaultIdle = stETH.balanceOf(address(iETH));
        uint256 fromVault = vaultValue < vaultIdle ? vaultValue : vaultIdle;
        uint256 fee = iETH.getWithdrawFee(fromVault);
        uint256 positionValue = stETH.balanceOf(address(this)) + (fromVault > fee ? fromVault - fee : 0);

        uint256 fundableFromPosition = remaining <= positionValue ? remaining : positionValue;
        return fromIdle + (fundableFromPosition * (BPS - params.slippageBPS)) / BPS;
    }

    function _asset() internal view returns (address) {
        return MYT.asset();
    }

    function _requestStatus(uint256 tokenId) internal view returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        return withdrawalQueue.getWithdrawalStatus(ids)[0];
    }

    
    /// @dev Returns the amount of claimable Ether for a given withdrawal request tokenId.
    function _claimableEther(uint256 tokenId) internal view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory hints = withdrawalQueue.findCheckpointHints(ids, 1, withdrawalQueue.getLastCheckpointIndex());
        return withdrawalQueue.getClaimableEther(ids, hints)[0];
    }

    function _roundUpMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }

    function pendingExitCount() external view returns (uint256) {
        return _pendingExit.tokenId == 0 ? 0 : 1;
    }

    function pendingExit() external view returns (PendingExit memory) {
        return _pendingExit;
    }

    function isPendingExit(uint256 tokenId) external view returns (bool) {
        return _pendingExit.tokenId == tokenId;
    }

    function claimableExits() external view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _requestStatus(tokenId);
        if (status.isClaimed || !status.isFinalized) return 0;
        return _claimableEther(tokenId);
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == _asset() || token == address(stETH) || token == address(iETH) || token == address(withdrawalQueue);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(withdrawalQueue), "Unexpected NFT sender");
        return this.onERC721Received.selector;
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setPriceGuard(PriceGuardParams calldata _guard) external onlyOwner {
        _setPriceGuard(_guard);
    }

    /// @notice Book the live price as the anchor if it lands inside `[minPps, maxPps]`, a band the owner reads off chain.
    function acceptPrice(uint256 minPps, uint256 maxPps) external onlyOwner {
        uint256 live = _liveSharePrice();
        if (live < minPps || live > maxPps) revert PriceOutsideAcceptBounds(live, minPps, maxPps);
        _acceptLivePrice();
    }

    /// @notice Move the anchor toward the live price by at most the accrued travel budget.
    function poke() external {
        _moveAnchor();
    }

    /// @notice Live stETH per `shareUnit`.
    function liveSharePrice() external view returns (uint256) {
        return _liveSharePrice();
    }

    /// @notice Floor and ceiling `_totalValue` reports inside, and the band `allocate` must sit inside.
    function priceBounds() external view returns (uint256 lower, uint256 upper) {
        return _reportingBounds();
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

    /// @dev Run after a vault call that realizes value, so it reads the realized price and a revert undoes the call.
    function _requireAboveFloor() internal view {
        uint256 live = _liveSharePrice();
        (uint256 lower, uint256 upper) = _reportingBounds();
        if (live < lower) revert PriceOutsideRoom(live, lower, upper);
    }

    function _liveSharePrice() internal view returns (uint256) {
        return iETH.previewRedeem(shareUnit);
    }

    /// @dev Band `_totalValue` reports inside and vault interactions check against; at least `baseBps` wide.
    function _reportingBounds() internal view returns (uint256 lower, uint256 upper) {
        return _boundsWithMinRoom(baseBps);
    }

    /// @dev Band the anchor may move into.
    function _anchorMoveBounds() internal view returns (uint256 lower, uint256 upper) {
        return _boundsWithMinRoom(0);
    }

    /// @param minRoomBps Room that is open regardless of elapsed time.
    function _boundsWithMinRoom(uint256 minRoomBps) internal view returns (uint256 lower, uint256 upper) {
        uint256 elapsed = block.timestamp > anchorTimestamp ? block.timestamp - anchorTimestamp : 0;
        uint256 upRoom = _room(upBpsPerDay, maxUpBps, elapsed, minRoomBps);
        uint256 downRoom = _room(downBpsPerDay, maxDownBps, elapsed, minRoomBps);
        upper = (anchorPps * (BPS + upRoom)) / BPS;
        lower = (anchorPps * (BPS - downRoom)) / BPS;
    }

    /// @dev Room in bps: `min(cap, minRoom + perDay * elapsed / 1 day)`.
    function _room(uint256 perDay, uint256 cap, uint256 elapsed, uint256 minRoomBps) internal pure returns (uint256) {
        uint256 room = minRoomBps + (perDay * elapsed) / 1 days;
        return room > cap ? cap : room;
    }

    receive() external payable {}
}
