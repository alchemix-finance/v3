// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPointMath as F} from "../../../src/libraries/FixedPointMath.sol";
import {SafeCast as C} from "../../../src/libraries/SafeCast.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

contract DinosatMathHarness {
    function down(uint256 x,uint256 y,uint256 d) external pure returns(uint256){return F.mulDiv(x,y,d);}
    function up(uint256 x,uint256 y,uint256 d) external pure returns(uint256){return F.mulDivUp(x,y,d);}
    function qm(uint256 x,uint256 y) external pure returns(uint256){return F.mulQ128(x,y);}
    function qd(uint256 x,uint256 y) external pure returns(uint256){return F.divQ128(x,y);}
    function enc(uint256 x) external pure returns(uint256){return F.encode(x).n;}
    function raw(uint256 x) external pure returns(uint256){return F.encodeRaw(x);}
    function rational(uint256 x,uint256 y) external pure returns(uint256){return F.rational(x,y).n;}
    function add(uint256 x,uint256 y,bool scalar) external pure returns(uint256){return scalar?F.add(F.Number(x),y).n:F.add(F.Number(x),F.Number(y)).n;}
    function sub(uint256 x,uint256 y,bool scalar) external pure returns(uint256){return scalar?F.sub(F.Number(x),y).n:F.sub(F.Number(x),F.Number(y)).n;}
    function mul(uint256 x,uint256 y,bool scalar) external pure returns(uint256){return scalar?F.mul(F.Number(x),y).n:F.mul(F.Number(x),F.Number(y)).n;}
    function div(uint256 x,uint256 y) external pure returns(uint256){return F.div(F.Number(x),y).n;}
    function trunc(uint256 x) external pure returns(uint256){return F.truncate(F.Number(x));}
    function cmp(uint256 x,uint256 y) external pure returns(int256){return F.cmp(F.Number(x),F.Number(y));}
    function eq(uint256 x,uint256 y) external pure returns(bool){return F.equals(F.Number(x),F.Number(y));}
    function maximum() external pure returns(uint256){return F.max().n;}
    function toInt(uint256 x) external pure returns(int256){return C.toInt256(x);}
    function toUint(int256 x) external pure returns(uint256){return C.toUint256(x);}
    function narrow(uint256 x) external pure returns(uint128){return C.uint256ToUint128(x);}
    function widen(uint128 x) external pure returns(uint256){return C.uint128ToUint256(x);}
}

