// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoEtherFlowTest is DinoEtherFixture {
    /// @notice STR-ETHER-CONSTRUCT. ether bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_bindings() public {
        assert(address(h.weETH())==address(we));assert(address(h.eETH())==address(receipt));assert(address(h.depositAdapter())==address(manager));assert(address(h.redemptionManager())==address(manager));assert(!h.canForceDeallocate());
    }
    /// @notice STR-ETHER-ALLOC. ether allocate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_allocate(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(we.balanceOf(address(strategy))==n);assert(asset.allowance(address(strategy),address(manager))==0);assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_ether_allocate.
    function test_fuzz_ether_allocate(uint64 raw) public { test_check_ether_allocate(raw); }
    /// @notice STR-ETHER-EXIT. ether idle exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_idle_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_ether_idle_exit.
    function test_fuzz_ether_idle_exit(uint64 raw) public { test_check_ether_idle_exit(raw); }
    /// @notice STR-ETHER-EXIT, STR-ETHER-RECEIVE. Concrete zero fee removes nonlinear sizing. Full variable-fee helper has separate refinement fuzz.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_active_exit_zero_fee(uint64 raw) public {
        uint256 n=uint256(raw)+1;we.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(we.balanceOf(address(strategy))==0);assert(we.allowance(address(strategy),address(manager))==0);assert(address(strategy).balance==0);
    }
    /// @notice Same property and domain as test_check_ether_active_exit_zero_fee.
    function test_fuzz_ether_active_exit_zero_fee(uint64 raw) public { test_check_ether_active_exit_zero_fee(raw); }
    /// @notice STR-ETHER-EXIT. ether exit bad fee.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_exit_bad_fee() public {
        manager.set(10000,true,0);we.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("Invalid exit fee"));assert(we.balanceOf(address(strategy))==1);
    }
    /// @notice STR-ETHER-EXIT. ether exit unavailable.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_exit_unavailable() public {
        manager.set(0,false,0);we.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("Cannot redeem. Instant redemption path is not available."));assert(we.balanceOf(address(strategy))==1);
    }
    /// @notice STR-ETHER-EXIT. ether exit short output.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_exit_short_output() public {
        manager.set(0,true,1);we.mint(address(strategy),5);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),_revertString("Insufficient ETH redeemed"));assert(we.balanceOf(address(strategy))==5);assert(address(strategy).balance==0);
    }
    /// @notice STR-ETHER-ROUND. ether roundup.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_roundup(uint64 raw) public {
        uint256 n=uint256(raw)+1;we.setRate(3e18);uint256 q=h.gross(n,n+1);assert(q*3>=n);assert((q-1)*3<n);
    }
    /// @notice Same property and domain as test_check_ether_roundup.
    function test_fuzz_ether_roundup(uint64 raw) public { test_check_ether_roundup(raw); }
    /// @notice STR-ETHER-PREVIEW-NET. ether preview net.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_preview_net(uint64 raw) public {
        manager.set(25,true,0);uint256 n=uint256(raw);uint256 out=h.net(n);assert(out<=n);assert(out*10000<=n*9975);assert(n*9975-out*10000<10000);
    }
    /// @notice Same property and domain as test_check_ether_preview_net.
    function test_fuzz_ether_preview_net(uint64 raw) public { test_check_ether_preview_net(raw); }
    /// @notice STR-ETHER-PREP. ether prep.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_prep(uint64 raw,uint64 cap) public {
        we.mint(address(strategy),raw);uint256 n=h.prep(cap);assert(n<=raw&&n<=cap);assert(n==raw||n==cap);
    }
    /// @notice Same property and domain as test_check_ether_prep.
    function test_fuzz_ether_prep(uint64 raw,uint64 cap) public { test_check_ether_prep(raw,cap); }
    /// @notice STR-ETHER-FORCE. ether force setter.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_force_setter(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(EtherfiEETHMYTStrategy.setCanForceDeallocate,(true)));h.setCanForceDeallocate(true);assert(h.canForceDeallocate());asset.mint(address(strategy),1);vm.prank(address(myt));strategy.deallocate(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0xe4d38cd8),address(this));assert(asset.allowance(address(strategy),address(myt))==1);
    }
    /// @notice Same property and domain as test_check_ether_force_setter.
    function test_fuzz_ether_force_setter(address caller) public { test_check_ether_force_setter((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-ETHER-BUFFER. ether buffer setter.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_buffer_setter(uint64 raw,address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        uint256 n=uint256(raw)%1e18;_ownerOnlyAs(caller,abi.encodeCall(EtherfiEETHMYTStrategy.setGrossRedeemAmountBuffer,(n)));h.setGrossRedeemAmountBuffer(n);assert(h.grossRedeemAmountBuffer()==n);_bad(address(h),abi.encodeCall(EtherfiEETHMYTStrategy.setGrossRedeemAmountBuffer,(1e18+1)),_revertString("Buffer too large"));assert(h.grossRedeemAmountBuffer()==n);
    }
    /// @notice Same property and domain as test_check_ether_buffer_setter.
    function test_fuzz_ether_buffer_setter(uint64 raw,address caller) public { test_check_ether_buffer_setter(raw,(caller==address(this)?ATTACKER:caller)); }
    function deployEther(uint8 mode) external returns(address){return address(new EtherfiEETHMYTStrategy(address(myt),_params(),mode==0?address(0):address(receipt),mode==1?address(0):address(we),mode==2?address(0):address(manager),mode==3?address(0):address(manager),address(oracle),1000));}
    /// @notice STR-ETHER-CONSTRUCT. ether constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployEther,(0)),_revertString("Zero eETH address"));_bad(address(this),abi.encodeCall(this.deployEther,(1)),_revertString("Zero weETH address"));_bad(address(this),abi.encodeCall(this.deployEther,(2)),_revertString("Zero deposit adapter address"));_bad(address(this),abi.encodeCall(this.deployEther,(3)),_revertString("Zero redemption manager address"));
    }
    /// @notice STR-ETHER-SIZE, STR-ETHER-EXIT. ether insufficient receipts.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ether_insufficient_receipts() public {
        we.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),2,bytes4(0),address(this))),_panic(0x11));assert(we.balanceOf(address(strategy))==1);assert(we.allowance(address(strategy),address(manager))==0);
    }
}

