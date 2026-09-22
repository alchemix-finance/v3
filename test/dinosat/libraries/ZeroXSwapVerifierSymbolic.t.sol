// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {ZeroXSwapVerifier as Z} from "../../../src/utils/ZeroXSwapVerifier.sol";
contract DinosatZeroXHarness {
    function verify(bytes calldata data,address owner,address token,uint256 maxBps)external view returns(bool){return Z.verifySwapCalldata(data,owner,token,maxBps);}
    function slice(bytes memory data,uint256 start,uint256 length)external pure returns(bytes memory){return Z._slice(data,start,length);}
    function tail(bytes memory data,uint256 start)external pure returns(bytes memory){return Z._slice(data,start);}
    function token(bytes memory data)external pure returns(address){return Z._extractTokenFromUniswapFills(data);}
    function rfq(bytes memory data)external pure returns(address,uint256){return Z._extractTokenAndAmountFromRFQ(data);}
}
abstract contract DinosatZeroXFixture is DinosatAssertions {
    DinosatZeroXHarness h;address constant TOKEN=address(0xA);address constant OWNER=address(0xB);
    function setUp()public{h=new DinosatZeroXHarness();}
    function _data(bytes memory action,bool meta,address recipient,address buyToken,uint256 minOut)internal pure returns(bytes memory){
        bytes[] memory actions=new bytes[](1);actions[0]=action;Z.SlippageAndActions memory s=Z.SlippageAndActions(recipient,buyToken,minOut,actions);
        if(meta)return abi.encodePacked(bytes4(0x0476baab),abi.encode(s,new bytes[](0),OWNER,bytes("")));
        return abi.encodePacked(bytes4(0xcf71ff4f),abi.encode(s,bytes("")));
    }
    function _action(uint8 kind,address token,uint256 value)internal pure returns(bytes memory){
        if(kind==0)return abi.encodePacked(bytes4(0x5228831d),abi.encode(token,value,address(0xC),uint256(0),bytes("")));
        if(kind==1)return abi.encodePacked(bytes4(0x9ebf8e8d),abi.encode(OWNER,value,uint256(0),false,abi.encode(token)));
        if(kind==2)return abi.encodePacked(bytes4(0x0dfeb419),abi.encode(uint256(0),abi.encode(token,value)));
        if(kind==3)return abi.encodePacked(bytes4(0x8d68a156),abi.encode(token,OWNER,address(0xC),value));
        if(kind==4)return abi.encodePacked(bytes4(0xf1e0a1c3),abi.encode(token,address(0xC),value,uint256(0),bytes("")));
        return abi.encodePacked(bytes4(0xb8df6d4d),abi.encode(token,value,false,uint256(0),uint256(0),bytes("")));
    }
}
contract DinosatZeroXSwapVerifierSymbolicTest is DinosatZeroXFixture {
    /// @notice ZX-ENTRY: short calldata returns false and unknown selectors reject.
    /// @dev Technique: T9 finite byte lengths. Classification: ENUMERATE.
    function test_check_entry(uint8 length)public {assert(!h.verify(new bytes(uint256(length)%4),OWNER,TOKEN,100));_fails(address(h),abi.encodeCall(h.verify,(hex"deadbeef",OWNER,TOKEN,100)),_err("IS"));}
    /// @notice ZX-SLICE: slices and tails preserve exact bytes and reject invalid bounds.
    /// @dev Technique: T9 fixed eight-byte input and exact boundaries. Classification: ENUMERATE.
    function test_check_slice(bytes8 data)public {
        bytes memory original=abi.encodePacked(data);bytes memory middle=h.slice(original,2,4);assert(middle.length==4);assert(middle[0]==original[2]&&middle[3]==original[5]);
        bytes memory tail=h.tail(original,4);assert(keccak256(tail)==keccak256(h.slice(original,4,4)));
        _fails(address(h),abi.encodeCall(h.slice,(original,8,1)),_panicData(0x32));_fails(address(h),abi.encodeCall(h.tail,(original,9)),_panicData(0x11));
    }
    /// @notice ZX-ACTIONS,ZX-BPS: six supported selectors validate their implemented token and bps fields.
    /// @dev Technique: T4 selector partitions and real ABI decoder. Classification: DECOMPOSE. ABI loops require explicit unroll budget.
    function test_check_supported(uint8 rawKind,uint16 rawValue,bool meta)public {
        uint8 kind=rawKind%6;uint256 value=uint256(rawValue)%101;bytes memory action=_action(kind,TOKEN,value);
        assert(h.verify(_data(action,meta,OWNER,address(0xC),1),OWNER,TOKEN,100));
        _fails(address(h),abi.encodeCall(h.verify,(_data(_action(kind,address(0xBAD),value),meta,OWNER,address(0xC),1),OWNER,TOKEN,100)),_err("IT"));
    }
    /// @notice ZX-BPS: supported bps-bearing actions reject a value above the configured threshold.
    /// @dev Technique: T9 three exact action formats. Classification: ENUMERATE.
    function test_check_bpsReject(uint8 raw)public {uint8 kind=raw%3;kind=kind==2?5:kind;_fails(address(h),abi.encodeCall(h.verify,(_data(_action(kind,TOKEN,101),false,OWNER,address(0xC),1),OWNER,TOKEN,100)),_err("Slippage too high"));}
    /// @notice ZX-ACTIONS: unsupported, native-deposit and short actions reject through the real entry.
    /// @dev Technique: finite selector/length cases. Classification: DECOMPOSE.
    function test_check_actionRejects()public {
        _fails(address(h),abi.encodeCall(h.verify,(_data(hex"1234",false,OWNER,TOKEN,0),OWNER,TOKEN,100)),_err("Invalid action length"));
        _fails(address(h),abi.encodeCall(h.verify,(_data(hex"deadbeef",false,OWNER,TOKEN,0),OWNER,TOKEN,100)),_err("IAC"));
        _fails(address(h),abi.encodeCall(h.verify,(_data(hex"c876d21d",false,OWNER,TOKEN,0),OWNER,TOKEN,100)),_err("not supported"));
    }
    /// @notice ZX-PARSERS: simplified parser decodes full words and rejects truncated data.
    /// @dev Technique: T9 exact minimum lengths. Classification: ENUMERATE. This proves only the implemented placeholder format.
    function test_check_parsers(address token,uint128 amount)public {
        assert(h.token(abi.encode(token))==token);(address a,uint256 n)=h.rfq(abi.encode(token,uint256(amount)));assert(a==token&&n==amount);
        _fails(address(h),abi.encodeCall(h.token,(new bytes(31))),_err("unimplemented"));_fails(address(h),abi.encodeCall(h.rfq,(new bytes(63))),_err("unimplemented"));
    }
    /// @notice ZX-NO-AMOUNT-GUARD: token-matching amount actions accept amounts above the passed limit.
    /// @dev Technique: source behavior characterization. Classification: ENUMERATE. Not a claim that the amount is secure.
    function test_check_amountNotBounded(uint128 value)public {uint256 amount=uint256(value)+101;assert(h.verify(_data(_action(3,TOKEN,amount),false,address(0xBAD),address(0xBAD),0),OWNER,TOKEN,100));}
    /// @notice ZX-ACTIONS: every action is checked in a multi-action list, while an empty list is accepted by the current source.
    /// @dev Technique: T9 zero/two action lists through the real decoder. Classification: ENUMERATE. Empty-list acceptance is behavior characterization.
    function test_check_actionLists(bool meta) public {
        bytes[] memory actions=new bytes[](0);Z.SlippageAndActions memory saa=Z.SlippageAndActions(OWNER,address(0xC),1,actions);
        bytes memory data=meta?abi.encodePacked(bytes4(0x0476baab),abi.encode(saa,new bytes[](0),OWNER,bytes(""))):abi.encodePacked(bytes4(0xcf71ff4f),abi.encode(saa,bytes("")));
        assert(h.verify(data,OWNER,TOKEN,100));actions=new bytes[](2);actions[0]=_action(3,TOKEN,1);actions[1]=_action(3,address(0xBAD),1);saa.actions=actions;
        data=meta?abi.encodePacked(bytes4(0x0476baab),abi.encode(saa,new bytes[](0),OWNER,bytes(""))):abi.encodePacked(bytes4(0xcf71ff4f),abi.encode(saa,bytes("")));
        _fails(address(h),abi.encodeCall(h.verify,(data,OWNER,TOKEN,100)),_err("IT"));saa.actions[1]=_action(3,TOKEN,2);
        data=meta?abi.encodePacked(bytes4(0x0476baab),abi.encode(saa,new bytes[](0),OWNER,bytes(""))):abi.encodePacked(bytes4(0xcf71ff4f),abi.encode(saa,bytes("")));assert(h.verify(data,OWNER,TOKEN,100));
    }
    /// @notice ZX-ENTRY,ZX-ACTIONS,ZX-PARSERS: truncated outer/action ABI and dirty address words reject with decoder errors.
    /// @dev Technique: exact malformed ABI partitions. Classification: ENUMERATE.
    function test_check_malformedABI(bool meta) public {
        bytes memory selector=abi.encodePacked(meta?bytes4(0x0476baab):bytes4(0xcf71ff4f));_fails(address(h),abi.encodeCall(h.verify,(selector,OWNER,TOKEN,100)),bytes(""));
        _fails(address(h),abi.encodeCall(h.verify,(_data(hex"8d68a156",meta,OWNER,TOKEN,1),OWNER,TOKEN,100)),bytes(""));
        uint256 dirtyAddress=uint256(1)<<160;_fails(address(h),abi.encodeCall(h.token,(abi.encode(dirtyAddress))),bytes(""));_fails(address(h),abi.encodeCall(h.rfq,(abi.encode(dirtyAddress,uint256(1)))),bytes(""));
        assert(h.token(abi.encode(TOKEN,type(uint256).max))==TOKEN);(address token,uint256 amount)=h.rfq(abi.encode(TOKEN,uint256(7),type(uint256).max));assert(token==TOKEN&&amount==7);
    }
    /// @notice ZX-NO-AMOUNT-GUARD: all amount-bearing formats accept full-word amounts and transferFrom ignores from/to fields.
    /// @dev Technique: real supported action decoders. Classification: ENUMERATE. Does not claim external 0x ABI conformance.
    function test_check_amountAndOwnerUnbound(uint256 amount,address from,address to) public {
        assert(h.verify(_data(_action(2,TOKEN,amount),false,OWNER,address(0xC),1),OWNER,TOKEN,0));
        assert(h.verify(_data(_action(4,TOKEN,amount),false,OWNER,address(0xC),1),OWNER,TOKEN,0));
        bytes memory action=abi.encodePacked(bytes4(0x8d68a156),abi.encode(TOKEN,from,to,amount));assert(h.verify(_data(action,false,OWNER,address(0xC),1),OWNER,TOKEN,0));
    }
    /// @notice ZX-FUZZ,ZX-SLICE: arbitrary bounded byte slices match an independent concatenation relation.
    /// @dev Technique: T17 constructive slice bounds. Classification: FUZZ. Payload max512 bytes.
    function test_fuzz_slice(bytes memory raw,uint256 a,uint256 b)public {
        uint256 n=raw.length>512?512:raw.length;bytes memory data=new bytes(n);for(uint256 i;i<n;i++)data[i]=raw[i];uint256 start=a%(n+1);uint256 length=b%(n-start+1);
        bytes memory part=h.slice(data,start,length);assert(part.length==length);for(uint256 i;i<length;i++)assert(part[i]==data[start+i]);
    }
    /// @notice ZX-FUZZ: mutating the checked sell token always rejects across the six supported encodings.
    /// @dev Technique: T17 parser mutation. Classification: FUZZ.
    function test_fuzz_wrongToken(uint8 kind,uint256 amount,bool meta)public {_fails(address(h),abi.encodeCall(h.verify,(_data(_action(kind%6,address(0xBAD),amount),meta,OWNER,TOKEN,0),OWNER,TOKEN,type(uint256).max)),_err("IT"));}
}
contract DinosatZeroXCounterexampleTest is DinosatZeroXFixture {
    /// @notice ZX-ACTIONS,ZX-NO-AMOUNT-GUARD: accepted swaps should bind expected output recipient.
    /// @dev Technique: actual accepted calldata candidate. Classification: ENUMERATE. Expected counterexample, actual 0x semantics remain unverified.
    function test_check_wrongRecipientMustReject()public {bool accepted=h.verify(_data(_action(3,TOKEN,1),false,address(0xBAD),address(0xBAD),0),OWNER,TOKEN,100);assert(!accepted);}
}
