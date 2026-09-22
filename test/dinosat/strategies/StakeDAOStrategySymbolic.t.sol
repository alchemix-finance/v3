// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoDAOFlowTest is DinoDAOFixture {
    /// @notice STR-DAO-CONSTRUCT. dao bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_bindings() public {
        assert(address(h.rewardVault())==address(vault));assert(address(h.curvePool())==address(curve));assert(h.ensoRouter()==address(swapper));assert(h.withdrawBufferBps()==25);assert(h.minWethPerCurveLp()==1e18);
    }
    /// @notice STR-DAO-SETWITHDRAWBUFFERBPS. dao set buffer.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_set_buffer(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(StakeDAOWETHStrategy.setWithdrawBufferBps,(649)));h.setWithdrawBufferBps(649);assert(h.withdrawBufferBps()==649);_bad(address(h),abi.encodeCall(StakeDAOWETHStrategy.setWithdrawBufferBps,(650)),_revertString("Withdraw buffer too high"));assert(h.withdrawBufferBps()==649);
    }
    /// @notice Same property and domain as test_check_dao_set_buffer.
    function test_fuzz_dao_set_buffer(address caller) public { test_check_dao_set_buffer((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-DAO-SETMINWETHPERCURVELP. dao set floor exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_set_floor_exit(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(StakeDAOWETHStrategy.setMinWethPerCurveLp,(2e18)));h.setMinWethPerCurveLp(2e18);assert(h.minWethPerCurveLp()==2e18);_bad(address(h),abi.encodeCall(StakeDAOWETHStrategy.setMinWethPerCurveLp,(0)),_revertString("Zero Curve LP floor"));assert(h.minWethPerCurveLp()==2e18);
    }
    /// @notice Same property and domain as test_check_dao_set_floor_exit.
    function test_fuzz_dao_set_floor_exit(address caller) public { test_check_dao_set_floor_exit((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-DAO-SETMINCURVELPPERWETH. dao set floor entry.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_set_floor_entry(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(StakeDAOWETHStrategy.setMinCurveLpPerWeth,(2e18)));h.setMinCurveLpPerWeth(2e18);assert(h.minCurveLpPerWeth()==2e18);_bad(address(h),abi.encodeCall(StakeDAOWETHStrategy.setMinCurveLpPerWeth,(0)),_revertString("Zero allocation floor"));assert(h.minCurveLpPerWeth()==2e18);
    }
    /// @notice Same property and domain as test_check_dao_set_floor_entry.
    function test_fuzz_dao_set_floor_entry(address caller) public { test_check_dao_set_floor_entry((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-DAO-SETCANFORCEDEALLOCATE. dao force.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_force(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(StakeDAOWETHStrategy.setCanForceDeallocate,(true)));h.setCanForceDeallocate(true);assert(h.canForceDeallocate());asset.mint(address(strategy),1);vm.prank(address(myt));strategy.deallocate(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0xe4d38cd8),address(this));assert(asset.allowance(address(strategy),address(myt))==1);
    }
    /// @notice Same property and domain as test_check_dao_force.
    function test_fuzz_dao_force(address caller) public { test_check_dao_force((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-DAO-SETENSOROUTER. dao router.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_router(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(StakeDAOWETHStrategy.setEnsoRouter,(ATTACKER)));h.setEnsoRouter(ATTACKER);assert(h.ensoRouter()==ATTACKER);_bad(address(h),abi.encodeCall(StakeDAOWETHStrategy.setEnsoRouter,(address(0))),_revertString("Zero enso router"));
    }
    /// @notice Same property and domain as test_check_dao_router.
    function test_fuzz_dao_router(address caller) public { test_check_dao_router((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-DAO-ALLOC. Concrete production path witness. Symbolic arithmetic lemmas and full amount-domain fuzz accompany this test.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_deposit_concrete() public {
        asset.mint(address(strategy),1e18);_allocate(IMYTStrategy.ActionType.direct,1e18,"");assert(vault.balanceOf(address(strategy))==1e18);assert(asset.allowance(address(strategy),address(curve))==0);assert(curve.allowance(address(strategy),address(vault))==0);
    }
    /// @notice STR-DAO-SWAP-ALLOC. dao swap deposit concrete.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_swap_deposit_concrete() public {
        asset.mint(address(strategy),1e18);_allocate(IMYTStrategy.ActionType.swap,1e18,_route(address(asset),address(vault),1e18,1e18));assert(vault.balanceOf(address(strategy))==1e18);assert(asset.allowance(address(strategy),address(swapper))==0);
    }
    /// @notice STR-DAO-EXIT. dao direct exit concrete.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_direct_exit_concrete() public {
        vault.mint(address(strategy),1e18);_exit(IMYTStrategy.ActionType.direct,1e18,"",0);assert(vault.balanceOf(address(strategy))==0);assert(curve.allowance(address(strategy),address(curve))==0);
    }
    /// @notice STR-DAO-SWAP-EXIT. dao swap exit concrete.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_swap_exit_concrete() public {
        vault.mint(address(strategy),1e18);_exit(IMYTStrategy.ActionType.swap,1e18,_route(address(vault),address(asset),1e18,1e18),0);assert(vault.balanceOf(address(strategy))==0);assert(vault.allowance(address(strategy),address(swapper))==0);
    }
    /// @notice STR-DAO-REWARDS. dao main reward.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_main_reward(uint64 raw) public {
        uint256 n=uint256(raw)+1;accountant.set(n,0);reward.mint(address(strategy),3);assert(strategy.claimRewards(address(reward),_route(address(reward),address(asset),n+3,n+3),n+3)==n+3);assert(mytAssetBalance()==n+3);assert(reward.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_dao_main_reward.
    function test_fuzz_dao_main_reward(uint64 raw) public { test_check_dao_main_reward(raw); }
    /// @notice STR-DAO-REWARDS. dao reward errors.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_reward_errors() public {
        accountant.set(0,1);assert(strategy.claimRewards(address(reward),"x",0)==0);accountant.set(0,2);_bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)),abi.encodeWithSelector(DinoAccountant.OtherFailure.selector));_bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes(""),0)),_revertString("params"));
    }
    /// @notice STR-DAO-REWARDS. dao extra reward.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_extra_reward(uint64 raw) public {
        uint128 n=uint128(raw)+1;vault.setEarned(n);assert(strategy.claimRewards(address(receipt),_route(address(receipt),address(asset),n,n),n)==n);assert(mytAssetBalance()==n);
    }
    /// @notice Same property and domain as test_check_dao_extra_reward.
    function test_fuzz_dao_extra_reward(uint64 raw) public { test_check_dao_extra_reward(raw); }
    /// @notice STR-DAO-PROTECTED. dao protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_protected() public {
        _bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(vault),ATTACKER,0)),_revertString("Protected token"));_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(curve),ATTACKER,0)),_revertString("Protected token"));
    }
    /// @notice STR-DAO-SLIPPAGE. dao slippage.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_slippage(uint64 raw) public {
        uint256 n=uint256(raw);uint256 out=h.minSlip(n);assert(out>=1);assert(n==0?out==1:out<=n);if(n*9975>=10000){assert(out*10000<=n*9975);assert(n*9975-out*10000<10000);}
    }
    /// @notice Same property and domain as test_check_dao_slippage.
    function test_fuzz_dao_slippage(uint64 raw) public { test_check_dao_slippage(raw); }
    /// @notice STR-DAO-MINSHARES. Actual quote and preview-deposit units coincide only under the explicit identity mocks.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_min_shares(uint64 raw) public {
        uint256 n=uint256(raw);assert(h.minShares(n)==h.minSlip(n));
    }
    /// @notice Same property and domain as test_check_dao_min_shares.
    function test_fuzz_dao_min_shares(uint64 raw) public { test_check_dao_min_shares(raw); }
    /// @notice STR-DAO-LPREQUIRED. dao lp required capped.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_lp_required_capped(uint64 raw) public {
        uint256 n=uint256(raw)+1;assert(h.lpRequired(n,n)==n);assert(h.lpRequired(0,n)==0);assert(h.lpRequired(n,0)==0);
    }
    /// @notice Same property and domain as test_check_dao_lp_required_capped.
    function test_fuzz_dao_lp_required_capped(uint64 raw) public { test_check_dao_lp_required_capped(raw); }
    /// @notice STR-DAO-LPREQUIRED. dao lp required partial.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_lp_required_partial(uint64 raw) public {
        uint256 n=uint256(raw)+1;uint256 out=h.lpRequired(n,2*n);assert(out>=n&&out<=2*n);
    }
    /// @notice Same property and domain as test_check_dao_lp_required_partial.
    function test_fuzz_dao_lp_required_partial(uint64 raw) public { test_check_dao_lp_required_partial(raw); }
    /// @notice STR-DAO-ROUTE. dao route output.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_route_output(uint64 raw) public {
        uint256 n=uint256(raw)+1;uint256 out=h.route(address(receipt),n,_route(address(asset),address(receipt),0,n));assert(out==n);assert(receipt.balanceOf(address(h))==n);_bad(address(h),abi.encodeCall(DinoDAOHarness.route,(address(receipt),1,bytes(""))),_revertString("Empty Enso calldata"));
    }
    /// @notice Same property and domain as test_check_dao_route_output.
    function test_fuzz_dao_route_output(uint64 raw) public { test_check_dao_route_output(raw); }
    /// @notice STR-DAO-ROUTE. dao route failure.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_route_failure() public {
        _bad(address(h),abi.encodeCall(DinoDAOHarness.route,(address(receipt),1,abi.encodeCall(DinoSwap.fail,()))),_revertString("Enso route failed"));_bad(address(h),abi.encodeCall(DinoDAOHarness.route,(address(receipt),1,abi.encodeCall(DinoSwap.noOp,()))),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,1,0));
    }
    function deployDAO(uint8 mode) external returns(address){return address(new StakeDAOWETHStrategy(address(myt),_params(),mode==0?address(0):address(vault),mode==1?address(0):mode==6?address(receipt):address(curve),mode==2?address(0):address(swapper),mode==3?650:25,mode==4?0:1e18,mode==5?0:95e16));}
    /// @notice STR-DAO-CONSTRUCT. dao constructor vault.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_vault() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(0)),_revertString("Zero reward vault"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor pool.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_pool() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(1)),_revertString("Zero curve pool"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor router.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_router() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(2)),_revertString("Zero enso router"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor buffer.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_buffer() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(3)),_revertString("Withdraw buffer too high"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor exitfloor.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_exitfloor() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(4)),_revertString("Zero Curve LP floor"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor entryfloor.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_entryfloor() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(5)),_revertString("Zero allocation floor"));
    }
    /// @notice STR-DAO-CONSTRUCT. dao constructor mismatch.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_constructor_mismatch() public {
        _bad(address(this),abi.encodeCall(this.deployDAO,(6)),_revertString("Vault asset != curve LP"));
    }
}

