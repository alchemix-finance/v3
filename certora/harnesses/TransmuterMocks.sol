// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAlchemistV3} from "../../src/interfaces/IAlchemistV3.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice OZ-based ERC20 with public mint for Transmuter verification.
contract MockToken is ERC20Burnable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function __mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock AlchemistV3 for Transmuter verification.
///
/// Conversion functions are 1:1 (identity) to simplify the math.
/// `totalSyntheticsIssued` starts at 1e30 (large enough for practical
/// testing, small enough that `totalSyntheticsIssued * 1e18` does not
/// overflow in claimRedemption's bad-debt-ratio calculation).
///
/// Mutation functions (`redeem`, `reduceSyntheticsIssued`,
/// `setTransmuterTokenBalance`) are restricted to the Transmuter address
/// so the prover cannot call them directly and artificially break
/// conservation invariants.
contract MockAlchemist {
    address public immutable myt;
    address public immutable underlyingToken;
    address public immutable transmuter;

    uint256 private _totalSyntheticsIssued;
    uint256 private _totalLockedUnderlyingValue;

    constructor(address myt_, address underlyingToken_, address transmuter_) {
        myt = myt_;
        underlyingToken = underlyingToken_;
        transmuter = transmuter_;
        _totalSyntheticsIssued = 1e30;
        _totalLockedUnderlyingValue = 1e30;
    }

    modifier onlyTransmuter() {
        require(msg.sender == transmuter);
        _;
    }

    // --- view functions (1:1 conversions) ---
    function totalSyntheticsIssued() external view returns (uint256) { return _totalSyntheticsIssued; }
    function getTotalLockedUnderlyingValue() external view returns (uint256) { return _totalLockedUnderlyingValue; }
    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) { return amount; }
    function convertYieldTokensToDebt(uint256 amount) external pure returns (uint256) { return amount; }
    function convertDebtTokensToYield(uint256 amount) external pure returns (uint256) { return amount; }

    // --- prover-controlled havoc (for claim-path exploration) ---
    function __setTotalLockedUnderlyingValue(uint256 v) external { _totalLockedUnderlyingValue = v; }

    // --- mutation functions (only callable by the Transmuter) ---
    function redeem(uint256 amount) external onlyTransmuter returns (uint256) {
        MockToken(myt).__mint(msg.sender, amount);
        return amount;
    }

    function reduceSyntheticsIssued(uint256 amount) external onlyTransmuter {
        _totalSyntheticsIssued = amount >= _totalSyntheticsIssued ? 0 : _totalSyntheticsIssued - amount;
    }

    function setTransmuterTokenBalance(uint256) external onlyTransmuter { }
}