contract DinosatMathSymbolicTest is Test {
    DinosatMathHarness h;
    uint256 constant P=1e18;
    uint256 constant Q=1<<128;
    function setUp() public {h=new DinosatMathHarness();}
    function _error(bytes memory data,bytes4 expected) internal pure {assert(data.length>=4);assert(bytes4(data)==expected);}
    function _panic(bytes memory data,uint256 expected) internal pure {assert(data.length==36);assert(bytes4(data)==bytes4(0x4e487b71));uint256 n;assembly{n:=mload(add(data,36))}assert(n==expected);}

    /// @notice FM-ENCODE: encoding round-trip and rational floor bounds.
    /// @dev Technique: T6 actual library calls. Classification: DIRECT. uint64 products fit uint256.
    function test_check_encoding(uint64 x,uint32 divisor) public view {
        uint256 d=uint256(divisor)+1;
        uint256 encoded=h.enc(x);
        assert(encoded==h.raw(x)); assert(h.trunc(encoded)==x);
        uint256 q=h.rational(x,d);
        assert(q*d<=encoded);assert(encoded-q*d<d);
    }
    /// @notice FM-ENCODE: invalid encoding and division fail at the specified boundary.
    /// @dev Technique: actual rejection witnesses. Classification: DIRECT.
    function test_check_encodingRejects() public {
        (bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.enc,(type(uint256).max/P+1)));
        assert(!ok);_panic(data,0x11);
        (ok,data)=address(h).call(abi.encodeCall(h.rational,(1,0)));assert(!ok);_panic(data,0x12);
    }
    /// @notice FM-ADDSUB: addition and subtraction are inverses for both overloads.
    /// @dev Technique: inverse property. Classification: DIRECT. uint64 operands bound encoded sums below 2^256.
    function test_check_addSub(uint64 x,uint64 y) public view {
        uint256 sum=h.add(x,y,false);assert(h.sub(sum,y,false)==x);
        uint256 scaledSum=h.add(x,y,true);assert(h.sub(scaledSum,y,true)==x);
        assert(sum>=x);assert(scaledSum>=x);
    }
    /// @notice FM-ADDSUB: overflow and underflow reject without wrap.
    /// @dev Technique: boundary calls. Classification: DIRECT.
    function test_check_addSubRejects() public {
        (bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.add,(type(uint256).max,1,false)));assert(!ok);_panic(data,0x11);
        (ok,data)=address(h).call(abi.encodeCall(h.sub,(0,1,false)));assert(!ok);_panic(data,0x11);
        (ok,data)=address(h).call(abi.encodeCall(h.sub,(P-1,1,true)));assert(!ok);_panic(data,0x11);
    }
    /// @notice FM-MULDIV-SIMPLE: floor remainder and scalar inverse bounds.
    /// @dev Technique: T6 identities. Classification: DIRECT. uint64 products fit uint128.
    function test_check_simpleMath(uint64 x,uint64 y,uint32 divisor) public view {
        uint256 d=uint256(divisor)+1;uint256 prod=uint256(x)*y;
        uint256 m=h.mul(x,y,false);assert(m*P<=prod);assert(prod-m*P<P);
        uint256 s=h.mul(x,y,true);assert(s==prod);
        uint256 q=h.div(x,d);assert(q*d<=x);assert(uint256(x)-q*d<d);
        uint256 t=h.trunc(x);assert(t*P<=x);assert(uint256(x)-t*P<P);
    }
    /// @notice FM-MULDIV-SIMPLE: invalid scalar arithmetic rejects.
    /// @dev Technique: boundary calls. Classification: DIRECT.
    function test_check_simpleMathRejects() public {
        (bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.mul,(type(uint256).max,2,true)));assert(!ok);_panic(data,0x11);
        (ok,data)=address(h).call(abi.encodeCall(h.div,(1,0)));assert(!ok);_panic(data,0x12);
    }
    /// @notice FM-COMPARE: trichotomy and equality agree.
    /// @dev Technique: actual library comparisons. Classification: DIRECT.
    function test_check_comparison(uint256 x,uint256 y) public view {
        int256 c=h.cmp(x,y);assert((c==-1)==(x<y));assert((c==0)==(x==y));assert((c==1)==(x>y));
        assert(h.eq(x,y)==(c==0));assert(h.maximum()==type(uint256).max);
    }
    /// @notice FM-MULDIV-BOUNDED: actual short-product implementation satisfies exact rounding bounds.
    /// @dev Technique: T4 short-product partition and T6. Classification: DECOMPOSE. uint32 product fits uint64.
    function test_check_mulDivBounded(uint32 x,uint32 y,uint32 rawD) public view {
        uint256 d=uint256(rawD)+1;uint256 n=uint256(x)*y;
        uint256 down=h.down(x,y,d);uint256 up=h.up(x,y,d);
        assert(down*d<=n);assert(n-down*d<d);assert(up*d>=n);assert(up*d-n<d);
        assert(up==down || up==down+1);assert((up==down)==(n%d==0));
    }
    /// @notice FM-MULDIV-BOUNDED,FM-MULDIV-WIDE: division and quotient overflow reject with exact errors.
    /// @dev Technique: boundary partition. Classification: DECOMPOSE.
    function test_check_mulDivErrors() public {
        (bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.down,(1,1,0)));assert(!ok);_error(data,F.MulDivZeroDenominator.selector);
        (ok,data)=address(h).call(abi.encodeCall(h.up,(0,0,0)));assert(!ok);_error(data,F.MulDivZeroDenominator.selector);
        (ok,data)=address(h).call(abi.encodeCall(h.down,(type(uint256).max,2,1)));assert(!ok);_error(data,F.MulDivOverflow.selector);
        uint256 a=type(uint256).max-1;
        (ok,data)=address(h).call(abi.encodeCall(h.up,(a,a,a-1)));assert(!ok);_error(data,F.MulDivOverflow.selector);
    }
    /// @notice FM-QMUL: exact fixed-point identity and half rounding.
    /// @dev Technique: concrete ratio partitions, actual assembly. Classification: DECOMPOSE.
    function test_check_qMul(uint128 x) public view {
        assert(h.qm(x,Q)==x);assert(h.qm(x,0)==0);assert(h.qm(0,x)==0);
        uint256 half=h.qm(x,Q/2);assert(half*2>=x);assert(half*2-uint256(x)<2);
    }
    /// @notice FM-QDIV: zero, fast, and Q128 numerator boundary.
    /// @dev Technique: T4 concrete denominators. Classification: DECOMPOSE.
    function test_check_qDiv(uint128 x) public view {
        assert(h.qd(x,Q)==x);assert(h.qd(Q,Q)==Q);assert(h.qd(0,0)==0);
    }
    /// @notice FM-QDIV: nonzero numerator with zero denominator rejects.
    /// @dev Technique: explicit failure witness. Classification: DECOMPOSE.
    function test_check_qDivZeroRejects() public {
        (bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.qd,(1,0)));assert(!ok);_panic(data,0x12);
    }
    /// @notice FM-MULDIV-WIDE,FM-QMUL,FM-QDIV: full-product differential oracle.
    /// @dev Technique: T17 against OpenZeppelin Math. Classification: FUZZ. Construct d>high product so the quotient fits.
    function test_fuzz_fullWidth(uint256 x,uint256 y,uint256 rawD) public view {
        uint256 hi;assembly{let lo:=mul(x,y) let mm:=mulmod(x,y,not(0)) hi:=sub(sub(mm,lo),lt(mm,lo))}
        uint256 d=hi+1+rawD%(type(uint256).max-hi);
        uint256 floor=OZMath.mulDiv(x,y,d);assert(h.down(x,y,d)==floor);
        if(floor<type(uint256).max || mulmod(x,y,d)==0){assert(h.up(x,y,d)==OZMath.mulDiv(x,y,d,OZMath.Rounding.Ceil));}
        else { (bool ok,bytes memory data)=address(h).staticcall(abi.encodeCall(h.up,(x,y,d)));assert(!ok);_error(data,F.MulDivOverflow.selector); }
        uint256 ratio=y% (Q+1);assert(h.qm(x,ratio)==OZMath.mulDiv(x,ratio,Q,OZMath.Rounding.Ceil));
        uint256 numerator=x%(Q+1);uint256 denominator=numerator+1+(y%(type(uint256).max-numerator));
        assert(h.qd(numerator,denominator)==OZMath.mulDiv(numerator,Q,denominator));
    }
}

