// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoBaseFlowTest is DinoBaseFixture {
    /// @notice STR-BASE-ALLOCATE. allocate direct.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_allocate_direct(uint64 raw,uint64 oldRaw) public {
        uint256 n=uint256(raw)+1;h.setValue(n+7);myt.setAllocation(strategy.adapterId(),oldRaw);int256 c=_allocate(IMYTStrategy.ActionType.direct,n,"");assert(c==int256(n+7)-int256(uint256(oldRaw)));assert(h.called()==1);
    }
    /// @notice Same property and domain as test_check_allocate_direct.
    function test_fuzz_allocate_direct(uint64 raw,uint64 oldRaw) public { test_check_allocate_direct(raw,oldRaw); }
    /// @notice STR-BASE-ALLOCATE. allocate swap.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_allocate_swap(uint64 raw) public {
        uint256 n=uint256(raw)+1;h.setValue(n);assert(_allocate(IMYTStrategy.ActionType.swap,n,"x")==int256(n));assert(h.called()==2);
    }
    /// @notice Same property and domain as test_check_allocate_swap.
    function test_fuzz_allocate_swap(uint64 raw) public { test_check_allocate_swap(raw); }
    /// @notice STR-BASE-DEALLOCATE. Enumerate all three actions through bounded modulo. Fake valuation hook isolates actual base accounting.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_deallocate_dispatch(uint64 raw,uint8 branch) public {
        uint256 n=uint256(raw)+1;IMYTStrategy.ActionType a=IMYTStrategy.ActionType(uint256(branch)%3);h.setValue(n+9);myt.setAllocation(strategy.adapterId(),12);
        vm.prank(address(myt));(,int256 c)=strategy.deallocate(_data(a,"",0),n,bytes4(0),address(this));assert(c==-3);assert(h.called()==uint256(a)+3);
    }
    /// @notice Same property and domain as test_check_deallocate_dispatch.
    function test_fuzz_deallocate_dispatch(uint64 raw,uint8 branch) public { test_check_deallocate_dispatch(raw,branch); }
    /// @notice STR-BASE-DEALLOCATE. inconsistent deallocation.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_inconsistent_deallocation() public {
        h.setValue(4);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),_revertString("inconsistent totalValue"));assert(h.called()==0);
    }
    /// @notice STR-BASE-FORCE. force optin.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_force_optin() public {
        h.setForce(false);_bad(address(h),abi.encodeCall(DinoBaseHarness.validate,(IMYTStrategy.ActionType.direct,bytes4(0xe4d38cd8))),abi.encodeWithSelector(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector));h.setForce(true);h.validate(IMYTStrategy.ActionType.direct,bytes4(0xe4d38cd8));assert(h.force());
    }
    /// @notice STR-BASE-PREVIEW, STR-BASE-REALASSETS. preview and value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_preview_and_value(uint64 raw) public {
        uint256 n=uint256(raw)+1;assert(strategy.previewAdjustedWithdraw(n)==n);h.setValue(n);assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_preview_and_value.
    function test_fuzz_preview_and_value(uint64 raw) public { test_check_preview_and_value(raw); }
    /// @notice STR-BASE-IDLE. idle guard.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_idle_guard(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(h),n);h.idle(address(asset),n);_bad(address(h),abi.encodeCall(DinoBaseHarness.idle,(address(asset),n+1)),abi.encodeWithSelector(IMYTStrategy.InsufficientBalance.selector,n+1,n));assert(asset.balanceOf(address(h))==n);
    }
    /// @notice Same property and domain as test_check_idle_guard.
    function test_fuzz_idle_guard(uint64 raw) public { test_check_idle_guard(raw); }
    /// @notice STR-BASE-SWAP. swap cleanup.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_swap_cleanup(uint64 raw,uint64 outRaw) public {
        uint256 n=uint256(raw)+1;uint256 out=uint256(outRaw)+1;asset.mint(address(h),n);uint256 got=h.swap(address(receipt),address(asset),n,out,_route(address(asset),address(receipt),n,out));assert(got==out);assert(receipt.balanceOf(address(h))==out);assert(asset.allowance(address(h),address(swapper))==0);assert(asset.balanceOf(address(h))==0);
    }
    /// @notice Same property and domain as test_check_swap_cleanup.
    function test_fuzz_swap_cleanup(uint64 raw,uint64 outRaw) public { test_check_swap_cleanup(raw,outRaw); }
    /// @notice STR-BASE-SWAP. swap rejects low output.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_swap_rejects_low_output(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(h),n);_bad(address(h),abi.encodeCall(DinoBaseHarness.swap,(address(receipt),address(asset),n,2,_route(address(asset),address(receipt),n,1))),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,2,1));assert(asset.balanceOf(address(h))==n);assert(asset.allowance(address(h),address(swapper))==0);
    }
    /// @notice Same property and domain as test_check_swap_rejects_low_output.
    function test_fuzz_swap_rejects_low_output(uint64 raw) public { test_check_swap_rejects_low_output(raw); }
    /// @notice STR-BASE-SWAP. swap rejects call failure.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_swap_rejects_call_failure() public {
        asset.mint(address(h),1);_bad(address(h),abi.encodeCall(DinoBaseHarness.swap,(address(receipt),address(asset),1,1,abi.encodeCall(DinoSwap.fail,()))),abi.encodeWithSelector(IMYTStrategy.CounterfeitSettler.selector,address(swapper)));assert(asset.balanceOf(address(h))==1);
    }
    /// @notice STR-BASE-RESCUE. rescue invalid.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_rescue_invalid() public {
        reward.mint(address(h),3);_bad(address(h),abi.encodeCall(MYTStrategy.rescueTokens,(address(reward),address(0),1)),_revertString("Invalid recipient"));_bad(address(h),abi.encodeCall(MYTStrategy.rescueTokens,(address(reward),ATTACKER,4)),_revertString("Insufficient balance"));assert(reward.balanceOf(address(h))==3);
    }
    /// @notice STR-BASE-QUEUE, STR-BASE-REWARDS, STR-BASE-REALASSETS, STR-BASE-PREVIEW. base noop hooks.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_base_noop_hooks() public {
        MYTStrategy plain=new MYTStrategy(address(myt),_params());assert(plain.realAssets()==0);assert(plain.claimWithdrawalQueue(1)==0);assert(plain.claimRewards(address(reward),"",0)==0);assert(plain.previewAdjustedWithdraw(1)==0);vm.prank(address(myt));_bad(address(plain),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));
    }
    function deployBase(address v,address owner,uint256 slippage) external returns(address){IMYTStrategy.StrategyParams memory p=_params();p.owner=owner;p.slippageBPS=slippage;return address(new MYTStrategy(v,p));}
    /// @notice STR-BASE-CONSTRUCT. constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployBase,(address(0),address(this),25)),"");_bad(address(this),abi.encodeCall(this.deployBase,(address(myt),address(this),5000)),"");_bad(address(this),abi.encodeCall(this.deployBase,(address(myt),address(0),25)),abi.encodeWithSignature("OwnableInvalidOwner(address)",address(0)));
    }
    /// @notice STR-BASE-ALLOCATE. unsupported allocate action.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_unsupported_allocate_action() public {
        vm.prank(address(myt));_bad(address(h),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.unwrapAndSwap,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));
    }
    /// @notice STR-BASE-ALLOCATE, STR-BASE-DEALLOCATE. malformed adapter data.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_malformed_adapter_data() public {
        vm.prank(address(myt));_bad(address(h),abi.encodeCall(MYTStrategy.allocate,(bytes(""),1,bytes4(0),address(this))),"");vm.prank(address(myt));_bad(address(h),abi.encodeCall(MYTStrategy.deallocate,(bytes(""),1,bytes4(0),address(this))),"");assert(h.called()==0);
    }
    /// @notice STR-BASE-SWAP. swap output balance decrease.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_swap_output_balance_decrease() public {
        receipt.mint(address(h),5);_bad(address(h),abi.encodeCall(DinoBaseHarness.swap,(address(receipt),address(asset),0,0,abi.encodeCall(DinoSwap.drain,(address(receipt),5)))),_panic(0x11));assert(receipt.balanceOf(address(h))==5);
    }
    /// @notice STR-BASE-SWAP. swap reentry rejected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_swap_reentry_rejected(uint64 raw) public {
        uint256 n=uint256(raw)+1;bytes memory payload=abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this)));uint256 out=h.swap(address(receipt),address(asset),0,n,abi.encodeCall(DinoSwap.reenter,(address(h),payload,address(receipt),n)));assert(out==n);assert(!swapper.reentrySucceeded());assert(swapper.reentryReason()==keccak256(_revertString("PD")));assert(h.called()==0);
    }
    /// @notice Same property and domain as test_check_swap_reentry_rejected.
    function test_fuzz_swap_reentry_rejected(uint64 raw) public { test_check_swap_reentry_rejected(raw); }
}

