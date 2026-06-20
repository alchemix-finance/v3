// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IAdapter} from "../../lib/vault-v2/src/interfaces/IAdapter.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";

/// @notice Minimal ERC20 underlying token for MYT verification.
///
/// Allowance checks are deliberately omitted on transferFrom — this
/// over-approximates (more transfers succeed) which strengthens
/// conservation proofs.  Public __mint / __burn let the scene harness
/// model yield generation and loss.
contract MockAsset {
    string public constant name = "Mock Asset";
    string public constant symbol = "MA";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function __mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function __burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @notice Mock strategy adapter implementing IAdapter for VaultV2.
///
/// Models a real strategy that can earn yield or incur losses.  The
/// prover controls yield/loss via __injectYield, which adjusts the
/// strategy's self-reported value AND mints/burns the underlying tokens
/// to keep the actual balance consistent.
///
/// Key design:
///   - allocate: vault transfers assets in, strategy adds to reportedValue,
///     returns change = reportedValue - oldAllocation (captures yield).
///   - deallocate: strategy returns assets, reduces reportedValue,
///     approves vault to pull tokens, returns change.
///   - realAssets: returns reportedValue (prover-controllable).
///   - __injectYield: havoc reportedValue, mint/burn tokens to match.
contract MockStrategy {
    address public immutable vault;
    address public immutable asset;
    bytes32 public immutable adapterId;

    uint256 public reportedValue;

    constructor(address vault_, address asset_) {
        vault = vault_;
        asset = asset_;
        adapterId = keccak256(abi.encode("this", address(this)));
    }

    function allocate(bytes memory, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        require(msg.sender == vault, "not vault");

        uint256 oldAlloc = IVaultV2(vault).allocation(adapterId);
        reportedValue += assets;
        change = int256(reportedValue) - int256(oldAlloc);

        ids = new bytes32[](1);
        ids[0] = adapterId;
    }

    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        require(msg.sender == vault, "not vault");

        uint256 oldAlloc = IVaultV2(vault).allocation(adapterId);
        reportedValue = reportedValue > assets ? reportedValue - assets : 0;

        IERC20(asset).approve(vault, assets);

        change = int256(reportedValue) - int256(oldAlloc);

        ids = new bytes32[](1);
        ids[0] = adapterId;
    }

    function realAssets() external view returns (uint256) {
        return reportedValue;
    }

    /// @notice Prover-controlled yield/loss injection.
    ///
    /// Sets reportedValue to newValue and adjusts the actual token
    /// balance (mint for yield, burn for loss) to keep them consistent.
    /// This ensures the strategy can always honor deallocate requests
    /// up to its reported value.
    function __injectYield(uint256 newValue) external {
        uint256 currentBalance = IERC20(asset).balanceOf(address(this));
        if (newValue > currentBalance) {
            MockAsset(asset).__mint(address(this), newValue - currentBalance);
        } else if (newValue < currentBalance) {
            MockAsset(asset).__burn(address(this), currentBalance - newValue);
        }
        reportedValue = newValue;
    }
}
