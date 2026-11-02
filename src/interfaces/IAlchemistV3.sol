// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Contract initialization parameters.
struct AlchemistInitializationParams {
    // The initial admin account.
    address admin;
    // The ERC20 token used to represent debt. i.e. the alAsset.
    address debtToken;
    // The ERC20 token used to represent the underlying token of the yield token.
    address underlyingToken;
    // The global maximum amount of deposited collateral.
    uint256 depositCap;
    // The minimum collateralization between 0 and 1 exclusive
    uint256 minimumCollateralization;
    // The global minimum collateralization, >= minimumCollateralization.
    uint256 globalMinimumCollateralization;
    // The minimum collateralization for liquidation eligibility. between 1 and minimumCollateralization inclusive.
    uint256 collateralizationLowerBound;
    // The target collateralization ratio to restore accounts to after liquidation. Must be >= minimumCollateralization.
    uint256 liquidationTargetCollateralization;
    // The initial transmuter or transmuter buffer.
    address transmuter;
    // The fee on user debt paid to the protocol.
    uint256 protocolFee;
    // The address that receives protocol fees.
    address protocolFeeReceiver;
    // Fee paid to liquidators.
    uint256 liquidatorFee;
    // Fee paid to liquidators forcing an account earmarked debt repayment.
    uint256 repaymentFee;
    // The address of the morpho v2 vault.
    address myt;
}

/// @notice A user account.
/// @notice This account struct is included in the main contract, AlchemistV3.sol, to aid readability.
struct Account {
    /// @notice User's collateral.
    uint256 collateralBalance;
    /// @notice User's debt.
    uint256 debt;
    /// @notice User debt earmarked for redemption.
    uint256 earmarked;
    /// @notice The amount of unlocked collateral.
    uint256 freeCollateral;
    /// @notice Last weight of earmark from most recent account sync.
    uint256 lastAccruedEarmarkWeight;
    /// @notice Last weight of redemption from most recent account sync.
    uint256 lastAccruedRedemptionWeight;
    /// @notice Last weight of collateral from most recent account sync.
    uint256 lastCollateralWeight;
    /// @notice Block of the most recent mint
    uint256 lastMintBlock;
    /// @notice Block of the most recent repay
    uint256 lastRepayBlock;
    /// @notice Last stored survival accumulator
    uint256 lastSurvivalAccumulator;
    /// @notice Total debt redeemed at last sync
    uint256 lastTotalRedeemedDebt;
    /// @notice Total debt paid out from redemptions at last sync
    uint256 lastTotalRedeemedSharesOut;
    /// @notice allowances for minting alAssets, per version.
    mapping(uint256 => mapping(address => uint256)) mintAllowances;
    /// @notice id used in the mintAllowances map which is incremented on reset.
    uint256 allowancesVersion;
}

/// @notice Information associated with a redemption.
/// @notice This redemption struct is included in the main contract, AlchemistV3.sol, to aid in calculating user debt from historic redemptions.
struct RedemptionInfo {
    uint256 earmarked;
    uint256 debt;
    uint256 earmarkWeight;
}

interface IAlchemistV3Actions {
    /// @notice Approve `spender` to mint `amount` debt tokens.
    ///
    /// @param tokenId The tokenId of account granting approval.
    /// @param spender The address that will be approved to mint.
    /// @param amount  The amount of tokens that `spender` will be allowed to mint.

    function approveMint(uint256 tokenId, address spender, uint256 amount) external;

    /// @notice Synchronizes the state of the account owned by `owner`.
    ///
    /// @param tokenId   The tokenId of account
    function poke(uint256 tokenId) external;

