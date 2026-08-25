// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IDepositAdapter {
    function depositWETHForWeETH(uint256 amount, address referral) external returns (uint256);
}

interface IRedemptionManager {
    struct RedemptionLimit {
        uint64 capacity;
        uint64 remaining;
        uint64 lastRefill;
        uint64 refillRate;
    }

    function canRedeem(uint256 amount, address token) external view returns (bool);
    function liquidityPool() external view returns (address);
    function previewRedeem(uint256 shares, address token) external view returns (uint256);
    function tokenToRedemptionInfo(address token)
        external
        view
        returns (RedemptionLimit memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl);
    function redeemWeEth(uint256 amount, address receiver, address outputToken) external;
}

interface ILiquidityPoolLike {
    function amountForShare(uint256 shares) external view returns (uint256);
    function sharesForAmount(uint256 amount) external view returns (uint256);
    function sharesForWithdrawalAmount(uint256 amount) external view returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
    function withdraw(address recipient, uint256 amount) external returns (uint256);
    function minWithdrawAmount() external view returns (uint256);
    function maxWithdrawAmount() external view returns (uint256);
    function withdrawRequestNFT() external view returns (address);
}

interface IWithdrawRequestNFT {
    struct WithdrawRequest {
        uint96 amountOfEEth;
        uint96 shareOfEEth;
        bool isValid;
        uint32 feeGwei;
    }

    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory);
    function isFinalized(uint256 requestId) external view returns (bool);
    function getClaimableAmount(uint256 tokenId) external view returns (uint256);
    function claimWithdraw(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IWeETH {
    function balanceOf(address account) external view returns (uint256);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256);
    function unwrap(uint256 weETHAmount) external returns (uint256);
    function wrap(uint256 eETHAmount) external returns (uint256);
}

/**
 * @title EtherfiEETHMYTStrategy
 * @notice Allocates WETH into weETH via the Ether.fi DepositAdapter. Oracle-free:
 *         values the position at the canonical weETH->eETH rate and pending
 *         withdrawal-queue claims at WithdrawRequestNFT state.
 */
