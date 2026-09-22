// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceTestBase} from "./GovernanceFixtures.sol";
import {AlchemistV3Position} from "src/AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "src/AlchemistV3PositionRenderer.sol";

contract GovernanceAlchemistCallback {
    uint256 public calls;
    uint256 public lastId;
    bool public fail;
    function setFail(bool value) external { fail=value; }
    function resetMintAllowances(uint256 id) external { require(!fail,"reset failed"); calls++; lastId=id; }
}
contract GovernanceNFTReceiver {
    uint8 public mode;
    bytes public received;
    function configure(uint8 value) external { mode=value; }
    function onERC721Received(address, address, uint256, bytes calldata data) external returns(bytes4) {
        require(mode != 2,"NFT receiver failed"); received=data;
        return mode==1 ? bytes4(0) : this.onERC721Received.selector;
    }
}
contract GovernanceRendererStub {
    function tokenURI(uint256) external pure returns(string memory) { return "stub metadata"; }
}
abstract contract GovernancePositionFixture is GovernanceTestBase {
    GovernanceAlchemistCallback internal core;
    AlchemistV3Position internal subject;
    function setUp() public virtual { core=new GovernanceAlchemistCallback(); subject=new AlchemistV3Position(address(core),ADMIN); }
    function _mint(address owner) internal returns(uint256 id) { vm.prank(address(core)); id=subject.mint(owner); }
}
contract GovernancePositionAccess is GovernancePositionFixture {
    /// @custom:property AlchemistV3Position-AC-01 AlchemistV3Position-AC-02 POS-ADMIN
    /// @custom:classification DIRECT: admin guard, old admin revocation and accepted zero values.
    function test_check_admin() public {
        _reject(address(subject),OUTSIDER,abi.encodeCall(subject.setMetadataRenderer,(BOB)),abi.encodeWithSignature("CallerNotAdmin()"));
        _reject(address(subject),OUTSIDER,abi.encodeCall(subject.setAdmin,(BOB)),abi.encodeWithSignature("CallerNotAdmin()"));
        assert(subject.admin()==ADMIN && subject.metadataRenderer()==address(0));
        vm.prank(ADMIN); subject.setMetadataRenderer(BOB); assert(subject.metadataRenderer()==BOB);
        vm.prank(ADMIN); subject.setAdmin(ALICE);
        _reject(address(subject),ADMIN,abi.encodeCall(subject.setMetadataRenderer,(BOB)),abi.encodeWithSignature("CallerNotAdmin()"));
        vm.prank(ALICE); subject.setMetadataRenderer(address(0));
        vm.prank(ALICE); subject.setAdmin(address(0));
        assert(subject.admin()==address(0) && subject.metadataRenderer()==address(0));
    }
    /// @custom:property AlchemistV3Position-AC-03 AlchemistV3Position-AC-04 POS-MINT POS-BURN
    /// @custom:classification DIRECT: implementation mint/burn guards and authorized controls.
    function test_check_mintBurnGuard() public {
        _reject(address(subject),OUTSIDER,abi.encodeCall(subject.mint,(ALICE)),abi.encodeWithSignature("CallerNotAlchemist()"));
        assert(subject.totalSupply()==0);
        uint256 id=_mint(ALICE);
        _reject(address(subject),OUTSIDER,abi.encodeCall(subject.burn,(id)),abi.encodeWithSignature("CallerNotAlchemist()"));
        assert(subject.ownerOf(id)==ALICE && subject.totalSupply()==1 && core.calls()==0);
        vm.prank(address(core)); subject.burn(id);
        assert(subject.totalSupply()==0 && subject.balanceOf(ALICE)==0 && core.calls()==1);
    }
    /// @custom:property AlchemistV3Position-AC-05 POS-APPROVAL
    /// @custom:classification ENUMERATE: owner, all-token operator, token-only approval and outsider branches.
    function test_check_approval() public {
        uint256 id=_mint(ALICE);
        _reject(address(subject),OUTSIDER,abi.encodeCall(subject.approve,(BOB,id)),abi.encodeWithSignature("ERC721InvalidApprover(address)",OUTSIDER));
        assert(subject.getApproved(id)==address(0) && subject.ownerOf(id)==ALICE);
        vm.prank(ALICE); subject.approve(BOB,id);
        _reject(address(subject),BOB,abi.encodeCall(subject.approve,(OUTSIDER,id)),abi.encodeWithSignature("ERC721InvalidApprover(address)",BOB));
        vm.prank(ALICE); subject.setApprovalForAll(OPERATOR,true);
        vm.prank(OPERATOR); subject.approve(OUTSIDER,id);
        assert(subject.getApproved(id)==OUTSIDER && subject.isApprovedForAll(ALICE,OPERATOR));
        assert(!subject.isApprovedForAll(BOB,OPERATOR) && subject.ownerOf(id)==ALICE && core.calls()==0);
        _reject(address(subject),ALICE,abi.encodeCall(subject.setApprovalForAll,(address(0),true)),abi.encodeWithSignature("ERC721InvalidOperator(address)",address(0)));
        vm.prank(ALICE); subject.setApprovalForAll(OPERATOR,false);
        assert(!subject.isApprovedForAll(ALICE,OPERATOR));
    }
    /// @custom:property AlchemistV3Position-AC-06 AlchemistV3Position-AC-07 AlchemistV3Position-AC-08 POS-TRANSFER
    /// @custom:classification ENUMERATE: actual three transfer overloads, callback rollback and authorized controls.
    function test_check_transferGuards(uint8 raw) public {
        uint256 id=_mint(ALICE); uint8 mode=raw % 3;
        bytes memory data=mode==0 ? abi.encodeWithSignature("transferFrom(address,address,uint256)",ALICE,BOB,id) : mode==1 ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)",ALICE,BOB,id) : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)",ALICE,BOB,id,hex"1234");
        _reject(address(subject),OUTSIDER,data,abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)",OUTSIDER,id));
        assert(subject.ownerOf(id)==ALICE && core.calls()==0);
        _success(address(subject),ALICE,data);
        assert(subject.ownerOf(id)==BOB && core.calls()==1 && core.lastId()==id);
    }
    /// @custom:property POS-METADATA
    /// @custom:classification ENUMERATE: existence/renderer failures and concrete metadata/interface IDs.
    function test_check_metadata() public {
        _reject(address(subject),ALICE,abi.encodeCall(subject.tokenURI,(uint256(1))),abi.encodeWithSignature("ERC721NonexistentToken(uint256)",uint256(1)));
        _mint(ALICE);
        _reject(address(subject),ALICE,abi.encodeCall(subject.tokenURI,(uint256(1))),abi.encodeWithSignature("MetadataRendererNotSet()"));
        GovernanceRendererStub renderer=new GovernanceRendererStub();
        vm.prank(ADMIN); subject.setMetadataRenderer(address(renderer));
        assert(keccak256(bytes(subject.tokenURI(1)))==keccak256("stub metadata"));
        assert(keccak256(bytes(subject.name()))==keccak256("AlchemistV3Position"));
        assert(keccak256(bytes(subject.symbol()))==keccak256("ALCV3"));
        assert(subject.supportsInterface(0x01ffc9a7) && subject.supportsInterface(0x80ac58cd) && subject.supportsInterface(0x5b5e139f) && subject.supportsInterface(0x780e9d63));
        assert(!subject.supportsInterface(0xffffffff));
    }

    /// @custom:property AlchemistV3Position-AC-01 AlchemistV3Position-AC-02 POS-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_admin() public { test_check_admin(); }
    /// @custom:property AlchemistV3Position-AC-03 AlchemistV3Position-AC-04 POS-MINT POS-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_mintBurnGuard() public { test_check_mintBurnGuard(); }
    /// @custom:property AlchemistV3Position-AC-05 POS-APPROVAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_approval() public { test_check_approval(); }
    /// @custom:property AlchemistV3Position-AC-06 AlchemistV3Position-AC-07 AlchemistV3Position-AC-08 POS-TRANSFER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_transferGuards(uint8 raw) public { test_check_transferGuards(raw); }
    /// @custom:property POS-METADATA
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_metadata() public { test_check_metadata(); }
}
contract GovernancePositionState is GovernancePositionFixture {
    /// @custom:property POS-MINT
    /// @custom:classification ENUMERATE: three-token history and compiler-confirmed private counter slot 12 boundary.
    function test_check_mintHistoryAndOverflow() public {
        assert(_mint(ALICE)==1 && _mint(ALICE)==2 && _mint(BOB)==3);
        assert(subject.balanceOf(ALICE)==2 && subject.balanceOf(BOB)==1 && subject.totalSupply()==3 && core.calls()==0);
        _reject(address(subject),address(core),abi.encodeCall(subject.mint,(address(0))),abi.encodeWithSignature("MintToZeroAddressError()"));
        // Source storageLayout in out-halmos/AlchemistV3Position.sol/AlchemistV3Position.json pins this boundary fixture.
        vm.store(address(subject),bytes32(uint256(12)),bytes32(type(uint256).max));
        _reject(address(subject),address(core),abi.encodeCall(subject.mint,(ALICE)),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(subject.totalSupply()==3 && subject.balanceOf(ALICE)==2 && core.calls()==0);
        try new AlchemistV3Position(address(0),ADMIN) { assert(false); } catch(bytes memory reason) { assert(keccak256(reason)==keccak256(abi.encodeWithSignature("AlchemistZeroAddressError()"))); }
    }
    /// @custom:property POS-BURN
    /// @custom:classification DECOMPOSE: last/non-last token swap-and-pop, with fixed history of three.
    function test_check_burnEnumeration(bool last) public {
        _mint(ALICE); _mint(ALICE); _mint(ALICE);
        uint256 id=last ? 3 : 1;
        vm.prank(ALICE); subject.approve(BOB,id);
        core.setFail(true);
        _reject(address(subject),address(core),abi.encodeCall(subject.burn,(id)),_error("reset failed"));
        assert(subject.ownerOf(id)==ALICE && subject.getApproved(id)==BOB && subject.totalSupply()==3 && core.calls()==0);
        core.setFail(false); vm.prank(address(core)); subject.burn(id);
        assert(subject.balanceOf(ALICE)==2 && subject.totalSupply()==2 && core.calls()==1);
        assert(subject.tokenByIndex(0)==(last ? 1 : 3) && subject.tokenByIndex(1)==2);
        assert(subject.tokenOfOwnerByIndex(ALICE,0)==(last ? 1 : 3) && subject.tokenOfOwnerByIndex(ALICE,1)==2);
        _reject(address(subject),ALICE,abi.encodeCall(subject.ownerOf,(id)),abi.encodeWithSignature("ERC721NonexistentToken(uint256)",id));
        _reject(address(subject),ALICE,abi.encodeCall(subject.getApproved,(id)),abi.encodeWithSignature("ERC721NonexistentToken(uint256)",id));
        _reject(address(subject),address(core),abi.encodeCall(subject.burn,(id)),abi.encodeWithSignature("ERC721NonexistentToken(uint256)",id));
        _reject(address(subject),ALICE,abi.encodeCall(subject.tokenByIndex,(uint256(2))),abi.encodeWithSignature("ERC721OutOfBoundsIndex(address,uint256)",address(0),uint256(2)));
        _reject(address(subject),ALICE,abi.encodeCall(subject.tokenOfOwnerByIndex,(ALICE,uint256(2))),abi.encodeWithSignature("ERC721OutOfBoundsIndex(address,uint256)",ALICE,uint256(2)));
    }
    /// @custom:property POS-TRANSFER POS-APPROVAL
    /// @custom:classification DECOMPOSE: owner/token-approved/operator and self-transfer with three NFTs.
    function test_check_transferEnumeration(uint8 actorRaw, bool self) public {
        _mint(ALICE); _mint(ALICE); _mint(BOB);
        vm.prank(ALICE); subject.approve(OUTSIDER,1);
        vm.prank(ALICE); subject.setApprovalForAll(OPERATOR,true);
        address actor=actorRaw % 3==0 ? ALICE : actorRaw % 3==1 ? OUTSIDER : OPERATOR;
        address recipient=self ? ALICE : BOB;
        vm.prank(actor); subject.transferFrom(ALICE,recipient,1);
        assert(subject.ownerOf(1)==recipient && subject.totalSupply()==3 && subject.getApproved(1)==address(0));
        assert(subject.balanceOf(ALICE)==(self ? 2 : 1) && subject.balanceOf(BOB)==(self ? 1 : 2));
        assert(subject.tokenOfOwnerByIndex(ALICE,0)==(self ? 1 : 2));
        assert(subject.tokenByIndex(0)==1 && subject.tokenByIndex(1)==2 && subject.tokenByIndex(2)==3);
        assert(core.calls()==1 && core.lastId()==1);
    }
    /// @custom:property POS-TRANSFER
    /// @custom:classification ENUMERATE: safe receiver accepts/rejects/reverts, transfer precondition failures.
    function test_check_safeReceiver(uint8 raw, bytes32 payload) public {
        _mint(ALICE); GovernanceNFTReceiver receiver=new GovernanceNFTReceiver(); uint8 mode=raw % 3; receiver.configure(mode);
        bytes memory data=abi.encode(payload);
        vm.prank(ALICE); (bool ok,bytes memory reason)=address(subject).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)",ALICE,address(receiver),uint256(1),data));
        assert(ok==(mode==0));
        if(ok) { assert(subject.ownerOf(1)==address(receiver) && core.calls()==1 && keccak256(receiver.received())==keccak256(data)); }
        else {
            assert(subject.ownerOf(1)==ALICE && core.calls()==0 && receiver.received().length==0);
            bytes memory expected=mode==1 ? abi.encodeWithSignature("ERC721InvalidReceiver(address)",address(receiver)) : _error("NFT receiver failed");
            assert(keccak256(reason)==keccak256(expected));
        }
    }
    /// @custom:property POS-TRANSFER POS-BURN
    /// @custom:classification ENUMERATE: zero recipient, wrong from, missing token and zero balance query.
    function test_check_invalidTransfers() public {
        _mint(ALICE);
        _reject(address(subject),ALICE,abi.encodeWithSignature("transferFrom(address,address,uint256)",ALICE,address(0),uint256(1)),abi.encodeWithSignature("ERC721InvalidReceiver(address)",address(0)));
        _reject(address(subject),ALICE,abi.encodeWithSignature("transferFrom(address,address,uint256)",BOB,OUTSIDER,uint256(1)),abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)",BOB,uint256(1),ALICE));
        _reject(address(subject),ALICE,abi.encodeWithSignature("transferFrom(address,address,uint256)",ALICE,BOB,uint256(2)),abi.encodeWithSignature("ERC721NonexistentToken(uint256)",uint256(2)));
        _reject(address(subject),ALICE,abi.encodeCall(subject.balanceOf,(address(0))),abi.encodeWithSignature("ERC721InvalidOwner(address)",address(0)));
        assert(subject.ownerOf(1)==ALICE && subject.totalSupply()==1 && core.calls()==0);
    }

    /// @custom:property POS-MINT
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_mintHistoryAndOverflow() public { test_check_mintHistoryAndOverflow(); }
    /// @custom:property POS-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_burnEnumeration(bool last) public { test_check_burnEnumeration(last); }
    /// @custom:property POS-TRANSFER POS-APPROVAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_transferEnumeration(uint8 actorRaw, bool self) public { test_check_transferEnumeration(actorRaw, self); }
    /// @custom:property POS-TRANSFER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_safeReceiver(uint8 raw, bytes32 payload) public { test_check_safeReceiver(raw, payload); }
    /// @custom:property POS-TRANSFER POS-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_invalidTransfers() public { test_check_invalidTransfers(); }
}