    /// @notice Deposit a yield token into a user's account.
    /// @notice Create a new position by using zero (0) for the `recipientId`.
    /// @notice Users may create as many positions as they want.
    ///
    /// @notice An approval must be set for `yieldToken` which is greater than `amount`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or the call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Deposit} event.
    ///
    /// @notice **_NOTE:_** When depositing, the `AlchemistV3` contract must have **allowance()** to spend funds on behalf of **msg.sender** for at least **amount** of the **yieldToken** being deposited.  This can be done via the standard `ERC20.approve()` method.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice address ydai = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    /// @notice uint256 amount = 50000;
    /// @notice IERC20(ydai).approve(alchemistAddress, amount);
    /// @notice (uint256 tokenId, uint256 debtValue) = AlchemistV3(alchemistAddress).deposit(amount, msg.sender, 0);
    /// @notice ```
    ///
    /// @param amount     The amount of yield tokens to deposit.
    /// @param recipient  The owner of the account that will receive the resulting shares.
    /// @param recipientId The id of account.
    /// @return tokenId The id of the account.
    /// @return debtValue The value of deposited tokens normalized to debt token value.
    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256 tokenId, uint256 debtValue);

    /// @notice Withdraw `amount` yield tokens to `recipient`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Withdraw} event.
    ///
    /// @notice **_NOTE:_** When withdrawing, th amount withdrawn must not put user over allowed LTV ratio.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice address ydai = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    /// @notice (uint256 LTV, ) = AlchemistV3(alchemistAddress).getLoanTerms(msg.sender);
    /// @notice (uint256 yieldTokens, ) = AlchemistV3(alchemistAddress).getCDP(tokenId);
    /// @notice uint256 maxWithdrawableTokens = (AlchemistV3(alchemistAddress).LTV() - LTV) * yieldTokens / LTV;
    /// @notice AlchemistV3(alchemistAddress).withdraw(maxWithdrawableTokens, msg.sender);
    /// @notice ```
    ///
    /// @param amount     The number of tokens to withdraw.
    /// @param recipient  The address of the recipient.
    /// @param tokenId The tokenId of account.
    ///
    /// @return amountWithdrawn The number of yield tokens that were withdrawn to `recipient`.
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256 amountWithdrawn);

    /// @notice Mint `amount` debt tokens.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    ///
    /// @notice Emits a {Mint} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtDebt = 5000;
    /// @notice AlchemistV3(alchemistAddress).mint(amtDebt, msg.sender);
    /// @notice ```
    ///
    /// @param tokenId The tokenId of account.
    /// @param amount    The amount of tokens to mint.
    /// @param recipient The address of the recipient.
    function mint(uint256 tokenId, uint256 amount, address recipient) external;

    /// @notice Mint `amount` debt tokens from the account owned by `owner` to `recipient`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    ///
    /// @notice Emits a {Mint} event.
    ///
    /// @notice **_NOTE:_** The caller of `mintFrom()` must have **mintAllowance()** to mint debt from the `Account` controlled by **owner** for at least the amount of **yieldTokens** that **shares** will be converted to.  This can be done via the `approveMint()` or `permitMint()` methods.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtDebt = 5000;
    /// @notice AlchemistV3(alchemistAddress).mintFrom(msg.sender, amtDebt, msg.sender);
    /// @notice ```
    ///
    /// @param tokenId   The tokenId of account.
    /// @param amount    The amount of tokens to mint.
    /// @param recipient The address of the recipient.
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external;

    /// @notice Burn `amount` debt tokens to credit the account owned by `recipientId`.
    ///
    /// @notice `amount` will be limited up to the amount of unearmarked debt that `recipient` currently holds.
    ///
    /// @notice `recipientId` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    /// @notice account for `recipientId` must have non-zero debt or this call will revert with an {IllegalState} error.
    ///
    /// @notice Emits a {Burn} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtBurn = 5000;
    /// @notice AlchemistV3(alchemistAddress).burn(amtBurn, 420);
    /// @notice ```
    ///
    /// @param amount    The amount of tokens to burn.
    /// @param recipientId   The tokenId of account to being credited.
    ///
    /// @return amountBurned The amount of tokens that were burned.
    function burn(uint256 amount, uint256 recipientId) external returns (uint256 amountBurned);

    /// @notice Repay `amount` debt using yield tokens to credit the account owned by `recipientId`.
    ///
    /// @notice `amount` will be limited up to the amount of debt that `recipient` currently holds.
    ///
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Repay} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtRepay = 5000;
    /// @notice AlchemistV3(alchemistAddress).repay(amtRepay, msg.sender);
    /// @notice ```
    ///
    /// @param amount          The amount of the yield tokens to repay with.
    /// @param recipientTokenId   The tokenId of account to be repaid
    ///
    /// @return amountRepaid The amount of tokens that were repaid.
    function repay(uint256 amount, uint256 recipientTokenId) external returns (uint256 amountRepaid);

    /**
     * @notice Liquidates `accountId` when it is below the collateralization lower bound.
     *
     * @notice Earmarked debt is force-repaid first. If that restores health, `yieldAmount` is the repaid MYT
     *         and {RepaymentFee} is emitted. Otherwise `yieldAmount` is only the MYT seized by liquidation
     *         and {Liquidated} is emitted. A preceding repayment is reported by {ForceRepay}.
     *
     * @notice Reverts with {LiquidationError} when the account is already healthy and no debt was reduced.
     *
     * @param accountId The tokenId of the account.
     *
     * @return yieldAmount      Repaid MYT if health is restored, otherwise MYT seized by liquidation.
     * @return feeInYield       MYT fee paid to the caller.
     * @return feeInUnderlying  Underlying fee paid to the caller from the fee vault.
     */
    function liquidate(uint256 accountId) external returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying);


    /// @notice Self liquidates the account owned by `accountId`.
    ///
    /// @notice `accountId` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `accountId` must be owned by `msg.sender` or this call will revert with an {Unauthorized} error.
    /// @notice `accountId` must be healthy (overcollateralized) or this call will revert with an {AccountNotHealthy} error.
    /// @notice in the event that account is not healthy, the account can only be liquidated using the regular liquidation path. (i.e. liquidate(accountId))
    ///
    /// @notice Emits a {SelfLiquidated} event.
    ///
    /// @param accountId The tokenId of account to be self liquidated.
    /// @param recipient The address of the recipient.
    function selfLiquidate(uint256 accountId, address recipient) external returns (uint256 amountLiquidated);

    /// @notice Liquidates `owners` if the debt for account `owner` is greater than the underlying value of their collateral * LTV.
    ///
    /// @notice `owner` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice AlchemistV3(alchemistAddress).batchLiquidate([id1, id35]);
    /// @notice ```
    ///
    /// @param accountIds   The tokenId of each account
    ///
    /// @return totalAmountLiquidated   Sum of each account's `yieldAmount`. See {liquidate}.
    /// @return totalFeesInYield        Sum of MYT fees paid to the caller.
    /// @return totalFeesInUnderlying   Sum of underlying fees paid to the caller.
    function batchLiquidate(uint256[] memory accountIds)
        external
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying);

    /// @notice Redeems `amount` debt from the alchemist in exchange for yield tokens sent to the transmuter.
    ///
    /// @notice This function is only callable by the transmuter.
    ///
    /// @notice Emits a {Redeem} event.
    ///
    /// @param amount The amount of tokens to redeem.
    function redeem(uint256 amount) external returns (uint256 sharesSent);

    /// @notice Reduces syntheticTokensIssued by `amount`.
    ///
    /// @notice This function is only callable by the transmuter.
    ///
    /// @param amount The amount of tokens burned during redemption.
    function reduceSyntheticsIssued(uint256 amount) external;

    /// @notice Sets lastTransmuterTokenBalance to `amount`.
    ///
    /// @notice This function is only callable by the transmuter.
    ///
    /// @param amount The balance of the transmuter.
    function setTransmuterTokenBalance(uint256 amount) external;

    /// @notice Resets all mint allowances by account managed by `tokenId`.
    ///
    /// @notice This function is only callable by the owner of the token id or the AlchemistV3Position contract.
    ///
    /// @notice Emits a {MintAllowancesReset} event.
    ///
    /// @param tokenId The token id of the account.
    function resetMintAllowances(uint256 tokenId) external;
}