contract DinoDAORefinementTest is DinoDAOFixture {
    /// @notice STR-DAO-MAXABS, STR-DAO-MINABS, STR-DAO-MINVP, STR-DAO-MAXVP, STR-DAO-EFFECTIVE. Actual helpers refine the separate exact-rounding lemmas at the configured price domain.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_price_refinement(uint64 raw) public {
        uint256 n=uint256(raw);uint256 floor=n*95e16/1e18+(n*95e16%1e18==0?0:1);assert(h.minAbs(n)==floor);assert(h.maxAbs(n)==n+1e6);uint256 vpFloor=n*9975/10000;uint256 vpCap=n*10000/9975+(n*10000%9975==0?0:1)+1e6;assert(h.minVP(n)==vpFloor);assert(h.maxVP(n)==vpCap);assert(h.effectiveMin(n)>=(floor>vpFloor?floor:vpFloor));assert(h.effectiveMax(n)<=(n+1e6<vpCap?n+1e6:vpCap));
    }
    /// @notice STR-DAO-VALUE, STR-DAO-PREVIEW. Actual valuation and preview honor idle plus position accounting and exact floor rounding.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_value_preview(uint64 raw,uint64 idleRaw) public {
        uint256 n=uint256(raw);uint256 idle=uint256(idleRaw);vault.mint(address(strategy),n);asset.mint(address(strategy),idle);assert(strategy.realAssets()==n+idle);uint256 requested=n+idle+1;uint256 out=strategy.previewAdjustedWithdraw(requested);assert(out==idle+n*9975/10000);assert(out<=requested);
    }
    /// @notice STR-DAO-ALLOC. Full production allocation over positive uint64 amounts with identity pool/vault mocks.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_allocate_direct(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(vault.balanceOf(address(strategy))==n);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice STR-DAO-SWAP-ALLOC. Full production allocation over positive uint64 amounts with identity pool/vault mocks.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_allocate_swap(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.swap,n,_route(address(asset),address(vault),n,n));assert(vault.balanceOf(address(strategy))==n);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice STR-DAO-EXIT. Full production deallocation over positive uint64 amounts with identity pool/vault mocks.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_exit_direct(uint64 raw) public {
        uint256 n=uint256(raw)+1;vault.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(vault.balanceOf(address(strategy))==0);assert(mytAssetBalance()==n);
    }
    /// @notice STR-DAO-SWAP-EXIT. Full production deallocation over positive uint64 amounts with identity pool/vault mocks.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_dao_exit_swap(uint64 raw) public {
        uint256 n=uint256(raw)+1;vault.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.swap,n,_route(address(vault),address(asset),n,n),0);assert(vault.balanceOf(address(strategy))==0);assert(mytAssetBalance()==n);
    }
    /// @notice STR-DAO-REWARDS. Real production assembly rethrow preserves the complete modeled revert payload.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_revert_bytes_0() public {
        accountant.set(0,3);bytes memory expected=new bytes(0); _bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)),expected);
    }
    /// @notice STR-DAO-REWARDS. Real production assembly rethrow preserves the complete modeled revert payload.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_revert_bytes_32() public {
        accountant.set(0,4);bytes memory expected=new bytes(32);expected[0]=0xa1; _bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)),expected);
    }
    /// @notice STR-DAO-REWARDS. Real production assembly rethrow preserves the complete modeled revert payload.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_revert_bytes_64() public {
        accountant.set(0,5);bytes memory expected=new bytes(64);expected[0]=0xa1; _bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)),expected);
    }
    /// @notice STR-DAO-MINVP, STR-DAO-MAXVP. dao zero virtual price.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_zero_virtual_price() public {
        curve.setVP(0);_bad(address(h),abi.encodeCall(DinoDAOHarness.minVP,(1)),_revertString("Zero virtual price"));_bad(address(h),abi.encodeCall(DinoDAOHarness.maxVP,(1)),_revertString("Zero virtual price"));
    }
    /// @notice STR-DAO-ALLOC. dao lying pool deposit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_lying_pool_deposit() public {
        curve.setLie(true);asset.mint(address(strategy),1e18);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1e18,bytes4(0),address(this))),_panic(0x11));assert(asset.balanceOf(address(strategy))==1e18);assert(vault.balanceOf(address(strategy))==0);
    }
    /// @notice STR-DAO-EXIT. dao lying pool exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_dao_lying_pool_exit() public {
        curve.setLie(true);vault.mint(address(strategy),1e18);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),1e18,bytes4(0),address(this))),abi.encodeWithSelector(StakeDAOWETHStrategy.CurveLpPriceBelowFloor.selector,1e18,1e6));assert(vault.balanceOf(address(strategy))==1e18);assert(asset.balanceOf(address(strategy))==0);
    }
}

