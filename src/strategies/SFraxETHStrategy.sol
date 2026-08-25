// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IFraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256 shares);
}

interface ISfrxETH {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface IFraxEtherRedemptionQueue {
    struct RedemptionQueueItem {
        bool hasBeenRedeemed;
        uint64 maturity;
        uint120 amount;
        uint64 earlyExitFee;
    }

    function nftInformation(uint256 nftId) external view returns (RedemptionQueueItem memory);
    function enterRedemptionQueueViaSfrxEth(address _recipient, uint120 _sfrxEthAmount) external returns (uint256 _nftId);
    function burnRedemptionTicketNft(uint256 _nftId, address payable _recipient) external;
}

/**
 * @title SFraxETHStrategy
 * @notice Allocates WETH into sfrxETH via the Frax minter. Oracle-free: values the
 *         position at the canonical sfrxETH share rate (frxETH priced 1:1 with ETH)
 *         and pending redemption-queue tickets at FraxEtherRedemptionQueue state.
 */
contract SFraxETHStrategy is MYTStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_PENDING_HAIRCUT_BPS = 1000;
    uint256 public constant MAX_RATE_DROP_BPS = 5000;

    IFraxMinter public immutable minter;
    IERC20 public immutable frxETH;
    ISfrxETH public immutable sfrxETH;
    IFraxEtherRedemptionQueue public immutable redemptionQueue;
    bool public canForceDeallocate = false;

    /// @notice Authorized caller (besides the owner) for `requestExits`.
    address public keeper;
    /// @notice Discount applied to unmatured queue tickets in `_totalValue`.
    uint256 public pendingHaircutBps = 100;
    /// @notice Max share-rate drop before the kill switch trips; zero disables.
    uint256 public maxRateDropBps = 50;
    /// @notice Canonical frxETH-per-sfrxETH rate observed at the last successful allocation.
    uint256 public rateCheckpoint;

    /// @dev At most one queue exit is in flight; tokenId == 0 means none.
    struct PendingExit {
        uint256 tokenId;
    }
    PendingExit internal _pendingExit;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    event KeeperUpdated(address indexed keeper);
    event PendingHaircutBpsUpdated(uint256 newPendingHaircutBps);
    event MaxRateDropBpsUpdated(uint256 newMaxRateDropBps);
    event RateGuardTripped(uint256 checkpointRate, uint256 observedRate);
    event ExitRequested(uint256 indexed tokenId, uint256 sfrxEthShares);
    event ExitClaimed(uint256 indexed tokenId, uint256 ethClaimed);