interface IAlchemistV3AdminActions {
    /// @notice Sets the pending administrator.
    ///
    /// @notice `msg.sender` must be the admin or this call will will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {PendingAdminUpdated} event.
    ///
    /// @dev This is the first step in the two-step process of setting a new administrator. After this function is called, the pending administrator will then need to call {acceptAdmin} to complete the process.
    ///
    /// @param value The address to set the pending admin to.
    function setPendingAdmin(address value) external;

    /// @notice Sets the active state of a guardian.
    ///
    /// @notice `msg.sender` must be the admin or this call will will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {GuardianSet} event.
    ///
    /// @param guardian The address of the target guardian.
    /// @param isActive The active state to set for the guardian.
    function setGuardian(address guardian, bool isActive) external;

    /// @notice Allows for `msg.sender` to accepts the role of administrator.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    /// @notice The current pending administrator must be non-zero or this call will revert with an {IllegalState} error.
    ///
    /// @dev This is the second step in the two-step process of setting a new administrator. After this function is successfully called, this pending administrator will be reset and the new administrator will be set.
    ///
    /// @notice Emits a {AdminUpdated} event.
    /// @notice Emits a {PendingAdminUpdated} event.
    function acceptAdmin() external;

    /// @notice Set a new alchemist deposit cap.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {DepositCapUpdated} event.
    ///
    /// @param value The value of the new deposit cap.
    function setDepositCap(uint256 value) external;

