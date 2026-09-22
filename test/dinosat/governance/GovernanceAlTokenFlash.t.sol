// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceAlTokenFixture} from "./GovernanceAlTokenAccess.t.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "src/AlTokenV3.sol";
import {IERC3156FlashBorrower} from "lib/v2-foundry/lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";

contract GovernanceFlashReceiver is IERC3156FlashBorrower {
    CrossChainCanonicalAlchemicTokenV3 public token;
    uint8 public mode;
    uint256 public observedBalance;
    address public initiator;
    address public observedToken;
    uint256 public principal;
    uint256 public fee;
    bytes public data;
    bytes public nestedReason;
    bool public nestedSuccess;
    constructor(CrossChainCanonicalAlchemicTokenV3 asset) { token=asset; }
    function configure(uint8 value) external { mode=value; }
    function onFlashLoan(address caller,address asset,uint256 amount,uint256 charge,bytes calldata payload) external returns(bytes32) {
        require(msg.sender==address(token),"only token");
        observedBalance=token.balanceOf(address(this)); initiator=caller; observedToken=asset; principal=amount; fee=charge; data=payload;
        if(mode==1) return bytes32(0);
        if(mode==2) revert("borrower failed");
        if(mode==3) { (nestedSuccess,nestedReason)=address(token).call(abi.encodeCall(token.flashLoan,(IERC3156FlashBorrower(address(this)),address(token),uint256(0),bytes("")))); }
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
contract GovernanceAlTokenFlash is GovernanceAlTokenFixture {
    /// @custom:property ALT-FLASHFEE
    /// @custom:classification DECOMPOSE: fee in [0,9999], amount uint96 bounds multiplication; explicit overflow branch.
    function test_check_flashFee(uint96 amount,uint16 feeRaw) public {
        uint256 fee=uint256(feeRaw)%10000;
        vm.prank(ADMIN); token.setFlashFee(fee); vm.prank(ADMIN); token.setMaxFlashLoan(amount);
        assert(token.flashMintFee()==fee && token.maxFlashLoan(address(token))==amount && token.maxFlashLoan(BOB)==0);
        uint256 charged=token.flashFee(address(token),amount);
        assert(charged*10000<=uint256(amount)*fee && uint256(amount)*fee<(charged+1)*10000);
        assert(amount==0 || charged<amount);
        _reject(address(token),ALICE,abi.encodeCall(token.flashFee,(BOB,uint256(amount))),abi.encodeWithSignature("IllegalArgument()"));
        _reject(address(token),ADMIN,abi.encodeCall(token.setFlashFee,(uint256(10000))),abi.encodeWithSignature("IllegalArgument()"));
        assert(token.flashMintFee()==fee);
        vm.prank(ADMIN); token.setFlashFee(2);
        _reject(address(token),ALICE,abi.encodeCall(token.flashFee,(address(token),type(uint256).max)),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
    }
    /// @custom:property ALT-FLASHLOAN
    /// @custom:classification DECOMPOSE: standard callback, explicit fee reserve, bounded principal and concrete payload width.
    function test_check_flashAccounting(uint96 raw,uint16 feeRaw,bytes32 payload,bool nested) public {
        uint256 amount=uint256(raw)+1; uint256 rate=uint256(feeRaw)%10000;
        GovernanceFlashReceiver receiver=new GovernanceFlashReceiver(token); receiver.configure(nested ? 3 : 0);
        vm.prank(ADMIN); token.setFlashFee(rate); vm.prank(ADMIN); token.setMaxFlashLoan(amount);
        uint256 fee=amount*rate/10000; _mint(address(receiver),fee);
        vm.prank(ALICE); bool ok=token.flashLoan(receiver,address(token),amount,abi.encode(payload)); assert(ok);
        assert(token.totalSupply()==0 && token.balanceOf(address(receiver))==0);
        assert(receiver.observedBalance()==amount+fee && receiver.initiator()==ALICE && receiver.observedToken()==address(token));
        assert(receiver.principal()==amount && receiver.fee()==fee && keccak256(receiver.data())==keccak256(abi.encode(payload)));
        if(nested) { assert(!receiver.nestedSuccess()); assert(keccak256(receiver.nestedReason())==keccak256(_error("ReentrancyGuard: reentrant call"))); }
    }
    /// @custom:property ALT-FLASHLOAN
    /// @custom:classification ENUMERATE: wrong token, cap, callback mismatch/revert, insufficient fee reserve; atomic rollback.
    function test_check_flashRejections(uint8 modeRaw) public {
        uint8 mode=modeRaw%3; GovernanceFlashReceiver receiver=new GovernanceFlashReceiver(token);
        vm.prank(ADMIN); token.setMaxFlashLoan(100); vm.prank(ADMIN); token.setFlashFee(1000);
        bytes memory valid=abi.encodeCall(token.flashLoan,(IERC3156FlashBorrower(address(receiver)),address(token),uint256(100),bytes("")));
        _reject(address(token),ALICE,abi.encodeCall(token.flashLoan,(IERC3156FlashBorrower(address(receiver)),BOB,uint256(100),bytes(""))),abi.encodeWithSignature("IllegalArgument()"));
        _reject(address(token),ALICE,abi.encodeCall(token.flashLoan,(IERC3156FlashBorrower(address(receiver)),address(token),uint256(101),bytes(""))),abi.encodeWithSignature("IllegalArgument()"));
        receiver.configure(mode);
        bytes memory expected=mode==0 ? _error("ERC20: burn amount exceeds balance") : mode==1 ? abi.encodeWithSignature("IllegalState()") : _error("borrower failed");
        _reject(address(token),ALICE,valid,expected);
        assert(token.totalSupply()==0 && token.balanceOf(address(receiver))==0 && receiver.observedBalance()==0);
        receiver.configure(0); _mint(address(receiver),10);
        _success(address(token),ALICE,valid); assert(token.totalSupply()==0);
    }

    /// @custom:property ALT-FLASHFEE
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_flashFee(uint96 amount,uint16 feeRaw) public { test_check_flashFee(amount, feeRaw); }
    /// @custom:property ALT-FLASHLOAN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_flashAccounting(uint96 raw,uint16 feeRaw,bytes32 payload,bool nested) public { test_check_flashAccounting(raw, feeRaw, payload, nested); }
    /// @custom:property ALT-FLASHLOAN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_flashRejections(uint8 modeRaw) public { test_check_flashRejections(modeRaw); }
}
