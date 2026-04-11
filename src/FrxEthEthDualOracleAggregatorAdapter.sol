// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFrxEthEthDualOracle {
    function getPrices() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh);
}

/// @notice Adapts the Frax dual-oracle frxETH/ETH source to a Chainlink-style reader.
/// @dev The Frax dual oracle does not expose a publication timestamp. This adapter therefore
///      returns the current block timestamp for `startedAt` and `updatedAt`, which satisfies
///      the AggregatorV3Interface shape but does not provide an underlying freshness signal.
contract FrxEthEthDualOracleAggregatorAdapter {
    IFrxEthEthDualOracle public immutable dualOracle;

    constructor(address _dualOracle) {
        require(_dualOracle != address(0), "Zero dual oracle address");
        dualOracle = IFrxEthEthDualOracle(_dualOracle);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (bool isBadData, uint256 priceLow, uint256 priceHigh) = dualOracle.getPrices();
        require(!isBadData, "Bad dual oracle data");

        uint256 averagePrice = (priceLow + priceHigh) / 2;
        require(averagePrice > 0, "Invalid dual oracle price");

        // The dual oracle exposes no round ids or publication time, so these fields are synthesized.
        return (uint80(block.number), int256(averagePrice), block.timestamp, block.timestamp, uint80(block.number));
    }
}