    /// @notice Sets the token adapter for the yield token.
    ///
    /// @notice `msg.sender` must be the admin or this call will will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {TokenAdapterSet} event.
    ///
    /// @param value The address of token adapter.
    function setTokenAdapter(address value) external;

    /// @notice Set the minimum collateralization ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {MinimumCollateralizationUpdated} event.
    ///
    /// @param value The new minimum collateralization ratio.
    function setMinimumCollateralization(uint256 value) external;

    /// @notice Set a new protocol fee receiver.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeReceiverUpdated} event.
    ///
    /// @param receiver The address of the new fee receiver.
    function setProtocolFeeReceiver(address receiver) external;

    /// @notice Set a new protocol debt fee.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeUpdated} event.
    ///
    /// @param fee The new protocol debt fee.
    function setProtocolFee(uint256 fee) external;

    /// @notice Set a new liquidator fee.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {LiquidatorFeeUpdated} event.
    ///
    /// @param fee The new liquidator fee.
    function setLiquidatorFee(uint256 fee) external;

    /// @notice Set a new repayment fee.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {RepaymentFeeUpdated} event.
    ///
    /// @param fee The new repayment fee.
    function setRepaymentFee(uint256 fee) external;

    /// @notice Set the global minimum collateralization ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {GlobalMinimumCollateralizationUpdated} event.
    ///
    /// @param value The new global minimum collateralization ratio.
    function setGlobalMinimumCollateralization(uint256 value) external;

    /// @notice Set the collateralization lower bound ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {CollateralizationLowerBoundUpdated} event.
    ///
    /// @param value The new collateralization lower bound ratio.
    function setCollateralizationLowerBound(uint256 value) external;

    /// @notice Set the liquidation target collateralization ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {LiquidationTargetCollateralizationUpdated} event.
    ///
    /// @param value The new liquidation target collateralization ratio.
    function setLiquidationTargetCollateralization(uint256 value) external;

    /// @notice Pause all future deposits in the Alchemist.
    ///
    /// @notice `msg.sender` must be the admin or guardian or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {DepositsPaused} event.
    ///
    /// @param isPaused The new pause state for deposits in the alchemist.
    function pauseDeposits(bool isPaused) external;

    /// @notice Pause all future loans in the Alchemist.
    ///
    /// @notice `msg.sender` must be the admin or guardian or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {LoansPaused} event.
    ///
    /// @param isPaused The new pause state for loans in the alchemist.
    function pauseLoans(bool isPaused) external;

    /// @notice Set the alchemist Fee vault.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {AlchemistFeeVaultUpdated} event.
    ///
    /// @param value The address of the new alchemist Fee vault.
    function setAlchemistFeeVault(address value) external;
}

interface IAlchemistV3Events {
    /// @notice Emitted when the pending admin is updated.
    ///
    /// @param pendingAdmin The address of the pending admin.
    event PendingAdminUpdated(address pendingAdmin);

    /// @notice Emitted when the alchemist Fee vault is updated.
    ///
    /// @param alchemistFeeVault The address of the alchemist Fee vault.
    event AlchemistFeeVaultUpdated(address alchemistFeeVault);

    /// @notice Emitted when the administrator is updated.
    ///
    /// @param admin The address of the administrator.
    event AdminUpdated(address admin);

    /// @notice Emitted when the deposit cap is updated.
    ///
    /// @param value The value of the new deposit cap.
    event DepositCapUpdated(uint256 value);

    /// @notice Emitted when a guardian is added or removed from the alchemist.
    ///
    /// @param guardian The addres of the new guardian.
    /// @param state    The active state of the guardian.
    event GuardianSet(address guardian, bool state);

    /// @notice Emitted when a new token adapter is set in the alchemist.
    ///
    /// @param adapter The addres of the new adapter.
    event TokenAdapterUpdated(address adapter);

    /// @notice Emitted when the transmuter is updated.
    ///
    /// @param transmuter The updated address of the transmuter.
    event TransmuterUpdated(address transmuter);

