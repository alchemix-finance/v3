// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./IAlchemistV3.sol";

interface ITransmuter {
    struct StakingPosition {
        // Amount staked.
        uint256 amount;
        // Block when the position was opened
        uint256 startBlock;
        // Time when the transmutation will be complete/claimable.
        uint256 maturationBlock;
    }

    struct TransmuterInitializationParams {
        address syntheticToken;
        address feeReceiver;
        uint256 timeToTransmute;
        uint256 transmutationFee;
        uint256 exitFee;
        uint256 graphSize;
    }

    /// @notice Gets the address of the alchemist.
    ///
    /// @return alchemist The alchemist address.
    function alchemist() external view returns (IAlchemistV3 alchemist);

    /// @notice Gets the address of the admin.
    ///
    /// @return admin The admin address.
    function admin() external view returns (address admin);

    /// @notice Gets the address of the pending admin.
    ///
    /// @return pendingAdmin The pending admin address.
    function pendingAdmin() external view returns (address pendingAdmin);

    /// @notice Returns the version of the alchemist.
    function version() external view returns (string memory version);

    /// @notice Returns the address of the synthetic token.
    function syntheticToken() external view returns (address token);

    /// @notice Returns the current transmuter deposit cap.
    function depositCap() external view returns (uint256 cap);

    /// @notice Returns the transmutation early exit fee.
    /// @notice This is for users who choose to pull from the transmuter before their position has fully matured.
    function exitFee() external view returns (uint256 fee);

    /// @notice Returns the transmutation fee.
    /// @notice This fee affects all claims.
    function transmutationFee() external view returns (uint256 fee);

    /// @notice Returns the current time to transmute (in blocks).
    function timeToTransmute() external view returns (uint256 transmutationTime);

    /// @notice Returns the total locked debt tokens in the transmuter adjusted for poked accounts.
    function totalActiveLocked() external view returns (uint256 totalLocked);

    /// @notice Returns the total locked debt tokens in the transmuter.
    function totalLocked() external view returns (uint256 totalLocked);

    function protocolFeeReceiver() external view returns (address receiver);

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

    /// @notice Set a new alchemist for redemptions.
    ///
    /// @param alchemist The address of the new alchemist.
    function setAlchemist(address alchemist) external;

    /// @notice Updates transmuter deposit limit to `cap`.
    ///
    /// @notice `cap` must be greater or equal to current synths locked in the transmuter.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    ///
    /// @param cap    The new deposit cap.
    function setDepositCap(uint256 cap) external;

    /// @notice Sets time to transmute to `time`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param time    The new transmutation time.
    function setTransmutationTime(uint256 time) external;

    /// @notice Sets the transmutation fee to `fee`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param fee    The new transmutation fee.
    function setTransmutationFee(uint256 fee) external;

    /// @notice Sets the early exit fee to `fee`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param fee    The new exit fee.
    function setExitFee(uint256 fee) external;

    /// @notice Set a new protocol fee receiver.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeReceiverUpdated} event.
    ///
    /// @param receiver The address of the new fee receiver.
    function setProtocolFeeReceiver(address receiver) external;

    /// @notice Gets position info for `id`.
    ///
    /// @param id      NFT ID,
    ///
    /// @return position   Position data.
    function getPosition(uint256 id) external view returns (StakingPosition memory position);

    /// @notice Creates a new staking position in the transmuter.
    ///
    /// @notice `depositAmount` must be non-zero or this call will revert with a {DepositZeroAmount} error.
    ///
    /// @notice Emits a {PositionCreated} event.
    ///
    /// @param depositAmount    Amount of debt tokens to deposit.
    function createRedemption(uint256 depositAmount) external;

    /// @notice Claims a staking position from the transmuter.
    ///
    /// @notice `id` must return a valid position or this call will revert with a {PositionNotFound} error.
    /// @notice End block of position must be <= to current block or this call will revert with a {PrematureClaim} error.
    ///
    /// @notice Emits a {PositionClaimed} event.
    ///
    /// @param id   Id of the nft representing the position.
    function claimRedemption(
        uint256 id
    ) external returns (uint256 claimYield, uint256 feeYield, uint256 syntheticReturned, uint256 syntheticFee);

    /// @notice Queries the staking graph from `startBlock` to `endBlock`.
    ///
    /// @param startBlock   The block to start query from.
    /// @param endBlock     The last block to query up to.
    ///
    /// @return totalValue  Total value of tokens needed to fulfill redemptions between `startBlock` and `endBlock`.
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256 totalValue);

    /// @notice Poke matured account to lower deposit cap
    ///
    /// @param id   The position ID.
    function pokeMatured(uint256 id) external;

    /// @notice Emitted when the admin address is updated.
    ///
    /// @param admin The new admin address.
    event AdminUpdated(address admin);

    /// @notice Emitted when the pending admin is updated.
    ///
    /// @param pendingAdmin The address of the pending admin.
    event PendingAdminUpdated(address pendingAdmin);

    /// @notice Emitted when the associated alchemist is updated.
    ///
    /// @param alchemist The address of the new alchemist.
    event AlchemistUpdated(address alchemist);

    /// @dev Emitted when a position is created.
    ///
    /// @param creator          The address that created the position.
    /// @param amountStaked     The amount of tokens staked.
    /// @param nftId            The id of the newly minted NFT.
    event PositionCreated(address indexed creator, uint256 amountStaked, uint256 nftId);

    /// @dev Emitted when a position is claimed.
    ///
    /// @param claimer          The address that claimed the position.
    /// @param amountClaimed    The amount of tokens claimed.
    /// @param amountUnclaimed  The amount of tokens that were not transmuted.
    event PositionClaimed(address indexed claimer, uint256 amountClaimed, uint256 amountUnclaimed);

    /// @dev Emitted when the graph size is extended.
    ///
    /// @param size  The new length of the graph.
    event GraphSizeUpdated(uint256 size);

    /// @dev Emitted when the deposit cap is updated.
    ///
    /// @param cap  The new transmuter deposit cap.
    event DepositCapUpdated(uint256 cap);

    /// @dev Emitted when the transmutaiton time is updated.
    ///
    /// @param time  The new transmutation time in blocks.
    event TransmutationTimeUpdated(uint256 time);

    /// @dev Emitted when the transmutaiton fee is updated.
    ///
    /// @param fee  The new transmutation fee.
    event TransmutationFeeUpdated(uint256 fee);

    /// @dev Emitted when the early exit fee is updated.
    ///
    /// @param fee  The new exit fee.
    event ExitFeeUpdated(uint256 fee);

    /// @dev Emitted when the fee receiver is updates.
    ///
    /// @param recevier  The new receiver.
    event ProtocolFeeReceiverUpdated(address recevier);

    event PositionPoked(uint256 indexed id, uint256 amountRemovedFromCap);
}
