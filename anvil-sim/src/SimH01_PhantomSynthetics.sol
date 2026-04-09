// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal reproduction of H-01: Phantom totalSyntheticsIssued
/// Isolates the core accounting bug: _subDebt decrements totalDebt
/// but NOT totalSyntheticsIssued. Also tests whether Transmuter MYT
/// backing saves the protocol (the Codex/Gemini dispute).
contract SimPhantomSynthetics {
    uint256 public totalDebt;
    uint256 public totalSyntheticsIssued;
    uint256 public transmuterMYTBalance;
    uint256 public alchemistMYTBalance;

    uint256 constant FIXED_POINT_SCALAR = 1e18;

    event Minted(address user, uint256 amount);
    event DebtSubtracted(uint256 amount);
    event SelfLiquidated(address user, uint256 debtCleared, uint256 mytToTransmuter);
    event BadDebtCheck(bool isBadDebt, uint256 issued, uint256 backing);

    function deposit(uint256 mytAmount) external {
        alchemistMYTBalance += mytAmount;
    }

    function mint(uint256 amount) external {
        totalDebt += amount;
        totalSyntheticsIssued += amount;
        emit Minted(msg.sender, amount);
    }

    /// @notice Simulates _subDebt — only decrements totalDebt, NOT totalSyntheticsIssued
    function _subDebt(uint256 amount) internal {
        totalDebt -= amount;
        emit DebtSubtracted(amount);
    }

    /// @notice Simulates selfLiquidate path: clears debt, moves MYT to transmuter
    function selfLiquidate(uint256 debtAmount) external {
        require(debtAmount <= totalDebt, "Exceeds debt");
        _subDebt(debtAmount);

        uint256 mytToMove = debtAmount;
        if (mytToMove > alchemistMYTBalance) mytToMove = alchemistMYTBalance;
        alchemistMYTBalance -= mytToMove;
        transmuterMYTBalance += mytToMove;

        emit SelfLiquidated(msg.sender, debtAmount, mytToMove);
    }

    /// @notice Simulates burn() — the ONLY path that decrements both
    function burn(uint256 amount) external {
        totalDebt -= amount;
        totalSyntheticsIssued -= amount;
    }

    /// @notice Plamen's claim: totalSyntheticsIssued > 0 when totalDebt = 0 → bad debt
    function isProtocolInBadDebt_plamenVersion() external view returns (bool) {
        if (totalSyntheticsIssued == 0) return false;
        return totalSyntheticsIssued > alchemistMYTBalance;
    }

    /// @notice Codex/Gemini rebuttal: includes Transmuter MYT in backing
    function isProtocolInBadDebt_actualCode() external view returns (bool) {
        if (totalSyntheticsIssued == 0) return false;
        uint256 backing = alchemistMYTBalance + transmuterMYTBalance;
        return totalSyntheticsIssued > backing;
    }

    function getState() external view returns (
        uint256 _totalDebt,
        uint256 _totalSyntheticsIssued,
        uint256 _alchemistMYT,
        uint256 _transmuterMYT,
        bool _badDebtPlamen,
        bool _badDebtActual
    ) {
        _totalDebt = totalDebt;
        _totalSyntheticsIssued = totalSyntheticsIssued;
        _alchemistMYT = alchemistMYTBalance;
        _transmuterMYT = transmuterMYTBalance;
        _badDebtPlamen = this.isProtocolInBadDebt_plamenVersion();
        _badDebtActual = this.isProtocolInBadDebt_actualCode();
    }
}