    /// @notice Emitted when the minimum collateralization is updated.
    ///
    /// @param minimumCollateralization The updated minimum collateralization.
    event MinimumCollateralizationUpdated(uint256 minimumCollateralization);

    /// @notice Emitted when the global minimum collateralization is updated.
    ///
    /// @param globalMinimumCollateralization The updated global minimum collateralization.
    event GlobalMinimumCollateralizationUpdated(uint256 globalMinimumCollateralization);

    /// @notice Emitted when the collateralization lower bound (for a liquidation) is updated.
    ///
    /// @param collateralizationLowerBound The updated collateralization lower bound.
    event CollateralizationLowerBoundUpdated(uint256 collateralizationLowerBound);

    /// @notice Emitted when the liquidation target collateralization ratio is updated.
    ///
    /// @param liquidationTargetCollateralization The updated liquidation target collateralization.
    event LiquidationTargetCollateralizationUpdated(uint256 liquidationTargetCollateralization);

    /// @notice Emitted when deposits are paused or unpaused in the alchemist.
    ///
    /// @param isPaused The current pause state of deposits in the alchemist.
    event DepositsPaused(bool isPaused);

    /// @notice Emitted when loans are paused or unpaused in the alchemist.
    ///
    /// @param isPaused The current pause state of loans in the alchemist.
    event LoansPaused(bool isPaused);

    /// @notice Emitted when `owner` grants `spender` the ability to mint debt tokens on its behalf.
    ///
    /// @param ownerTokenId   The id of the account authorized to grant approval
    /// @param spender The address which is being permitted to mint tokens on the behalf of `owner`.
    /// @param amount  The amount of debt tokens that `spender` is allowed to mint.
    event ApproveMint(uint256 indexed ownerTokenId, address indexed spender, uint256 amount);

    /// @notice Emitted when a user deposits `amount of yieldToken to `recipient`.
    ///
    /// @notice This event does not imply that `sender` directly deposited yield tokens. It is possible that the
    ///         underlying tokens were wrapped.
    ///
    /// @param amount       The amount of yield tokens that were deposited.
    /// @param recipientId    The id of the account that received the deposited funds.
    event Deposit(uint256 amount, uint256 indexed recipientId);

    /// @notice Emitted when yieldToken is withdrawn from the account owned.
    ///         by `owner` to `recipient`.
    ///
    /// @notice This event does not imply that `recipient` received yield tokens. It is possible that the yield tokens
    ///         were unwrapped.
    ///
    /// @param amount     Amount of tokens withdrawn.
    /// @param tokenId The id of the account that the funds are withdrawn from.
    /// @param recipient  The address that received the withdrawn funds.
    event Withdraw(uint256 amount, uint256 indexed tokenId, address recipient);

    /// @notice Emitted when `amount` debt tokens are minted to `recipient` using the account owned by `owner`.
    ///
    /// @param tokenId     The tokenId of the account owner.
    /// @param amount    The amount of tokens that were minted.
    /// @param recipient The recipient of the minted tokens.
    event Mint(uint256 indexed tokenId, uint256 amount, address recipient);

    /// @notice Emitted when `sender` burns `amount` debt tokens to grant credit to  account owner `recipientId`.
    ///
    /// @param amount    The amount of tokens that were burned.
    /// @param recipientId The token id of account owned by recipientId that received credit for the burned tokens.
    event Burn(address indexed sender, uint256 amount, uint256 indexed recipientId);

    /// @notice Emitted when `amount` of `underlyingToken` are repaid to grant credit to account owned by `recipientId`.
    ///
    /// @param sender          The address which is repaying tokens.
    /// @param amount          The amount of the underlying token that was used to repay debt.
    /// @param recipientId     The id of account that received credit for the repaid tokens.
    /// @param credit          The amount of debt that was paid-off to the account owned by owner.
    event Repay(address indexed sender, uint256 amount, uint256 indexed recipientId, uint256 credit);

    /// @notice Emitted when the transmuter triggers a redemption.
    ///
    /// @param amount   The amount of debt to redeem.
    event Redemption(uint256 amount);

    /// @notice Emitted when the protocol debt fee is updated.
    ///
    /// @param fee  The new protocol fee.
    event ProtocolFeeUpdated(uint256 fee);

    /// @notice Emitted when the liquidator fee is updated.
    ///
    /// @param fee  The new liquidator fee.
    event LiquidatorFeeUpdated(uint256 fee);

