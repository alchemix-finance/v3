// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {RouterFixture} from "./AlchemistRouterSymbolic.t.sol";
import {CoreAlchemistHarness,ERC1967Proxy,AlchemistV3,AlchemistRouter,AlchemistV3Position} from "../common/CoreFixture.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract RouterETHActor {
    address public target; bytes public nested; bool public rejectETH; bytes4 public rejection; bool public attempted;
    function configure(address target_,bytes calldata data,bool reject_) external {target=target_;nested=data;rejectETH=reject_;}
    function invoke(address receiver,bytes calldata data,uint256 value) external returns(bytes memory result) {
        (bool ok,bytes memory r)=receiver.call{value:value}(data); require(ok); return r;
    }
    receive() external payable {
        require(!rejectETH); attempted=true;
        (bool ok,bytes memory r)=target.call(nested); require(!ok); if(r.length>=4) rejection=bytes4(r);
    }
}
contract RouterCallbackNFT is AlchemistV3Position {
    address public target; bytes public nested; bytes4 public rejection; bool public attempted;
    constructor(address alc,address admin_) AlchemistV3Position(alc,admin_) {}
    function configure(address target_,bytes calldata data) external {target=target_;nested=data;}
    function transferFrom(address from,address to,uint256 id) public override(ERC721,IERC721) {
        super.transferFrom(from,to,id);
        if(target!=address(0)) {attempted=true;(bool ok,bytes memory r)=target.call(nested);require(!ok); if(r.length>=4) rejection=bytes4(r);}
    }
}
contract AlchemistRouterCallbacksSymbolic is RouterFixture {
    bytes4 internal constant GUARD=bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    /// @custom:property ROUTER-REENTRY
    /// @notice ROUTER-REENTRY: check vault callback and guard reset.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_vaultCallbackAndGuardReset() public {
        vault.setCallback(address(router),abi.encodeCall(AlchemistRouter.depositMYT,(0,1,0,block.timestamp)));
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,100,block.timestamp)));
        assert(vault.callbackAttempted() && !vault.callbackSucceeded() && vault.callbackError()==GUARD);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,100,block.timestamp)));
        assert(alc.getTotalDeposited()==200 && nft.ownerOf(2)==ALICE);
    }
    /// @custom:property ROUTER-REENTRY
    /// @notice ROUTER-REENTRY: check token callback.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_tokenCallback() public {
        asset.setCallback(address(router),abi.encodeCall(AlchemistRouter.repayUnderlying,(1,1,0,block.timestamp)));
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,100,block.timestamp)));
        assert(asset.callbackAttempted() && asset.callbackError()==GUARD && alc.getTotalDeposited()==100);
    }
    /// @custom:property ROUTER-REENTRY
    /// @notice ROUTER-REENTRY: check nft callback.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_nftCallback() public {
        CoreAlchemistHarness implementation=new CoreAlchemistHarness();
        alc=CoreAlchemistHarness(address(new ERC1967Proxy(address(implementation),abi.encodeCall(AlchemistV3.initialize,(_params(address(asset),address(debt),address(vault),address(trans)))))));
        RouterCallbackNFT hostile=new RouterCallbackNFT(address(alc),address(this)); nft=hostile;
        _ok(address(alc),abi.encodeCall(AlchemistV3.setAlchemistPositionNFT,(address(nft)))); router=new AlchemistRouter(address(alc));
        vm.prank(ALICE); asset.approve(address(router),type(uint256).max);
        hostile.configure(address(router),abi.encodeCall(AlchemistRouter.withdrawUnderlying,(1,1,0,block.timestamp)));
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,100,block.timestamp)));
        assert(hostile.attempted() && hostile.rejection()==GUARD && nft.ownerOf(1)==ALICE);
    }
    /// @custom:property ROUTER-REENTRY ROUTER-WITHDRAW
    /// @notice ROUTER-WITHDRAW, ROUTER-REENTRY: check eth callback.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_ethCallback(bool reject_) public {
        RouterETHActor actor=new RouterETHActor(); vm.deal(address(actor),1000);
        actor.configure(address(router),abi.encodeCall(AlchemistRouter.depositMYT,(0,1,0,block.timestamp)),reject_);
        _ok(address(actor),abi.encodeCall(RouterETHActor.invoke,(address(router),abi.encodeCall(AlchemistRouter.depositETH,(0,0,100,block.timestamp)),100)));
        _ok(address(actor),abi.encodeCall(RouterETHActor.invoke,(address(nft),abi.encodeWithSignature("approve(address,uint256)",address(router),1),0)));
        bytes memory data=abi.encodeCall(RouterETHActor.invoke,(address(router),abi.encodeCall(AlchemistRouter.withdrawETH,(1,100,100,block.timestamp)),0));
        (bool ok,)=address(actor).call(data); assert(ok==!reject_);
        assert(nft.ownerOf(1)==address(actor));
        if(!reject_) {assert(actor.attempted() && actor.rejection()==GUARD && address(actor).balance==1000); _checkCDP(1,0,0,0);}
        else {_checkCDP(1,100,0,0); assert(address(actor).balance==900);}
    }
    /// @notice ROUTER-WITHDRAW, ROUTER-REENTRY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_ethCallback(bool reject_) public { test_check_ethCallback(reject_); }

    /// @custom:property ROUTER-REENTRY
    /// @notice ROUTER-REENTRY: check all entries guarded.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_allEntriesGuarded(uint8 which) public {
        uint256 k=uint256(which)%11; bytes memory data;
        if(k==0) data=abi.encodeCall(AlchemistRouter.depositUnderlying,(0,1,0,0,block.timestamp));
        if(k==1) data=abi.encodeCall(AlchemistRouter.depositETH,(0,0,0,block.timestamp));
        if(k==2) data=abi.encodeCall(AlchemistRouter.depositMYT,(0,1,0,block.timestamp));
        if(k==3) data=abi.encodeCall(AlchemistRouter.depositETHToVaultOnly,(0,block.timestamp));
        if(k==4) data=abi.encodeCall(AlchemistRouter.repayUnderlying,(1,1,0,block.timestamp));
        if(k==5) data=abi.encodeCall(AlchemistRouter.repayETH,(1,0,block.timestamp));
        if(k==6) data=abi.encodeCall(AlchemistRouter.withdrawUnderlying,(1,1,0,block.timestamp));
        if(k==7) data=abi.encodeCall(AlchemistRouter.withdrawETH,(1,1,0,block.timestamp));
        if(k==8) data=abi.encodeCall(AlchemistRouter.selfLiquidateToUnderlying,(1,0,block.timestamp));
        if(k==9) data=abi.encodeCall(AlchemistRouter.selfLiquidateToETH,(1,0,block.timestamp));
        if(k==10) data=abi.encodeCall(AlchemistRouter.claimRedemption,(1,0,block.timestamp,false));
        vault.setCallback(address(router),data);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,100,block.timestamp)));
        assert(vault.callbackAttempted() && !vault.callbackSucceeded() && vault.callbackError()==GUARD);
    }
    /// @notice ROUTER-REENTRY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_allEntriesGuarded(uint8 which) public { test_check_allEntriesGuarded(which); }

}
