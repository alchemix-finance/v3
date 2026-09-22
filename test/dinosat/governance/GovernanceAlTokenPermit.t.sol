// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceAlTokenFixture} from "./GovernanceAlTokenAccess.t.sol";

contract GovernanceAlTokenPermit is GovernanceAlTokenFixture {
    bytes32 internal constant PERMIT_TYPEHASH=keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    function _digest(address owner,uint256 value,uint256 nonce,uint256 deadline,bytes32 domain) internal pure returns(bytes32) {
        return keccak256(abi.encodePacked(hex"1901",domain,keccak256(abi.encode(PERMIT_TYPEHASH,owner,BOB,value,nonce,deadline))));
    }
    /// @custom:property ALT-PERMIT
    /// @custom:classification FUZZ: actual ecrecover with constructed valid signature and independent EIP712 domain oracle.
    function test_fuzz_validPermitAndReplay(uint256 value) public {
        address signer=vm.addr(0xA11CE); uint256 deadline=block.timestamp+1 days;
        bytes32 domain=keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),keccak256("Alchemic"),keccak256("1"),block.chainid,address(token)));
        assert(token.DOMAIN_SEPARATOR()==domain);
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(0xA11CE,_digest(signer,value,0,deadline,domain));
        token.permit(signer,BOB,value,deadline,v,r,s);
        assert(token.allowance(signer,BOB)==value && token.nonces(signer)==1 && token.totalSupply()==0);
        assert(token.allowance(signer,ALICE)==0);
        _reject(address(token),OUTSIDER,abi.encodeCall(token.permit,(signer,BOB,value,deadline,v,r,s)),_error("ERC20Permit: invalid signature"));
        assert(token.allowance(signer,BOB)==value && token.nonces(signer)==1);
    }
    /// @custom:property ALT-PERMIT
    /// @custom:classification FUZZ: wrong signer, value, domain and chain; no nonce consumed on rejection.
    function test_fuzz_invalidPermit(uint256 value,uint8 modeRaw) public {
        uint8 mode=modeRaw%4; address signer=vm.addr(0xA11CE); uint256 deadline=block.timestamp+1 days;
        bytes32 domain=mode==2 ? bytes32(uint256(123)) : token.DOMAIN_SEPARATOR();
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(mode==0 ? 0xB0B : 0xA11CE,_digest(signer,value,0,deadline,domain));
        if(mode==3) vm.chainId(block.chainid ^ 1);
        uint256 submitted=mode==1 ? value ^ 1 : value;
        _reject(address(token),OUTSIDER,abi.encodeCall(token.permit,(signer,BOB,submitted,deadline,v,r,s)),_error("ERC20Permit: invalid signature"));
        assert(token.allowance(signer,BOB)==0 && token.nonces(signer)==0 && token.totalSupply()==0);
    }
    /// @custom:property ALT-PERMIT
    /// @custom:classification DIRECT: expiry and high-s reject before cryptographic recovery.
    function test_check_expiredAndHighS(uint256 value) public {
        _reject(address(token),OUTSIDER,abi.encodeCall(token.permit,(ALICE,BOB,value,uint256(99),uint8(27),bytes32(0),bytes32(0))),_error("ERC20Permit: expired deadline"));
        assert(token.nonces(ALICE)==0 && token.allowance(ALICE,BOB)==0);
        _reject(address(token),OUTSIDER,abi.encodeCall(token.permit,(ALICE,BOB,value,uint256(100),uint8(27),bytes32(0),bytes32(type(uint256).max))),_error("ECDSA: invalid signature 's' value"));
        assert(token.nonces(ALICE)==0 && token.allowance(ALICE,BOB)==0);
    }

    /// @custom:property ALT-PERMIT
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_expiredAndHighS(uint256 value) public { test_check_expiredAndHighS(value); }
}
