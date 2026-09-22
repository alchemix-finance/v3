// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {PerpetualGauge} from "../../../src/PerpetualGauge.sol";
contract DinosatVoteToken {mapping(address=>uint256) public balanceOf;function set(address a,uint256 v) external {balanceOf[a]=v;}}
contract DinosatClassifierMock {
    uint256 public individual=1e18;uint256 public global=1e18;uint8 public risk;
    function configure(uint256 i,uint256 g,uint8 r) external {individual=i;global=g;risk=r;}
    function getIndividualCap(uint256) external view returns(uint256){return individual;}
    function getGlobalCap(uint8) external view returns(uint256){return global;}
    function getStrategyRiskLevel(uint256) external view returns(uint8){return risk;}
}
contract DinosatAllocationRecorder {mapping(uint256=>uint256) public allocated;function allocate(uint256 id,uint256 amount) external {allocated[id]+=amount;}}
contract DinosatGaugeHarness is PerpetualGauge {
    constructor(address c,address a,address t)PerpetualGauge(c,a,t){}
    // Synthetic-state exposure only. The production registration function cannot populate strategyList.
    function seedStrategy(uint256 yt,uint256 id) external {strategyList[yt].push(id);}
}
abstract contract DinosatGaugeFixture is DinosatAssertions {
    DinosatGaugeHarness g;DinosatVoteToken t;DinosatClassifierMock c;DinosatAllocationRecorder a;
    function setUp() public {vm.warp(100 days);t=new DinosatVoteToken();c=new DinosatClassifierMock();a=new DinosatAllocationRecorder();g=new DinosatGaugeHarness(address(c),address(a),address(t));t.set(address(this),10);}
    function _vote(uint256 x,uint256 y) internal {uint256[] memory ids=new uint256[](2);uint256[] memory w=new uint256[](2);ids[0]=1;ids[1]=2;w[0]=x;w[1]=y;g.vote(1,ids,w);}
    function _seed() internal {g.seedStrategy(1,1);g.seedStrategy(1,2);}
}
contract DinosatPerpetualGaugeSymbolicTest is DinosatGaugeFixture {
    /// @notice PG-CONSTRUCTOR: all dependency addresses must be nonzero.
    /// @dev Technique: actual deployment partitions. Classification: DIRECT.
    function test_check_constructor() public {
        assert(address(g.votingToken())==address(t));assert(address(g.allocatorProxy())==address(a));assert(address(g.stratClassifier())==address(c));
        try new PerpetualGauge(address(0),address(a),address(t)){assert(false);}catch(bytes memory e){assert(keccak256(e)==keccak256(_err("Bad address")));}
        try new PerpetualGauge(address(c),address(0),address(t)){assert(false);}catch(bytes memory e){assert(keccak256(e)==keccak256(_err("Bad address")));}
        try new PerpetualGauge(address(c),address(a),address(0)){assert(false);}catch(bytes memory e){assert(keccak256(e)==keccak256(_err("Bad address")));}
    }
    /// @notice PG-REGISTER,PG-ALLOCATIONS: public registration only updates time and leaves allocations empty.
    /// @dev Technique: actual reachable state. Classification: DIRECT. Characterizes an incomplete implementation.
    function test_check_registration(address caller) public {
        vm.prank(caller);g.registerNewStrategy(1,7);assert(g.lastStrategyAddedAt(1)==block.timestamp);
        (uint256[] memory ids,uint256[] memory w)=g.getCurrentAllocations(1);assert(ids.length==0);assert(w.length==0);
        _fails(address(g),abi.encodeCall(g.executeAllocation,(1,100)),_err("No allocations"));
    }
    /// @notice PG-VOTE-STATE: array guards and all expiry branches use actual stored votes.
    /// @dev Technique: T4 time partitions and fixed two-entry arrays. Classification: DECOMPOSE.
    function test_check_expiry() public {
        _vote(1,1);uint256 oldExpiry=g.votes(1,address(this));assert(oldExpiry==block.timestamp+365 days);
        vm.warp(oldExpiry-10 days);g.registerNewStrategy(1,1);_vote(2,1);assert(g.votes(1,address(this))==oldExpiry);
        vm.warp(oldExpiry+1);_vote(1,1);assert(g.votes(1,address(this))==block.timestamp+365 days);
        uint256[] memory ids=new uint256[](0);uint256[] memory weights=new uint256[](0);
        _fails(address(g),abi.encodeCall(g.vote,(1,ids,weights)),_err("Invalid input"));
    }
    /// @notice PG-VOTE-STATE: mismatched arrays and overflowing weight products reject atomically.
    /// @dev Technique: valid existing vote followed by two isolated errors. Classification: DIRECT.
    function test_check_rejectedVotePreservesState() public {
        _seed();_vote(1,1);uint256 expiry=g.votes(1,address(this));uint256[] memory ids=new uint256[](2);ids[0]=1;ids[1]=2;uint256[] memory w=new uint256[](1);w[0]=1;
        _fails(address(g),abi.encodeCall(g.vote,(1,ids,w)),_err("Invalid input"));w=new uint256[](2);w[0]=type(uint256).max;w[1]=1;
        _fails(address(g),abi.encodeCall(g.vote,(1,ids,w)),_panicData(0x11));assert(g.votes(1,address(this))==expiry);(,uint256[] memory afterWeights)=g.getCurrentAllocations(1);assert(afterWeights[0]==5e17&&afterWeights[1]==5e17);
    }
    /// @notice PG-VOTE-STATE,PG-CLEAR: duplicate strategy IDs aggregate and clear both contributions exactly.
    /// @dev Technique: actual duplicate-entry vote, disclosed seeded strategy list. Classification: ENUMERATE.
    function test_check_duplicateStrategies(uint32 raw) public {
        _seed();uint256[] memory ids=new uint256[](2);ids[0]=1;ids[1]=1;uint256[] memory w=new uint256[](2);w[0]=uint256(raw)+1;w[1]=2;g.vote(1,ids,w);
        (,uint256[] memory allocations)=g.getCurrentAllocations(1);assert(allocations[0]==1e18&&allocations[1]==0);g.clearVote(1);(,allocations)=g.getCurrentAllocations(1);assert(allocations[0]==0&&allocations[1]==0);
    }
    /// @notice PG-VOTE-STATE,PG-CLEAR,PG-ALLOCATIONS: same-power replacement normalizes the new weights and clear removes them.
    /// @dev Technique: T9 seeded list and two entries. Classification: ENUMERATE. Synthetic list state is explicit.
    function test_check_replaceAndClear(uint32 rawX,uint32 rawY) public {
        _seed();_vote(5,3);uint256 x=uint256(rawX)+1;uint256 y=uint256(rawY)+1;_vote(x,y);
        (uint256[] memory ids,uint256[] memory w)=g.getCurrentAllocations(1);assert(ids[0]==1&&ids[1]==2);
        uint256 total=x+y;assert(w[0]*total<=x*1e18);assert(x*1e18-w[0]*total<total);
        assert(w[0]+w[1]<=1e18);assert(1e18-w[0]-w[1]<2);
        g.clearVote(1);(,w)=g.getCurrentAllocations(1);assert(w[0]==0&&w[1]==0);assert(g.votes(1,address(this))==0);
        _fails(address(g),abi.encodeCall(g.clearVote,(1)),_err("No vote"));
    }
    /// @notice PG-EXECUTION: with unrestricted caps, actual forwarded amounts cannot exceed idle funds.
    /// @dev Technique: T4 zero-risk and fixed list. Classification: DECOMPOSE. Does not prove cap-unit correctness.
    function test_check_executeUnrestricted(uint64 assets) public {
        _seed();_vote(1,1);g.executeAllocation(1,assets);assert(a.allocated(1)==uint256(assets)/2);assert(a.allocated(2)==uint256(assets)/2);assert(a.allocated(1)+a.allocated(2)<=assets);
    }
    /// @notice PG-FUZZ: same-power vote histories preserve latest normalized allocation and complete clear.
    /// @dev Technique: T17 constructive positive weights. Classification: FUZZ. 8 replacements, two seeded strategies.
    function test_fuzz_replacements(uint256 seed) public {
        _seed();for(uint256 i;i<8;i++){uint256 x=1+((seed>>(i*16))&255);uint256 y=1+((seed>>(i*16+8))&255);_vote(x,y);(,uint256[] memory w)=g.getCurrentAllocations(1);assert(w[0]==x*1e18/(x+y));assert(w[1]==y*1e18/(x+y));}g.clearVote(1);(,uint256[] memory afterW)=g.getCurrentAllocations(1);assert(afterW[0]+afterW[1]==0);
    }
}
contract DinosatGaugeCounterexampleTest is DinosatGaugeFixture {
    /// @notice PG-POWER-CHANGE: a holder must be able to clear after receiving more voting tokens.
    /// @dev Technique: concrete real-bytecode candidate. Classification: ENUMERATE. Expected counterexample.
    function test_check_clearAfterPowerIncrease() public {_vote(1,1);t.set(address(this),20);(bool ok,)=address(g).call(abi.encodeCall(g.clearVote,(1)));assert(ok);}
    /// @notice PG-POWER-CHANGE: clearing after a balance decrease must not leave stale weight.
    /// @dev Technique: actual vote state plus disclosed synthetic strategy list. Classification: ENUMERATE. Expected counterexample.
    function test_check_clearAfterPowerDecrease() public {_seed();_vote(1,1);t.set(address(this),5);g.clearVote(1);(,uint256[] memory w)=g.getCurrentAllocations(1);assert(w[0]+w[1]==0);}
    /// @notice PG-POWER-CHANGE: a holder must be able to replace a vote after receiving more voting tokens.
    /// @dev Technique: concrete real-bytecode candidate. Classification: ENUMERATE. Expected counterexample.
    function test_check_revoteAfterPowerIncrease() public {
        _vote(1,1);t.set(address(this),20);uint256[] memory ids=new uint256[](1);ids[0]=1;uint256[] memory w=new uint256[](1);w[0]=1;(bool ok,)=address(g).call(abi.encodeCall(g.vote,(1,ids,w)));assert(ok);
    }
    /// @notice PG-POWER-CHANGE,PG-ALLOCATIONS: replacing an expired vote must not retain the old contribution.
    /// @dev Technique: actual time transition, disclosed seeded list. Classification: ENUMERATE. Expected counterexample.
    function test_check_expiredContribution() public {
        _seed();_vote(1,1);vm.warp(g.votes(1,address(this))+1);_vote(3,1);(,uint256[] memory w)=g.getCurrentAllocations(1);assert(w[0]==75e16&&w[1]==25e16);
    }
    /// @notice PG-EXECUTION: WAD individual caps must limit actual allocation.
    /// @dev Technique: fixed seeded list. Classification: DECOMPOSE. Expected counterexample in a synthetic nonempty-list state.
    function test_check_wadIndividualCap() public {_seed();_vote(1,1);c.configure(1e16,1e18,0);g.executeAllocation(1,10000);assert(a.allocated(1)<=100);assert(a.allocated(2)<=100);}
}