    error NoPendingExit();
    error ExitPending(uint256 tokenId);
    error UnknownExit(uint256 tokenId);
    error NotKeeper(address caller);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper(msg.sender);
        _;
    }

    constructor(address _myt, StrategyParams memory _params, address _minter, address _frxETH, address _sfrxETH, address _redemptionQueue)
        MYTStrategy(_myt, _params)
    {
        require(_minter != address(0), "Zero minter address");
        require(_frxETH != address(0), "Zero frxETH address");
        require(_sfrxETH != address(0), "Zero sfrxETH address");
        require(_redemptionQueue != address(0), "Zero redemption queue address");

        minter = IFraxMinter(_minter);
        frxETH = IERC20(_frxETH);
        sfrxETH = ISfrxETH(_sfrxETH);
        redemptionQueue = IFraxEtherRedemptionQueue(_redemptionQueue);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _checkRate();
        _ensureIdleBalance(_asset(), amount);
        IWETH(_asset()).withdraw(amount);
        uint256 sharesReceived = minter.submitAndDeposit{value: amount}(address(this));
        require(sharesReceived > 0, "No sfrxETH received");
        return amount;
    }

    /// @dev Min output floored by the canonical 1:1 frxETH:ETH rate instead of a price feed.
    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _checkRate();
        _ensureIdleBalance(_asset(), amount);

        uint256 minFrxEthOut = (amount * (BPS - params.slippageBPS)) / BPS;
        if (minFrxEthOut == 0) minFrxEthOut = 1;

        uint256 frxEthReceived = dexSwap(address(frxETH), _asset(), amount, minFrxEthOut, callData);
        require(frxEthReceived > 0, "No frxETH received");

        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), frxEthReceived);
        uint256 sharesReceived = sfrxETH.deposit(frxEthReceived, address(this));
        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), 0);
        require(sharesReceived > 0, "No sfrxETH received");
        return amount;
    }

    /// @notice Frax has no protocol-native instant exit, so amounts beyond instant
    ///         capacity revert; the async queue refills idle WETH over subsequent days.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        _settleMaturedExit();
        uint256 idleBalance = _idleAssets();
        require(idleBalance >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    /// @dev Redeems sfrxETH into frxETH as needed, then swaps frxETH -> WETH with the
    ///      min output floored at the shortfall. Matured queue exits are auto-claimed first.
    function _deallocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        return _deallocateViaFrxEth(amount, callData, 0);
    }

    /// @dev Unwrap-and-swap path; a nonzero `minIntermediateOut` floors the frxETH produced before the swap.
    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount) internal override returns (uint256) {
        return _deallocateViaFrxEth(amount, callData, minIntermediateOutAmount);
    }

    function _deallocateViaFrxEth(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount) internal returns (uint256) {
        _settleMaturedExit();
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }
        uint256 shortfall = amount - idleBalance;

        uint256 maxFrxEthIn = _roundUpMulDiv(shortfall, BPS, BPS - params.slippageBPS);
        require(minIntermediateOutAmount <= maxFrxEthIn, "Intermediate exceeds max oracle token in");
        uint256 target = maxFrxEthIn;

        uint256 frxEthBalance = frxETH.balanceOf(address(this));
        if (frxEthBalance < target) {
            uint256 sharesBalance = sfrxETH.balanceOf(address(this));
            require(sharesBalance > 0, "No sfrxETH available");
            uint256 shares = _sharesForFrxEthUp(target - frxEthBalance);
            if (shares > sharesBalance) shares = sharesBalance;
            sfrxETH.redeem(shares, address(this), address(this));
        }

        uint256 frxEthToSwap = frxETH.balanceOf(address(this));
        if (frxEthToSwap > target) frxEthToSwap = target;
        require(frxEthToSwap > 0, "No frxETH to swap");

        dexSwap(_asset(), address(frxETH), frxEthToSwap, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    /// @notice Redeem sfrxETH and enter the Frax redemption queue; the minted
    ///         FrxETHRedemptionTicket NFT is tracked until claimed. One exit at a time:
    ///         a matured previous exit is auto-claimed first, an unmatured one
    ///         reverts `ExitPending`.
    function requestExits(uint256 wethAmount) external onlyKeeperOrOwner returns (uint256 tokenId) {
        if (wethAmount == 0) revert InvalidAmount(1, 0);
        _settleMaturedExit();
        if (_pendingExit.tokenId != 0) revert ExitPending(_pendingExit.tokenId);

        uint256 sharesBalance = sfrxETH.balanceOf(address(this));
        require(sharesBalance > 0, "No sfrxETH available");

        uint256 shares = _sharesForFrxEthUp(wethAmount);
        if (shares > sharesBalance) shares = sharesBalance;
        require(shares > 0, "No sfrxETH to exit");
        require(shares <= type(uint120).max, "Amount exceeds queue limits");

        TokenUtils.safeApprove(address(sfrxETH), address(redemptionQueue), shares);
        tokenId = redemptionQueue.enterRedemptionQueueViaSfrxEth(address(this), uint120(shares));
        TokenUtils.safeApprove(address(sfrxETH), address(redemptionQueue), 0);

        _pendingExit = PendingExit({tokenId: tokenId});

        emit ExitRequested(tokenId, shares);
    }

    /// @notice Claim the pending redemption ticket and wrap the received ETH as idle WETH.
    /// @dev Permissionless; reverts via the protocol when the ticket is not yet mature.
    function claimExits() external returns (uint256 ethClaimed) {
        return _claimExit();
    }

    function _claimExit() internal returns (uint256 ethClaimed) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) revert NoPendingExit();

        uint256 ethBefore = address(this).balance;
        redemptionQueue.burnRedemptionTicketNft(tokenId, payable(address(this)));
        ethClaimed = address(this).balance - ethBefore;

        delete _pendingExit;
        if (ethClaimed > 0) IWETH(_asset()).deposit{value: ethClaimed}();
        emit ExitClaimed(tokenId, ethClaimed);
    }

    /// @dev Claims the pending exit once matured; no-op otherwise. The queue's
    ///      documented ETH-shortage state (available ETH earmarked for earlier
    ///      tickets) is pre-checked via its balance and skipped; after the
    ///      pre-checks the claim is deterministic, so any other failure reverts
    ///      loudly through the caller.
    function _settleMaturedExit() internal {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return;
        IFraxEtherRedemptionQueue.RedemptionQueueItem memory item = redemptionQueue.nftInformation(tokenId);
        if (item.hasBeenRedeemed || block.timestamp < item.maturity) return;
        if (address(redemptionQueue).balance < item.amount) return;
        _claimExit();
    }

    /// @dev Claim hook for the base contract; only the tracked exit is claimable.
    function _claimWithdrawalQueue(uint256 positionId) internal override returns (uint256) {
        if (positionId != _pendingExit.tokenId) revert UnknownExit(positionId);
        return _claimExit();
    }

    /// @notice Idle WETH + loose frxETH + sfrxETH at the canonical share rate + pending
    ///         ticket (matured at claimable amount, otherwise amount minus haircut).
    function _totalValue() internal view override returns (uint256) {
        return _idleAssets() + frxETH.balanceOf(address(this)) + sfrxETH.convertToAssets(sfrxETH.balanceOf(address(this))) + _pendingExitValue();
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(_asset(), address(this));
    }

    function _pendingExitValue() internal view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        IFraxEtherRedemptionQueue.RedemptionQueueItem memory item = redemptionQueue.nftInformation(tokenId);
        if (item.hasBeenRedeemed) return 0;
        if (block.timestamp >= item.maturity) return item.amount;
        return (uint256(item.amount) * (BPS - pendingHaircutBps)) / BPS;
    }

    /// @notice Instant capacity only; pending queue tickets are excluded.
    /// @dev The position-value leg assumes a market (dex) exit for sfrxETH/frxETH;
    ///      the direct path can only serve idle WETH plus matured tickets.
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;
        uint256 positionValue = frxETH.balanceOf(address(this)) + sfrxETH.convertToAssets(sfrxETH.balanceOf(address(this)));
        uint256 fundableFromPosition = remaining <= positionValue ? remaining : positionValue;
        return fromIdle + (fundableFromPosition * (BPS - params.slippageBPS)) / BPS;
    }

    function _asset() internal view returns (address) {
        return MYT.asset();
    }

    /// @dev Shares that redeem at least `frxEthAmount` (redeem rounds down).
    function _sharesForFrxEthUp(uint256 frxEthAmount) internal view returns (uint256 shares) {
        shares = sfrxETH.previewWithdraw(frxEthAmount);
        if (sfrxETH.convertToAssets(shares) < frxEthAmount) {
            shares += 1;
        }
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

    /// @notice Claimable amount once the pending ticket is mature, else 0.
    function claimableExits() external view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        IFraxEtherRedemptionQueue.RedemptionQueueItem memory item = redemptionQueue.nftInformation(tokenId);
        if (item.hasBeenRedeemed || block.timestamp < item.maturity) return 0;
        return item.amount;
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == _asset() || token == address(frxETH) || token == address(sfrxETH) || token == address(redemptionQueue);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(redemptionQueue), "Unexpected NFT sender");
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

    function setPendingHaircutBps(uint256 newPendingHaircutBps) external onlyOwner {
        require(newPendingHaircutBps <= MAX_PENDING_HAIRCUT_BPS, "Haircut too high");
        pendingHaircutBps = newPendingHaircutBps;
        emit PendingHaircutBpsUpdated(newPendingHaircutBps);
    }

    function setMaxRateDropBps(uint256 newMaxRateDropBps) external onlyOwner {
        require(newMaxRateDropBps <= MAX_RATE_DROP_BPS, "Rate drop bound too high");
        maxRateDropBps = newMaxRateDropBps;
        emit MaxRateDropBpsUpdated(newMaxRateDropBps);
    }

    /// @dev Trips the kill switch when the canonical share rate drops more than
    ///      `maxRateDropBps` below the allocation checkpoint. Does not revert, so the
    ///      kill-switch write persists; future allocations revert until the owner clears it.
    function _checkRate() internal {
        uint256 rate = sfrxETH.convertToAssets(1e18);
        if (maxRateDropBps != 0 && rateCheckpoint != 0 && rate < (rateCheckpoint * (BPS - maxRateDropBps)) / BPS) {
            killSwitch = true;
            emit RateGuardTripped(rateCheckpoint, rate);
            emit Emergency(true);
            return;
        }
        rateCheckpoint = rate;
    }

    receive() external payable {}
}
