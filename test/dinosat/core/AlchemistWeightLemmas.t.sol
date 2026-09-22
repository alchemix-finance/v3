// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreAlchemistHarness} from "../common/CoreFixture.sol";
import {Test} from "forge-std/Test.sol";
contract AlchemistWeightLemmas is Test {
    CoreAlchemistHarness internal h; uint256 constant Q=uint256(1)<<128;
    function setUp() public { h=new CoreAlchemistHarness(); }
    /// @custom:property AV3-PACKED
    /// @notice AV3-PACKED: check same epoch.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_sameEpoch(uint64 before_,uint64 after_) public view {
        uint256 a=uint256(before_)+1; uint256 b=uint256(after_)%a;
        // Indices <=2^64, so b*Q fits in 193 bits. Compare original code to exact floor spec.
        uint256 oldPacked=(uint256(1)<<129)|a; uint256 newPacked=(uint256(1)<<129)|b;
        assert(h.earmarkRatio(oldPacked,newPacked)==b*Q/a);
        assert(h.redemptionRatio(oldPacked,newPacked)==b*Q/a);
        assert(h.redemptionRatio(oldPacked,newPacked)<=Q);
    }
    /// @notice AV3-PACKED: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_sameEpoch(uint64 before_,uint64 after_) public view { test_check_sameEpoch(before_,after_); }

    /// @custom:property AV3-PACKED
    /// @notice AV3-PACKED: check sentinel and epoch.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_sentinelAndEpoch(uint64 index) public view {
        uint256 oldPacked=(uint256(2)<<129)|(uint256(index)+1);
        uint256 next=(uint256(3)<<129)|Q;
        assert(h.earmarkRatio(oldPacked,next)==0 && h.redemptionRatio(oldPacked,next)==0);
        assert(h.earmarkRatio(0,next)==Q && h.redemptionRatio(0,next)==Q);
        assert(h.earmarkRatio(next,next)==Q && h.redemptionRatio(next,next)==Q);
        assert(h.earmarkRatio(uint256(2)<<129,oldPacked)==0);
    }
    /// @notice AV3-PACKED: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_sentinelAndEpoch(uint64 index) public view { test_check_sentinelAndEpoch(index); }

    /// @custom:property AV3-PACKED
    /// @notice AV3-PACKED: check partial update.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_partialUpdate(uint64 index,uint64 ratio) public view {
        uint256 a=uint256(index)+1; uint256 r=uint256(ratio)+1;
        (uint256 packed,uint256 applied,uint256 old,uint256 epoch,bool crossed)=h.packedUpdate((uint256(7)<<129)|a,r);
        uint256 product=a*r; uint256 newIndex=product/Q+(product%Q==0?0:1); // mulQ128 rounds UP. Product <=2^128.
        assert(old==a && epoch==7 && !crossed);
        assert(packed==((uint256(7)<<129)|newIndex)); assert(applied==newIndex*Q/a && applied<=Q);
    }
    /// @notice AV3-PACKED: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_partialUpdate(uint64 index,uint64 ratio) public view { test_check_partialUpdate(index,ratio); }

    /// @custom:property AV3-PACKED
    /// @notice AV3-PACKED: check full update.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_fullUpdate(uint64 epoch_) public view {
        uint256 epoch=epoch_;
        (uint256 packed,uint256 applied,uint256 old,uint256 next,bool crossed)=h.packedUpdate((epoch<<129)|Q,0);
        assert(packed==(((epoch+1)<<129)|Q)); assert(applied==0 && old==Q && next==epoch+1 && crossed);
    }
    /// @notice AV3-PACKED: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_fullUpdate(uint64 epoch_) public view { test_check_fullUpdate(epoch_); }

    /// @custom:property AV3-PACKED
    /// @dev Full-width index/epoch refinement. Epoch limit excluded to avoid bit-packing overflow.
    /// @notice AV3-PACKED: check packed refinement.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: FUZZ.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_fuzz_packedRefinement(uint128 index_,uint128 ratio_,uint128 epoch_) public view {
        uint256 a=uint256(index_)+1; uint256 r=uint256(ratio_)+1; uint256 e=uint256(epoch_)%(uint256(1)<<127);
        (uint256 packed,uint256 applied,,,)=h.packedUpdate((e<<129)|a,r);
        uint256 expected; if(a==Q) expected=r; else { uint256 product=a*r; expected=product/Q+(product%Q==0?0:1); }
        assert((packed & ((uint256(1)<<129)-1))==expected);
        assert(applied<=Q);
    }
}
