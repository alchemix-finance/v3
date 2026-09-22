// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {StakingGraph} from "../../../src/libraries/StakingGraph.sol";
contract DinosatGraphHarness {
    using StakingGraph for StakingGraph.Graph;
    StakingGraph.Graph internal graph;
    function add(int256 rate,uint256 start,uint256 duration) external {graph.addStake(rate,start,duration);}
    function query(uint256 from,uint256 to) external view returns(int256){return graph.queryStake(from,to);}
    function size() external view returns(uint256){return graph.size;}
    function node(uint256 index) external view returns(uint256){return graph.g[index];}
}
contract DinosatStakingGraphSymbolicTest is DinosatAssertions {
    DinosatGraphHarness h;
    function setUp() public {h=new DinosatGraphHarness();}
    /// @notice SG-ADD-QUERY,SG-PACK: positive and negative packed deltas preserve inclusive interval values.
    /// @dev Technique: T9 concrete timeline, real Fenwick traversal. Classification: ENUMERATE. int64 rates fit signed112 and signed144 products.
    function test_check_oneInterval(int64 rate) public {
        h.add(rate,2,4);assert(h.query(1,2)==0);assert(h.query(3,6)==int256(rate)*4);assert(h.query(3,3)==rate);assert(h.query(7,20)==0);
        assert(h.query(1,20)==int256(rate)*4);
    }
    /// @notice SG-ADD-QUERY,SG-PACK: expansion and partial cancellation preserve earlier totals.
    /// @dev Technique: T9 fixed tree growth. Classification: ENUMERATE.
    function test_check_expansionAndCancellation(uint64 rawRate) public {
        int256 r=int256(uint256(rawRate));h.add(r,2,4);uint256 size=h.size();
        h.add(r,12,4);assert(h.size()>size);assert(h.query(1,10)==r*4);assert(h.query(1,20)==r*8);
        h.add(-r,4,2);assert(h.query(1,20)==r*6);assert(h.query(5,6)==0);assert(h.query(3,4)==r*2);
    }
    /// @notice SG-BOUNDS: explicit range failures preserve graph state.
    /// @dev Technique: T4 invalid rate/block partitions. Classification: DECOMPOSE.
    function test_check_rejectedBounds() public {
        h.add(7,2,4);uint256 beforeSize=h.size();int256 beforeSum=h.query(1,20);
        _fails(address(h),abi.encodeCall(h.add,(int256(1)<<111,2,4)),bytes(""));
        _fails(address(h),abi.encodeCall(h.add,(-((int256(1)<<111)+1),2,4)),bytes(""));
        _fails(address(h),abi.encodeCall(h.add,(1,(uint256(1)<<32)-1,1)),bytes(""));
        _fails(address(h),abi.encodeCall(h.query,(0,1)),bytes(""));
        _fails(address(h),abi.encodeCall(h.query,(1,(uint256(1)<<32)+1)),bytes(""));
        assert(h.size()==beforeSize);assert(h.query(1,20)==beforeSum);
    }
    /// @notice SG-PACK: packed delta overflow rejects and preserves the prior tree.
    /// @dev Technique: exact packed boundary. Classification: DECOMPOSE.
    function test_check_nodeOverflow() public {
        int256 maxDelta=(int256(1)<<111)-1;h.add(maxDelta,0,1);assert(h.query(1,1)==maxDelta);
        _fails(address(h),abi.encodeCall(h.add,(1,0,1)),bytes(""));assert(h.query(1,1)==maxDelta);
    }
    /// @notice SG-BOUNDS: a timeline immediately below the rejected expansion boundary fits the full tree.
    /// @dev Technique: concrete boundary timeline. Classification: ENUMERATE. Requires loop bound at least 34.
    function test_check_maxTimeline() public {
        uint256 start=(uint256(1)<<32)-4;h.add(1,start,1);assert(h.size()==uint256(1)<<32);assert(h.query(start+1,start+1)==1);assert(h.query(start+2,uint256(1)<<32)==0);
    }
    /// @notice SG-HISTORY: actual graph matches a separate per-block model after additions and cancellations.
    /// @dev Technique: T17 bounded model history. Classification: FUZZ. 4 intervals over blocks 1..40.
    function test_fuzz_intervalModel(uint256 seed) public {
        int256[41] memory model;
        for(uint256 k;k<4;k++){
            uint256 start=1+((seed>>(k*48))&15);uint256 duration=1+((seed>>(k*48+8))&7);int256 r=int256(1+((seed>>(k*48+16))&65535));
            h.add(r,start,duration);for(uint256 b=start+1;b<=start+duration;b++)model[b]+=r;
            if(((seed>>(k*48+32))&1)==1){uint256 consumed=duration/2;h.add(-r,start+consumed,duration-consumed);for(uint256 b=start+consumed+1;b<=start+duration;b++)model[b]-=r;}
        }
        int256 sum;for(uint256 b=1;b<=40;b++){sum+=model[b];assert(h.query(b,b)==model[b]);assert(h.query(1,b)==sum);}
    }
}
// Deliberately retains the intended reject property. This source-level candidate must be reported if execution confirms it.
contract DinosatGraphCounterexampleTest is DinosatAssertions {
    /// @notice SG-BOUNDS: arbitrary durations must not wrap to an earlier expiration.
    /// @dev Technique: concrete candidate on real library bytecode. Classification: DECOMPOSE. Expected counterexample, not a passing safety test.
    function test_check_durationMustNotWrap() public {
        DinosatGraphHarness h=new DinosatGraphHarness();(bool ok,)=address(h).call(abi.encodeCall(h.add,(1,2,type(uint256).max)));assert(!ok);
    }
    /// @notice SG-BOUNDS: the last expiration allowed by explicit guards must not fail tree expansion.
    /// @dev Technique: concrete off-by-one candidate against actual implementation. Classification: ENUMERATE. Expected counterexample.
    function test_check_lastAdmittedExpiration() public {
        DinosatGraphHarness h=new DinosatGraphHarness();uint256 start=(uint256(1)<<32)-3;(bool ok,)=address(h).call(abi.encodeCall(h.add,(1,start,1)));assert(ok);
    }

}
