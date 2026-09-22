// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {TokenUtils as T} from "../../../src/libraries/TokenUtils.sol";
import {SafeERC20 as S} from "../../../src/libraries/SafeERC20.sol";
contract DinosatTokenWrapperHarness {
    function read(address token,bool legacy,bool balance) external view returns(uint256){if(balance)return T.safeBalanceOf(token,address(this));return legacy?S.expectDecimals(token):T.expectDecimals(token);}
    function write(address token,uint8 op,bool legacy,address from,address to,uint256 value) external {
        if(legacy){if(op==0)S.safeTransfer(token,to,value);else if(op==1)S.safeApprove(token,to,value);else S.safeTransferFrom(token,from,to,value);}
        else {if(op==0)T.safeTransfer(token,to,value);else if(op==1)T.safeApprove(token,to,value);else if(op==2)T.safeTransferFrom(token,from,to,value);else if(op==3)T.safeMint(token,to,value);else if(op==4)T.safeBurn(token,value);else T.safeBurnFrom(token,from,value);}
    }
}
contract DinosatReturnToken {
    bytes internal response;bool internal shouldRevert;bytes public lastData;
    constructor(bytes memory result,bool failure){response=result;shouldRevert=failure;}
    fallback() external {
        // Read selectors use no SSTORE, so staticcall can exercise the same response modes.
        if(msg.sig!=0x313ce567 && msg.sig!=0x70a08231)lastData=msg.data;
        bytes memory result=response;bool failure=shouldRevert;
        assembly {switch failure case 0 {return(add(result,32),mload(result))} default {revert(add(result,32),mload(result))}}
    }
}
contract DinosatTokenWrappersSymbolicTest is DinosatAssertions {
    DinosatTokenWrapperHarness h;
    function setUp() public {h=new DinosatTokenWrapperHarness();}
    function _expected(uint8 op,address from,address to,uint256 value) internal pure returns(bytes memory){
        if(op==0)return abi.encodeWithSignature("transfer(address,uint256)",to,value);
        if(op==1)return abi.encodeWithSignature("approve(address,uint256)",to,value);
        if(op==2)return abi.encodeWithSignature("transferFrom(address,address,uint256)",from,to,value);
        if(op==3)return abi.encodeWithSignature("mint(address,uint256)",to,value);
        if(op==4)return abi.encodeWithSignature("burn(uint256)",value);
        return abi.encodeWithSignature("burnFrom(address,uint256)",from,value);
    }
    /// @notice TokenUtils-READ,SafeERC20-READ: reads decode exact full words.
    /// @dev Technique: finite read modes. Classification: DIRECT.
    function test_check_reads(uint8 decimals,uint128 balance,bool legacy) public {
        DinosatReturnToken dec=new DinosatReturnToken(abi.encode(uint256(decimals)),false);assert(h.read(address(dec),legacy,false)==decimals);
        DinosatReturnToken bal=new DinosatReturnToken(abi.encode(uint256(balance)),false);assert(h.read(address(bal),false,true)==balance);
    }
    /// @notice TokenUtils-READ,SafeERC20-READ: trailing ABI words do not alter the decoded result.
    /// @dev Technique: real staticcall return decoder. Classification: DIRECT.
    function test_check_readTrailingWords(uint8 d,uint256 value,uint256 trailing,bool legacy) public {
        DinosatReturnToken dec=new DinosatReturnToken(abi.encode(uint256(d),trailing),false);assert(h.read(address(dec),legacy,false)==d);
        DinosatReturnToken bal=new DinosatReturnToken(abi.encode(value,trailing),false);assert(h.read(address(bal),false,true)==value);
    }
    /// @notice TokenUtils-READ,SafeERC20-READ: failed and truncated responses reject.
    /// @dev Technique: T9 lengths below one ABI word. Classification: ENUMERATE.
    function test_check_readRejects(uint8 rawLength,bool legacy,bool fails) public {
        bytes memory result=new bytes(uint256(rawLength)%32);DinosatReturnToken token=new DinosatReturnToken(result,fails);
        _failsSelector(address(h),abi.encodeCall(h.read,(address(token),legacy,false)),T.ERC20CallFailed.selector);
        _failsSelector(address(h),abi.encodeCall(h.read,(address(token),false,true)),T.ERC20CallFailed.selector);
        DinosatReturnToken badDec=new DinosatReturnToken(abi.encode(uint256(256)),false);
        (bool ok,bytes memory reason)=address(h).call(abi.encodeCall(h.read,(address(badDec),legacy,false)));assert(!ok);assert(reason.length==0);
    }
    /// @notice TokenUtils-WRITE,SafeERC20-WRITE: each operation forwards the exact ABI data and accepts true or empty.
    /// @dev Technique: T9 operation and return modes. Classification: ENUMERATE. No balance-change claim about the mock.
    function test_check_writes(uint8 rawOp,bool legacy,bool empty,address from,address to,uint64 value) public {
        uint8 op=rawOp%(legacy?3:6);DinosatReturnToken token=new DinosatReturnToken(empty?bytes(""):abi.encode(true),false);
        h.write(address(token),op,legacy,from,to,value);assert(keccak256(token.lastData())==keccak256(_expected(op,from,to,value)));
    }
    /// @notice TokenUtils-WRITE,SafeERC20-WRITE: false or failed calls revert all mock state changes.
    /// @dev Technique: T9 operation and failure partitions. Classification: ENUMERATE.
    function test_check_writeRejects(uint8 rawOp,bool legacy,bool fails) public {
        uint8 op=rawOp%(legacy?3:6);DinosatReturnToken token=new DinosatReturnToken(abi.encode(false),fails);
        _failsSelector(address(h),abi.encodeCall(h.write,(address(token),op,legacy,address(1),address(2),1)),T.ERC20CallFailed.selector);
        assert(token.lastData().length==0);
    }
    /// @notice TokenUtils-WRITE,SafeERC20-WRITE: malformed nonempty ABI returns reject without partial writes.
    /// @dev Technique: T9 malformed bool words and lengths. Classification: ENUMERATE.
    function test_check_malformedWrite(bool legacy,uint8 shortLength) public {
        bytes memory result=new bytes(1+uint256(shortLength)%31);DinosatReturnToken token=new DinosatReturnToken(result,false);
        (bool ok,bytes memory reason)=address(h).call(abi.encodeCall(h.write,(address(token),0,legacy,address(1),address(2),1)));assert(!ok);assert(reason.length==0);assert(token.lastData().length==0);
        token=new DinosatReturnToken(abi.encode(uint256(2)),false);
        (ok,reason)=address(h).call(abi.encodeCall(h.write,(address(token),0,legacy,address(1),address(2),1)));assert(!ok);assert(reason.length==0);assert(token.lastData().length==0);
    }
    /// @notice TokenUtils-CODE,SafeERC20-CODE: characterize the actual difference for zero-code targets.
    /// @dev Technique: real EOA calls. Classification: DIRECT. Legacy acceptance is not token-flow proof.
    function test_check_zeroCode(uint8 rawOp) public {
        address eoa=address(0xDEAD);assert(eoa.code.length==0);uint8 op=rawOp%6;
        _failsSelector(address(h),abi.encodeCall(h.write,(eoa,op,false,address(1),address(2),1)),T.ERC20CallFailed.selector);
        h.write(eoa,rawOp%3,true,address(1),address(2),1);
        _failsSelector(address(h),abi.encodeCall(h.read,(eoa,false,false)),T.ERC20CallFailed.selector);
        _failsSelector(address(h),abi.encodeCall(h.read,(eoa,true,false)),T.ERC20CallFailed.selector);
    }
}
