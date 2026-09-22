// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,CoreToken,CoreAlchemistHarness,ERC1967Proxy,AlchemistV3,AlchemistInitializationParams} from "../common/CoreFixture.sol";
abstract contract NormalizationFixture is CoreFixture {
    function _normalization(uint8 difference, uint256 input) internal {
        CoreToken underlying=new CoreToken(0); CoreToken synthetic=new CoreToken(difference);
        AlchemistInitializationParams memory p=_params(address(underlying),address(synthetic),address(vault),address(trans));
        CoreAlchemistHarness implementation=new CoreAlchemistHarness();
        CoreAlchemistHarness instance=CoreAlchemistHarness(address(new ERC1967Proxy(address(implementation),abi.encodeCall(AlchemistV3.initialize,(p)))));
        uint256 factor=10**uint256(difference);
        // Construct the exact non-overflow domain; no assumption discards boundary inputs.
        uint256 units=input%(type(uint256).max/factor+ (factor==1?0:1));
        if(factor==1) units=input;
        uint256 normalized=abi.decode(_ok(address(instance),abi.encodeCall(AlchemistV3.normalizeUnderlyingTokensToDebt,(units))),(uint256));
        assert(normalized==units*factor && instance.normalizeDebtTokensToUnderlying(normalized)==units);
        uint256 floorUnits=instance.normalizeDebtTokensToUnderlying(input);
        assert(floorUnits*factor<=input && input-floorUnits*factor<factor);
        assert(instance.underlyingConversionFactor()==factor);
        if(factor>1) _fails(address(this),address(instance),abi.encodeCall(AlchemistV3.normalizeUnderlyingTokensToDebt,(type(uint256).max/factor+1)));
    }
    function deployDecimals(uint8 ud,uint8 dd,uint256 protocolFee,uint256 target) external returns (address) {
        CoreToken underlying=new CoreToken(ud); CoreToken synthetic=new CoreToken(dd);
        AlchemistInitializationParams memory p=_params(address(underlying),address(synthetic),address(vault),address(trans));
        p.protocolFee=protocolFee; p.liquidationTargetCollateralization=target;
        return address(new ERC1967Proxy(address(new CoreAlchemistHarness()),abi.encodeCall(AlchemistV3.initialize,(p))));
    }
}
contract AlchemistNormalization0Symbolic is NormalizationFixture {
    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 0.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_0(uint128 input) public { _normalization(0,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_0(uint256 input) public { _normalization(0,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 1.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_1(uint128 input) public { _normalization(1,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_1(uint256 input) public { _normalization(1,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 2.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_2(uint128 input) public { _normalization(2,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_2(uint256 input) public { _normalization(2,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 3.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_3(uint128 input) public { _normalization(3,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_3(uint256 input) public { _normalization(3,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 4.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_4(uint128 input) public { _normalization(4,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_4(uint256 input) public { _normalization(4,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 5.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_5(uint128 input) public { _normalization(5,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_5(uint256 input) public { _normalization(5,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 6.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_6(uint128 input) public { _normalization(6,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_6(uint256 input) public { _normalization(6,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 7.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_7(uint128 input) public { _normalization(7,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_7(uint256 input) public { _normalization(7,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 8.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_8(uint128 input) public { _normalization(8,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_8(uint256 input) public { _normalization(8,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 9.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_9(uint128 input) public { _normalization(9,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_9(uint256 input) public { _normalization(9,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 10.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_10(uint128 input) public { _normalization(10,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_10(uint256 input) public { _normalization(10,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 11.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_11(uint128 input) public { _normalization(11,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_11(uint256 input) public { _normalization(11,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 12.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_12(uint128 input) public { _normalization(12,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_12(uint256 input) public { _normalization(12,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 13.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_13(uint128 input) public { _normalization(13,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_13(uint256 input) public { _normalization(13,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 14.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_14(uint128 input) public { _normalization(14,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_14(uint256 input) public { _normalization(14,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 15.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_15(uint128 input) public { _normalization(15,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_15(uint256 input) public { _normalization(15,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 16.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_16(uint128 input) public { _normalization(16,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_16(uint256 input) public { _normalization(16,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 17.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_17(uint128 input) public { _normalization(17,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_17(uint256 input) public { _normalization(17,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 18.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_18(uint128 input) public { _normalization(18,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_18(uint256 input) public { _normalization(18,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 19.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_19(uint128 input) public { _normalization(19,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_19(uint256 input) public { _normalization(19,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 20.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_20(uint128 input) public { _normalization(20,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_20(uint256 input) public { _normalization(20,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 21.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_21(uint128 input) public { _normalization(21,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_21(uint256 input) public { _normalization(21,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 22.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_22(uint128 input) public { _normalization(22,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_22(uint256 input) public { _normalization(22,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 23.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_23(uint128 input) public { _normalization(23,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_23(uint256 input) public { _normalization(23,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 24.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_24(uint128 input) public { _normalization(24,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_24(uint256 input) public { _normalization(24,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 25.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_25(uint128 input) public { _normalization(25,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_25(uint256 input) public { _normalization(25,input); }

}
contract AlchemistNormalization1Symbolic is NormalizationFixture {
    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 26.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_26(uint128 input) public { _normalization(26,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_26(uint256 input) public { _normalization(26,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 27.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_27(uint128 input) public { _normalization(27,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_27(uint256 input) public { _normalization(27,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 28.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_28(uint128 input) public { _normalization(28,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_28(uint256 input) public { _normalization(28,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 29.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_29(uint128 input) public { _normalization(29,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_29(uint256 input) public { _normalization(29,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 30.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_30(uint128 input) public { _normalization(30,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_30(uint256 input) public { _normalization(30,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 31.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_31(uint128 input) public { _normalization(31,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_31(uint256 input) public { _normalization(31,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 32.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_32(uint128 input) public { _normalization(32,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_32(uint256 input) public { _normalization(32,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 33.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_33(uint128 input) public { _normalization(33,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_33(uint256 input) public { _normalization(33,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 34.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_34(uint128 input) public { _normalization(34,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_34(uint256 input) public { _normalization(34,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 35.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_35(uint128 input) public { _normalization(35,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_35(uint256 input) public { _normalization(35,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 36.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_36(uint128 input) public { _normalization(36,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_36(uint256 input) public { _normalization(36,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 37.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_37(uint128 input) public { _normalization(37,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_37(uint256 input) public { _normalization(37,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 38.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_38(uint128 input) public { _normalization(38,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_38(uint256 input) public { _normalization(38,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 39.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_39(uint128 input) public { _normalization(39,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_39(uint256 input) public { _normalization(39,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 40.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_40(uint128 input) public { _normalization(40,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_40(uint256 input) public { _normalization(40,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 41.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_41(uint128 input) public { _normalization(41,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_41(uint256 input) public { _normalization(41,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 42.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_42(uint128 input) public { _normalization(42,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_42(uint256 input) public { _normalization(42,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 43.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_43(uint128 input) public { _normalization(43,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_43(uint256 input) public { _normalization(43,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 44.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_44(uint128 input) public { _normalization(44,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_44(uint256 input) public { _normalization(44,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 45.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_45(uint128 input) public { _normalization(45,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_45(uint256 input) public { _normalization(45,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 46.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_46(uint128 input) public { _normalization(46,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_46(uint256 input) public { _normalization(46,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 47.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_47(uint128 input) public { _normalization(47,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_47(uint256 input) public { _normalization(47,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 48.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_48(uint128 input) public { _normalization(48,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_48(uint256 input) public { _normalization(48,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 49.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_49(uint128 input) public { _normalization(49,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_49(uint256 input) public { _normalization(49,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 50.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_50(uint128 input) public { _normalization(50,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_50(uint256 input) public { _normalization(50,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 51.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_51(uint128 input) public { _normalization(51,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_51(uint256 input) public { _normalization(51,input); }

}
contract AlchemistNormalization2Symbolic is NormalizationFixture {
    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 52.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_52(uint128 input) public { _normalization(52,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_52(uint256 input) public { _normalization(52,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 53.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_53(uint128 input) public { _normalization(53,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_53(uint256 input) public { _normalization(53,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 54.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_54(uint128 input) public { _normalization(54,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_54(uint256 input) public { _normalization(54,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 55.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_55(uint128 input) public { _normalization(55,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_55(uint256 input) public { _normalization(55,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 56.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_56(uint128 input) public { _normalization(56,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_56(uint256 input) public { _normalization(56,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 57.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_57(uint128 input) public { _normalization(57,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_57(uint256 input) public { _normalization(57,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 58.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_58(uint128 input) public { _normalization(58,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_58(uint256 input) public { _normalization(58,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 59.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_59(uint128 input) public { _normalization(59,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_59(uint256 input) public { _normalization(59,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 60.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_60(uint128 input) public { _normalization(60,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_60(uint256 input) public { _normalization(60,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 61.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_61(uint128 input) public { _normalization(61,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_61(uint256 input) public { _normalization(61,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 62.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_62(uint128 input) public { _normalization(62,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_62(uint256 input) public { _normalization(62,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 63.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_63(uint128 input) public { _normalization(63,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_63(uint256 input) public { _normalization(63,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 64.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_64(uint128 input) public { _normalization(64,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_64(uint256 input) public { _normalization(64,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 65.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_65(uint128 input) public { _normalization(65,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_65(uint256 input) public { _normalization(65,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 66.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_66(uint128 input) public { _normalization(66,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_66(uint256 input) public { _normalization(66,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 67.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_67(uint128 input) public { _normalization(67,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_67(uint256 input) public { _normalization(67,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 68.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_68(uint128 input) public { _normalization(68,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_68(uint256 input) public { _normalization(68,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 69.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_69(uint128 input) public { _normalization(69,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_69(uint256 input) public { _normalization(69,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 70.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_70(uint128 input) public { _normalization(70,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_70(uint256 input) public { _normalization(70,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 71.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_71(uint128 input) public { _normalization(71,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_71(uint256 input) public { _normalization(71,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 72.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_72(uint128 input) public { _normalization(72,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_72(uint256 input) public { _normalization(72,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 73.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_73(uint128 input) public { _normalization(73,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_73(uint256 input) public { _normalization(73,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 74.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_74(uint128 input) public { _normalization(74,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_74(uint256 input) public { _normalization(74,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 75.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_75(uint128 input) public { _normalization(75,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_75(uint256 input) public { _normalization(75,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 76.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_76(uint128 input) public { _normalization(76,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_76(uint256 input) public { _normalization(76,input); }

    /// @custom:property AV3-NORMALIZE AV3-INIT
    /// @notice AV3-INIT, AV3-NORMALIZE: check decimal difference 77.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_decimalDifference_77(uint128 input) public { _normalization(77,input); }
    /// @notice AV3-INIT, AV3-NORMALIZE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_decimalDifference_77(uint256 input) public { _normalization(77,input); }

}
contract AlchemistConversionSymbolic is NormalizationFixture {
    /// @custom:property AV3-INIT AV3-NORMALIZE
    /// @notice AV3-INIT, AV3-NORMALIZE: check invalid initialization domains.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    function test_check_invalidInitializationDomains() public {
        _fails(address(this),address(this),abi.encodeCall(this.deployDecimals,(19,18,0,15e17)));
        _fails(address(this),address(this),abi.encodeCall(this.deployDecimals,(0,78,0,15e17)));
        _fails(address(this),address(this),abi.encodeCall(this.deployDecimals,(18,18,10001,15e17)));
        _fails(address(this),address(this),abi.encodeCall(this.deployDecimals,(18,18,0,14e17)));
    }
    /// @custom:property AV3-CONVERT
    /// @notice AV3-CONVERT: check fractional price round trips.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_fractionalPriceRoundTrips(uint64 raw,uint32 priceRaw) public {
        uint256 shares=uint256(raw); uint256 price=uint256(priceRaw)+1;
        vault.setPrice(price);
        uint256 assets=shares*price/1e18;
        assert(alc.convertYieldTokensToUnderlying(shares)==assets && alc.convertYieldTokensToDebt(shares)==assets);
        uint256 back=abi.decode(_ok(address(alc),abi.encodeCall(AlchemistV3.convertDebtTokensToYield,(assets))),(uint256));
        assert(back==assets*1e18/price && back<=shares);
        assert(alc.convertUnderlyingTokensToYield(assets)==back);
    }
    /// @notice AV3-CONVERT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_fractionalPriceRoundTrips(uint64 raw,uint32 priceRaw) public { test_check_fractionalPriceRoundTrips(raw,priceRaw); }

    /// @custom:property AV3-INIT
    /// @notice Each initial fee rejects values above BPS and accepts valid values.
    /// @dev Technique: T3 finite field selection with real deployment. Classification: ENUMERATE.
    /// @dev Domain: uint16 includes all valid fees and invalid values through 65535.
    function test_check_initialFeeDomains(uint16 fee,uint8 selection) public {
        AlchemistInitializationParams memory p=_params(address(asset),address(debt),address(vault),address(trans));
        uint8 k=selection%3;
        if(k==0) p.protocolFee=fee; else if(k==1) p.liquidatorFee=fee; else p.repaymentFee=fee;
        CoreAlchemistHarness implementation=new CoreAlchemistHarness();
        try new ERC1967Proxy(address(implementation),abi.encodeCall(AlchemistV3.initialize,(p))) returns(ERC1967Proxy proxy) {
            assert(fee<=10000);
            AlchemistV3 instance=AlchemistV3(address(proxy));
            assert(instance.protocolFee()==p.protocolFee && instance.liquidatorFee()==p.liquidatorFee && instance.repaymentFee()==p.repaymentFee);
        } catch { assert(fee>10000); }
    }
}
