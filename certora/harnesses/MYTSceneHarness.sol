// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {MockAsset, MockStrategy} from "./MYTMocks.sol";

import {
    WAD,
    MAX_PERFORMANCE_FEE,
    MAX_MANAGEMENT_FEE,
    MAX_MAX_RATE,
    MAX_FORCE_DEALLOCATE_PENALTY
} from "../../lib/vault-v2/src/libraries/ConstantsLib.sol";

/// @notice Scene harness for MYT (VaultV2) conservation verification.
///
/// Inherits from the REAL VaultV2 — every invariant is checked against
/// the actual vault logic.  Two MockStrategy adapters model strategies
/// that can randomly earn yield or incur losses (controlled by the
/// prover via __injectYield).
///
/// Setup:
///   - Harness is owner, curator, sentinel, and allocator of the vault
///   - Timelocks are zero (submit + accept in the same call)
///   - Two strategies registered as adapters with absolute + relative caps
///   - Performance fee, maxRate, and fee recipients configured
///   - Initial seed deposit for inflation-attack protection
contract MYTSceneHarness is VaultV2 {
    MockAsset public immutable token;
    MockStrategy public immutable strategy0;
    MockStrategy public immutable strategy1;

    address public constant FEE_RECIPIENT = address(0xFEED);
    address public constant ZERO_ADDRESS = address(0);

    constructor() VaultV2(address(this), address(new MockAsset())) {
        token = MockAsset(asset);

        MockStrategy s0 = new MockStrategy(address(this), asset);
        MockStrategy s1 = new MockStrategy(address(this), asset);
        strategy0 = s0;
        strategy1 = s1;

        // --- roles (owner calls) ---
        this.setCurator(address(this));
        this.setIsSentinel(address(this), true);

        // --- allocator (timelocked: submit + accept) ---
        _submitAccept(abi.encodeWithSelector(IVaultV2.setIsAllocator.selector, address(this)));

        // --- add adapters (timelocked) ---
        _submitAccept(abi.encodeWithSelector(IVaultV2.addAdapter.selector, address(s0)));
        _submitAccept(abi.encodeWithSelector(IVaultV2.addAdapter.selector, address(s1)));

        // --- caps (timelocked increases) ---
        bytes memory idData0 = abi.encode("this", address(s0));
        bytes memory idData1 = abi.encode("this", address(s1));
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, idData0, type(uint128).max));
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, idData1, type(uint128).max));
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, idData0, WAD));
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, idData1, WAD));

        // --- fee configuration (timelocked) ---
        _submitAccept(abi.encodeWithSelector(IVaultV2.setPerformanceFeeRecipient.selector, FEE_RECIPIENT));
        _submitAccept(abi.encodeWithSelector(IVaultV2.setPerformanceFee.selector, uint256(0.15e18)));
        _submitAccept(abi.encodeWithSelector(IVaultV2.setManagementFeeRecipient.selector, FEE_RECIPIENT));

        // maxRate (allocator — not timelocked)
        this.setMaxRate(MAX_MAX_RATE);

        // --- seed deposit (inflation-attack protection) ---
        token.__mint(address(this), 1e18);
        token.approve(address(this), 1e18);
        this.deposit(1e18, address(this));
    }

    // -----------------------------------------------------------------------
    // Internal: submit + accept a timelocked operation in one step
    // (timelocks are zero so executableAt == block.timestamp)
    // -----------------------------------------------------------------------
    function _submitAccept(bytes memory data) internal {
        this.submit(data);
        (bool ok,) = address(this).call(data);
        require(ok, "timelocked call failed");
    }

    // -----------------------------------------------------------------------
    // Prover-facing wrappers
    // -----------------------------------------------------------------------

    /// @notice Deposit assets into the vault (harness funds itself).
    function __deposit(uint256 assets) external {
        token.__mint(address(this), assets);
        token.approve(address(this), assets);
        this.deposit(assets, address(this));
    }

    /// @notice Withdraw assets from the vault.
    function __withdraw(uint256 assets) external {
        this.withdraw(assets, address(this), address(this));
    }

    /// @notice Allocate assets to a strategy.
    function __allocate(uint256 which, uint256 assets) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        this.allocate(adapter, "", assets);
    }

    /// @notice Deallocate assets from a strategy.
    function __deallocate(uint256 which, uint256 assets) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        this.deallocate(adapter, "", assets);
    }

    /// @notice Inject yield (newValue > current) or loss (newValue < current)
    ///         into a strategy's reported value.
    function __injectYield(uint256 which, uint256 newValue) external {
        if (which == 0) {
            strategy0.__injectYield(newValue);
        } else {
            strategy1.__injectYield(newValue);
        }
    }

    // -----------------------------------------------------------------------
    // Timelocked parameter setters (prover-controlled)
    // -----------------------------------------------------------------------

    function __setPerformanceFee(uint256 newFee) external {
        _submitAccept(abi.encodeWithSelector(IVaultV2.setPerformanceFee.selector, newFee));
    }

    function __setPerformanceFeeRecipient(address recipient) external {
        _submitAccept(abi.encodeWithSelector(IVaultV2.setPerformanceFeeRecipient.selector, recipient));
    }

    function __setManagementFee(uint256 newFee) external {
        _submitAccept(abi.encodeWithSelector(IVaultV2.setManagementFee.selector, newFee));
    }

    function __setManagementFeeRecipient(address recipient) external {
        _submitAccept(abi.encodeWithSelector(IVaultV2.setManagementFeeRecipient.selector, recipient));
    }

    function __setMaxRate(uint256 newRate) external {
        this.setMaxRate(newRate);
    }

    function __setForceDeallocatePenalty(address adapter, uint256 penalty) external {
        _submitAccept(abi.encodeWithSelector(IVaultV2.setForceDeallocatePenalty.selector, adapter, penalty));
    }

    function __increaseAbsoluteCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, idData, newCap));
    }

    function __decreaseAbsoluteCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        this.decreaseAbsoluteCap(idData, newCap);
    }

    function __increaseRelativeCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        _submitAccept(abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, idData, newCap));
    }

    function __decreaseRelativeCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        this.decreaseRelativeCap(idData, newCap);
    }

    // -----------------------------------------------------------------------
    // CVL helper readers
    // -----------------------------------------------------------------------

    function __adapterId(uint256 which) external view returns (bytes32) {
        return which == 0 ? strategy0.adapterId() : strategy1.adapterId();
    }

    function __idleBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function __strategyRealAssets(uint256 which) external view returns (uint256) {
        return which == 0 ? strategy0.reportedValue() : strategy1.reportedValue();
    }

    function __strategyBalance(uint256 which) external view returns (uint256) {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        return IERC20(asset).balanceOf(adapter);
    }

    function __totalRealAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + strategy0.reportedValue() + strategy1.reportedValue();
    }

    function __MAX_PERFORMANCE_FEE() external pure returns (uint256) {
        return MAX_PERFORMANCE_FEE;
    }

    function __MAX_MANAGEMENT_FEE() external pure returns (uint256) {
        return MAX_MANAGEMENT_FEE;
    }

    function __MAX_MAX_RATE() external pure returns (uint256) {
        return MAX_MAX_RATE;
    }

    function __MAX_FORCE_DEALLOCATE_PENALTY() external pure returns (uint256) {
        return MAX_FORCE_DEALLOCATE_PENALTY;
    }
}