contract DinoEtherRefinementTest is DinoEtherFixture {
    /// @notice STR-ETHER-SIZE. Real sizing helper equals exact-ceil model with identity liquidity/weETH conversions.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_ether_size_refinement(uint64 raw,uint16 feeRaw) public {
        uint256 n=uint256(raw)+1;uint256 fee=uint256(feeRaw)%10000;uint256 d=10000-fee;uint256 p=n*10000;uint256 expected=p/d+(p%d==0?0:1);assert(h.size(n,fee,expected+1)==expected);
    }
    /// @notice STR-ETHER-EXIT. Real full fee-dependent exit produces requested assets and clears redemption allowance.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_ether_fee_exit(uint64 raw,uint16 feeRaw) public {
        uint256 n=uint256(raw)+1;uint16 fee=uint16(uint256(feeRaw)%10000);manager.set(fee,true,0);uint256 shares=(n*10000+9999-fee)/(10000-fee);we.mint(address(strategy),shares);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(we.allowance(address(strategy),address(manager))==0);assert(mytAssetBalance()==n);
    }
    /// @notice STR-ETHER-SIZE. Actual sizing helper applies the buffer only when a non-identity share conversion loses a unit.
    /// @dev Classification: FUZZ. Actual bytecode refinement over the bounded uint64 domain.
    function test_fuzz_ether_buffer_branch(uint8 raw) public {
        uint256 buffer=uint256(raw)+1;manager.setShareRate(15e17);h.setGrossRedeemAmountBuffer(buffer);assert(h.size(1,0,1000)==1+buffer);h.setGrossRedeemAmountBuffer(0);assert(h.size(1,0,1000)==1);
    }
}

