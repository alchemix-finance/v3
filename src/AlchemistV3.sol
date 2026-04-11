// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
///
/// For Juris, Graham, and Marcus
contract AlchemistV3 is IAlchemistV3, Initializable {
    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant ONE_Q128 = uint256(1) << 128;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public alchemistFeeVault;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    address public myt;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public depositCap;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastRedemptionBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastTransmuterTokenBalance;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;

    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidationTargetCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalSyntheticsIssued;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public repaymentFee;

    /// @inheritdoc IAlchemistV3State
    address public alchemistPositionNFT;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;

    /// @inheritdoc IAlchemistV3State
    address public tokenAdapter;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public guardians;

    /// @dev Total debt retired through Transmuter-driven redemptions.
    uint256 private _totalRedeemedDebt;

    /// @dev Total MYT shares removed from global accounting by redemptions and redemption fees.
    uint256 private _totalRedeemedSharesOut;

    /// @dev Packed earmark weight used to track how much live unearmarked debt survives each earmark step.
    uint256 private _earmarkWeight;

    /// @dev Packed redemption weight used to track survival of earmarked debt across redemptions.
    uint256 private _redemptionWeight;

    /// @dev Accumulator used to reconstruct earmarked debt survival across redemption windows.
    uint256 private _survivalAccumulator;

    /// @dev Total MYT shares currently assigned to open positions.
    /// This intentionally excludes any unrelated MYT balance the contract may temporarily hold.
    uint256 private _mytSharesDeposited;

    /// @dev Transmuter MYT balance increases not yet applied as cover in `_earmark()`.
    uint256 private _pendingCoverShares;

    /// @dev User accounts
    mapping(uint256 => Account) private _accounts;

    /// @dev Redemption weight snapshot at the start of each earmark epoch.
    mapping(uint256 => uint256) private _earmarkEpochStartRedemptionWeight;

    /// @dev Survival accumulator snapshot at the start of each earmark epoch.
    mapping(uint256 => uint256) private _earmarkEpochStartSurvivalAccumulator;
    
    uint256 private constant _REDEMPTION_INDEX_BITS = 129;
    uint256 private constant _REDEMPTION_INDEX_MASK = (uint256(1) << _REDEMPTION_INDEX_BITS) - 1;

    uint256 private constant _EARMARK_INDEX_BITS = 129;
    uint256 private constant _EARMARK_INDEX_MASK = (uint256(1) << _EARMARK_INDEX_BITS) - 1;

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyAdminOrGuardian() {
        _onlyAdminOrGuardian();
        _;
    }

    modifier onlyTransmuter() {
        _onlyTransmuter();
        _;
    }

    constructor() initializer {}

    function initialize(AlchemistInitializationParams calldata params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);
        _checkArgument(params.repaymentFee <= BPS);
        _checkArgument(params.liquidationTargetCollateralization >= params.minimumCollateralization);
        
        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingConversionFactor = 10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        depositCap = params.depositCap;
        minimumCollateralization = params.minimumCollateralization;
        globalMinimumCollateralization = params.globalMinimumCollateralization;
        collateralizationLowerBound = params.collateralizationLowerBound;
        liquidationTargetCollateralization = params.liquidationTargetCollateralization;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        repaymentFee = params.repaymentFee;
        lastEarmarkBlock = block.number;
        lastRedemptionBlock = block.number;
        myt = params.myt;

        // Initialize packed weights at full survival.
        _redemptionWeight = ONE_Q128;
        _earmarkWeight = ONE_Q128;

        // Initialize epoch checkpoints.
        _earmarkEpochStartRedemptionWeight[0] = _redemptionWeight;
        _earmarkEpochStartSurvivalAccumulator[0] = _survivalAccumulator;
    }

    /// @notice Sets the NFT position token, callable by admin.
    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        if (nft == address(0)) {
            revert AlchemistV3NFTZeroAddressError();
        }

        if (alchemistPositionNFT != address(0)) {
            revert AlchemistV3NFTAlreadySetError();
        }

        alchemistPositionNFT = nft;
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setAlchemistFeeVault(address value) external onlyAdmin {
        if (IFeeVault(value).token() != underlyingToken) {
            revert AlchemistVaultTokenMismatchError();
        }
        alchemistFeeVault = value;
        emit AlchemistFeeVaultUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
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

    /// @inheritdoc IAlchemistV3AdminActions
    function setDepositCap(uint256 value) external onlyAdmin {
        _checkArgument(value >= IERC20(myt).balanceOf(address(this)));

        depositCap = value;
        emit DepositCapUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        protocolFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidatorFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        liquidatorFee = fee;
        emit LiquidatorFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setRepaymentFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        repaymentFee = fee;
        emit RepaymentFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTokenAdapter(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGuardian(address guardian, bool isActive) external onlyAdmin {
        _checkArgument(guardian != address(0));

        guardians[guardian] = isActive;
        emit GuardianSet(guardian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= FIXED_POINT_SCALAR);

        // cannot exceed global minimum
        minimumCollateralization = value > globalMinimumCollateralization ? globalMinimumCollateralization : value;

        // cannot exceed liquidation target
        if (minimumCollateralization > liquidationTargetCollateralization) {
            minimumCollateralization = liquidationTargetCollateralization;
        }
        emit MinimumCollateralizationUpdated(minimumCollateralization);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGlobalMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= minimumCollateralization);
        globalMinimumCollateralization = value;
        emit GlobalMinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setCollateralizationLowerBound(uint256 value) external onlyAdmin {
        _checkArgument(value < minimumCollateralization);
        _checkArgument(value >= FIXED_POINT_SCALAR);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidationTargetCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value > FIXED_POINT_SCALAR);
        _checkArgument(value >= minimumCollateralization);
        _checkArgument(value > collateralizationLowerBound);
        _checkArgument(value <= 2 * FIXED_POINT_SCALAR);
        liquidationTargetCollateralization = value;
        emit LiquidationTargetCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGuardian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGuardian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return _mytSharesDeposited;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(collateral);
        uint256 capacity = (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization);
        return debt > capacity  ? 0 : capacity - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxWithdrawable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);

        uint256 lockedCollateral = 0;
        if (debt != 0) {
            uint256 debtShares = convertDebtTokensToYield(debt);
            lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
        }

        uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
        uint256 required = _requiredLockedShares();
        uint256 globalFree = _mytSharesDeposited > required ? _mytSharesDeposited - required : 0;

        return positionFree < globalFree ? positionFree : globalFree;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    
    /// @inheritdoc IAlchemistV3State
    function getTotalLockedUnderlyingValue() external view returns (uint256) {
        return _getTotalLockedUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        return _totalCollateralValue(tokenId, true);
    }

    /// @notice Returns cumulative earmarked debt including one simulated pending earmark window.
    function getUnrealizedCumulativeEarmarked() external view returns (uint256) {
        if (totalDebt == 0) return 0;
        (, uint256 effectiveEarmarked) = _simulateUnrealizedEarmark();
        return cumulativeEarmarked + effectiveEarmarked;
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256, uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(!depositsPaused);
        _checkState(!_isProtocolInBadDebt());
        _checkState(_mytSharesDeposited + amount <= depositCap);

        // Only mint a new position if the id is 0
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
        } else {
            _checkForValidAccountId(tokenId);
            _earmark();
            _sync(tokenId);
        }

        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(myt, msg.sender, address(this), amount);
        _mytSharesDeposited += amount;

        emit Deposit(amount, tokenId);

        return (tokenId, convertYieldTokensToDebt(amount));
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _earmark();
        _sync(tokenId);

        if (_accounts[tokenId].collateralBalance > _mytSharesDeposited) {
            _accounts[tokenId].collateralBalance = _mytSharesDeposited;
        }

        uint256 debtShares = convertDebtTokensToYield(_accounts[tokenId].debt);
        uint256 lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
        _checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount);
        uint256 transferred = _subCollateralBalance(amount, tokenId);

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(myt, recipient, transferred);

        emit Withdraw(transferred, tokenId, recipient);

        return transferred;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkState(!loansPaused);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);

        // Query transmuter and earmark global debt
        _earmark();
        _checkState(!_isProtocolInBadDebt());
        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens to recipient
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkForValidAccountId(tokenId);
        _checkArgument(recipient != address(0));
        _checkState(!loansPaused);
        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(tokenId, msg.sender, amount);

        // Query transmuter and earmark global debt
        _earmark();
        _checkState(!_isProtocolInBadDebt());
        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens from the tokenId's account to the recipient.
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientId);
        // Block same-block mint -> burn round trips.
        if (block.number == _accounts[recipientId].lastMintBlock) revert CannotRepayOnMintBlock();

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipientId);

        uint256 debt;
        // Debt-token burns can only repay the unearmarked portion.
        _checkState((debt = _accounts[recipientId].debt - _accounts[recipientId].earmarked) > 0);

        uint256 credit = _capDebtCredit(amount, debt);
        if (credit == 0) return 0;

        // Must only burn enough tokens that the transmuter positions can still be fulfilled
        if (credit > totalSyntheticsIssued - ITransmuter(transmuter).totalLocked()) {
            revert BurnLimitExceeded(credit, totalSyntheticsIssued - ITransmuter(transmuter).totalLocked());
        }

        // Burn the debt tokens from the caller.
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Apply the repayment to the target account.
        _subDebt(recipientId, credit);
        _accounts[recipientId].lastRepayBlock = block.number;

        totalSyntheticsIssued -= credit;

        // Assure that the collateralization invariant is still held.
        _validate(recipientId);

        emit Burn(msg.sender, credit, recipientId);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientTokenId);
        Account storage account = _accounts[recipientTokenId];
        // Block same-block mint -> repay round trips.
        if (block.number == account.lastMintBlock) revert CannotRepayOnMintBlock();

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipientTokenId);

        uint256 debt;

        // MYT repayments can extinguish both earmarked and unearmarked debt.
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = _capDebtCredit(yieldToDebt, debt);
        if (credit == 0) return 0;

        // Repay earmarked debt first so protocol fees are charged on the earmarked portion only.
        uint256 earmarkedRepaid = _subEarmarkedDebt(credit, recipientTokenId);


        uint256 creditToYield = convertDebtTokensToYield(credit);
        uint256 earmarkedRepaidToYield = convertDebtTokensToYield(earmarkedRepaid);


        // Protocol fee only applies to the earmarked portion of the repayment.
        uint256 feeAmount = earmarkedRepaidToYield * protocolFee / BPS;
        if (feeAmount > account.collateralBalance) {
            revert IllegalState();
        } else {
            _subCollateralBalance(feeAmount, recipientTokenId);
        }

        _subDebt(recipientTokenId, credit);
        account.lastRepayBlock = block.number;

        // Forward the repaid MYT to the transmuter.
        TokenUtils.safeTransferFrom(myt, msg.sender, transmuter, creditToYield);
        _syncEarmarkedTransmuterTransfer(creditToYield, earmarkedRepaidToYield);
        if (feeAmount > 0) {
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeAmount);
        }
        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external override returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying) {
        _checkForValidAccountId(accountId);
        uint256 debtBefore = _accounts[accountId].debt;
        (yieldAmount, feeInYield, feeInUnderlying) = _liquidate(accountId);
        if (yieldAmount > 0 || feeInYield > 0 || feeInUnderlying > 0 || _accounts[accountId].debt < debtBefore) {
            return (yieldAmount, feeInYield, feeInUnderlying);
        } else {
            // No collateral or fee movement occurred and debt did not decrease.
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] calldata accountIds)
        external
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        bool anyProgress = false;
        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            uint256 debtBefore = _accounts[accountId].debt;
            (uint256 underlyingAmount, uint256 feeInYield, uint256 feeInUnderlying) = _liquidate(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFeesInYield += feeInYield;
            totalFeesInUnderlying += feeInUnderlying;
            if (
                underlyingAmount > 0 || feeInYield > 0 || feeInUnderlying > 0 || _accounts[accountId].debt < debtBefore
            ) {
                anyProgress = true;
            }
        }

        if (anyProgress) {
            return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        } else {
            // None of the requested accounts made progress.
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter returns (uint256 sharesSent) {
        _earmark();

        uint256 liveEarmarked = cumulativeEarmarked;
        if (amount > liveEarmarked) amount = liveEarmarked;

        uint256 effectiveRedeemed = 0;

        if (liveEarmarked != 0 && amount != 0) {
            // ratioWanted = (liveEarmarked - amount) / liveEarmarked in Q128.128
            uint256 ratioWanted = (amount == liveEarmarked) ? 0 : FixedPointMath.divQ128(liveEarmarked - amount, liveEarmarked);

            // Snapshot old packed
            uint256 packedOld = _redemptionWeight;
            uint256 oldEpoch  = _redEpoch(packedOld);
            uint256 oldIndex  = _redIndex(packedOld);

            // Normalize uninitialized / zero index
            if (packedOld == 0) {
                oldEpoch = 0;
                oldIndex = ONE_Q128;
            }
            if (oldIndex == 0) {
                oldEpoch += 1;
                oldIndex = ONE_Q128;
            }

            // Compute new packed
            uint256 newEpoch = oldEpoch;
            uint256 newIndex;

            if (ratioWanted == 0) {
                newEpoch += 1;
                newIndex = ONE_Q128;
            } else {
                newIndex = FixedPointMath.mulQ128(oldIndex, ratioWanted);
            }

            _redemptionWeight = _packRed(newEpoch, newIndex);

            // ratioApplied is what accounts will actually see via _redemptionSurvivalRatio()
            // epoch advance => full wipe => 0 survival
            uint256 ratioApplied = (newEpoch > oldEpoch) ? 0 : FixedPointMath.divQ128(newIndex, oldIndex);

            // Apply survival using the APPLIED ratio
            _survivalAccumulator = FixedPointMath.mulQ128(_survivalAccumulator, ratioApplied);

            // Derive effective redeemed amount using the SAME applied ratio
            uint256 remainingEarmarked = FixedPointMath.mulQ128(liveEarmarked, ratioApplied);
            effectiveRedeemed = liveEarmarked - remainingEarmarked;

            cumulativeEarmarked = remainingEarmarked;
            totalDebt -= effectiveRedeemed;
        }

        lastRedemptionBlock = block.number;

        // Use the effective redeemed amount everywhere downstream
        uint256 collRedeemed  = convertDebtTokensToYield(effectiveRedeemed);
        uint256 feeCollateral = collRedeemed * protocolFee / BPS;

        _totalRedeemedDebt += effectiveRedeemed;
        _totalRedeemedSharesOut += collRedeemed;

        TokenUtils.safeTransfer(myt, transmuter, collRedeemed);
        _mytSharesDeposited -= collRedeemed;

        // If the remaining tracked MYT cannot fully cover the protocol fee, skip the fee entirely.
        if (feeCollateral <= _mytSharesDeposited) {
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeCollateral);
            _mytSharesDeposited -= feeCollateral;
            _totalRedeemedSharesOut += feeCollateral;
        }

        emit Redemption(effectiveRedeemed);
        return collRedeemed;
    }

    /// @inheritdoc IAlchemistV3Actions
    function selfLiquidate(uint256 accountId, address recipient) external returns (uint256 amountLiquidated) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(accountId);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(accountId), msg.sender);
        _poke(accountId);
        _checkState(_accounts[accountId].debt > 0);
        if (!_isAccountHealthy(accountId, false)) {
            // Unhealthy accounts must go through the regular liquidation path.
           revert AccountNotHealthy();
        }
        Account storage account = _accounts[accountId];

        // First clear any earmarked debt from the account's own collateral.
        uint256 repaidEarmarkedDebtInYield = _forceRepay(accountId, account.earmarked, true);
    
        uint256 debt = account.debt;

        // Then clear whatever debt remains.
        _subDebt(accountId, debt);

        // Remove the collateral that backed the remaining debt.
        uint256 repaidDebtInYield = _subCollateralBalance(convertDebtTokensToYield(debt), accountId);

        // Sweep any residual collateral out of the account.
        uint256 remainingCollateral = _subCollateralBalance(account.collateralBalance, accountId);

        if(repaidDebtInYield > 0) {
            // Forward repaid collateral to the transmuter.
            TokenUtils.safeTransfer(myt, transmuter, repaidDebtInYield);
        }

        if(remainingCollateral > 0) {
            // Return leftover collateral to the recipient.
            TokenUtils.safeTransfer(myt, recipient, remainingCollateral);
        }   
        emit SelfLiquidated(accountId, repaidEarmarkedDebtInYield + repaidDebtInYield);
        return repaidEarmarkedDebtInYield + repaidDebtInYield;
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) public pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt if debt is greater than collateral
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt in high ltv global environment
            return (debt, debt, 0, outsourcedFee);
        }

        // fee is taken from surplus = collateral - debt
        uint256 surplus = collateral - debt;

        fee = (surplus * feeBps) / BPS;

        // collateral remaining for margin‐restore calc
        uint256 adjCollat = collateral - fee;
        // compute m*d  (both plain units)
        uint256 md = (targetCollateralization * debt) / FIXED_POINT_SCALAR;
        // if md <= adjCollat, nothing to liquidate
        if (md <= adjCollat) {
            return (0, 0, 0, 0);
        }

        // numerator = md - adjCollat
        uint256 num = md - adjCollat;

        // denom = m - 1  =>  (targetCollateralization - FIXED_POINT_SCALAR)/FIXED_POINT_SCALAR
        uint256 denom = targetCollateralization - FIXED_POINT_SCALAR;

        debtToBurn = (num * FIXED_POINT_SCALAR) / denom;

        // gross collateral seize = net + fee
        grossCollateralToSeize = debtToBurn + fee;
    }

    ///@inheritdoc IAlchemistV3Actions
    function reduceSyntheticsIssued(uint256 amount) external onlyTransmuter {
        totalSyntheticsIssued -= amount;
    }

    ///@inheritdoc IAlchemistV3Actions
    function setTransmuterTokenBalance(uint256 amount) external onlyTransmuter {
        uint256 last = lastTransmuterTokenBalance;

        // If balance went down, assume cover could have been spent and reduce it conservatively.
        if (amount < last) {
            uint256 spent = last - amount;
            uint256 cover = _pendingCoverShares;

            if (spent >= cover) {
                _pendingCoverShares = 0;
            } else {
                _pendingCoverShares = cover - spent;
            }
        }

        // Always keep cover <= actual transmuter balance.
        if (_pendingCoverShares > amount) {
            _pendingCoverShares = amount;
        }

        // Update baseline
        lastTransmuterTokenBalance = amount;
    }

    /// @dev Keeps already-earmarked transfers from being re-counted as future cover.
    function _syncEarmarkedTransmuterTransfer(uint256 sharesSent, uint256 earmarkedShares) internal {
        if (earmarkedShares == 0) return;

        // Only the portion that satisfied an existing earmark should bypass cover accounting.
        if (sharesSent > earmarkedShares) sharesSent = earmarkedShares;
        lastTransmuterTokenBalance += sharesSent;
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _checkForValidAccountId(tokenId);
        _poke(tokenId);
    }


    /// @dev Pokes the account owned by `tokenId` to sync the state.
    /// @param tokenId The tokenId of the account to poke.
    function _poke(uint256 tokenId) internal {
        _earmark();
        _sync(tokenId);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount) external {
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId) external {
        // Allow calls from either the token owner or the NFT contract
        if (msg.sender != address(alchemistPositionNFT)) {
            // Direct call - verify caller is current owner
            address tokenOwner = IERC721(alchemistPositionNFT).ownerOf(tokenId);
            if (msg.sender != tokenOwner) {
                revert Unauthorized();
            }
        }
        // increment version to start the mapping from a fresh state
        _accounts[tokenId].allowancesVersion += 1;
        // Emit event to notify allowance clearing
        emit MintAllowancesReset(tokenId);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) public view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertDebtTokensToYield(uint256 amount) public view returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `tokenId`.
    /// @param tokenId     The tokenId of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(uint256 tokenId, uint256 amount, address recipient) internal {
        if (block.number == _accounts[tokenId].lastRepayBlock) revert CannotMintOnRepayBlock();
        _addDebt(tokenId, amount);

        totalSyntheticsIssued += amount;

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        _accounts[tokenId].lastMintBlock = block.number;

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /**
     * @notice Uses the account's own collateral to retire debt and the associated protocol fee.
     * @param accountId The token id of the account to repay from.
     * @param amount The requested debt repayment amount, denominated in debt tokens.
     * @param skipPoke Whether to skip syncing the account before repayment.
     * @return creditToYield The MYT shares routed to the transmuter for the retired debt.
     */
     function _forceRepay(uint256 accountId, uint256 amount, bool skipPoke) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        _checkForValidAccountId(accountId);
        if (!skipPoke) {
            _poke(accountId);
        }
        Account storage account = _accounts[accountId];
        uint256 debt;

        // Retiring debt from collateral can cover any debt bucket.
        _checkState((debt = account.debt) > 0);

        // Clamp requested repayment against live account/global debt.
        uint256 credit = _capDebtCredit(amount, debt);
        if (credit == 0) return 0;
        // Reduce earmarked debt first, then total debt.
        uint256 earmarkedRepaid = _subEarmarkedDebt(credit, accountId);
        _subDebt(accountId, credit);
        
        // Remove the collateral that backs the retired debt.
        uint256 creditToYield = _subCollateralBalance(convertDebtTokensToYield(credit), accountId);

        // Collect as much protocol fee as the remaining collateral can support.
        uint256 targetProtocolFee = creditToYield * protocolFee / BPS;
        uint256 protocolFeeTotal = _subCollateralBalance(targetProtocolFee, accountId);


        emit ForceRepay(accountId, amount, creditToYield, protocolFeeTotal);

        if (creditToYield > 0) {
            // Route the retired collateral to the transmuter.
            TokenUtils.safeTransfer(myt, address(transmuter), creditToYield);
            _syncEarmarkedTransmuterTransfer(creditToYield, convertDebtTokensToYield(earmarkedRepaid));
        }

        if (protocolFeeTotal > 0) {
            // Forward the realized fee to the protocol fee receiver.
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, protocolFeeTotal);
        }

        return creditToYield;
    }

    /// @dev Subtracts the earmarked debt by `amount` for the account owned by `accountId`.
    /// @param amountInDebtTokens The amount of debt tokens to subtract from the earmarked debt.
    /// @param accountId The tokenId of the account to subtract the earmarked debt from.
    /// @return The amount of debt tokens subtracted from the earmarked debt.
    function _subEarmarkedDebt(uint256 amountInDebtTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];

        uint256 debt = account.debt;
        uint256 earmarkedDebt = account.earmarked;

        uint256 credit = amountInDebtTokens > debt ? debt : amountInDebtTokens;
        uint256 earmarkToRemove = credit > earmarkedDebt ? earmarkedDebt : credit;

        // Always reduce local earmark by the full local repay amount.
        account.earmarked = earmarkedDebt - earmarkToRemove;

        // Global can lag local by rounding; clamp only the global subtraction.
        uint256 remove = earmarkToRemove > cumulativeEarmarked ? cumulativeEarmarked : earmarkToRemove;
        cumulativeEarmarked -= remove;

        return earmarkToRemove;
    }


    /// @dev Subtracts the collateral balance by `amount` for the account owned by `accountId`.
    /// @param amountInYieldTokens The amount of yield tokens to subtract from the collateral balance.
    /// @param accountId The tokenId of the account to subtract the collateral balance from.
    /// @return The amount of yield tokens subtracted from the collateral balance.
    function _subCollateralBalance(uint256 amountInYieldTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 collateralBalance = account.collateralBalance;

        // Reconcile local collateral against global tracked shares before subtraction.
        // This prevents underflow if rounding/drift made local storage exceed global storage.
        if (collateralBalance > _mytSharesDeposited) {
            collateralBalance = _mytSharesDeposited;
            account.collateralBalance = collateralBalance;
        }

        uint256 amountToRemove = amountInYieldTokens > collateralBalance ? collateralBalance : amountInYieldTokens;
        account.collateralBalance = collateralBalance - amountToRemove;
        _mytSharesDeposited -= amountToRemove;
        return amountToRemove;
    }

    /// @dev Syncs the account, attempts earmarked debt repayment, and liquidates collateral if still unhealthy.
    /// @param accountId The token id of the account to liquidate.
    /// @return amountLiquidated The amount of MYT seized from the account.
    /// @return feeInYield The MYT fee paid to the liquidator.
    /// @return feeInUnderlying The underlying-denominated fee paid from the fee vault, if any.
    function _liquidate(uint256 accountId) internal returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        // Query transmuter and earmark global debt
        _earmark();
        // Sync current user debt before deciding how much needs to be liquidated
        _sync(accountId);

        Account storage account = _accounts[accountId];

        // If one share is worth zero underlying, liquidation math is undefined and should noop.
        if (IVaultV2(myt).convertToAssets(1e18) == 0) {
            return (0, 0, 0);
        }
       
        if (_isAccountHealthy(accountId, false)) {
            return (0, 0, 0);
        }

        // First try to clear earmarked debt from the account's own collateral.
        uint256 repaidAmountInYield = 0;
        if (account.earmarked > 0) {
            repaidAmountInYield = _forceRepay(accountId, account.earmarked, false);
            feeInYield = _calculateRepaymentFee(repaidAmountInYield);
            // Final safety check after all deductions
            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        // Recalculate ratio after any repayment to determine if further liquidation is needed
        if (_isAccountHealthy(accountId, false)) {
            if (feeInYield > 0) {
                uint256 targetFeeInYield = feeInYield;
                uint256 maxSafeFeeInYield = _maxRepaymentFeeInYield(accountId);
                // Use a single fee source: either the account can safely cover the full fee in MYT,
                // or the entire fee is outsourced to the fee vault.
                if (maxSafeFeeInYield < targetFeeInYield) {
                    feeInYield = 0;
                    feeInUnderlying = convertYieldTokensToUnderlying(targetFeeInYield);
                }
            }

            if (feeInYield > 0) {
                feeInYield = _subCollateralBalance(feeInYield, accountId); // clamps to available balance
                TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
            } else if (feeInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeInUnderlying);
            }
            emit RepaymentFee(accountId, msg.sender, feeInYield, feeInUnderlying);
            return (repaidAmountInYield, feeInYield, feeInUnderlying);
        } else {
            // Do actual liquidation
            return _doLiquidation(accountId);
        }

    }

    /// @dev Pays the fee to msg.sender in underlying tokens using the fee vault
    /// @param amountInUnderlying The amount of underlying tokens to pay
    /// @return actual amount paid based on the vault balance
    function _payWithFeeVault(uint256 amountInUnderlying) internal returns (uint256) {
        if (amountInUnderlying == 0) return 0;
        if (alchemistFeeVault == address(0)) {
            emit FeeShortfall(msg.sender, amountInUnderlying, 0);
            return 0;
        }
        uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
        if (vaultBalance > 0) {
            uint256 adjustedAmount = amountInUnderlying > vaultBalance ? vaultBalance : amountInUnderlying;
            IFeeVault(alchemistFeeVault).withdraw(msg.sender, adjustedAmount);
            if (adjustedAmount < amountInUnderlying) {
                emit FeeShortfall(msg.sender, amountInUnderlying, adjustedAmount);
            }
            return adjustedAmount;
        }
        emit FeeShortfall(msg.sender, amountInUnderlying, 0);
        return 0;
    }

    /// @dev Checks if the account is healthy
    /// @dev An account is healthy if its collateralization ratio is greater than the collateralization lower bound
    /// @dev An account is healthy if it has no debt
    /// @param accountId The tokenId of the account to check.
    /// @param refresh Whether to refresh the account's collateral value by including unrealized debt.
    /// @return true if the account is healthy, false otherwise.
    function _isAccountHealthy(uint256 accountId, bool refresh) internal view returns (bool) {
        if (_accounts[accountId].debt == 0) {
            return true;
        }
        uint256 collateralInUnderlying = _totalCollateralValue(accountId, refresh);
        uint256 collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / _accounts[accountId].debt;
        return collateralizationRatio > collateralizationLowerBound;
    }

    /// @dev Performs the collateral-seizure phase of liquidation once the account must be liquidated.
    /// @param accountId The token id of the account to liquidate.
    /// @return amountLiquidated The amount of MYT seized from the account.
    /// @return feeInYield The MYT fee paid to the liquidator.
    /// @return feeInUnderlying The underlying-denominated fee paid from the fee vault.
    function _doLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying)
    {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        uint256 collateralInUnderlying = totalValue(accountId);
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralInUnderlying,
            debt,
            liquidationTargetCollateralization,
            normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt,
            globalMinimumCollateralization,
            liquidatorFee
        );

        if (liquidationAmount == 0) {
            // Debt-only closeout path: account can be insolvent with no remaining collateral to seize.
            if (debtToBurn > 0) {
                uint256 burnableDebt = _capDebtCredit(debtToBurn, account.debt);
                if (burnableDebt > 0) {
                    _subDebt(accountId, burnableDebt);
                }
            }

            uint256 feeRequestInUnderlying = normalizeDebtTokensToUnderlying(outsourcedFee);
            if (feeRequestInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeRequestInUnderlying);
            }

            if (account.debt < debt || feeInUnderlying > 0) {
                emit Liquidated(accountId, msg.sender, 0, 0, feeInUnderlying);
                return (0, 0, feeInUnderlying);
            }

            return (0, 0, 0);
        }

        uint256 requestedLiquidationInYield = convertDebtTokensToYield(liquidationAmount);
        amountLiquidated = _subCollateralBalance(requestedLiquidationInYield, accountId);
        if (amountLiquidated == 0) return (0, 0, 0);

        // Fee and debt burn are derived from idealized liquidation math, so clamp them to what was
        // actually realized after collateral capping to avoid underflow and over-burning debt.
        uint256 requestedFeeInYield = convertDebtTokensToYield(baseFee);
        feeInYield = requestedFeeInYield > amountLiquidated ? amountLiquidated : requestedFeeInYield;

        uint256 netToTransmuter = amountLiquidated - feeInYield;
        uint256 maxDebtByRealized = convertYieldTokensToDebt(netToTransmuter);
        uint256 maxDebtByStorage = account.debt < totalDebt ? account.debt : totalDebt;

        if (debtToBurn > maxDebtByRealized) debtToBurn = maxDebtByRealized;
        if (debtToBurn > maxDebtByStorage) debtToBurn = maxDebtByStorage;

        // Apply the realized debt reduction.
        if (debtToBurn > 0) {
            _subDebt(accountId, debtToBurn);
        }

        // If liquidation still leaves the account unhealthy, force-close the residual:
        // sweep all remaining collateral and clear any debt that cannot be backed anymore.
        if (account.debt > 0 && !_isAccountHealthy(accountId, false)) {
            uint256 remainingShares = account.collateralBalance;
            if (remainingShares > 0) {
                uint256 removedShares = _subCollateralBalance(remainingShares, accountId);
                netToTransmuter += removedShares;

                uint256 extraDebtBurn = _capDebtCredit(convertYieldTokensToDebt(removedShares), account.debt);
                if (extraDebtBurn > 0) {
                    _subDebt(accountId, extraDebtBurn);
                }
            }

            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        // Route seized collateral net of liquidator fee to the transmuter.
        TokenUtils.safeTransfer(myt, transmuter, netToTransmuter);

        // Pay the liquidator from MYT if available, otherwise fall back to the fee vault.
        if (feeInYield > 0) {
            TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
        } else if (normalizeDebtTokensToUnderlying(outsourcedFee) > 0) {
            feeInUnderlying = _payWithFeeVault(normalizeDebtTokensToUnderlying(outsourcedFee));
        }
        emit Liquidated(accountId, msg.sender, amountLiquidated, feeInYield, feeInUnderlying);
        return (amountLiquidated, feeInYield, feeInUnderlying);
    }

 
    /// @dev Handles repayment fee calculation.
    /// @param repaidAmountInYield The amount of debt repaid in yield tokens.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    function _calculateRepaymentFee(uint256 repaidAmountInYield) internal view returns (uint256 feeInYield) {
        return repaidAmountInYield * repaymentFee / BPS;
    }

    /// @dev Returns max yield-fee removable while remaining strictly healthy (> lower bound).
    /// @param accountId The tokenId of the account to compute the max repayment fee for.
    /// @return The max repayment fee in yield tokens.
    function _maxRepaymentFeeInYield(uint256 accountId) internal view returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        if (debt == 0) {
            return account.collateralBalance;
        }

        uint256 collateralInDebt = convertYieldTokensToDebt(account.collateralBalance);
        uint256 minimumByLowerBound = FixedPointMath.mulDivUp(debt, collateralizationLowerBound, FIXED_POINT_SCALAR);
        if (minimumByLowerBound == type(uint256).max) {
            return 0;
        }

        // _isAccountHealthy uses a strict ">" check, so retain one debt-unit of margin.
        uint256 minRequiredPostFee = minimumByLowerBound + 1;
        if (collateralInDebt <= minRequiredPostFee) {
            return 0;
        }

        uint256 removableInDebt = collateralInDebt - minRequiredPostFee;
        return convertDebtTokensToYield(removableInDebt);
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        uint256 newDebt = account.debt + amount;

        // After _sync(tokenId), you can use the current collateralBalance (no simulation needed)
        uint256 collateralValue = _totalCollateralValue(tokenId, false);

        uint256 required = FixedPointMath.mulDivUp(newDebt, minimumCollateralization, FIXED_POINT_SCALAR);
        if (collateralValue < required) revert Undercollateralized();

        account.debt = newDebt;
        totalDebt += amount;
    }

    /// @dev Subtracts the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to decrease the debt by.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        account.debt -= amount;
        totalDebt -= amount;

        if (cumulativeEarmarked > totalDebt) {
            cumulativeEarmarked = totalDebt;
        }
    }

    /// @dev Caps a debt-denominated credit against account debt and global debt.
    function _capDebtCredit(uint256 requested, uint256 accountDebt) internal view returns (uint256) {
        uint256 credit = requested > accountDebt ? accountDebt : requested;
        if (credit > totalDebt) credit = totalDebt;
        return credit;
    }

    /// @dev Returns debt that can be safely cleared against global debt accounting.
    function _clearableDebt(uint256 accountDebt) internal view returns (uint256) {
        return accountDebt > totalDebt ? totalDebt : accountDebt;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The id of the account granting approval.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
        emit ApproveMint(ownerTokenId, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `ownerTokenId`.
    ///
    /// @param ownerTokenId The id of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] -= amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks if owner == sender and reverts with an {UnauthorizedAccountAccessError} error if the result is {false}.
    ///
    /// @param owner The address of the owner of an account.
    /// @param user The address of the user attempting to access an account.
    function _checkAccountOwnership(address owner, address user) internal pure {
        if (owner != user) {
            revert UnauthorizedAccountAccessError();
        }
    }

    /// @dev reverts {UnknownAccountOwnerIDError} error by if no owner exists.
    ///
    /// @param tokenId The id of an account.
    function _checkForValidAccountId(uint256 tokenId) internal view {
        if (!_tokenExists(alchemistPositionNFT, tokenId)) {
            revert UnknownAccountOwnerIDError();
        }
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
    }

    function _onlyAdminOrGuardian() internal view {
        if (msg.sender != admin && !guardians[msg.sender]) {
            revert Unauthorized();
        }
    }

    function _onlyTransmuter() internal view {
        if (msg.sender != transmuter) {
            revert Unauthorized();
        }
    }

    /**
     * @notice Checks whether a token id is linked to an owner. Non blocking / no reverts.
     * @param nft The address of the ERC721 based contract.
     * @param tokenId The token id to check.
     * @return exists A boolean that is true if the token exists.
     */
    function _tokenExists(address nft, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) {
            // token ids start from 1
            return false;
        }
        try IERC721(nft).ownerOf(tokenId) {
            // If the call succeeds, the token exists.
            exists = true;
        } catch {
            // If the call fails, then the token does not exist.
            exists = false;
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

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param tokenId The id of the account owner.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }

    /// @dev Calculate the total collateral value of the account in debt tokens.
    /// @param tokenId The id of the account owner.
    /// @return The total collateral value of the account in debt tokens.
    function _totalCollateralValue(uint256 tokenId, bool includeUnrealizedDebt) internal view returns (uint256) {
        uint256 totalUnderlying;
        if (includeUnrealizedDebt) {
            (,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
            if (collateral > 0) totalUnderlying += convertYieldTokensToUnderlying(collateral);
        } else {
            totalUnderlying = convertYieldTokensToUnderlying(_accounts[tokenId].collateralBalance);
        }
        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];
        (uint256 newDebt, uint256 newEarmarked, uint256 redeemedTotal) =
            _computeUnrealizedAccount(account, _earmarkWeight, _redemptionWeight, _survivalAccumulator);

        // Calculate collateral to remove
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta != 0 && redeemedTotal != 0) {
            uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;

            // sharesToDebit = redeemedTotal * globalSharesDelta / globalDebtDelta
            uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedTotal, globalSharesDelta, globalDebtDelta);

            if (sharesToDebit > account.collateralBalance) sharesToDebit = account.collateralBalance;
            account.collateralBalance -= sharesToDebit;
        }

        // advance checkpoints even if redeemedTotal==0
        account.lastTotalRedeemedDebt = _totalRedeemedDebt;
        account.lastTotalRedeemedSharesOut = _totalRedeemedSharesOut;

        account.earmarked = newEarmarked;
        account.debt = newDebt;

        // Advance account checkpoint
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.lastAccruedRedemptionWeight = _redemptionWeight;

        // Snapshot G for this account
        account.lastSurvivalAccumulator = _survivalAccumulator;
    }

    /// @dev Computes the account debt/earmark state at a given global weight snapshot.
    /// @return newDebt The debt after applying earmark + redemption.
    /// @return newEarmarked The earmarked portion after applying survival and new earmarks.
    /// @return redeemedDebt Realized redeemed debt for this step.
    function _computeUnrealizedAccount(
        Account storage account,
        uint256 earmarkWeightCurrent,
        uint256 redemptionWeightCurrent,
        uint256 survivalAccumulatorCurrent
    ) internal view returns (uint256 newDebt, uint256 newEarmarked, uint256 redeemedDebt) {
        // Survival during current sync window
        uint256 survivalRatio = 
            _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, redemptionWeightCurrent);

        // User exposure at last sync used to calculate newly earmarked debt pre redemption
        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 unearmarkSurvivalRatio = 
            _earmarkSurvivalRatio(account.lastAccruedEarmarkWeight, earmarkWeightCurrent);

        // amount that stayed unearmarked from userExposure
        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(userExposure, unearmarkSurvivalRatio);

        // amount newly earmarked since last sync
        uint256 earmarkRaw = userExposure - unearmarkedRemaining;

        // No redemption in this sync window -> debt cannot decrease.
        if (survivalRatio == ONE_Q128) {
            newDebt = account.debt;
            newEarmarked = account.earmarked + earmarkRaw;
            if (newEarmarked > newDebt) newEarmarked = newDebt;
            redeemedDebt = 0;
            return (newDebt, newEarmarked, redeemedDebt);
        }

        // Unwind via the survival accumulator.
        uint256 earmarkSurvival = _redIndex(account.lastAccruedEarmarkWeight);
        if (earmarkSurvival == 0) earmarkSurvival = ONE_Q128;

        // Default path for accounts that stayed inside the same earmark epoch.
        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        uint256 survivalDiff = survivalAccumulatorCurrent > decayedRedeemed ? survivalAccumulatorCurrent - decayedRedeemed : 0;
        if (survivalDiff > earmarkSurvival) survivalDiff = earmarkSurvival;
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);

        uint256 oldEarEpoch = account.lastAccruedEarmarkWeight >> _EARMARK_INDEX_BITS;
        uint256 newEarEpoch = earmarkWeightCurrent >> _EARMARK_INDEX_BITS;
        if (newEarEpoch == oldEarEpoch) {
            uint256 currentEarmarkIndex = earmarkWeightCurrent & _EARMARK_INDEX_MASK;
            uint256 telescopedEarmarkDrop = earmarkSurvival > currentEarmarkIndex ? earmarkSurvival - currentEarmarkIndex : 0;

            // When the current sync window stayed inside one earmark epoch and the accumulator
            // collapses to the telescoped earmark drop, there were no interleaved pre-claim
            // redemptions that require per-step weighting. Using the user-sized formula here
            // avoids amplifying index-scale ceil rounding by exposure / earmarkSurvival.
            if (survivalDiff == FixedPointMath.mulQ128(telescopedEarmarkDrop, survivalRatio)) {
                earmarkedUnredeemed = FixedPointMath.mulQ128(earmarkRaw, survivalRatio);
            }
        }

        // If the account crossed an earmark epoch, split math at the first boundary:
        // - pre-boundary via accumulator diff at epoch boundary,
        // - post-boundary via redemption survival only.
        // This avoids both over-redemption (pre-boundary redemptions applied twice)
        // and under-redemption (post-boundary accumulator contamination).
        if (newEarEpoch > oldEarEpoch) {
            uint256 boundaryEpoch = oldEarEpoch + 1;
            uint256 boundaryRedemptionWeight = _earmarkEpochStartRedemptionWeight[boundaryEpoch];
            uint256 boundarySurvivalAccumulator = _earmarkEpochStartSurvivalAccumulator[boundaryEpoch];

            if (boundaryRedemptionWeight != 0) {
                uint256 preBoundarySurvival =
                    _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, boundaryRedemptionWeight);
                uint256 decayedAtBoundary = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, preBoundarySurvival);

                uint256 boundaryDiff =
                    boundarySurvivalAccumulator > decayedAtBoundary ? boundarySurvivalAccumulator - decayedAtBoundary : 0;
                if (boundaryDiff > earmarkSurvival) boundaryDiff = earmarkSurvival;

                uint256 unredeemedAtBoundaryRatio = FixedPointMath.divQ128(boundaryDiff, earmarkSurvival);
                uint256 unredeemedAtBoundary = FixedPointMath.mulQ128(userExposure, unredeemedAtBoundaryRatio);

                uint256 postBoundarySurvival =
                    _redemptionSurvivalRatio(boundaryRedemptionWeight, redemptionWeightCurrent);

                earmarkedUnredeemed = FixedPointMath.mulQ128(unredeemedAtBoundary, postBoundarySurvival);
            } else {
                // Backward-compatibility fallback for old state without boundary checkpoints.
                earmarkedUnredeemed = FixedPointMath.mulQ128(earmarkRaw, survivalRatio);
            }
        }

        if (earmarkedUnredeemed > earmarkRaw) earmarkedUnredeemed = earmarkRaw;

        // Old earmarks that survived redemptions in the current sync window
        uint256 exposureSurvival = FixedPointMath.mulQ128(account.earmarked, survivalRatio);
        // What was redeemed from the newly earmark between last sync and now
        uint256 redeemedFromEarmarked = earmarkRaw - earmarkedUnredeemed;
        // Total overall earmarked to adjust user debt
        uint256 redeemedTotal = (account.earmarked - exposureSurvival) + redeemedFromEarmarked;

        newDebt = account.debt >= redeemedTotal ? account.debt - redeemedTotal : 0;
        redeemedDebt = account.debt - newDebt;
        newEarmarked = exposureSurvival + earmarkedUnredeemed;
        if (newEarmarked > newDebt) newEarmarked = newDebt;
    }

    /// @dev Earmarks the debt for redemption.
    function _earmark() internal {
        if (totalDebt == 0) return;
        if (block.number <= lastEarmarkBlock) return;

        // update pending cover shares based on transmuter balance delta
        uint256 transmuterBalance = TokenUtils.safeBalanceOf(myt, address(transmuter));

        if (transmuterBalance > lastTransmuterTokenBalance) {
            _pendingCoverShares += (transmuterBalance - lastTransmuterTokenBalance);
        }

        lastTransmuterTokenBalance = transmuterBalance;

        // how to earmark this window
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        // apply cover
        uint256 coverInDebt = convertYieldTokensToDebt(_pendingCoverShares);
        if (amount != 0 && coverInDebt != 0) {
            uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
            amount -= usedDebt;

            // consume the corresponding portion of pending cover shares so we can't reuse it
            uint256 sharesUsed = FixedPointMath.mulDivUp(_pendingCoverShares, usedDebt, coverInDebt);
            if (sharesUsed > _pendingCoverShares) sharesUsed = _pendingCoverShares;
            _pendingCoverShares -= sharesUsed;
        }

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;

        if (amount > 0 && liveUnearmarked != 0) {
            // ratioWanted = (liveUnearmarked - amount) / liveUnearmarked
            uint256 ratioWanted =
                (amount == liveUnearmarked) ? 0 : FixedPointMath.divQ128(liveUnearmarked - amount, liveUnearmarked);

            uint256 packedOld = _earmarkWeight;
            (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced) =
                _simulateEarmarkPackedUpdate(packedOld, ratioWanted);

            _earmarkWeight = packedNew;

            // Survival increment uses the APPLIED earmark fraction
            uint256 earmarkedFraction = ONE_Q128 - ratioApplied;
            _survivalAccumulator += FixedPointMath.mulQ128(oldIndex, earmarkedFraction);

            if (epochAdvanced) {
                _earmarkEpochStartRedemptionWeight[newEpoch] = _redemptionWeight;
                _earmarkEpochStartSurvivalAccumulator[newEpoch] = _survivalAccumulator;
            }

            // Bump cumulativeEarmarked by the effective amount implied by ratioApplied
            uint256 newUnearmarked = FixedPointMath.mulQ128(liveUnearmarked, ratioApplied);
            uint256 effectiveEarmarked = liveUnearmarked - newUnearmarked;

            cumulativeEarmarked += effectiveEarmarked;
        }

        lastEarmarkBlock = block.number;
    }

    /// @dev Projects an account through one sync, including one simulated pending earmark window.
    ///
    /// @param tokenId The account id to project.
    ///
    /// @return The projected debt after sync.
    /// @return The projected earmarked debt after sync.
    /// @return The projected collateral remaining after realized redemptions are applied.
    function _calculateUnrealizedDebt(uint256 tokenId)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        Account storage account = _accounts[tokenId];

        // Simulate one uncommitted earmark window and use its simulated weight.
        (uint256 earmarkWeightCopy,) = _simulateUnrealizedEarmark();

        // First, compute account state against committed globals only.
        (uint256 newDebt, uint256 newEarmarked, uint256 redeemedTotalSim) =
            _computeUnrealizedAccount(account, _earmarkWeight, _redemptionWeight, _survivalAccumulator);

        // Then, apply the simulated earmark-only delta.
        // Important: this prospective earmark happens "now", so historical redemptions must not
        // reduce debt again through this simulated step.
        if (earmarkWeightCopy != _earmarkWeight) {
            uint256 exposure = newDebt > newEarmarked ? newDebt - newEarmarked : 0;
            if (exposure != 0) {
                uint256 unearmarkedRatio = _earmarkSurvivalRatio(_earmarkWeight, earmarkWeightCopy);
                uint256 unearmarkedRemaining = FixedPointMath.mulQ128(exposure, unearmarkedRatio);
                uint256 newlyEarmarked = exposure - unearmarkedRemaining;
                newEarmarked += newlyEarmarked;
                if (newEarmarked > newDebt) newEarmarked = newDebt;
            }
        }

        // Calculate collateral to remove from fees and redemptions
        uint256 collateralBalanceCopy = account.collateralBalance;
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta != 0 && redeemedTotalSim != 0) {
            uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;
            uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedTotalSim, globalSharesDelta, globalDebtDelta);
            if (sharesToDebit > collateralBalanceCopy) sharesToDebit = collateralBalanceCopy;
            collateralBalanceCopy -= sharesToDebit;
        }

        return (newDebt, newEarmarked, collateralBalanceCopy);
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev Returns true only if the account is undercollateralized
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        // totalValue(tokenId) is already denominated in debt-token units
        uint256 collateralValue = totalValue(tokenId);

        // Required collateral value = ceil(debt * minCollat / 1e18)
        uint256 required = FixedPointMath.mulDivUp(debt, minimumCollateralization, FIXED_POINT_SCALAR);

        return collateralValue < required;
    }

    /// @dev Converts tracked MYT shares into underlying units.
    /// @return totalUnderlyingValue The underlying value represented by `_mytSharesDeposited`.
    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(_mytSharesDeposited);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }

    /// @dev Returns the underlying value that must remain locked to support live debt, capped by tracked MYT.
    function _getTotalLockedUnderlyingValue() internal view returns (uint256) {
        uint256 required = _requiredLockedShares();

        // Cap by actual shares held in the Alchemist
        uint256 held = _mytSharesDeposited;

        uint256 lockedShares = required > held ? held : required;
        return convertYieldTokensToUnderlying(lockedShares);
    }
    /// @dev Returns true if issued synthetics exceed global backing.
    ///      Backing mirrors Transmuter claim math:
    ///      locked collateral in Alchemist + MYT shares currently held by Transmuter.
    function _isProtocolInBadDebt() internal view returns (bool) {
        if (totalSyntheticsIssued == 0) return false;

        uint256 transmuterShares = TokenUtils.safeBalanceOf(myt, address(transmuter));
        uint256 backingUnderlying = _getTotalLockedUnderlyingValue() + convertYieldTokensToUnderlying(transmuterShares);
        uint256 backingDebt = normalizeUnderlyingTokensToDebt(backingUnderlying);

        return totalSyntheticsIssued > backingDebt;
    }

    /// @dev Calculates locked collateral based on share price
    function _requiredLockedShares() internal view returns (uint256) {
        if (totalDebt == 0) return 0;

        uint256 debtShares = convertDebtTokensToYield(totalDebt);
        return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
    }

    // Survival ratio of *unearmarked* exposure between two packed earmark states.
    function _earmarkSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure returns (uint256) {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128; // uninitialized snapshot => assume "no change"

        uint256 oldEpoch = oldPacked >> _EARMARK_INDEX_BITS;
        uint256 newEpoch = newPacked >> _EARMARK_INDEX_BITS;

        // Epoch advanced => old unearmarked was fully earmarked at some point.
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIdx = oldPacked & _EARMARK_INDEX_MASK;
        uint256 newIdx = newPacked & _EARMARK_INDEX_MASK;

        if (oldIdx == 0) return 0;

        return FixedPointMath.divQ128(newIdx, oldIdx);
    }

    /// @dev Computes redemption survival ratio between two redemption weights.
    ///      Uses division when survivals are representable, and falls back to delta-weight
    ///      when SurvivalFromWeight() underflows to 0 for both endpoints.
    function _redemptionSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure returns (uint256) {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128;

        uint256 oldEpoch = oldPacked >> _REDEMPTION_INDEX_BITS;
        uint256 newEpoch = newPacked >> _REDEMPTION_INDEX_BITS;

        // If epoch advances, there was a full wipe at some point
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIndex = oldPacked & _REDEMPTION_INDEX_MASK;
        uint256 newIndex = newPacked & _REDEMPTION_INDEX_MASK;

        // If oldIndex is 0, treat as fully redeemed.
        if (oldIndex == 0) return 0;

        // ratio = newIndex / oldIndex
        return FixedPointMath.divQ128(newIndex, oldIndex);
    }

    /// @dev Simulates one uncommitted earmark window using current on-chain state.
    /// @return earmarkWeightCopy Simulated earmark packed weight after the window.
    /// @return effectiveEarmarked The additional earmarked debt from this simulated window.
    function _simulateUnrealizedEarmark() internal view returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked) {
        earmarkWeightCopy = _earmarkWeight;
        if (block.number <= lastEarmarkBlock || totalDebt == 0) return (earmarkWeightCopy, 0);

        uint256 transmuterBalance = TokenUtils.safeBalanceOf(myt, address(transmuter));

        // simulate pending cover
        uint256 pendingCover = _pendingCoverShares;
        if (transmuterBalance > lastTransmuterTokenBalance) {
            pendingCover += (transmuterBalance - lastTransmuterTokenBalance);
        }

        // simulate earmark amount for this window
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        // apply cover the same way
        uint256 coverInDebt = convertYieldTokensToDebt(pendingCover);
        if (amount != 0 && coverInDebt != 0) {
            uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
            amount -= usedDebt;
        }

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;
        if (amount == 0 || liveUnearmarked == 0) return (earmarkWeightCopy, 0);

        // ratioWanted = (liveUnearmarked - amount) / liveUnearmarked
        uint256 ratioWanted =
            (amount == liveUnearmarked) ? 0 : FixedPointMath.divQ128(liveUnearmarked - amount, liveUnearmarked);

        (uint256 packedNew, uint256 ratioApplied,,,) = _simulateEarmarkPackedUpdate(earmarkWeightCopy, ratioWanted);
        earmarkWeightCopy = packedNew;

        uint256 newUnearmarked = FixedPointMath.mulQ128(liveUnearmarked, ratioApplied);
        effectiveEarmarked = liveUnearmarked - newUnearmarked;
    }

    /// @dev Simulates the packed earmark update and returns the applied survival ratio.
    /// @param packedOld Existing packed earmark weight.
    /// @param ratioWanted Wanted survival ratio for unearmarked debt in this step.
    /// @return packedNew The new packed earmark weight.
    /// @return ratioApplied The effective survival ratio that will be observed by accounts.
    /// @return oldIndex The normalized previous index.
    /// @return newEpoch The resulting epoch after this step.
    /// @return epochAdvanced Whether the update crossed an epoch boundary.
    function _simulateEarmarkPackedUpdate(uint256 packedOld, uint256 ratioWanted)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        uint256 oldEpoch = packedOld >> _EARMARK_INDEX_BITS;
        oldIndex = packedOld & _EARMARK_INDEX_MASK;

        if (packedOld == 0) {
            oldEpoch = 0;
            oldIndex = ONE_Q128;
        }
        if (oldIndex == 0) {
            oldEpoch += 1;
            oldIndex = ONE_Q128;
        }

        newEpoch = oldEpoch;
        uint256 newIndex;

        if (ratioWanted == 0) {
            newEpoch += 1;
            newIndex = ONE_Q128;
        } else {
            newIndex = FixedPointMath.mulQ128(oldIndex, ratioWanted);
        }

        epochAdvanced = newEpoch > oldEpoch;
        packedNew = _packRed(newEpoch, newIndex);
        ratioApplied = epochAdvanced ? 0 : FixedPointMath.divQ128(newIndex, oldIndex);
    }

    // Bitwise helpers
    function _redEpoch(uint256 packed) private pure returns (uint256) {
        return packed >> _REDEMPTION_INDEX_BITS;
    }

    function _redIndex(uint256 packed) private pure returns (uint256) {
        return packed & _REDEMPTION_INDEX_MASK;
    }

    function _packRed(uint256 epoch, uint256 index) private pure returns (uint256) {
        return (epoch << _REDEMPTION_INDEX_BITS) | index;
    }

}