contract GovernancePositionRenderer is GovernanceTestBase {
    AlchemistV3PositionRenderer internal renderer;
    function setUp() public { renderer=new AlchemistV3PositionRenderer(); }
    function _suffix(bytes memory input, bytes memory prefix) internal pure returns(bytes memory result) {
        assert(input.length>=prefix.length); for(uint256 i;i<prefix.length;i++) assert(input[i]==prefix[i]);
        result=new bytes(input.length-prefix.length); for(uint256 i;i<result.length;i++) result[i]=input[i+prefix.length];
    }
    function _value(bytes1 c) internal pure returns(uint256) {
        uint8 n=uint8(c);
        if(n>=65 && n<=90) return n-65;
        if(n>=97 && n<=122) return n-71;
        if(n>=48 && n<=57) return n+4;
        if(n==43) return 62;
        if(n==47) return 63;
        assert(c=="="); return 0;
    }
    function _decode(bytes memory input) internal pure returns(bytes memory result) {
        assert(input.length>0 && input.length % 4==0);
        uint256 len=input.length/4*3;
        if(input[input.length-1]=="=") len--;
        if(input[input.length-2]=="=") len--;
        result=new bytes(len);
        for(uint256 i;i<input.length;i+=4) {
            uint256 n=(_value(input[i])<<18)|(_value(input[i+1])<<12)|(_value(input[i+2])<<6)|_value(input[i+3]);
            uint256 j=i/4*3; result[j]=bytes1(uint8(n>>16));
            if(j+1<len) result[j+1]=bytes1(uint8(n>>8)); if(j+2<len) result[j+2]=bytes1(uint8(n));
        }
    }
    function _contains(bytes memory haystack, bytes memory needle) internal pure returns(bool) {
        for(uint256 i;i+needle.length<=haystack.length;i++) {
            bool same=true; for(uint256 j;j<needle.length;j++) if(haystack[i+j]!=needle[j]) { same=false; break; }
            if(same) return true;
        } return false;
    }
    /// @custom:property RENDER-URI
    /// @custom:classification FUZZ: independent Base64 decoder, JSON parser and vm.toString decimal oracle.
    function test_fuzz_render(uint256 id) public {
        string memory json=string(_decode(_suffix(bytes(renderer.tokenURI(id)),bytes("data:application/json;base64,"))));
        assert(keccak256(bytes(vm.parseJsonString(json,".name")))==keccak256(bytes(string.concat("AlchemistV3 Position #",vm.toString(id)))));
        assert(keccak256(bytes(vm.parseJsonString(json,".description")))==keccak256("Position token for Alchemist V3"));
        bytes memory svg=_decode(_suffix(bytes(vm.parseJsonString(json,".image")),bytes("data:image/svg+xml;base64,")));
        assert(_contains(svg,bytes("<svg xmlns=\"http://www.w3.org/2000/svg\"")) && _contains(svg,bytes("Alchemist V3 Position</text>")) && _contains(svg,bytes("</svg>")));
        bytes memory digits=bytes(string.concat("#",vm.toString(id)));
        for(uint256 start;start<digits.length;start+=25) {
            uint256 len=digits.length-start<25 ? digits.length-start : 25;
            bytes memory line=new bytes(len); for(uint256 j;j<len;j++) line[j]=digits[start+j];
            bytes memory prefix=start==0 ? bytes('<tspan x="250">') : bytes('<tspan x="250" dy="22">');
            assert(_contains(svg,abi.encodePacked(prefix,line,"</tspan>")));
        }
    }
    /// @custom:property RENDER-URI
    /// @custom:classification FUZZ: pinned decimal-width and uint256 boundary regression cases.
    function test_fuzz_renderBoundaries() public {
        test_fuzz_render(0); test_fuzz_render(9); test_fuzz_render(10); test_fuzz_render(10**24-1); test_fuzz_render(10**24); test_fuzz_render(10**49); test_fuzz_render(10**74); test_fuzz_render(type(uint256).max);
    }
}