contract DinosatSafeCastSymbolicTest is Test {
    DinosatMathHarness h;
    function setUp() public {h=new DinosatMathHarness();}
    function _illegal(bytes memory data) internal pure{assert(data.length==4);assert(bytes4(data)==bytes4(keccak256("IllegalArgument()")));}
    /// @notice SC-toInt256,SC-toUint256: accepted signed conversion round-trips.
    /// @dev Technique: actual harness. Classification: DIRECT. uint128 is a declared subset of positive int256.
    function test_check_signedRoundtrip(uint128 value) public view {assert(h.toUint(h.toInt(value))==value);}
    /// @notice SC-toInt256: every value with the high bit set rejects.
    /// @dev Technique: bit partition. Classification: DIRECT.
    function test_check_signedReject(uint256 raw) public {
        uint256 value=raw | (uint256(1)<<255);(bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.toInt,(value)));assert(!ok);_illegal(data);
    }
    /// @notice SC-toUint256: negative values reject.
    /// @dev Technique: bit partition. Classification: DIRECT.
    function test_check_negativeReject(uint256 raw) public {
        int256 value=int256(raw | (uint256(1)<<255));(bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.toUint,(value)));assert(!ok);_illegal(data);
    }
    /// @notice SC-uint256ToUint128,SC-uint128ToUint256: narrow and wide casts round-trip exactly.
    /// @dev Technique: inverse. Classification: DIRECT.
    function test_check_narrowRoundtrip(uint128 value) public view {assert(h.narrow(h.widen(value))==value);assert(h.widen(value)==value);}
    /// @notice SC-uint256ToUint128: values above the destination range reject.
    /// @dev Technique: bit partition. Classification: DIRECT.
    function test_check_narrowReject(uint256 raw) public {
        uint256 value=raw | (uint256(1)<<128);(bool ok,bytes memory data)=address(h).call(abi.encodeCall(h.narrow,(value)));assert(!ok);_illegal(data);
    }
    /// @notice SC-toInt256,SC-toUint256: cover the full accepted signed range under fuzz.
    /// @dev Technique: T17 constructive domain. Classification: FUZZ.
    function test_fuzz_signedRoundtrip(uint256 raw) public view {uint256 value=raw>>1;assert(h.toUint(h.toInt(value))==value);}
}

contract DinosatMathCounterexampleTest is Test {
    /// @notice FM-QDIV: the Q128 numerator boundary must retain the high bit of the scaled remainder.
    /// @dev Technique: exact real-bytecode boundary. Classification: DECOMPOSE. Expected counterexample for denominator above Q128; caller reachability needs separate review.
    function test_check_qDivBoundary() public {
        DinosatMathHarness h=new DinosatMathHarness();uint256 q=uint256(1)<<128;assert(h.qd(q,2*q)==q/2);
    }
}
