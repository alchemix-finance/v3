// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICollateralPriceOracle} from "./interfaces/ICollateralPriceOracle.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Prices a collateral underlying token against a debt reference token using Chainlink feeds.
/// @dev With no quote feed, the base feed must report quote tokens per base token. Otherwise both
///      feeds must use the same denomination, such as base/USD and quote/USD. Token decimals do
///      not affect the returned whole-token price. Feed decimals are fixed at construction.
contract ChainlinkCollateralPriceOracle is ICollateralPriceOracle {
    error InvalidConfiguration();
    error UnsupportedDecimals();
    error InvalidFeedAnswer(address feed);
    error StaleFeedAnswer(address feed);
    error InvalidPrice();
    error InvalidSequencerData();
    error SequencerDown();
    error SequencerGracePeriodNotOver();

    address public immutable override baseToken;
    address public immutable override quoteToken;
    AggregatorV3Interface public immutable baseFeed;
    AggregatorV3Interface public immutable quoteFeed;
    uint256 public immutable baseMaxAge;
    uint256 public immutable quoteMaxAge;
    AggregatorV3Interface public immutable sequencerFeed;
    uint256 public immutable gracePeriod;

    uint256 private immutable _scale;
    bool private immutable _divideByScale;

    /// @param _baseToken The collateral underlying token being priced.
    /// @param _quoteToken The token in which debt is denominated.
    /// @param _baseFeed A direct base/quote feed, or base/common-denomination feed when a quote feed is supplied.
    /// @param _quoteFeed Optional quote/common-denomination feed; zero selects direct pricing.
    /// @param _baseMaxAge Maximum accepted age of the base feed's answer, in seconds.
    /// @param _quoteMaxAge Maximum accepted age of the quote feed's answer; must be zero in direct mode.
    /// @param _sequencerFeed Optional L2 sequencer uptime feed; zero disables the sequencer check.
    /// @param _gracePeriod Recovery time after a sequencer outage; must be zero when no sequencer feed is supplied.
    constructor(
        address _baseToken,
        address _quoteToken,
        address _baseFeed,
        address _quoteFeed,
        uint256 _baseMaxAge,
        uint256 _quoteMaxAge,
        address _sequencerFeed,
        uint256 _gracePeriod
    ) {
        if (_baseToken == address(0) || _quoteToken == address(0) || _baseFeed == address(0) || _baseMaxAge == 0) {
            revert InvalidConfiguration();
        }
        if ((_quoteFeed == address(0)) != (_quoteMaxAge == 0) || (_sequencerFeed == address(0)) != (_gracePeriod == 0)) {
            revert InvalidConfiguration();
        }

        baseToken = _baseToken;
        quoteToken = _quoteToken;
        baseFeed = AggregatorV3Interface(_baseFeed);
        quoteFeed = AggregatorV3Interface(_quoteFeed);
        baseMaxAge = _baseMaxAge;
        quoteMaxAge = _quoteMaxAge;
        sequencerFeed = AggregatorV3Interface(_sequencerFeed);
        gracePeriod = _gracePeriod;

        int256 exponent = 18 - int256(uint256(AggregatorV3Interface(_baseFeed).decimals()));
        if (_quoteFeed != address(0)) exponent += int256(uint256(AggregatorV3Interface(_quoteFeed).decimals()));
        if (exponent < -77 || exponent > 77) revert UnsupportedDecimals();
        _divideByScale = exponent < 0;
        _scale = 10 ** uint256(exponent < 0 ? -exponent : exponent);
    }

    /// @inheritdoc ICollateralPriceOracle
    function price() external view override returns (uint256 value) {
        if (address(sequencerFeed) != address(0)) _validateSequencer();

        uint256 baseAnswer = _readAnswer(baseFeed, baseMaxAge);
        uint256 quoteAnswer = address(quoteFeed) == address(0) ? 1 : _readAnswer(quoteFeed, quoteMaxAge);

        // Sequential division has the same downward rounding as division by the product,
        // while avoiding an overflowing denominator when the decimal exponent is negative.
        value = _divideByScale ? (baseAnswer / quoteAnswer) / _scale : FixedPointMath.mulDiv(baseAnswer, _scale, quoteAnswer);
        if (value == 0) revert InvalidPrice();
    }

    function _readAnswer(AggregatorV3Interface feed, uint256 maxAge) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert InvalidFeedAnswer(address(feed));
        if (block.timestamp - updatedAt > maxAge) revert StaleFeedAnswer(address(feed));
        return uint256(answer);
    }

    function _validateSequencer() internal view {
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || startedAt > block.timestamp) revert InvalidSequencerData();
        if (block.timestamp - startedAt <= gracePeriod) revert SequencerGracePeriodNotOver();
    }
}
