// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reproduction of H-05: Retroactive collateralizationLowerBound
/// Shows admin can change bounds instantly, making healthy positions liquidatable.
contract SimRetroactiveParams {
    uint256 public collateralizationLowerBound;
    uint256 public minimumCollateralization;
    address public admin;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId;

    constructor(uint256 _lowerBound, uint256 _minCollat) {
        admin = msg.sender;
        collateralizationLowerBound = _lowerBound;
        minimumCollateralization = _minCollat;
    }

    function createPosition(uint256 collateral, uint256 debt) external returns (uint256) {
        uint256 id = nextId++;
        positions[id] = Position(collateral, debt);
        return id;
    }

    function isHealthy(uint256 id) external view returns (bool) {
        Position memory p = positions[id];
        if (p.debt == 0) return true;
        uint256 ratio = (p.collateral * 1e18) / p.debt;
        return ratio > collateralizationLowerBound;
    }

    function getRatio(uint256 id) external view returns (uint256) {
        Position memory p = positions[id];
        if (p.debt == 0) return type(uint256).max;
        return (p.collateral * 1e18) / p.debt;
    }

    // No timelock, no grace period — instant effect
    function setCollateralizationLowerBound(uint256 newBound) external {
        require(msg.sender == admin, "Not admin");
        collateralizationLowerBound = newBound;
    }

    function setMinimumCollateralization(uint256 newMin) external {
        require(msg.sender == admin, "Not admin");
        minimumCollateralization = newMin;
    }
}
