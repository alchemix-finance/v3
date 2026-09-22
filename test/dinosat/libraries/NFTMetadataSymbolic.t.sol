// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {NFTMetadataGenerator as N} from "../../../src/libraries/NFTMetadataGenerator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
contract DinosatMetadataHarness {
    function svg(uint256 id,string memory title)external pure returns(string memory){return N.generateSVG(id,title);}
    function json(uint256 id,string memory svg_)external pure returns(string memory){return N.generateJSONString(id,svg_);}
    function uri(uint256 id,string memory title)external pure returns(string memory){return N.generateTokenURI(id,title);}
}
contract DinosatNFTMetadataSymbolicTest is DinosatAssertions {
    DinosatMetadataHarness h;
    function setUp()public{h=new DinosatMetadataHarness();}
    function _find(bytes memory text,bytes memory word,uint256 start)internal pure returns(uint256){
        for(uint256 i=start;i+word.length<=text.length;i++){bool found=true;for(uint256 j;j<word.length;j++){if(text[i+j]!=word[j]){found=false;break;}}if(found)return i;}revert("missing expected field");
    }
    function _sub(bytes memory data,uint256 start,uint256 n)internal pure returns(bytes memory out){out=new bytes(n);for(uint256 i;i<n;i++)out[i]=data[start+i];}
    function _digit(uint8 c)internal pure returns(uint256){if(c>=65&&c<=90)return c-65;if(c>=97&&c<=122)return c-71;if(c>=48&&c<=57)return c+4;if(c==43)return 62;if(c==47)return 63;assert(false);return 0;}
    function _decode(bytes memory input)internal pure returns(bytes memory out){
        assert(input.length%4==0);uint256 length=input.length/4*3;if(input.length>0&&input[input.length-1]==0x3d)length--;if(input.length>1&&input[input.length-2]==0x3d)length--;
        out=new bytes(length);uint256 pos;for(uint256 i;i<input.length;i+=4){uint256 a=_digit(uint8(input[i]));uint256 b=_digit(uint8(input[i+1]));uint256 c=input[i+2]==0x3d?0:_digit(uint8(input[i+2]));uint256 d=input[i+3]==0x3d?0:_digit(uint8(input[i+3]));uint256 group=(a<<18)|(b<<12)|(c<<6)|d;
            if(pos<length)out[pos++]=bytes1(uint8(group>>16));if(pos<length)out[pos++]=bytes1(uint8(group>>8));if(pos<length)out[pos++]=bytes1(uint8(group));}
    }
    function _check(uint256 id,string memory title)internal view {
        bytes memory svg=bytes(h.svg(id,title));assert(svg[0]==0x3c);_find(svg,bytes(title),0);
        bytes memory wanted=abi.encodePacked("#",Strings.toString(id));bytes memory assembled;uint256 cursor;uint256 lines=(wanted.length+24)/25;
        for(uint256 i;i<lines;i++){uint256 tag=_find(svg,bytes("<tspan"),cursor);uint256 begin=_find(svg,bytes(">"),tag)+1;uint256 end=_find(svg,bytes("</tspan>"),begin);assert(end-begin<=25);assembled=abi.encodePacked(assembled,_sub(svg,begin,end-begin));cursor=end+8;}
        assert(keccak256(assembled)==keccak256(wanted));
        bytes memory uri=bytes(h.uri(id,title));bytes memory prefix=bytes("data:application/json;base64,");assert(keccak256(_sub(uri,0,prefix.length))==keccak256(prefix));
        bytes memory json=_decode(_sub(uri,prefix.length,uri.length-prefix.length));assert(json[0]==0x7b&&json[json.length-1]==0x7d);
        _find(json,abi.encodePacked('"name": "AlchemistV3 Position #',Strings.toString(id),'"'),0);
        bytes memory marker=bytes('"image": "data:image/svg+xml;base64,');uint256 imageStart=_find(json,marker,0)+marker.length;uint256 imageEnd=_find(json,bytes('"'),imageStart);
        assert(keccak256(_decode(_sub(json,imageStart,imageEnd-imageStart)))==keccak256(svg));
        assert(keccak256(_decode(bytes(h.json(id,string(svg)))))==keccak256(json));
    }
    /// @notice NFT-SVG,NFT-JSON,TR-METADATA: decoded URI preserves ID, title, line widths, JSON fields and SVG.
    /// @dev Technique: T17 independent Base64 decoder and SVG text reconstruction. Classification: FUZZ. All uint256 IDs, fixed production title.
    function test_fuzz_metadata(uint256 id)public view{_check(id,"Transmuter V3 Position");}
    /// @notice NFT-SVG,NFT-JSON: zero and maximum IDs cover all decimal line boundaries.
    /// @dev Technique: exact boundary outputs. Classification: FUZZ. Concrete regression, no symbolic safety claim.
    function test_check_metadataBoundaries()public view{_check(0,"Transmuter V3 Position");_check(type(uint256).max,"Alchemist V3 Position");}
}
