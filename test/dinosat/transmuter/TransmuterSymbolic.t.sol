// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "../libraries/DinosatAssertions.sol";
import {Transmuter} from "../../../src/Transmuter.sol";
import {ITransmuter} from "../../../src/interfaces/ITransmuter.sol";
import {NFTMetadataGenerator as N} from "../../../src/libraries/NFTMetadataGenerator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DinosatTransmuterToken is ERC20 {
    uint8 immutable precision;
    constructor(uint8 d)ERC20("DinoSAT token","DINO"){precision=d;}
    function decimals() public view override returns(uint8){return precision;}
    function mint(address to,uint256 n) external {_mint(to,n);}
    function burn(uint256 n) external {_burn(msg.sender,n);}
}
contract DinosatAlchemistMock {
    address public immutable myt;address public immutable underlyingToken;uint256 public immutable underlyingScale;address public transmuter;
    uint256 public totalSyntheticsIssued=1e27;uint256 public backing=1e27;uint256 public redeemLimit=type(uint256).max;
    uint256 public lastBalance;uint256 public redeemed;uint256 public reduced;
    constructor(address shares,address underlying){myt=shares;underlyingToken=underlying;uint8 d=DinosatTransmuterToken(underlying).decimals();underlyingScale=d<=18?10**(18-d):1;}
    function configure(address t,uint256 issued,uint256 value,uint256 limit) external{transmuter=t;totalSyntheticsIssued=issued;backing=value;redeemLimit=limit;}
    function getTotalLockedUnderlyingValue() external view returns(uint256){return backing;}
    function convertYieldTokensToUnderlying(uint256 n) external view returns(uint256){return n/underlyingScale;}
    function convertYieldTokensToDebt(uint256 n) external pure returns(uint256){return n;}
    function convertDebtTokensToYield(uint256 n) external pure returns(uint256){return n;}
    function redeem(uint256 amount) external returns(uint256){require(msg.sender==transmuter);uint256 n=amount<redeemLimit?amount:redeemLimit;DinosatTransmuterToken(myt).mint(msg.sender,n);redeemed+=n;return n;}
    function reduceSyntheticsIssued(uint256 n) external{require(msg.sender==transmuter);totalSyntheticsIssued-=n;reduced+=n;}
    function setTransmuterTokenBalance(uint256 n) external{require(msg.sender==transmuter);lastBalance=n;}
}
abstract contract DinosatTransmuterFixture is DinosatAssertions {
    Transmuter t;DinosatTransmuterToken synth;DinosatTransmuterToken shares;DinosatAlchemistMock al;
    address constant USER=address(0xABCD);address constant OTHER=address(0xDCBA);address constant FEE=address(0xFEE);
    function _params() internal view returns(ITransmuter.TransmuterInitializationParams memory p){p=ITransmuter.TransmuterInitializationParams(address(synth),FEE,4,0,0,0);}
    function setUp() public {vm.roll(10);synth=new DinosatTransmuterToken(18);shares=new DinosatTransmuterToken(18);al=new DinosatAlchemistMock(address(shares),address(synth));t=new Transmuter(_params());t.setAlchemist(address(al));t.setDepositCap(1e27);al.configure(address(t),1e27,1e27,type(uint256).max);synth.approve(address(t),type(uint256).max);}
    function _create(uint256 n,address to) internal returns(uint256 id){synth.mint(address(this),n);t.createRedemption(n,to);id=t.totalSupply();}
    function _invariants() internal view {assert(t.exitFee()<=10000&&t.transmutationFee()<=10000);assert(t.timeToTransmute()>0);assert(t.totalActiveLocked()<=t.totalLocked());assert(t.totalLocked()<=al.totalSyntheticsIssued());assert(synth.balanceOf(address(t))>=t.totalLocked());}
}
contract DinosatTransmuterAdminSymbolicTest is DinosatTransmuterFixture {
    /// @notice TR-CONSTRUCTOR,TR-RECEIVER,TR-PERSISTENT-INVARIANTS: configuration initializes exactly.
    /// @dev Technique: actual deployment. Classification: DIRECT.
    function test_check_constructor() public view {assert(t.admin()==address(this));assert(t.syntheticToken()==address(synth));assert(t.timeToTransmute()==4);assert(t.protocolFeeReceiver()==FEE);_invariants();}
    /// @notice TR-CONSTRUCTOR: invalid receiver, time and fees reject deployment.
    /// @dev Technique: finite invalid parameter partitions. Classification: DIRECT.
    function test_check_constructorRejects(uint8 raw) public {
        ITransmuter.TransmuterInitializationParams memory p=_params();uint8 which=raw%5;
        if(which==0)p.feeReceiver=address(0);else if(which==1)p.timeToTransmute=0;else if(which==2)p.timeToTransmute=uint256(type(int256).max)+1;else if(which==3)p.exitFee=10001;else p.transmutationFee=10001;
        try new Transmuter(p){assert(false);}catch(bytes memory e){assert(bytes4(e)==bytes4(keccak256("IllegalArgument()")));}
    }
    /// @notice TR-ADMIN: every admin selector rejects the same unauthorized actor on valid arguments.
    /// @dev Technique: real guarded calls, fixed valid state. Classification: DIRECT.
    function test_check_adminGuards(uint8 raw) public {
        bytes memory data;uint8 which=raw%7;
        if(which==0)data=abi.encodeCall(t.setPendingAdmin,(OTHER));else if(which==1)data=abi.encodeCall(t.setAlchemist,(OTHER));else if(which==2)data=abi.encodeCall(t.setDepositCap,(100));else if(which==3)data=abi.encodeCall(t.setTransmutationFee,(1));else if(which==4)data=abi.encodeCall(t.setExitFee,(1));else if(which==5)data=abi.encodeCall(t.setTransmutationTime,(5));else data=abi.encodeCall(t.setProtocolFeeReceiver,(OTHER));
        vm.prank(OTHER);_failsSelector(address(t),data,bytes4(keccak256("IllegalArgument()")));
        assert(t.pendingAdmin()==address(0));assert(address(t.alchemist())==address(al));assert(t.depositCap()==1e27);assert(t.exitFee()==0&&t.transmutationFee()==0);assert(t.timeToTransmute()==4);assert(t.protocolFeeReceiver()==FEE);
    }
    /// @notice TR-HANDOFF: only pending admin accepts and old authority ends.
    /// @dev Technique: actual two-step roles. Classification: DIRECT.
    function test_check_handoff() public {
        _failsSelector(address(t),abi.encodeCall(t.acceptAdmin,()),bytes4(keccak256("IllegalState()")));t.setPendingAdmin(OTHER);
        vm.prank(USER);_failsSelector(address(t),abi.encodeCall(t.acceptAdmin,()),bytes4(keccak256("Unauthorized()")));assert(t.pendingAdmin()==OTHER);
        vm.prank(OTHER);t.acceptAdmin();assert(t.admin()==OTHER);assert(t.pendingAdmin()==address(0));
        _failsSelector(address(t),abi.encodeCall(t.setExitFee,(1)),bytes4(keccak256("IllegalArgument()")));vm.prank(OTHER);t.setExitFee(1);assert(t.exitFee()==1);
    }
    /// @notice TR-FEES,TR-TIME,TR-CAP,TR-RECEIVER: accepted values persist and rejected values preserve them.
    /// @dev Technique: constructor-sized scalar domains and boundaries. Classification: DIRECT.
    function test_check_setters(uint16 fee,uint64 cap,uint32 duration) public {
        uint256 f=uint256(fee)%10001;uint256 d=uint256(duration)+1;t.setExitFee(f);t.setTransmutationFee(f);t.setDepositCap(cap);t.setTransmutationTime(d);t.setProtocolFeeReceiver(OTHER);
        assert(t.exitFee()==f&&t.transmutationFee()==f);assert(t.depositCap()==cap);assert(t.timeToTransmute()==d);assert(t.protocolFeeReceiver()==OTHER);
        _failsSelector(address(t),abi.encodeCall(t.setExitFee,(10001)),bytes4(keccak256("IllegalArgument()")));
        _failsSelector(address(t),abi.encodeCall(t.setTransmutationFee,(10001)),bytes4(keccak256("IllegalArgument()")));
        _failsSelector(address(t),abi.encodeCall(t.setTransmutationTime,(0)),bytes4(keccak256("IllegalArgument()")));
        _failsSelector(address(t),abi.encodeCall(t.setDepositCap,(uint256(type(int256).max)+1)),bytes4(keccak256("IllegalArgument()")));
        _failsSelector(address(t),abi.encodeCall(t.setProtocolFeeReceiver,(address(0))),bytes4(keccak256("IllegalArgument()")));
        assert(t.exitFee()==f&&t.transmutationFee()==f);assert(t.depositCap()==cap);assert(t.timeToTransmute()==d);assert(t.protocolFeeReceiver()==OTHER);
    }
    /// @notice TR-CAP,TR-TIME: configuration changes do not rewrite existing positions.
    /// @dev Technique: actual historical position. Classification: DIRECT. Lowering cap below active locked is accepted behavior.
    function test_check_existingPositionConfig() public {_create(100,USER);t.setDepositCap(0);t.setTransmutationTime(99);ITransmuter.StakingPosition memory p=t.getPosition(1);assert(p.amount==100&&p.startBlock==10&&p.maturationBlock==14);assert(t.totalActiveLocked()==100);assert(t.depositCap()==0);}
}
contract DinosatTransmuterStateSymbolicTest is DinosatTransmuterFixture {
    /// @notice TR-CREATE-ACCOUNTING,TR-GET,TR-GRAPH,TR-PERSISTENT-INVARIANTS: create transfers exact principal and records the NFT.
    /// @dev Technique: T9 start=10,duration=4. Classification: ENUMERATE. uint64 amount bounds the signed rate below packed limits.
    function test_check_create(uint64 rawAmount) public {uint256 n=uint256(rawAmount)+1;_create(n,USER);ITransmuter.StakingPosition memory p=t.getPosition(1);assert(p.amount==n&&p.startBlock==10&&p.maturationBlock==14);assert(t.ownerOf(1)==USER);assert(t.totalLocked()==n&&t.totalActiveLocked()==n);assert(synth.balanceOf(address(t))==n);assert(t.getPosition(2).amount==0);assert(t.queryGraph(11,14)==n);assert(t.queryGraph(15,20)==0);assert(t.queryGraph(15,14)==0);_invariants();}
    /// @notice TR-CREATE-GATES: zero, recipient, active cap and issued cap errors preserve all balances.
    /// @dev Technique: T4 one rejection per branch. Classification: DECOMPOSE.
    function test_check_createRejects(uint8 raw) public {
        uint8 which=raw%4;uint256 n=1;address recipient=USER;
        if(which==0)n=0;else if(which==1)recipient=address(0);else if(which==2)t.setDepositCap(0);else al.configure(address(t),0,1e27,type(uint256).max);
        synth.mint(address(this),1);bytes4 error=which==0?bytes4(keccak256("DepositZeroAmount()")):which==1?bytes4(keccak256("IllegalArgument()")):bytes4(keccak256("DepositCapReached()"));
        _failsSelector(address(t),abi.encodeCall(t.createRedemption,(n,recipient)),error);assert(t.totalLocked()==0);assert(t.totalActiveLocked()==0);assert(t.totalSupply()==0);assert(synth.balanceOf(address(this))==1);assert(synth.balanceOf(address(t))==0);
    }
    /// @notice TR-CLAIM-GATES: no same-block, unknown, approved-only or former-owner claims.
    /// @dev Technique: T4 real NFT ownership transitions. Classification: DECOMPOSE.
    function test_check_claimAuthorization() public {
        _create(100,USER);vm.prank(USER);_failsSelector(address(t),abi.encodeCall(t.claimRedemption,(1)),bytes4(keccak256("PrematureClaim()")));
        vm.roll(11);vm.prank(USER);t.approve(OTHER,1);vm.prank(OTHER);_failsSelector(address(t),abi.encodeCall(t.claimRedemption,(1)),bytes4(keccak256("CallerNotOwner()")));
        vm.prank(USER);t.transferFrom(USER,OTHER,1);vm.prank(USER);_failsSelector(address(t),abi.encodeCall(t.claimRedemption,(1)),bytes4(keccak256("CallerNotOwner()")));
        vm.prank(OTHER);t.claimRedemption(1);assert(t.totalSupply()==0);assert(t.getPosition(1).amount==0);
        vm.prank(OTHER);_failsSelector(address(t),abi.encodeCall(t.claimRedemption,(1)),bytes4(keccak256("PositionNotFound()")));_invariants();
    }
    function _claimCase(uint256 n,uint256 elapsed,uint256 fee,uint256 exitFee,uint256 limit,bool haircut) internal {
        t.setTransmutationFee(fee);t.setExitFee(exitFee);_create(n,USER);
        if(haircut)al.configure(address(t),1e27,5e26,limit);else al.configure(address(t),1e27,1e27,limit);
        uint256 issued=al.totalSyntheticsIssued();vm.roll(10+elapsed);
        vm.prank(USER);(uint256 cy,uint256 fy,uint256 returned,uint256 sf)=t.claimRedemption(1);
        uint256 left=elapsed<4?4-elapsed:0;uint256 notTransmuted=(n*left)/4+((n*left)%4==0?0:1);uint256 transmuted=n-notTransmuted;
        uint256 scaled=haircut?transmuted/2:transmuted;uint256 payout=scaled<limit?scaled:limit;
        assert(cy+fy==payout);assert(fy==payout*fee/10000);assert(sf==notTransmuted*exitFee/10000);
        assert(returned+sf+al.reduced()==n);assert(synth.balanceOf(USER)==returned);assert(synth.balanceOf(FEE)==sf);assert(shares.balanceOf(USER)==cy);assert(shares.balanceOf(FEE)==fy);
        assert(issued-al.totalSyntheticsIssued()==al.reduced());assert(al.lastBalance()==shares.balanceOf(address(t)));assert(t.totalSupply()==0);assert(t.totalLocked()==0);assert(t.totalActiveLocked()==0);assert(t.getPosition(1).maturationBlock==0);_invariants();
    }
    /// @notice TR-CLAIM-TIME,TR-CLAIM-SPLIT,TR-CLAIM-SETTLEMENT: early settlement conserves principal and both token flows.
    /// @dev Technique: T4 elapsed=1, bounded real 512-bit code short path. Classification: DECOMPOSE. uint64 values make all products fit.
    function test_check_earlyClaim(uint64 raw,uint16 f,uint16 ef) public {_claimCase(uint256(raw)+1,1,uint256(f)%10001,uint256(ef)%10001,type(uint256).max,false);}
    /// @notice TR-CLAIM-BAD-DEBT,TR-CLAIM-SPLIT: mature bad-debt haircut uses the real ceil ratio implementation.
    /// @dev Technique: T4 backing exactly half issued, decimals18. Classification: DECOMPOSE.
    function test_check_badDebtClaim(uint64 raw,uint16 f) public {_claimCase(uint256(raw)+1,4,uint256(f)%10001,0,type(uint256).max,true);}
    /// @notice TR-CLAIM-SETTLEMENT,TR-CLAIM-SPLIT: a share shortfall returns synths instead of burning them.
    /// @dev Technique: T4 exact zero-share redemption branch. Classification: DECOMPOSE.
    function test_check_shortfall(uint64 raw,uint16 ef) public {_claimCase(uint256(raw)+1,2,0,uint256(ef)%10001,0,false);}
    /// @notice TR-CLAIM-CAP,TR-PERSISTENT-INVARIANTS: permissionless matured poke releases active cap once.
    /// @dev Technique: T4 two positions and before/after maturity. Classification: DECOMPOSE.
    function test_check_pokeAndClaim() public {
        _create(100,USER);_create(200,OTHER);vm.roll(14);vm.prank(OTHER);t.pokeMatured(1);assert(t.totalLocked()==300);assert(t.totalActiveLocked()==200);
        _failsSelector(address(t),abi.encodeCall(t.pokeMatured,(1)),bytes4(keccak256("PositionAlreadyPoked(uint256)")));
        vm.prank(USER);t.claimRedemption(1);assert(t.totalLocked()==200);assert(t.totalActiveLocked()==200);
        vm.prank(OTHER);t.claimRedemption(2);assert(t.totalLocked()==0&&t.totalActiveLocked()==0);_invariants();
    }
    /// @notice TR-GRAPH,TR-CLAIM-CAP: early claim removes only the future rate and cannot be poked early.
    /// @dev Technique: concrete graph cancellation branch. Classification: ENUMERATE.
    function test_check_earlyGraphCancellation() public {
        _create(100,USER);_failsSelector(address(t),abi.encodeCall(t.pokeMatured,(1)),bytes4(keccak256("PositionNotMatured(uint256,uint256,uint256)")));
        vm.roll(11);vm.prank(USER);t.claimRedemption(1);assert(t.queryGraph(12,20)==0);assert(t.queryGraph(11,11)==25);_invariants();
    }
    /// @notice TR-CREATE-FUZZ,TR-CLAIM-SETTLEMENT: real create/claim arithmetic across bounded dates, fees and shortfalls.
    /// @dev Technique: T17 constructive state. Classification: FUZZ. All inputs execute assertions, without discarded fuzz cases.
    function test_fuzz_claimCases(uint256 rawAmount,uint256 rawElapsed,uint256 rawFee,uint256 rawExit,uint256 rawLimit,bool haircut) public {
        uint256 n=1+rawAmount%1e27;uint256 limit=rawLimit%(n+1);_claimCase(n,1+rawElapsed%6,rawFee%10001,rawExit%10001,limit,haircut);
    }

    /// @notice TR-CLAIM-BAD-DEBT: real decimals 0,6,8,12,18 preserve a fully backed mature claim.
    /// @dev Technique: T9 concrete decimal enumeration with unit-consistent mock backing. Classification: ENUMERATE. This is a subset of uint8 decimals.
    function _decimalCase(uint8 d) internal {
        DinosatTransmuterToken underlying=new DinosatTransmuterToken(d);
        DinosatAlchemistMock scaled=new DinosatAlchemistMock(address(shares),address(underlying));t.setAlchemist(address(scaled));uint256 factor=10**(18-d);scaled.configure(address(t),1e27,1e27/factor,type(uint256).max);
        _create(4e18,USER);vm.roll(14);vm.prank(USER);(uint256 claimed,,,)=t.claimRedemption(1);assert(claimed==4e18);assert(shares.balanceOf(USER)==4e18);assert(t.totalLocked()==0);
    }
    /// @notice TR-CLAIM-BAD-DEBT: fully backed claim at 0 decimals.
    /// @dev Technique: T9 concrete exponent. Classification: ENUMERATE.
    function test_check_decimals_0() public {_decimalCase(0);}
    /// @notice TR-CLAIM-BAD-DEBT: fully backed claim at 6 decimals.
    /// @dev Technique: T9 concrete exponent. Classification: ENUMERATE.
    function test_check_decimals_6() public {_decimalCase(6);}
    /// @notice TR-CLAIM-BAD-DEBT: fully backed claim at 8 decimals.
    /// @dev Technique: T9 concrete exponent. Classification: ENUMERATE.
    function test_check_decimals_8() public {_decimalCase(8);}
    /// @notice TR-CLAIM-BAD-DEBT: fully backed claim at 12 decimals.
    /// @dev Technique: T9 concrete exponent. Classification: ENUMERATE.
    function test_check_decimals_12() public {_decimalCase(12);}
    /// @notice TR-CLAIM-BAD-DEBT: fully backed claim at 18 decimals.
    /// @dev Technique: T9 concrete exponent. Classification: ENUMERATE.
    function test_check_decimals_18() public {_decimalCase(18);}
    /// @notice TR-CLAIM-BAD-DEBT: unsupported exponent78 rejects and restores the burned NFT and all accounting.
    /// @dev Technique: explicit decimals overflow boundary. Classification: ENUMERATE.
    function test_check_decimalOverflow() public {
        DinosatTransmuterToken underlying=new DinosatTransmuterToken(78);DinosatAlchemistMock scaled=new DinosatAlchemistMock(address(shares),address(underlying));t.setAlchemist(address(scaled));scaled.configure(address(t),1e27,1e27,type(uint256).max);
        _create(100,USER);vm.roll(14);vm.prank(USER);_fails(address(t),abi.encodeCall(t.claimRedemption,(1)),_panicData(0x11));assert(t.ownerOf(1)==USER);assert(t.totalLocked()==100);assert(synth.balanceOf(address(t))==100);
    }
    /// @notice TR-CREATE-FUZZ: out-of-domain signed/graph arithmetic reverts atomically.
    /// @dev Technique: boundary calls against real source. Classification: FUZZ. Exact panic precedes graph insertion.
    function test_check_largeAmountRejects() public {
        uint256 n=uint256(type(int256).max)/1e8+1;t.setDepositCap(uint256(type(int256).max));al.configure(address(t),uint256(type(int256).max),uint256(type(int256).max),type(uint256).max);synth.mint(address(this),n);
        _fails(address(t),abi.encodeCall(t.createRedemption,(n,USER)),_panicData(0x11));assert(t.totalSupply()==0);assert(t.totalLocked()==0);assert(synth.balanceOf(address(this))==n);
    }
    /// @notice TR-METADATA: actual Transmuter URI wrapper preserves the requested ID and production title.
    /// @dev Technique: wrapper refinement against the independently decoded dependency suite. Classification: FUZZ.
    function test_fuzz_tokenURI(uint256 id) public view {
        assert(keccak256(bytes(t.tokenURI(id)))==keccak256(bytes(N.generateTokenURI(id,"Transmuter V3 Position"))));
    }
    /// @notice TR-CLAIM-SETTLEMENT: existing MYT is used before an Alchemist redemption.
    /// @dev Technique: two concrete balance branches, actual bytecode. Classification: DECOMPOSE.
    function test_check_existingYield(bool enough) public {
        _create(100,USER);shares.mint(address(t),enough?150:50);vm.roll(14);vm.prank(USER);(uint256 claimed,,,)=t.claimRedemption(1);
        assert(claimed==100);assert(al.redeemed()==(enough?0:50));assert(shares.balanceOf(address(t))==(enough?50:0));assert(al.lastBalance()==shares.balanceOf(address(t)));_invariants();
    }
    /// @notice TR-GRAPH: the Transmuter wrapper preserves graph bounds.
    /// @dev Technique: exact graph rejection and inclusive domain boundary. Classification: ENUMERATE.
    function test_check_graphBounds() public {
        _create(100,USER);_fails(address(t),abi.encodeCall(t.queryGraph,(0,1)),bytes(""));_fails(address(t),abi.encodeCall(t.queryGraph,(1,(uint256(1)<<32)+1)),bytes(""));assert(t.queryGraph(1,uint256(1)<<32)==100);
    }
    /// @notice TR-CLAIM-BAD-DEBT,TR-CLAIM-SPLIT: zero and non-exact backing ratios round against claimants without increasing transmuted principal.
    /// @dev Technique: T17 exact integer quotient/remainder oracle independent of mulDiv. Classification: FUZZ. n<=1e24, backing<=2e27 keeps oracle products in range.
    function test_fuzz_badDebtRatio(uint256 rawAmount,uint256 rawBacking) public {
        uint256 n=1+rawAmount%1e24;uint256 backing=rawBacking%(2e27+1);_create(n,USER);al.configure(address(t),1e27,backing,type(uint256).max);vm.roll(14);
        uint256 denominator=backing==0?1:backing;uint256 ratio=1e45/denominator+(1e45%denominator==0?0:1);uint256 scaled=ratio>1e18?n*1e18/ratio:n;
        assert(ratio*denominator>=1e45);assert(ratio*denominator-1e45<denominator);assert(scaled<=n);
        vm.prank(USER);(uint256 claim,uint256 fee,uint256 returned,uint256 syntheticFee)=t.claimRedemption(1);
        assert(claim==scaled);assert(fee==0&&returned==0&&syntheticFee==0);assert(shares.balanceOf(USER)==scaled);assert(al.reduced()==n);_invariants();
    }
    /// @notice TR-CREATE-FUZZ,TR-CLAIM-TIME: variable durations follow ceil remaining-principal rounding through actual settlement.
    /// @dev Technique: T17 constructive positive amount/duration. Classification: FUZZ. Amount<=1e24 and duration<=2^20 keep graph endpoints/rates within bounds.
    function test_fuzz_variableSchedule(uint256 rawAmount,uint256 rawDuration,uint256 rawElapsed) public {
        uint256 n=1+rawAmount%1e24;uint256 duration=1+rawDuration%(1<<20);uint256 elapsed=1+rawElapsed%(duration+1);t.setTransmutationTime(duration);_create(n,USER);vm.roll(10+elapsed);
        vm.prank(USER);(uint256 claim,,uint256 returned,)=t.claimRedemption(1);uint256 left=elapsed<duration?duration-elapsed:0;uint256 remaining=n*left/duration+(n*left%duration==0?0:1);
        assert(returned==remaining);assert(claim+remaining==n);assert(al.reduced()==claim);_invariants();
    }

}
