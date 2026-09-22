// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
abstract contract DinosatAssertions is Test {
    function _fails(address target,bytes memory input,bytes memory expected) internal {
        (bool ok,bytes memory data)=target.call(input);assert(!ok);assert(keccak256(data)==keccak256(expected));
    }
    function _failsSelector(address target,bytes memory input,bytes4 expected) internal {
        (bool ok,bytes memory data)=target.call(input);assert(!ok);assert(data.length>=4);assert(bytes4(data)==expected);
    }
    function _err(string memory reason) internal pure returns(bytes memory){return abi.encodeWithSignature("Error(string)",reason);}
    function _panicData(uint256 code) internal pure returns(bytes memory){return abi.encodeWithSignature("Panic(uint256)",code);}
}