    /// @notice Emitted when the repayment fee is updated.
    ///
    /// @param fee  The new repayment fee.
    event RepaymentFeeUpdated(uint256 fee);

    /// @notice Emitted when the fee receiver is updated.
    ///
    /// @param receiver   The address of the new receiver.
    event ProtocolFeeReceiverUpdated(address receiver);

    /// @notice Emitted when account owned by 'accountId' has been liquidated.
    ///
    /// @param accountId        The token id of the account liquidated
    /// @param liquidator   The address of the liquidator
    /// @param amount       MYT seized by liquidation. Excludes a preceding {ForceRepay}.
    /// @param feeInYield          The liquidation fee sent to 'liquidator' in yield tokens.
    /// @param feeInUnderlying            The liquidation fee sent to 'liquidator' in ETH (if needed i.e. if there isn't enough remaining collateral to cover the fee).
    event Liquidated(uint256 indexed accountId, address liquidator, uint256 amount, uint256 feeInYield, uint256 feeInUnderlying);

    /// @notice Emitted when account owned by 'accountId' has been self liquidated.
    ///
    /// @param accountId        The token id of the account self liquidated
    /// @param amountLiquidated The amount liquidated in yield tokens
    event SelfLiquidated(uint256 indexed accountId, uint256 amountLiquidated);

    /// @notice Emitted when account for 'owner' has been liquidated.
    ///
    /// @param accounts       The address of the accounts liquidated
    /// @param liquidator   The address of the liquidator
    /// @param amount       The amount liquidated
    /// @param feeInYield          The liquidation fee sent to 'liquidator' in yield tokens.
    /// @param feeInETH            The liquidation fee sent to 'liquidator' in ETH (if needed i.e. if there isn't enough remaining collateral to cover the fee).
    event BatchLiquidated(uint256[] indexed accounts, address liquidator, uint256 amount, uint256 feeInYield, uint256 feeInETH);

    /// @notice Emitted when all mint allowances for account managed by `tokenId` are reset.
    ///
    /// @param tokenId       The tokenId of the account.
    event MintAllowancesReset(uint256 indexed tokenId);

    /// @notice Emitted when `amount` of debt is force repaid from `accountId`.
    ///
    /// @param accountId       The tokenId of the account.
    /// @param amount          The amount of debt repaid.
    /// @param creditToYield   The amount of collateral used to repay the debt in yield tokens.
    /// @param protocolFeeTotal The amount of protocol fee paid.
    event ForceRepay(uint256 indexed accountId, uint256 amount, uint256 creditToYield, uint256 protocolFeeTotal);

    /// @notice Emitted when `amount` of debt is repaid from `accountId`.
    ///
    /// @param accountId       The tokenId of the account.
    /// @param feeReciever     The address of the fee receiver.
    /// @param feeInYield      The amount of fee paid in yield tokens.
    /// @param feeInUnderlying The amount of fee paid in underlying tokens.
    event RepaymentFee(uint256 indexed accountId, address feeReciever, uint256 feeInYield, uint256 feeInUnderlying);

    /// @notice Emitted when a fee-vault payout is short of the requested amount.
    ///
    /// @param liquidator The liquidator receiving the payout.
    /// @param requested  The requested fee amount in underlying tokens.
    /// @param paid       The amount actually paid from the fee vault.
    event FeeShortfall(address indexed liquidator, uint256 requested, uint256 paid);


    /// @notice Emitted when a new Position NFT is minted.
    ///
    /// @param to The address of the account that minted the Position NFT.
    /// @param tokenId The tokenId of the Position NFT.
    event AlchemistV3PositionNFTMinted(address indexed to, uint256 indexed tokenId);
}

interface IAlchemistV3Immutables {
    /// @notice Returns the version of the alchemist.
    ///
    /// @return The version.
    function version() external view returns (string memory);

    /// @notice Returns the address of the debt token used by the system.
    ///
    /// @return The address of the debt token.
    function debtToken() external view returns (address);
}

interface IAlchemistV3State {
    /// @notice Gets the address of the admin.
    ///
    /// @return admin The admin address.
    function admin() external view returns (address admin);

    function depositCap() external view returns (uint256 cap);

    function guardians(address guardian) external view returns (bool isActive);

    function cumulativeEarmarked() external view returns (uint256 earmarked);

    function lastEarmarkBlock() external view returns (uint256 block);

    function lastRedemptionBlock() external view returns (uint256 block);

