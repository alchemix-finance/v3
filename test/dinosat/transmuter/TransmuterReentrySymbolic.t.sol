// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "../libraries/DinosatAssertions.sol";
import {Transmuter} from "../../../src/Transmuter.sol";
import {ITransmuter} from "../../../src/interfaces/ITransmuter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DinosatTransmuterToken,DinosatAlchemistMock} from "./TransmuterSymbolic.t.sol";
contract DinosatReentrantSynthetic is ERC20 {
    Transmuter public target;uint256 public nestedAmount;bool public armed;
    constructor()ERC20("Callback synth","CS"){}
    function mint(address to,uint256 n)external{_mint(to,n);}
    function burn(uint256 n)external{_burn(msg.sender,n);}
    function arm(Transmuter t,uint256 n)external{target=t;nestedAmount=n;armed=true;_mint(address(this),n);_approve(address(this),address(t),n);}
    function transferFrom(address from,address to,uint256 n)public override returns(bool){bool result=super.transferFrom(from,to,n);if(armed){armed=false;target.createRedemption(nestedAmount,address(this));}return result;}
}
contract DinosatTransmuterReentryCounterexampleTest is DinosatAssertions {
    /// @notice TR-REENTRY: a synthetic callback must not bypass the configured active deposit cap.
    /// @dev Technique: one callback through real Transmuter. Classification: FUZZ. Expected counterexample under a malicious-token assumption.
    function test_check_callbackDepositCap() public {
        vm.roll(10);DinosatReentrantSynthetic synth=new DinosatReentrantSynthetic();DinosatTransmuterToken shares=new DinosatTransmuterToken(18);
        DinosatAlchemistMock al=new DinosatAlchemistMock(address(shares),address(synth));
        Transmuter t=new Transmuter(ITransmuter.TransmuterInitializationParams(address(synth),address(0xFEE),4,0,0,0));
        t.setAlchemist(address(al));t.setDepositCap(100);al.configure(address(t),1000,1000,type(uint256).max);
        synth.mint(address(this),100);synth.approve(address(t),100);synth.arm(t,100);t.createRedemption(100,address(this));
        assert(t.totalActiveLocked()<=t.depositCap());
    }
}

contract DinosatClaimCallbackActor {
    Transmuter public target;bool public attempted;bool public nestedSucceeded;bytes public nestedError;
    function configure(Transmuter t) external {target=t;}
    function claim() external {target.claimRedemption(1);}
    function attempt() external {attempted=true;(nestedSucceeded,nestedError)=address(target).call(abi.encodeCall(target.claimRedemption,(1)));}
}
contract DinosatClaimCallbackToken is ERC20 {
    DinosatClaimCallbackActor public actor;uint8 public mode;bool internal armed;
    constructor() ERC20("Callback settlement token","CST") {}
    function mint(address to,uint256 n) external {_mint(to,n);}
    function arm(DinosatClaimCallbackActor a,uint8 m) external {actor=a;mode=m;armed=true;}
    function transfer(address to,uint256 n) public override returns(bool){bool ok=super.transfer(to,n);if(armed&&mode==1){armed=false;actor.attempt();}return ok;}
    function burn(uint256 n) external {_burn(msg.sender,n);if(armed&&mode==2){armed=false;actor.attempt();}}
}
contract DinosatClaimCallbackAlchemist {
    address public myt;address public underlyingToken;address public transmuter;uint256 public totalSyntheticsIssued=1000;uint256 public reduced;uint256 public lastBalance;
    DinosatClaimCallbackActor public actor;uint8 public mode;bool internal armed;
    constructor(address shares,address synth){myt=shares;underlyingToken=synth;}
    function arm(address t,DinosatClaimCallbackActor a,uint8 m) external {transmuter=t;actor=a;mode=m;armed=true;}
    function _callback(uint8 expected) internal {if(armed&&mode==expected){armed=false;actor.attempt();}}
    function getTotalLockedUnderlyingValue() external pure returns(uint256){return 1000;}
    function convertYieldTokensToUnderlying(uint256 n) external pure returns(uint256){return n;}
    function convertYieldTokensToDebt(uint256 n) external pure returns(uint256){return n;}
    function convertDebtTokensToYield(uint256 n) external pure returns(uint256){return n;}
    function redeem(uint256 n) external returns(uint256){require(msg.sender==transmuter);_callback(3);DinosatClaimCallbackToken(myt).mint(msg.sender,n);return n;}
    function reduceSyntheticsIssued(uint256 n) external {require(msg.sender==transmuter);_callback(4);totalSyntheticsIssued-=n;reduced+=n;}
    function setTransmuterTokenBalance(uint256 n) external {require(msg.sender==transmuter);_callback(5);lastBalance=n;}
}
contract DinosatTransmuterClaimCallbackSymbolicTest is DinosatAssertions {
    /// @notice TR-REENTRY,TR-CLAIM-GATES: burning the NFT before settlement blocks a second claim during each mutating dependency callback.
    /// @dev Technique: five concrete callback locations, actual Transmuter bytecode. Classification: ENUMERATE. Covers the same NFT only; no cross-position safety claim.
    function test_check_samePositionCallbacks(uint8 rawMode) public {
        uint8 mode=1+rawMode%5;vm.roll(10);DinosatClaimCallbackToken synth=new DinosatClaimCallbackToken();DinosatClaimCallbackToken shares=new DinosatClaimCallbackToken();DinosatClaimCallbackActor actor=new DinosatClaimCallbackActor();
        DinosatClaimCallbackAlchemist al=new DinosatClaimCallbackAlchemist(address(shares),address(synth));Transmuter t=new Transmuter(ITransmuter.TransmuterInitializationParams(address(synth),address(0xFEE),4,0,0,0));
        t.setAlchemist(address(al));t.setDepositCap(1000);actor.configure(t);al.arm(address(t),actor,mode);synth.mint(address(this),100);synth.approve(address(t),100);t.createRedemption(100,address(actor));
        if(mode==1)shares.arm(actor,mode);if(mode==2)synth.arm(actor,mode);vm.roll(14);actor.claim();
        assert(actor.attempted());assert(!actor.nestedSucceeded());assert(keccak256(actor.nestedError())==keccak256(abi.encodeWithSignature("ERC721NonexistentToken(uint256)",uint256(1))));
        assert(t.totalSupply()==0);assert(t.totalLocked()==0&&t.totalActiveLocked()==0);assert(shares.balanceOf(address(actor))==100);assert(synth.totalSupply()==0);assert(al.reduced()==100);assert(al.totalSyntheticsIssued()==900);assert(al.lastBalance()==0);
    }
}
