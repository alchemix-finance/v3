// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Exact reproduction of H-02: Dual Oracle Timestamp Fabrication
/// The FrxEthEthDualOracleAggregatorAdapter returns block.timestamp as updatedAt.
contract SimDualOracle {
    uint256 public priceLow;
    uint256 public priceHigh;

    constructor(uint256 _low, uint256 _high) {
        priceLow = _low;
        priceHigh = _high;
    }

    function getPrices() external view returns (bool, uint256, uint256) {
        return (false, priceLow, priceHigh);
    }
}

/// @notice Exact copy of FrxEthEthDualOracleAggregatorAdapter
contract SimFrxAdapter {
    SimDualOracle public immutable dualOracle;

    constructor(address _dualOracle) {
        dualOracle = SimDualOracle(_dualOracle);
    }

    function latestRoundData()
        external view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (bool isBadData, uint256 low, uint256 high) = dualOracle.getPrices();
        require(!isBadData, "Bad data");
        uint256 avg = (low + high) / 2;
        require(avg > 0, "Invalid price");
        // BUG: updatedAt = block.timestamp (fabricated)
        return (uint80(block.number), int256(avg), block.timestamp, block.timestamp, uint80(block.number));
    }

    function decimals() external pure returns (uint8) { return 18; }
}

/// @notice Consumer that checks staleness — mirrors OraclePricedSwapStrategy
contract SimOracleConsumer {
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;
    SimFrxAdapter public oracle;

    constructor(address _oracle) {
        oracle = SimFrxAdapter(_oracle);
    }

    function checkPrice() external view returns (int256 price, uint256 age, bool staleDetected) {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        age = block.timestamp - updatedAt;
        price = answer;
        staleDetected = age > MAX_ORACLE_STALENESS;
    }
}