    function lastTransmuterTokenBalance() external view returns (uint256 balance);

    function totalDebt() external view returns (uint256 debt);

    function totalSyntheticsIssued() external view returns (uint256 syntheticAmount);

    function protocolFee() external view returns (uint256 fee);

    function liquidatorFee() external view returns (uint256 fee);

    function repaymentFee() external view returns (uint256 fee);

    function underlyingConversionFactor() external view returns (uint256 factor);

    function protocolFeeReceiver() external view returns (address receiver);

    function underlyingToken() external view returns (address token);

    function myt() external view returns (address token);

    function depositsPaused() external view returns (bool isPaused);

    function loansPaused() external view returns (bool isPaused);

    function alchemistPositionNFT() external view returns (address nftContract);

    /// @notice Gets the address of the pending administrator.
    ///
    /// @return pendingAdmin The pending administrator address.
    function pendingAdmin() external view returns (address pendingAdmin);

    /// @notice Gets the address of the current yield token adapter.
    ///
    /// @return adapter The token adapter address.
    function tokenAdapter() external returns (address adapter);

    /// @notice Gets the address of the alchemist fee vault.
    ///
    /// @return vault The alchemist fee vault address.
    function alchemistFeeVault() external view returns (address vault);

    /// @notice Gets the address of the transmuter.
    ///
    /// @return transmuter The transmuter address.
    function transmuter() external view returns (address transmuter);

    /// @notice Gets the minimum collateralization.
    ///
    /// @notice Collateralization is determined by taking the total value of collateral that a user has deposited into their account and dividing it their debt.
    ///
    /// @dev The value returned is a 18 decimal fixed point integer.
    ///
    /// @return minimumCollateralization The minimum collateralization.
    function minimumCollateralization() external view returns (uint256 minimumCollateralization);

    /// @notice Gets the global minimum collateralization.
    ///
    /// @notice Collateralization is determined by taking the total value of collateral deposited in the alchemist and dividing it by the total debt.
    ///
    /// @dev The value returned is a 18 decimal fixed point integer.
    ///
    /// @return globalMinimumCollateralization The global minimum collateralization.
    function globalMinimumCollateralization() external view returns (uint256 globalMinimumCollateralization);

    ///  @notice Gets collaterlization level that will result in an account being eligible for partial liquidation
    function collateralizationLowerBound() external view returns (uint256 ratio);

    /// @notice Gets the liquidation target collateralization ratio.
    ///
    /// @notice This is the collateralization ratio that accounts are restored to after liquidation.
    ///
    /// @dev The value returned is a 18 decimal fixed point integer.
    ///
    /// @return liquidationTargetCollateralization The liquidation target collateralization.
    function liquidationTargetCollateralization() external view returns (uint256 liquidationTargetCollateralization);

    /// @dev Returns the debt value of `amount` yield tokens.
    ///
    /// @param amount   The amount to convert.
    function convertYieldTokensToDebt(uint256 amount) external view returns (uint256);

    /// @dev Returns the underlying value of `amount` yield tokens.
    ///
    /// @param amount   The amount to convert.
    function convertYieldTokensToUnderlying(uint256 amount) external view returns (uint256);

    /// @dev Returns the yield token value of `amount` debt tokens.
    ///
    /// @param amount   The amount to convert.
    function convertDebtTokensToYield(uint256 amount) external view returns (uint256);

    /// @dev Returns the yield token value of `amount` underlying tokens.
    ///
    /// @param amount   The amount to convert.
    function convertUnderlyingTokensToYield(uint256 amount) external view returns (uint256);

