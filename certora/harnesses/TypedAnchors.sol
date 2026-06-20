// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAlchemistV3} from "../../src/interfaces/IAlchemistV3.sol";

/// @notice Typed-anchor stub for the MYT / VaultV2 collateral token.
///
/// Alchemix interacts with the vault via three surfaces:
///   1. ERC20  — transfer, transferFrom, balanceOf (through TokenUtils low-level calls)
///   2. ERC4626 — convertToAssets, convertToShares (direct interface calls)
///   3. Metadata — decimals (during initialize, which we bypass)
///
/// The anchor implements all three with concrete, simple arithmetic so the
/// prover reasons about real accounting.  A performance-fee field exists to
/// verify the ≤ 5 % cap (feeBounds / cfg rules); the fee is on yield only
/// and does NOT affect position collateralization.
contract VaultAnchor {
    // -----------------------------------------------------------------------
    // ERC20 metadata
    // -----------------------------------------------------------------------
    string public constant name = "Vault Anchor MYT";
    string public constant symbol = "vaMYT";
    uint8 public constant decimals = 18;

    // -----------------------------------------------------------------------
    // ERC20 state
    // -----------------------------------------------------------------------
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // -----------------------------------------------------------------------
    // Vault state
    // -----------------------------------------------------------------------
    /// @dev Total underlying assets backing all shares.  Havoc'd by the scene
    ///      harness to model yield generation / loss.
    uint256 public totalAssets_;

    // -----------------------------------------------------------------------
    // Fee state (VaultV2 performance-fee model)
    // -----------------------------------------------------------------------
    /// @dev Performance fee in basis points.  Capped to 500 (5 %).
    uint96 public performanceFee;
    /// @dev Recipient of minted fee shares.  A fresh EOA outside the actor set.
    address public performanceFeeRecipient;
    /// @dev Management fee — always zero in this verification scope.
    uint96 public managementFee;

    // -----------------------------------------------------------------------
    // ERC20
    // -----------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Allowance check deliberately omitted — over-approximation that
    ///      strengthens conservation proofs (more transfers can succeed).
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // -----------------------------------------------------------------------
    // ERC4626 exchange-rate
    // -----------------------------------------------------------------------

    function totalAssets() external view returns (uint256) {
        return totalAssets_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return shares * totalAssets_ / totalSupply;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        if (totalAssets_ == 0) return assets;
        return assets * totalSupply / totalAssets_;
    }

    // -----------------------------------------------------------------------
    // Performance fee (environment action — not called by Alchemix)
    // -----------------------------------------------------------------------

    /// @notice VaultV2 performance-fee field (verification target: ≤ 5 % cap).
    ///
    /// The fee is on yield performance only and does NOT affect collateral.
    /// Not exercised as an environment action in the current scene.
    function takePerformanceFee(uint256 yieldAssets) external {
        if (yieldAssets == 0 || performanceFee == 0) return;
        uint256 feeAssets = yieldAssets * uint256(performanceFee) / 10_000;
        if (feeAssets == 0 || totalAssets_ == 0 || totalSupply == 0) return;
        uint256 feeShares = feeAssets * totalSupply / totalAssets_;
        if (feeShares == 0) return;
        totalSupply += feeShares;
        balanceOf[performanceFeeRecipient] += feeShares;
    }

    // -----------------------------------------------------------------------
    // Scene-harness helpers
    // -----------------------------------------------------------------------

    function __mintShares(address to, uint256 shares) external {
        totalSupply += shares;
        balanceOf[to] += shares;
    }

    function __burnShares(address from, uint256 shares) external {
        totalSupply -= shares;
        balanceOf[from] -= shares;
    }

    function __setTotalAssets(uint256 assets) external {
        totalAssets_ = assets;
    }

    function __setPerformanceFee(uint96 fee) external {
        require(fee <= 500, "performance fee > 5%");
        performanceFee = fee;
    }

    function __setPerformanceFeeRecipient(address recipient) external {
        performanceFeeRecipient = recipient;
    }
}

/// @notice Typed-anchor stub for the synthetic debt token.
///
/// Alchemix calls `mint`, `burn`, and `burnFrom` via TokenUtils low-level
/// calls, plus standard ERC20 `transfer` / `transferFrom` / `balanceOf`.
contract DebtTokenAnchor {
    string public constant name = "Debt Token Anchor";
    string public constant symbol = "daALCH";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address recipient, uint256 amount) external {
        totalSupply += amount;
        balanceOf[recipient] += amount;
    }

    function burn(uint256 amount) external returns (bool) {
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        return true;
    }

    function burnFrom(address owner, uint256 amount) external returns (bool) {
        totalSupply -= amount;
        balanceOf[owner] -= amount;
        return true;
    }
}

/// @notice Typed-anchor stub for the Transmuter.
///
/// Alchemix reads `totalLocked()` and `queryGraph()` from the Transmuter.
/// The Transmuter calls back into Alchemix via `reduceSyntheticsIssued`
/// (onlyTransmuter).  The anchor stores havoc'd values that CVL axioms
/// constrain; the scene harness exposes setters so the prover can vary them.
contract TransmuterAnchor {
    /// @dev Address of the Alchemix implementation — set during scene wiring.
    address public alchemist;

    /// @dev Ghost-coupled: havoc'd by CVL, read by Alchemix's earmark logic.
    uint256 public totalLocked_;
    uint256 public queryGraphResult_;

    // -----------------------------------------------------------------------
    // ITransmuter view methods (read storage — CVL controls values via setters)
    // -----------------------------------------------------------------------

    function totalLocked() external view returns (uint256) {
        return totalLocked_;
    }

    function queryGraph(uint256, uint256) external view returns (uint256) {
        return queryGraphResult_;
    }

    // -----------------------------------------------------------------------
    // Callback into Alchemix (onlyTransmuter path)
    // -----------------------------------------------------------------------

    /// @notice Models the Transmuter calling `reduceSyntheticsIssued` on
    ///         Alchemix during claim/poke.  Decreases `totalLocked_` by the
    ///         same amount so the T3 coupling
    ///         (`totalSyntheticsIssued >= totalLocked`) is maintained
    ///         atomically at the Solidity level.
    function callReduceSyntheticsIssued(uint256 amount) external {
        totalLocked_ -= amount;
        IAlchemistV3(alchemist).reduceSyntheticsIssued(amount);
    }

    // -----------------------------------------------------------------------
    // Scene-harness helpers (coupled — enforce T3 at Solidity level)
    // -----------------------------------------------------------------------

    function __setAlchemist(address alchemist_) external {
        alchemist = alchemist_;
    }

    /// @dev Enforces T3: `totalLocked <= totalSyntheticsIssued`.
    function __stakeLocked(uint256 amount) external {
        require(
            totalLocked_ + amount <= IAlchemistV3(alchemist).totalSyntheticsIssued(),
            "stake exceeds synthetics"
        );
        totalLocked_ += amount;
    }

    function __setTotalLocked(uint256 value) external {
        require(
            value <= IAlchemistV3(alchemist).totalSyntheticsIssued(),
            "totalLocked > syntheticsIssued"
        );
        totalLocked_ = value;
    }

    function __setQueryGraphResult(uint256 value) external {
        queryGraphResult_ = value;
    }
}