contract EtherfiEETHMYTStrategy is MYTStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_GROSS_REDEEM_AMOUNT_BUFFER = 1e18;
    uint256 public constant MAX_PENDING_HAIRCUT_BPS = 1000;
    uint256 public constant MAX_RATE_DROP_BPS = 5000;

    IDepositAdapter public immutable depositAdapter;
    IRedemptionManager public immutable redemptionManager;
    IWeETH public immutable weETH;
    IERC20 public immutable eETH;
    // address used to request native ETH instead of an ERC20 token.
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bool public canForceDeallocate = false;
    uint256 public grossRedeemAmountBuffer = 1;

    /// @notice Authorized caller (besides the owner) for `requestExits`.
    address public keeper;
    /// @notice Discount applied to unfinalized queue claims in `_totalValue`.
    uint256 public pendingHaircutBps = 100;
    /// @notice Max canonical-rate drop before the kill switch trips; zero disables.
    uint256 public maxRateDropBps = 50;
    /// @notice Canonical eETH-per-weETH rate observed at the last successful allocation.
    uint256 public rateCheckpoint;

    /// @dev At most one queue exit is in flight; tokenId == 0 means none.
    struct PendingExit {
        uint256 tokenId;
        uint96 shareOfEEth;
    }
    PendingExit internal _pendingExit;

    event GrossRedeemAmountBufferUpdated(uint256 grossRedeemAmountBuffer);
    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    event KeeperUpdated(address indexed keeper);
    event PendingHaircutBpsUpdated(uint256 newPendingHaircutBps);
    event MaxRateDropBpsUpdated(uint256 newMaxRateDropBps);
    event RateGuardTripped(uint256 checkpointRate, uint256 observedRate);
    event ExitRequested(uint256 indexed tokenId, uint256 indexed eEthAmount, uint96 shares);
    event ExitClaimed(uint256 indexed tokenId, uint256 ethClaimed);
    event InvalidExitRemoved(uint256 indexed tokenId);

    error NoPendingExit();
    error ExitPending(uint256 tokenId);
    error UnknownExit(uint256 tokenId);
    error NotKeeper(address caller);
    error ExitStillValid(uint256 tokenId);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper(msg.sender);
        _;
    }

    constructor(address _myt, StrategyParams memory _params, address _eETH, address _weETH, address _depositAdapter, address _redemptionManager)
        MYTStrategy(_myt, _params)
    {
        require(_eETH != address(0), "Zero eETH address");
        require(_weETH != address(0), "Zero weETH address");
        require(_depositAdapter != address(0), "Zero deposit adapter address");
        require(_redemptionManager != address(0), "Zero redemption manager address");

        eETH = IERC20(_eETH);
        weETH = IWeETH(_weETH);
        depositAdapter = IDepositAdapter(_depositAdapter);
        redemptionManager = IRedemptionManager(_redemptionManager);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _checkRate();
        _ensureIdleBalance(_asset(), amount);
        TokenUtils.safeApprove(_asset(), address(depositAdapter), amount);
        depositAdapter.depositWETHForWeETH(amount, address(0));
        TokenUtils.safeApprove(_asset(), address(depositAdapter), 0);
        return amount;
    }

    /// @dev Min output floored by the canonical weETH->eETH rate instead of a price feed.
    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _checkRate();
        _ensureIdleBalance(_asset(), amount);

        uint256 minEEthOut = (amount * (BPS - params.slippageBPS)) / BPS;
        if (minEEthOut == 0) minEEthOut = 1;
        uint256 minWeEthOut = _weEthFromEEthUp(minEEthOut);
        if (minWeEthOut == 0) minWeEthOut = 1;

        dexSwap(address(weETH), _asset(), amount, minWeEthOut, callData);
        return amount;
    }

    /// @notice Synchronous exit cascading idle WETH -> instant redemption ->
    ///         LP instant withdraw; reverts when instant capacity cannot cover `amount`.
    ///         Finalized queue exits are auto-claimed into idle WETH first.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        _settleFinalizedExit();
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }
        uint256 shortfall = amount - idleBalance;

        // Leg 1: Ether.fi instant redemption through the RedemptionManager.
        uint256 weETHBalance = weETH.balanceOf(address(this));
        if (weETHBalance > 0) {
            (, uint16 exitFeeInBps,) = _redemptionInfo();
            if (exitFeeInBps < BPS) {
                uint256 weETHToRedeem = _weETHForNetShortfall(shortfall, exitFeeInBps, weETHBalance);
                uint256 grossRedeemAmount = weETH.getEETHByWeETH(weETHToRedeem);
                bool canRedeem;
                try redemptionManager.canRedeem(grossRedeemAmount, ETH) returns (bool ok) {
                    canRedeem = ok;
                } catch {
                    canRedeem = false;
                }
                if (canRedeem) {
                    TokenUtils.safeApprove(address(weETH), address(redemptionManager), weETHToRedeem);
                    uint256 ethBefore = address(this).balance;
                    redemptionManager.redeemWeEth(weETHToRedeem, address(this), ETH);
                    uint256 ethReceived = address(this).balance - ethBefore;
                    TokenUtils.safeApprove(address(weETH), address(redemptionManager), 0);
                    if (ethReceived > 0) IWETH(_asset()).deposit{value: ethReceived}();
                }
            }
        }

        // Leg 2: LiquidityPool instant withdraw against held eETH.
        if (_idleAssets() < amount) {
            uint256 weETHRemaining = weETH.balanceOf(address(this));
            if (weETHRemaining > 0) {
                uint256 remaining = amount - _idleAssets();
                uint256 weETHToUnwrap = weETH.getWeETHByeETH(remaining);
                if (weETHToUnwrap == 0 || weETH.getEETHByWeETH(weETHToUnwrap) < remaining) {
                    weETHToUnwrap += 1;
                }
                if (weETHToUnwrap > weETHRemaining) weETHToUnwrap = weETHRemaining;
                weETH.unwrap(weETHToUnwrap);
                _tryLiquidityPoolWithdraw();
            }
        }

        require(_idleAssets() >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    /// @dev Min WETH out is the shortfall; max weETH in is bounded by the canonical
    ///      rate plus slippage tolerance. Finalized queue exits are auto-claimed first.
    function _deallocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _settleFinalizedExit();
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }
        uint256 shortfall = amount - idleBalance;

        uint256 weETHBalance = weETH.balanceOf(address(this));
        require(weETHBalance > 0, "No weETH available");

        uint256 maxAssetIn = _roundUpMulDiv(shortfall, BPS, BPS - params.slippageBPS);
        uint256 maxWeEthIn = _weEthFromEEthUp(maxAssetIn);
        if (maxWeEthIn == 0) maxWeEthIn = 1;
        uint256 weEthToSwap = maxWeEthIn > weETHBalance ? weETHBalance : maxWeEthIn;

        dexSwap(_asset(), address(weETH), weEthToSwap, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    /// @notice Unwrap weETH and enter the Ether.fi withdrawal queue; the minted
    ///         WithdrawRequestNFT is tracked until claimed. One exit at a time:
    ///         a finalized previous exit is auto-claimed first, an unfinalized
    ///         one reverts `ExitPending`.
    function requestExits(uint256 wethAmount) external onlyKeeperOrOwner returns (uint256 tokenId, uint96 shares) {
        if (wethAmount == 0) revert InvalidAmount(1, 0);
        _settleFinalizedExit();
        if (_pendingExit.tokenId != 0) revert ExitPending(_pendingExit.tokenId);

        uint256 weETHBalance = weETH.balanceOf(address(this));
        require(weETHBalance > 0, "No weETH available");

        uint256 weETHToUnwrap = weETH.getWeETHByeETH(wethAmount);
        if (weETHToUnwrap == 0 || weETH.getEETHByWeETH(weETHToUnwrap) < wethAmount) {
            weETHToUnwrap += 1;
        }
        if (weETHToUnwrap > weETHBalance) weETHToUnwrap = weETHBalance;
        require(weETHToUnwrap > 0, "No weETH to exit");

        uint256 eEthToExit = weETH.unwrap(weETHToUnwrap);
        require(eEthToExit > 0, "No eETH to exit");

        ILiquidityPoolLike pool = _liquidityPool();
        TokenUtils.safeApprove(address(eETH), address(pool), eEthToExit);
        tokenId = pool.requestWithdraw(address(this), eEthToExit);
        TokenUtils.safeApprove(address(eETH), address(pool), 0);

        IWithdrawRequestNFT.WithdrawRequest memory request = _withdrawRequestNFT().getRequest(tokenId);
        require(request.isValid && request.shareOfEEth > 0, "Invalid withdraw request");
        shares = request.shareOfEEth;

        _pendingExit = PendingExit({tokenId: tokenId, shareOfEEth: shares});

        emit ExitRequested(tokenId, eEthToExit, shares);
    }

    /// @notice Claim the pending withdrawal request and wrap the received ETH as idle WETH.
    /// @dev Permissionless; reverts via the protocol when the request is not finalized.
    function claimExits() external returns (uint256 ethClaimed) {
        return _claimExit();
    }

    /// @notice Drop a pending exit invalidated by the protocol (no residual claim).
    function removeInvalidExit() external onlyOwner {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) revert NoPendingExit();
        if (_withdrawRequestNFT().getRequest(tokenId).isValid) revert ExitStillValid(tokenId);
        delete _pendingExit;
        emit InvalidExitRemoved(tokenId);
    }

    function _claimExit() internal returns (uint256 ethClaimed) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) revert NoPendingExit();

        uint256 ethBefore = address(this).balance;
        _withdrawRequestNFT().claimWithdraw(tokenId);
        ethClaimed = address(this).balance - ethBefore;

        delete _pendingExit;
        if (ethClaimed > 0) IWETH(_asset()).deposit{value: ethClaimed}();
        emit ExitClaimed(tokenId, ethClaimed);
    }

    /// @dev Claims the pending exit once finalized; no-op otherwise.
    function _settleFinalizedExit() internal {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return;
        if (_withdrawRequestNFT().isFinalized(tokenId)) _claimExit();
    }

    /// @dev Claim hook for the base contract; only the tracked exit is claimable.
    function _claimWithdrawalQueue(uint256 positionId) internal override returns (uint256) {
        if (positionId != _pendingExit.tokenId) revert UnknownExit(positionId);
        return _claimExit();
    }

    /// @notice Idle WETH + loose eETH + weETH at the canonical rate + pending claim
    ///         (finalized at claimable amount, otherwise share value minus haircut).
    function _totalValue() internal view override returns (uint256) {
        return _idleAssets() + eETH.balanceOf(address(this)) + weETH.getEETHByWeETH(weETH.balanceOf(address(this))) + _pendingExitValue();
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(_asset(), address(this));
    }

    function _pendingExitValue() internal view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        if (_withdrawRequestNFT().isFinalized(tokenId)) {
            return _withdrawRequestNFT().getClaimableAmount(tokenId);
        }
        return (_liquidityPool().amountForShare(_pendingExit.shareOfEEth) * (BPS - pendingHaircutBps)) / BPS;
    }

    /// @notice Instant capacity only; pending queue claims are excluded.
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;
        uint256 positionValue = eETH.balanceOf(address(this)) + weETH.getEETHByWeETH(weETH.balanceOf(address(this)));
        uint256 fundableFromPosition = remaining <= positionValue ? remaining : positionValue;
        return fromIdle + (fundableFromPosition * (BPS - params.slippageBPS)) / BPS;
    }

    function _asset() internal view returns (address) {
        return MYT.asset();
    }

    function _liquidityPool() internal view returns (ILiquidityPoolLike) {
        return ILiquidityPoolLike(redemptionManager.liquidityPool());
    }

    function _withdrawRequestNFT() internal view returns (IWithdrawRequestNFT) {
        return IWithdrawRequestNFT(_liquidityPool().withdrawRequestNFT());
    }

    /// @dev Instant LP withdraw with the full eETH balance; bounds reads tolerate
    ///      pools without `min/maxWithdrawAmount`, failures are tolerated, and
    ///      leftover eETH is re-wrapped.
    function _tryLiquidityPoolWithdraw() internal {
        ILiquidityPoolLike pool = _liquidityPool();
        uint256 eEthHeld = eETH.balanceOf(address(this));
        if (eEthHeld == 0) return;

        uint256 minWithdraw;
        uint256 maxWithdraw = type(uint256).max;
        try pool.minWithdrawAmount() returns (uint256 min) {
            minWithdraw = min;
        } catch {}
        try pool.maxWithdrawAmount() returns (uint256 max) {
            maxWithdraw = max;
        } catch {}

        if (eEthHeld >= minWithdraw && eEthHeld <= maxWithdraw) {
            uint256 ethBefore = address(this).balance;
            TokenUtils.safeApprove(address(eETH), address(pool), eEthHeld);
            try pool.withdraw(address(this), eEthHeld) {
                TokenUtils.safeApprove(address(eETH), address(pool), 0);
                uint256 ethReceived = address(this).balance - ethBefore;
                if (ethReceived > 0) IWETH(_asset()).deposit{value: ethReceived}();
            } catch {
                TokenUtils.safeApprove(address(eETH), address(pool), 0);
            }
        }

        uint256 leftover = eETH.balanceOf(address(this));
        if (leftover > 0) {
            TokenUtils.safeApprove(address(eETH), address(weETH), leftover);
            weETH.wrap(leftover);
            TokenUtils.safeApprove(address(eETH), address(weETH), 0);
        }
    }

    /// @dev Trips the kill switch when the canonical rate drops more than `maxRateDropBps`
    ///      below the allocation checkpoint. Does not revert, so the kill-switch write
    ///      persists; future allocations revert until the owner clears it.
    function _checkRate() internal {
        uint256 rate = weETH.getEETHByWeETH(1e18);
        if (maxRateDropBps != 0 && rateCheckpoint != 0 && rate < (rateCheckpoint * (BPS - maxRateDropBps)) / BPS) {
            killSwitch = true;
            emit RateGuardTripped(rateCheckpoint, rate);
            emit Emergency(true);
            return;
        }
        rateCheckpoint = rate;
    }

    function _redemptionInfo() internal view returns (uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl) {
        (, exitFeeSplitToTreasuryInBps, exitFeeInBps, lowWatermarkInBpsOfTvl) = redemptionManager.tokenToRedemptionInfo(ETH);
    }

    function _weETHForGrossRedeem(uint256 grossRedeemAmount, uint256 weETHBalance) internal view returns (uint256) {
        uint256 weETHToRedeem = weETH.getWeETHByeETH(grossRedeemAmount);
        if (weETHToRedeem < weETHBalance && weETH.getEETHByWeETH(weETHToRedeem) < grossRedeemAmount) {
            weETHToRedeem += 1;
        }
        return weETHToRedeem;
    }

    function _weETHForNetShortfall(uint256 shortfall, uint256 exitFeeInBps, uint256 weETHBalance) internal view returns (uint256) {
        ILiquidityPoolLike liquidityPool = _liquidityPool();
        uint256 requiredNetShares = liquidityPool.sharesForWithdrawalAmount(shortfall);
        uint256 requiredGrossShares = Math.mulDiv(requiredNetShares, BPS, BPS - exitFeeInBps, Math.Rounding.Ceil);
        uint256 grossRedeemAmount = liquidityPool.amountForShare(requiredGrossShares);
        if (liquidityPool.sharesForAmount(grossRedeemAmount) < requiredGrossShares) {
            grossRedeemAmount += grossRedeemAmountBuffer;
        }

        uint256 weETHToRedeem = _weETHForGrossRedeem(grossRedeemAmount, weETHBalance);
        if (weETHToRedeem > weETHBalance) {
            weETHToRedeem = weETHBalance;
        }
        return weETHToRedeem;
    }

    function _weEthFromEEthUp(uint256 eEthAmount) internal view returns (uint256 weEthAmount) {
        weEthAmount = weETH.getWeETHByeETH(eEthAmount);
        if (weETH.getEETHByWeETH(weEthAmount) < eEthAmount) {
            weEthAmount += 1;
        }
    }

    function _roundUpMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }

    /// @notice 0 or 1; feature-detection hook for handlers.
    function pendingExitCount() external view returns (uint256) {
        return _pendingExit.tokenId == 0 ? 0 : 1;
    }

    function pendingExit() external view returns (PendingExit memory) {
        return _pendingExit;
    }

    function isPendingExit(uint256 tokenId) external view returns (bool) {
        return _pendingExit.tokenId == tokenId;
    }

    /// @notice Claimable amount when the pending exit is finalized, else 0.
    function claimableExits() external view returns (uint256) {
        uint256 tokenId = _pendingExit.tokenId;
        if (tokenId == 0) return 0;
        if (!_withdrawRequestNFT().isFinalized(tokenId)) return 0;
        return _withdrawRequestNFT().getClaimableAmount(tokenId);
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == _asset() || token == address(weETH) || token == address(eETH) || token == address(_withdrawRequestNFT());
    }

    /// @dev Only accepts NFTs minted by the Etherfi queue.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(_withdrawRequestNFT()), "Unexpected NFT sender");
        return this.onERC721Received.selector;
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function setGrossRedeemAmountBuffer(uint256 grossRedeemAmountBuffer_) external onlyOwner {
        require(grossRedeemAmountBuffer_ <= MAX_GROSS_REDEEM_AMOUNT_BUFFER, "Buffer too large");
        grossRedeemAmountBuffer = grossRedeemAmountBuffer_;
        emit GrossRedeemAmountBufferUpdated(grossRedeemAmountBuffer_);
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

    receive() external payable {}
}
