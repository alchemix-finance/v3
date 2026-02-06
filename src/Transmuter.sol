// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAlchemistV3} from "./interfaces/IAlchemistV3.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NFTMetadataGenerator} from "./libraries/NFTMetadataGenerator.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";
import "./base/TransmuterErrors.sol";

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ERC721Enumerable {
    using StakingGraph for StakingGraph.Graph;
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    int256 public constant BLOCK_SCALING_FACTOR = 1e8;
    
    /// @inheritdoc ITransmuter
    string public constant version = "3.0.0";

    /// @inheritdoc ITransmuter
    uint256 public depositCap;

    /// @inheritdoc ITransmuter
    uint256 public exitFee;

    /// @inheritdoc ITransmuter
    uint256 public transmutationFee;

    /// @inheritdoc ITransmuter
    uint256 public timeToTransmute;

    /// @inheritdoc ITransmuter
    uint256 public totalLocked;

    /// @inheritdoc ITransmuter
    uint256 public totalActiveLocked; 

    /// @inheritdoc ITransmuter
    address public admin;

    /// @inheritdoc ITransmuter
    address public pendingAdmin;

    /// @inheritdoc ITransmuter
    address public protocolFeeReceiver;

    /// @inheritdoc ITransmuter
    address public syntheticToken;

    /// @inheritdoc ITransmuter
    IAlchemistV3 public alchemist;

    /// @dev Map of user positions data.
    mapping(uint256 => StakingPosition) private _positions;

    /// @dev Map of users whos position counts towards deposit cap.
    mapping(uint256 => bool) private _countsTowardCap;

    /// @dev Graph of transmuter positions.
    StakingGraph.Graph private _stakingGraph;

    /// @dev Nonce data used for minting of new nft positions.
    uint256 private _nonce;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    constructor(ITransmuter.TransmuterInitializationParams memory params) ERC721("Alchemix V3 Transmuter", "TRNSMTR") {
        syntheticToken = params.syntheticToken;
        require(params.timeToTransmute != 0, "Must set transmutation time");
        timeToTransmute = params.timeToTransmute;
        transmutationFee = params.transmutationFee;
        exitFee = params.exitFee;
        protocolFeeReceiver = params.feeReceiver;
        admin = msg.sender;
    }

    /// @inheritdoc ITransmuter
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc ITransmuter
    function acceptAdmin() external {
        _checkState(pendingAdmin != address(0));

        if (msg.sender != pendingAdmin) {
            revert Unauthorized();
        }

        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminUpdated(admin);
        emit PendingAdminUpdated(address(0));
    }

    /// @inheritdoc ITransmuter
    function setAlchemist(address value) external onlyAdmin {
        alchemist = IAlchemistV3(value);

        emit AlchemistUpdated(value);
    }

    /// @inheritdoc ITransmuter
    function setDepositCap(uint256 cap) external onlyAdmin {
        _checkArgument(cap <= type(int256).max.toUint256());

        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ITransmuter
    function setTransmutationFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        transmutationFee = fee;
        emit TransmutationFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setExitFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        exitFee = fee;
        emit ExitFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setTransmutationTime(uint256 time) external onlyAdmin {
        timeToTransmute = time;

        emit TransmutationTimeUpdated(time);
    }

    /// @inheritdoc ITransmuter
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        return NFTMetadataGenerator.generateTokenURI(id, "Transmuter V3 Position");
    }

    /// @inheritdoc ITransmuter
    function getPosition(uint256 id) external view returns (StakingPosition memory) {
        return _positions[id];
    }

    /// @inheritdoc ITransmuter
    function createRedemption(uint256 syntheticDepositAmount) external {
        if (syntheticDepositAmount == 0) {
            revert DepositZeroAmount();
        }

        if (totalActiveLocked + syntheticDepositAmount > depositCap) {
            revert DepositCapReached();
        }

        if (totalLocked + syntheticDepositAmount > alchemist.totalSyntheticsIssued()) {
            revert DepositCapReached();
        }

        TokenUtils.safeTransferFrom(syntheticToken, msg.sender, address(this), syntheticDepositAmount);

        _positions[++_nonce] = StakingPosition(syntheticDepositAmount, block.number, block.number + timeToTransmute);

        // Update Fenwick Tree
        _updateStakingGraph(syntheticDepositAmount.toInt256() * BLOCK_SCALING_FACTOR / timeToTransmute.toInt256(), timeToTransmute);

        totalLocked += syntheticDepositAmount;

        totalActiveLocked += syntheticDepositAmount;
        _countsTowardCap[_nonce] = true;

        _mint(msg.sender, _nonce);

        emit PositionCreated(msg.sender, syntheticDepositAmount, _nonce);
    }

    /// @inheritdoc ITransmuter
    function claimRedemption(uint256 id) external returns (uint256 claimYield, uint256 feeYield, uint256 syntheticReturned, uint256 syntheticFee) {
        StakingPosition storage position = _positions[id];

        if (position.maturationBlock == 0) {
            revert PositionNotFound();
        }

        if (position.startBlock == block.number) {
            revert PrematureClaim();
        }

        uint256 transmutationTime = position.maturationBlock - position.startBlock;
        uint256 blocksLeft = position.maturationBlock > block.number ? position.maturationBlock - block.number : 0;
        uint256 amountNottransmuted = blocksLeft > 0 ? FixedPointMath.mulDivUp(position.amount, blocksLeft, transmutationTime) : 0;
        uint256 amountTransmuted = position.amount - amountNottransmuted;

        if (_requireOwned(id) != msg.sender) {
            revert CallerNotOwner();
        }

        // Burn position NFT
        _burn(id);
        
        // Ratio of total synthetics issued by the alchemist / underlingying value of collateral stored in the alchemist
        // If the system experiences bad debt we use this ratio to scale back the value of yield tokens that are transmuted
        address myt = alchemist.myt();
        uint256 yieldTokenBalance = TokenUtils.safeBalanceOf(myt, address(this));

        // Avoid divide by 0
        uint256 backingUnderlying = alchemist.getTotalLockedUnderlyingValue() + alchemist.convertYieldTokensToUnderlying(yieldTokenBalance);
        uint256 denominator = backingUnderlying > 0 ? backingUnderlying : 1;

        // Round up so badDebtRatio is never understated.
        // Understating badDebtRatio makes scaledTransmuted slightly too large, which can cause alchemist.redeem(amountToRedeem) to revert due to share rounding.
        uint256 badDebtRatio = FixedPointMath.mulDivUp(alchemist.totalSyntheticsIssued(), 10 ** TokenUtils.expectDecimals(alchemist.underlyingToken()), denominator);

        uint256 scaledTransmuted = amountTransmuted;

        if (badDebtRatio > 1e18) {
            scaledTransmuted = amountTransmuted * FIXED_POINT_SCALAR / badDebtRatio;
        }

        // If the contract has a balance of yield tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 debtValue = alchemist.convertYieldTokensToDebt(yieldTokenBalance);
        uint256 amountToRedeem = scaledTransmuted > debtValue ? scaledTransmuted - debtValue : 0;

        uint256 redeemedShares = 0;
        if (amountToRedeem > 0) {
            redeemedShares = alchemist.redeem(amountToRedeem);
        }

        uint256 sharesAvailable = yieldTokenBalance + redeemedShares;
        uint256 totalYield = alchemist.convertDebtTokensToYield(scaledTransmuted);
        uint256 distributable = totalYield <= sharesAvailable ? totalYield : sharesAvailable;

        // Split distributable amount. Round fee down. claimant gets the remainder.
        feeYield = distributable * transmutationFee / BPS;
        claimYield = distributable - feeYield;

        uint256 debtPaid = alchemist.convertYieldTokensToDebt(distributable);
        if (debtPaid > scaledTransmuted) {
            debtPaid = scaledTransmuted;
        }

        // Shortfall debt to offset if some amount of MYT cannot be paid to the user
        // We will return some synthetics instead of burning them all if this is the case
        uint256 shortfallDebt = scaledTransmuted > debtPaid ? scaledTransmuted - debtPaid : 0;

        syntheticFee = amountNottransmuted * exitFee / BPS;
        syntheticReturned = (amountNottransmuted - syntheticFee) + shortfallDebt;

        uint256 burnAmountDebt = position.amount - (syntheticReturned + syntheticFee);

        // Remove untransmuted amount from the staking graph
        if (blocksLeft > 0) _updateStakingGraph(-position.amount.toInt256() * BLOCK_SCALING_FACTOR / transmutationTime.toInt256(), blocksLeft);

        TokenUtils.safeTransfer(myt, msg.sender, claimYield);
        TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeYield);

        TokenUtils.safeTransfer(syntheticToken, msg.sender, syntheticReturned);
        TokenUtils.safeTransfer(syntheticToken, protocolFeeReceiver, syntheticFee);

        if (burnAmountDebt > 0) {
            TokenUtils.safeBurn(syntheticToken, burnAmountDebt);
            alchemist.reduceSyntheticsIssued(burnAmountDebt);
        }

        alchemist.setTransmuterTokenBalance(TokenUtils.safeBalanceOf(myt, address(this)));

        // If this position still counted toward cap, remove it now.
        if (_countsTowardCap[id]) {
            _countsTowardCap[id] = false;
            totalActiveLocked -= position.amount;
        }

        totalLocked -= position.amount;

        emit PositionClaimed(msg.sender, claimYield, syntheticReturned);

        delete _positions[id];
    }

    /// @inheritdoc ITransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        if (endBlock < startBlock) return 0;

        int256 queried = _stakingGraph.queryStake(startBlock, endBlock);
        if (queried == 0) return 0;

        return (queried / BLOCK_SCALING_FACTOR).toUint256() + (queried % BLOCK_SCALING_FACTOR == 0 ? 0 : 1);
    }

    /// @inheritdoc ITransmuter
    function pokeMatured(uint256 id) external {
        StakingPosition storage position = _positions[id];

        if (position.maturationBlock == 0) revert PositionNotFound();

        // must be fully matured
        if (block.number < position.maturationBlock) {
            revert PositionNotMatured(id, position.maturationBlock, block.number);
        }

        if (!_countsTowardCap[id]) revert PositionAlreadyPoked(id);

        _countsTowardCap[id] = false;
        totalActiveLocked -= position.amount;

        emit PositionPoked(id, position.amount);
    }

    /// @dev Updates staking graphs
    function _updateStakingGraph(int256 amount, uint256 blocks) private {
        _stakingGraph.addStake(amount, block.number, blocks);
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }
}