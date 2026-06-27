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
/// IMPORTANT: The constructor uses DIRECT STORAGE WRITES instead of
/// external function calls.  This avoids accrueInterest() invocations
/// (which loop over adapters and are havoc'd by --optimistic_loop) that
/// make the prover unable to verify the induction base case.
///
/// The prover-facing setters (__setPerformanceFee, etc.) still use the
/// real submit+call path so the induction step tests actual logic.
///
/// Setup:
///   - Harness is owner, curator, sentinel, and allocator of the vault
///   - Two strategies registered as adapters with absolute + relative caps
///   - Performance fee, maxRate, and fee recipients configured
///   - Initial seed deposit for inflation-attack protection
contract MYTSceneHarness is VaultV2 {
    MockAsset public immutable token;
    MockStrategy public immutable strategy0;
    MockStrategy public immutable strategy1;

    bytes32 public id0;
    bytes32 public id1;

    address public constant FEE_RECIPIENT = address(0xFEED);
    address public constant ZERO_ADDRESS = address(0);

    constructor() VaultV2(address(this), address(new MockAsset())) {
        token = MockAsset(asset);

        MockStrategy s0 = new MockStrategy(address(this), asset);
        MockStrategy s1 = new MockStrategy(address(this), asset);
        strategy0 = s0;
        strategy1 = s1;

        // --- Direct storage setup (no external calls, no accrueInterest) ---
        // This ensures the Certora prover can verify the induction base case.

        // Roles
        curator = address(this);
        isSentinel[address(this)] = true;
        isAllocator[address(this)] = true;

        // Adapters
        isAdapter[address(s0)] = true;
        isAdapter[address(s1)] = true;
        adapters.push(address(s0));
        adapters.push(address(s1));

        // Caps — same keccak256 input as MockStrategy.adapterId
        bytes32 local_id0 = keccak256(abi.encode("this", address(s0)));
        bytes32 local_id1 = keccak256(abi.encode("this", address(s1)));
        id0 = local_id0;
        id1 = local_id1;
        caps[local_id0].absoluteCap = type(uint128).max;
        caps[local_id1].absoluteCap = type(uint128).max;
        caps[local_id0].relativeCap = uint128(WAD);
        caps[local_id1].relativeCap = uint128(WAD);

        // Fees & rate
        performanceFeeRecipient = FEE_RECIPIENT;
        managementFeeRecipient = FEE_RECIPIENT;
        performanceFee = uint96(uint256(0.15e18));
        maxRate = uint64(MAX_MAX_RATE);

        // Seed deposit (direct — equivalent to deposit without accrueInterest)
        token.__mint(address(this), 1e18);
        _totalAssets = uint128(1e18);
        totalSupply = 1e18;
        balanceOf[address(this)] = 1e18;
        lastUpdate = uint64(block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Prover-facing wrappers (only those used by spec rules)
    // -----------------------------------------------------------------------

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

    /// @notice Force-deallocate from a strategy.  Callable by anyone; the
    ///         penalty is taken from the harness's own shares (onBehalf = self).
    function __forceDeallocate(uint256 which, uint256 assets) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        this.forceDeallocate(adapter, "", assets, address(this));
    }

    // -----------------------------------------------------------------------
    // Timelocked parameter setters (used by CAPM rules)
    // -----------------------------------------------------------------------

    function __increaseAbsoluteCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        bytes memory d = abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, idData, newCap);
        this.submit(d);
        this.increaseAbsoluteCap(idData, newCap);
    }

    function __decreaseAbsoluteCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        this.decreaseAbsoluteCap(idData, newCap);
    }

    function __increaseRelativeCap(uint256 which, uint256 newCap) external {
        address adapter = which == 0 ? address(strategy0) : address(strategy1);
        bytes memory idData = abi.encode("this", adapter);
        bytes memory d = abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, idData, newCap);
        this.submit(d);
        this.increaseRelativeCap(idData, newCap);
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
        return which == 0 ? id0 : id1;
    }

    function __strategyAdapterId(uint256 which) external view returns (bytes32) {
        return which == 0 ? strategy0.adapterId() : strategy1.adapterId();
    }

    function __idleBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function __assetBalanceOf(address who) external view returns (uint256) {
        return IERC20(asset).balanceOf(who);
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

    function __vaultAddress() external view returns (address) {
        return address(this);
    }
}