    /// @notice Calculates fee, net debt burn, and gross collateral seize,
    ///         using a single minCollateralization factor (FIXED_POINT_SCALAR scaled).
    /// @param collateral               Current collateral value
    /// @param debt                     Current debt value
    /// @param targetCollateralization  Target collateralization ratio, (e.g. 100/90 =  1.1111e18 for 111.11%)
    /// @param alchemistCurrentCollateralization Current collateralization ratio of the alchemist
    /// @param alchemistMinimumCollateralization Minimum collateralization ratio of the alchemist to trigger full liquidation
    /// @param feeBps                   Fee in basis points on the surplus (0–10000)
    /// @return grossCollateralToSeize  Total collateral to take (fee + net)
    /// @return debtToBurn              Amount of debt to erase (sent to protocol)
    /// @return fee                     Amount of collateral paid to liquidator
    /// @return outsourcedFee           Amount of fee paid to liquidator in underlying tokens in the event that account funds are insufficient to cover the fee
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) external view returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee);

    /// @dev Normalizes underlying tokens to debt tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view returns (uint256);

    /// @dev Normalizes debt tokens to underlying tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeDebtTokensToUnderlying(uint256 amount) external view returns (uint256);

    /// @dev Get information about CDP of tokenId
    ///
    /// @param  tokenId   The token Id of the account.
    ///
    /// @return collateral  Collateral balance.
    /// @return debt        Current debt.
    /// @return earmarked   Current debt that is earmarked for redemption.
    function getCDP(uint256 tokenId) external view returns (uint256 collateral, uint256 debt, uint256 earmarked);

    /// @dev Gets total value of account managed by `tokenId` in units of underlying tokens.
    ///
    /// @param tokenId    tokenId of the account to query.
    ///
    /// @return value   Underlying value of the account.
    function totalValue(uint256 tokenId) external view returns (uint256 value);

    /// @dev Gets total value deposited in the alchemist
    ///
    /// @return amount   Total deposite amount.
    function getTotalDeposited() external view returns (uint256 amount);

    /// @dev Gets maximum debt that `user` can borrow from their CDP.
    ///
    /// @param tokenId    tokenId of the account to query.
    ///
    /// @return maxDebt   Maximum debt that can be taken.
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256 maxDebt);

    
    /// @notice Returns the maximum MYT shares that could be withdrawn from a position
    ///
    /// @param tokenId    tokenId of the account to query.
    ///
    /// @return maxWithraw   Maximum yield tokens that can be withdrawn.
    function getMaxWithdrawable(uint256 tokenId) external view returns (uint256 maxWithraw);

    /// @dev Gets total underlying value deposited in the alchemist.
    ///
    /// @return TVL   Total value deposited.
    function getTotalUnderlyingValue() external view returns (uint256 TVL);

    /// @dev Gets total underlying value locked in the alchemist.
    ///
    /// @return TVL   Total value locked.
    function getTotalLockedUnderlyingValue() external view returns (uint256);

    /// @notice Gets the amount of debt tokens `spender` is allowed to mint on behalf of `owner`.
    ///
    /// @param ownerTokenId    tokenId of the account to query.
    /// @param spender The address which is allowed to mint on behalf of `owner`.
    ///
    /// @return allowance The amount of debt tokens that `spender` can mint on behalf of `owner`.
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256 allowance);
}

interface IAlchemistV3Errors {
    /// @notice An error which is used to indicate that an operation failed because an account became undercollateralized.
    error Undercollateralized();

    /// @notice An error which is used to indicate that a liquidate operation failed because an account is sufficiaenly collateralized.
    error LiquidationError();

    /// @notice An error which is used to indicate that a user is performing an action on an account that requires account ownership
    error UnauthorizedAccountAccessError();

    /// @notice An error which is used to indicate that a burn operation failed because the transmuter requires more debt in the system.
    ///
    /// @param amount    The amount of debt tokens that were requested to be burned.
    /// @param available The amount of debt tokens which can be burned;
    error BurnLimitExceeded(uint256 amount, uint256 available);

    /// @notice An error which is used to indicate that the account id used is not linked to any owner
    error UnknownAccountOwnerIDError();

    /// @notice An error which is used to indicate that the NFT address being set is the zero address
    error AlchemistV3NFTZeroAddressError();

    /// @notice An error which is used to indicate that the NFT address for the Alchemist has already been set
    error AlchemistV3NFTAlreadySetError();

    /// @notice An error which is used to indicate that the token address for the AlchemistTokenVault does not match the underlyingToken
    error AlchemistVaultTokenMismatchError();

    /// @notice An error which is used to indicate that a user is trying to repay on the same block they are minting
    error CannotRepayOnMintBlock();
    error CannotMintOnRepayBlock();

    error GlobalCollateralizationTooLow(uint256, uint256);

    /// @notice An error which is used to indicate that an account is not healthy
    error AccountNotHealthy();
}

/// @title  IAlchemistV3
/// @author Alchemix Finance
interface IAlchemistV3 is IAlchemistV3Actions, IAlchemistV3AdminActions, IAlchemistV3Errors, IAlchemistV3Immutables, IAlchemistV3Events, IAlchemistV3State {}
