// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkCollateralPriceOracle} from "../ChainlinkCollateralPriceOracle.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

contract MockCollateralAggregator {
    error FeedUnavailable();

    uint8 public immutable decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    bool public unavailable;

    constructor(uint8 decimals_) {
        decimals = decimals_;
        setAnswer(1, block.timestamp);
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
        startedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        answeredInRound = answeredInRound_;
    }

    function setUnavailable() external {
        unavailable = true;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (unavailable) revert FeedUnavailable();
        return (1, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract ChainlinkCollateralPriceOracleTest is Test {
    address internal constant BASE_TOKEN = address(0xBACE);
    address internal constant QUOTE_TOKEN = address(0xC0DE);
    uint256 internal constant BASE_MAX_AGE = 1 hours;
    uint256 internal constant QUOTE_MAX_AGE = 1 days;
    uint256 internal constant GRACE_PERIOD = 30 minutes;

    MockCollateralAggregator internal base;
    MockCollateralAggregator internal quote;
    MockCollateralAggregator internal sequencer;
    ChainlinkCollateralPriceOracle internal directOracle;
    ChainlinkCollateralPriceOracle internal compositeOracle;

    function setUp() public {
        vm.warp(10 days);
        base = new MockCollateralAggregator(8);
        quote = new MockCollateralAggregator(8);
        sequencer = new MockCollateralAggregator(0);
        base.setAnswer(3000e8, block.timestamp);
        quote.setAnswer(1e8, block.timestamp);
        sequencer.setAnswer(0, block.timestamp - GRACE_PERIOD - 1);
        directOracle = _deploy(base, address(0), BASE_MAX_AGE, 0, address(0), 0);
        compositeOracle = _deploy(base, address(quote), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0);
    }

    function test_constructorStoresConfiguration() public {
        ChainlinkCollateralPriceOracle oracle = _deploy(base, address(quote), BASE_MAX_AGE, QUOTE_MAX_AGE, address(sequencer), GRACE_PERIOD);
        assertEq(oracle.baseToken(), BASE_TOKEN);
        assertEq(oracle.quoteToken(), QUOTE_TOKEN);
        assertEq(address(oracle.baseFeed()), address(base));
        assertEq(address(oracle.quoteFeed()), address(quote));
        assertEq(oracle.baseMaxAge(), BASE_MAX_AGE);
        assertEq(oracle.quoteMaxAge(), QUOTE_MAX_AGE);
        assertEq(address(oracle.sequencerFeed()), address(sequencer));
        assertEq(oracle.gracePeriod(), GRACE_PERIOD);
    }

    function test_directPairReturnsWholeTokenWad() public view {
        // Neither token implements decimals(): feed prices already refer to whole tokens.
        assertEq(directOracle.price(), 3000e18);
    }

    function test_compositionIncludesUsdcDepeg() public {
        quote.setAnswer(0.8e8, block.timestamp);
        assertEq(compositeOracle.price(), 3750e18);
    }

    function test_stablecoinAndEquityComposition() public {
        base.setAnswer(0.99e8, block.timestamp);
        quote.setAnswer(0.9e8, block.timestamp);
        assertEq(compositeOracle.price(), 1.1e18);

        base.setAnswer(152.5e8, block.timestamp);
        quote.setAnswer(1.25e8, block.timestamp);
        assertEq(compositeOracle.price(), 122e18);
    }

    function test_differingFeedDecimals() public {
        MockCollateralAggregator base18 = new MockCollateralAggregator(18);
        base18.setAnswer(2000e18, block.timestamp);
        quote.setAnswer(0.8e8, block.timestamp);
        assertEq(_deploy(base18, address(quote), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), 2500e18);

        MockCollateralAggregator quote18 = new MockCollateralAggregator(18);
        quote18.setAnswer(1.2e18, block.timestamp);
        assertEq(_deploy(base, address(quote18), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), 2500e18);
    }

    function test_negativeDecimalExponentRoundsDown() public {
        MockCollateralAggregator base20 = new MockCollateralAggregator(20);
        MockCollateralAggregator quote0 = new MockCollateralAggregator(0);
        base20.setAnswer(1099, block.timestamp);
        quote0.setAnswer(3, block.timestamp);
        assertEq(_deploy(base20, address(quote0), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), 3);
        assertEq(_deploy(base20, address(0), BASE_MAX_AGE, 0, address(0), 0).price(), 10);
    }

    function test_compositionRoundsDown() public {
        base.setAnswer(1, block.timestamp);
        quote.setAnswer(3, block.timestamp);
        assertEq(compositeOracle.price(), 333_333_333_333_333_333);
    }

    function test_compositionUsesFullPrecisionIntermediate() public {
        MockCollateralAggregator base0 = new MockCollateralAggregator(0);
        MockCollateralAggregator quote18 = new MockCollateralAggregator(18);
        base0.setAnswer(int256(uint256(1) << 200), block.timestamp);
        quote18.setAnswer(int256(uint256(1) << 180), block.timestamp);
        assertEq(_deploy(base0, address(quote18), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), (uint256(1) << 20) * 1e36);
    }

    function test_largestSupportedPositiveExponent() public {
        MockCollateralAggregator base0 = new MockCollateralAggregator(0);
        MockCollateralAggregator quote59 = new MockCollateralAggregator(59);
        base0.setAnswer(1, block.timestamp);
        quote59.setAnswer(1e60, block.timestamp);
        assertEq(_deploy(base0, address(quote59), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), 1e17);
    }

    function test_largeEqualDecimalsDoNotOverflowScale() public {
        MockCollateralAggregator base255 = new MockCollateralAggregator(255);
        MockCollateralAggregator quote255 = new MockCollateralAggregator(255);
        base255.setAnswer(5, block.timestamp);
        quote255.setAnswer(2, block.timestamp);
        assertEq(_deploy(base255, address(quote255), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0).price(), 2.5e18);
    }

    function test_rejectsUnsupportedDecimalExponents() public {
        MockCollateralAggregator base0 = new MockCollateralAggregator(0);
        MockCollateralAggregator quote60 = new MockCollateralAggregator(60);
        vm.expectRevert(ChainlinkCollateralPriceOracle.UnsupportedDecimals.selector);
        _deploy(base0, address(quote60), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0);

        MockCollateralAggregator base96 = new MockCollateralAggregator(96);
        vm.expectRevert(ChainlinkCollateralPriceOracle.UnsupportedDecimals.selector);
        _deploy(base96, address(0), BASE_MAX_AGE, 0, address(0), 0);
    }

    function test_rejectsZeroNormalizedPrice() public {
        base.setAnswer(1, block.timestamp);
        quote.setAnswer(1e30, block.timestamp);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidPrice.selector);
        compositeOracle.price();
    }

    function test_rejectsUnrepresentablePrice() public {
        MockCollateralAggregator base0 = new MockCollateralAggregator(0);
        base0.setAnswer(type(int256).max, block.timestamp);
        ChainlinkCollateralPriceOracle oracle = _deploy(base0, address(0), BASE_MAX_AGE, 0, address(0), 0);
        vm.expectRevert(FixedPointMath.MulDivOverflow.selector);
        oracle.price();
    }

    function test_rejectsInvalidConfiguration() public {
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        new ChainlinkCollateralPriceOracle(address(0), QUOTE_TOKEN, address(base), address(0), BASE_MAX_AGE, 0, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        new ChainlinkCollateralPriceOracle(BASE_TOKEN, address(0), address(base), address(0), BASE_MAX_AGE, 0, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        new ChainlinkCollateralPriceOracle(BASE_TOKEN, QUOTE_TOKEN, address(0), address(0), BASE_MAX_AGE, 0, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        _deploy(base, address(0), 0, 0, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        _deploy(base, address(quote), BASE_MAX_AGE, 0, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        _deploy(base, address(0), BASE_MAX_AGE, 1, address(0), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        _deploy(base, address(0), BASE_MAX_AGE, 0, address(sequencer), 0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidConfiguration.selector);
        _deploy(base, address(0), BASE_MAX_AGE, 0, address(0), 1);
    }

    function test_rejectsNonpositiveAnswersInEitherFeed() public {
        base.setAnswer(0, block.timestamp);
        _expectInvalidFeed(directOracle, base);
        base.setAnswer(-1, block.timestamp);
        _expectInvalidFeed(directOracle, base);
        base.setAnswer(1e8, block.timestamp);
        quote.setAnswer(0, block.timestamp);
        _expectInvalidFeed(compositeOracle, quote);
        quote.setAnswer(type(int256).min, block.timestamp);
        _expectInvalidFeed(compositeOracle, quote);
    }

    function test_rejectsMissingOrFutureTimestampsInEitherFeed() public {
        base.setAnswer(1e8, 0);
        _expectInvalidFeed(directOracle, base);
        base.setAnswer(1e8, block.timestamp + 1);
        _expectInvalidFeed(directOracle, base);
        base.setAnswer(1e8, block.timestamp);
        quote.setAnswer(1e8, 0);
        _expectInvalidFeed(compositeOracle, quote);
        quote.setAnswer(1e8, block.timestamp + 1);
        _expectInvalidFeed(compositeOracle, quote);
    }

    function test_freshnessBoundaryForEachFeed() public {
        base.setAnswer(3000e8, block.timestamp - BASE_MAX_AGE);
        quote.setAnswer(1e8, block.timestamp - QUOTE_MAX_AGE);
        assertEq(compositeOracle.price(), 3000e18);
        base.setAnswer(3000e8, block.timestamp - BASE_MAX_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCollateralPriceOracle.StaleFeedAnswer.selector, address(base)));
        compositeOracle.price();
        base.setAnswer(3000e8, block.timestamp);
        quote.setAnswer(1e8, block.timestamp - QUOTE_MAX_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCollateralPriceOracle.StaleFeedAnswer.selector, address(quote)));
        compositeOracle.price();
    }

    function test_propagatesFeedFailures() public {
        quote.setUnavailable();
        vm.expectRevert(MockCollateralAggregator.FeedUnavailable.selector);
        compositeOracle.price();
        base.setUnavailable();
        vm.expectRevert(MockCollateralAggregator.FeedUnavailable.selector);
        directOracle.price();
    }

    function test_deprecatedAnsweredInRoundDoesNotAffectFreshness() public {
        base.setAnsweredInRound(0);
        quote.setAnsweredInRound(0);
        assertEq(compositeOracle.price(), 3000e18);
    }

    function test_sequencerDownAndUnknownStatusRevert() public {
        ChainlinkCollateralPriceOracle oracle = _withSequencer();
        sequencer.setAnswer(1, block.timestamp - GRACE_PERIOD - 1);
        vm.expectRevert(ChainlinkCollateralPriceOracle.SequencerDown.selector);
        oracle.price();
        sequencer.setAnswer(-1, block.timestamp - GRACE_PERIOD - 1);
        vm.expectRevert(ChainlinkCollateralPriceOracle.SequencerDown.selector);
        oracle.price();
    }

    function test_sequencerRecoveryBoundary() public {
        ChainlinkCollateralPriceOracle oracle = _withSequencer();
        sequencer.setAnswer(0, block.timestamp);
        vm.expectRevert(ChainlinkCollateralPriceOracle.SequencerGracePeriodNotOver.selector);
        oracle.price();
        sequencer.setStartedAt(block.timestamp - GRACE_PERIOD);
        vm.expectRevert(ChainlinkCollateralPriceOracle.SequencerGracePeriodNotOver.selector);
        oracle.price();
        sequencer.setStartedAt(block.timestamp - GRACE_PERIOD - 1);
        assertEq(oracle.price(), 3000e18);
    }

    function test_sequencerRejectsMissingAndFutureStatusTimes() public {
        ChainlinkCollateralPriceOracle oracle = _withSequencer();
        sequencer.setStartedAt(0);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidSequencerData.selector);
        oracle.price();
        sequencer.setStartedAt(block.timestamp + 1);
        vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidSequencerData.selector);
        oracle.price();
    }

    function test_oldSequencerStatusDoesNotExpire() public {
        ChainlinkCollateralPriceOracle oracle = _withSequencer();
        sequencer.setAnswer(0, 1);
        assertEq(oracle.price(), 3000e18);
    }

    function test_sequencerFailurePropagates() public {
        ChainlinkCollateralPriceOracle oracle = _withSequencer();
        sequencer.setUnavailable();
        vm.expectRevert(MockCollateralAggregator.FeedUnavailable.selector);
        oracle.price();
    }

    function test_disabledSequencerDoesNotReadStatus() public {
        sequencer.setUnavailable();
        assertEq(directOracle.price(), 3000e18);
    }

    function testFuzz_directDecimalNormalization(uint128 raw, uint8 decimalsSeed) public {
        uint8 decimals_ = uint8(bound(decimalsSeed, 0, 18));
        raw = uint128(bound(raw, 1, type(uint128).max));
        MockCollateralAggregator feed = new MockCollateralAggregator(decimals_);
        feed.setAnswer(int256(uint256(raw)), block.timestamp);
        ChainlinkCollateralPriceOracle oracle = _deploy(feed, address(0), BASE_MAX_AGE, 0, address(0), 0);
        assertEq(oracle.price(), uint256(raw) * (10 ** (18 - decimals_)));
    }

    function testFuzz_compositionAgainstNormalizedWholeTokenPrices(uint96 baseRaw, uint96 quoteRaw, uint8 baseDecimalsSeed, uint8 quoteDecimalsSeed) public {
        uint8 baseDecimals_ = uint8(bound(baseDecimalsSeed, 0, 18));
        uint8 quoteDecimals_ = uint8(bound(quoteDecimalsSeed, 0, 18));
        baseRaw = uint96(bound(baseRaw, 1, type(uint96).max));
        quoteRaw = uint96(bound(quoteRaw, 1, type(uint96).max));
        MockCollateralAggregator base_ = new MockCollateralAggregator(baseDecimals_);
        MockCollateralAggregator quote_ = new MockCollateralAggregator(quoteDecimals_);
        base_.setAnswer(int256(uint256(baseRaw)), block.timestamp);
        quote_.setAnswer(int256(uint256(quoteRaw)), block.timestamp);
        ChainlinkCollateralPriceOracle oracle = _deploy(base_, address(quote_), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0);
        uint256 baseWad = uint256(baseRaw) * (10 ** (18 - baseDecimals_));
        uint256 quoteWad = uint256(quoteRaw) * (10 ** (18 - quoteDecimals_));
        uint256 expected = baseWad * 1e18 / quoteWad;
        if (expected == 0) {
            vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidPrice.selector);
            oracle.price();
        } else {
            assertEq(oracle.price(), expected);
        }
    }

    function testFuzz_negativeExponentAgainstCombinedDenominator(uint128 baseRaw, uint96 quoteRaw, uint8 exponentSeed) public {
        uint8 exponent = uint8(bound(exponentSeed, 1, 18));
        baseRaw = uint128(bound(baseRaw, 1, type(uint128).max));
        quoteRaw = uint96(bound(quoteRaw, 1, type(uint96).max));
        MockCollateralAggregator base_ = new MockCollateralAggregator(18 + exponent);
        MockCollateralAggregator quote_ = new MockCollateralAggregator(0);
        base_.setAnswer(int256(uint256(baseRaw)), block.timestamp);
        quote_.setAnswer(int256(uint256(quoteRaw)), block.timestamp);
        ChainlinkCollateralPriceOracle oracle = _deploy(base_, address(quote_), BASE_MAX_AGE, QUOTE_MAX_AGE, address(0), 0);
        uint256 expected = uint256(baseRaw) / (uint256(quoteRaw) * (10 ** exponent));
        if (expected == 0) {
            vm.expectRevert(ChainlinkCollateralPriceOracle.InvalidPrice.selector);
            oracle.price();
        } else {
            assertEq(oracle.price(), expected);
        }
    }

    function _expectInvalidFeed(ChainlinkCollateralPriceOracle oracle, MockCollateralAggregator feed) internal {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCollateralPriceOracle.InvalidFeedAnswer.selector, address(feed)));
        oracle.price();
    }

    function _withSequencer() internal returns (ChainlinkCollateralPriceOracle) {
        return _deploy(base, address(quote), BASE_MAX_AGE, QUOTE_MAX_AGE, address(sequencer), GRACE_PERIOD);
    }

    function _deploy(MockCollateralAggregator base_, address quote_, uint256 baseAge, uint256 quoteAge, address sequencer_, uint256 grace)
        internal
        returns (ChainlinkCollateralPriceOracle)
    {
        return new ChainlinkCollateralPriceOracle(BASE_TOKEN, QUOTE_TOKEN, address(base_), quote_, baseAge, quoteAge, sequencer_, grace);
    }
}
