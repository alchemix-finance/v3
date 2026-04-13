// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC721Tiny {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title MYTStrategy
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 * @notice This contract should be inherited by all strategies
 */
contract MYTStrategy is IMYTStrategy, Ownable {
    using Math for uint256;

    IVaultV2 public immutable MYT;
   // address public immutable receiptToken;
    address public allowanceHolder; // 0x Allowance holder
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    bytes4 public constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8;
    
    IMYTStrategy.StrategyParams public params;
    bytes32 public immutable adapterId;
    
    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    modifier onlyVault() {
        require(msg.sender == address(MYT), "PD");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Constructor for the MYTStrategy contract
     * @param _myt The address of the MYT vault
     * @param _params The parameters for the strategy
     */
    constructor(address _myt, StrategyParams memory _params) Ownable(_params.owner) {
        require(_params.owner != address(0));
        require(_myt != address(0));
        require(_params.slippageBPS < 5000);
        MYT = IVaultV2(_myt);
        params = _params;
        adapterId = keccak256(abi.encode("this", address(this)));
        allowanceHolder = 0x0000000000001fF3684f28c67538d4D072C22734;
    }

    /* ========== CORE ADAPTER FUNCTIONS ========== */

    /// @notice See Morpho V2 vault spec
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        if (killSwitch) revert StrategyAllocationPaused(address(this));
        if (assets == 0) revert InvalidAmount(1, 0);

        VaultAdapterParams memory adapterParams = abi.decode(data, (VaultAdapterParams));
        uint256 amountAllocated;

        if (adapterParams.action == ActionType.direct) {
            amountAllocated = _allocate(assets);
        } else if (adapterParams.action == ActionType.swap) {
            amountAllocated = _allocate(assets, adapterParams.swapParams.txData);
        } else {
            revert ActionNotSupported();
        }
        
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _totalValue();
        emit Allocate(amountAllocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @notice See Morpho V2 vault spec
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        if (assets == 0) revert InvalidAmount(1, 0);

        uint256 oldAllocation = allocation();
        uint256 totalValueBefore = _totalValue();

        VaultAdapterParams memory adapterParams = abi.decode(data, (VaultAdapterParams));
        _validateDeallocateAction(adapterParams.action, selector);
        uint256 amountDeallocated;

        if (adapterParams.action == ActionType.direct) {
            amountDeallocated = _deallocate(assets);
        } else if (adapterParams.action == ActionType.swap) {
            amountDeallocated = _deallocate(assets, adapterParams.swapParams.txData);
        } else if (adapterParams.action == ActionType.unwrapAndSwap) {
            amountDeallocated = _deallocate(assets, adapterParams.swapParams.txData, adapterParams.swapParams.minIntermediateOut);
        } else {
            revert ActionNotSupported();
        }

        uint256 totalValueAfter = _totalValue();
        require(totalValueAfter >= assets, "inconsistent totalValue");
        uint256 newAllocation = totalValueAfter - assets;
        emit Deallocate(amountDeallocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /* ========== INTERNAL HELPER FUNCTIONS ========== */

    /// @dev Helper to swap tokens via 0x
    function dexSwap(address to, address from, uint256 amount, uint256 minAmountOut, bytes memory callData) internal returns (uint256) {
        SafeERC20.safeApprove(from, allowanceHolder, amount);
        uint256 targetBalanceBefore = IERC20(to).balanceOf(address(this));
        (bool success, ) = allowanceHolder.call(callData);
        if (!success) revert CounterfeitSettler(allowanceHolder);
        SafeERC20.safeApprove(from, allowanceHolder, 0);
        
        uint256 amountReceived = IERC20(to).balanceOf(address(this)) - targetBalanceBefore;
        if (amountReceived < minAmountOut) revert InvalidAmount(minAmountOut, amountReceived);
        return amountReceived;
    }

    /// @dev Helper to check if strategy holds enough idle assets
    function _ensureIdleBalance(address asset, uint256 amount) internal view {
        uint256 balance = TokenUtils.safeBalanceOf(asset, address(this));
        if (balance < amount) revert InsufficientBalance(amount, balance);
    }

    /// @dev Force deallocations are limited to direct withdrawals.
    function _validateDeallocateAction(ActionType action, bytes4 selector) internal pure {
        if (selector == FORCE_DEALLOCATE_SELECTOR && action != ActionType.direct) {
            revert ForceDeallocateSwapNotAllowed();
        }
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice helper function to estimate the correct amount that can be fully
    /// withdrawn from a strategy, accounting for losses
    /// due to slippage, protocol fees, and rounding differences
    function previewAdjustedWithdraw(uint256 amount) external view returns (uint256) {
        if (amount == 0) revert InvalidAmount(1, 0);
        return _previewAdjustedWithdraw(amount);
    }

    /// @notice call this function to handle strategies with withdrawal queue NFT
    function claimWithdrawalQueue(uint256 positionId) public virtual onlyOwner returns (uint256 ret) {
        return _claimWithdrawalQueue(positionId);
    }

    /// @notice call this function to claim all available rewards from the respective
    /// protocol of this strategy
    function claimRewards(address token, bytes memory quote, uint256 minAmountOut) public onlyOwner virtual returns (uint256) {
        require(!killSwitch, "emergency");
        return _claimRewards(token, quote, minAmountOut);
    }

    /// @notice withdraw any leftover assets back to the vault
    function withdrawToVault() public virtual onlyOwner returns (uint256) {
        uint256 leftover = IERC20(MYT.asset()).balanceOf(address(this));
        SafeERC20.safeTransfer(MYT.asset(), address(MYT), leftover);
        emit WithdrawToVault(leftover);
        return leftover;
    }

    /// @notice Rescue arbitrary ERC20 tokens sent to this contract by mistake
    /// @param token The token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(!_isProtectedToken(token), "Protected token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Insufficient balance");
        IERC20(token).transfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(RiskClass newClass) public onlyOwner {
        params.riskClass = newClass;
        emit RiskClassUpdated(newClass);
    }

    /// @dev some protocols may pay yield in baby tokens
    /// so we need to manually collect them
    function setAdditionalIncentives(bool newValue) public onlyOwner {
        params.additionalIncentives = newValue;
        emit IncentivesUpdated(newValue);
    }

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(bool val) public onlyOwner {
        killSwitch = val;
        emit Emergency(val);
    }

    function setAllowanceHolder(address _new) public onlyOwner {
        require(_new != address(0));
        allowanceHolder = _new;
    }

    /// @notice Update the slippage tolerance for this strategy
    function setSlippageBPS(uint256 newSlippageBPS) public onlyOwner {
        require(newSlippageBPS < 9999, "Slippage too high");
        params.slippageBPS = newSlippageBPS;
        emit SlippageBPSUpdated(newSlippageBPS);
    }

    /* ========== GETTERS ========== */

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield() public view returns (uint256) {
        return params.estimatedYield;
    }

    function getCap() external view returns (uint256) {
        return params.cap;
    }

    function getGlobalCap() external view returns (uint256) {
        return params.globalCap;
    }

    /// @notice Returns the primary token the strategy holds as its deployed position.
    /// @dev Child strategies should override this when they hold receipt, share, or staking tokens.
    function positionToken() public view virtual returns (address) {
        return address(0);
    }

    /// @notice Returns the token produced before a DEX swap in unwrap-and-swap deallocation flows.
    /// @dev Child strategies should override this when they redeem or unwrap into an intermediate token.
    function intermediateToken() public view virtual returns (address) {
        return address(0);
    }

    function ids() public view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = adapterId;
        return ids_;
    }

    /// @notice Returns the vault's current allocation tracking for this adapter
    function allocation() public view returns (uint256) {
        return MYT.allocation(adapterId);
    }

    function getIdData() external view returns (bytes memory) {
        return abi.encode("this", address(this));
    }

    /// @notice External function per IAdapter spec - returns total underlying value
    function realAssets() external view virtual returns (uint256) {
        return _totalValue();
    }

    /* ========== VIRTUAL FUNCTIONS ========== */

    /// @dev Check if a token is protected and cannot be rescued.
    /// Override this function in child contracts to add protocol-specific protected tokens
    /// (e.g., receipt tokens, aTokens, mTokens, staking tokens).
    /// @param token The token to check
    /// @return True if the token is protected
    function _isProtectedToken(address token) internal view virtual returns (bool) {
        return token == MYT.asset();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned should be equal to the amount parameter passed in
    /// @notice should attempt to log any loss due to rounding
    function _allocate(uint256 amount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned should be equal to the amount parameter passed in
    /// @notice should attempt to log any loss due to rounding
    function _allocate(uint256 amount, bytes memory callData) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned must be equal to the amount parameter passed in
    /// @notice due to how MorphoVaultV2 internally handles deallocations,
    /// strategies must have atleast >= amount available at the end of this function call
    /// if not, the strategy will revert
    /// @notice amount of asset must be approved to the vault (i.e. msg.sender)
    function _deallocate(uint256 amount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned must be equal to the amount parameter passed in
    /// @notice due to how MorphoVaultV2 internally handles deallocations,
    /// strategies must have atleast >= amount available at the end of this function call
    /// if not, the strategy will revert
    /// @notice amount of asset must be approved to the vault (i.e. msg.sender)
    function _deallocate(uint256 amount, bytes memory callData) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the strategy to the vault using a swap with specified in calldata 
    /// @param amount the WETH amount expected to be returned to the vault
    /// @param callData the 0x swap calldata
    /// @param minIntermediateOutAmount the minimum amount of intermediate token expected to be received from the unwrap
    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle preview withdraw with slippage
    /// @notice this function should be used to estimate the correct amount that can be fully withdrawn, accounting for losses
    /// due to slippage, protocol fees, and rounding differences
    function _previewAdjustedWithdraw(uint256 amount) internal view virtual returns (uint256) {}

    /// @dev override this function to handle strategies with withdrawal queue NFT
    function _claimWithdrawalQueue(uint256 positionId) internal virtual returns (uint256) {}

    /// @dev override this function to claim all available rewards from the respective
    /// protocol of this strategy in the form of a specific token
    /// this ERC20 reward must then be converted to the MYT's asset
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual returns (uint256) {}

    /// @dev override this function to return the total underlying value of the strategy
    /// @dev must return the total underling value of the strategy's position (i.e. in vault asset e.g. USDC or WETH)
    function _totalValue() internal view virtual returns (uint256) {}

    function _idleAssets() internal view virtual returns (uint256) {}
}
