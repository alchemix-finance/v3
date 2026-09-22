// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoFraxFlowTest is DinoFraxFixture {
    /// @notice STR-FRAX-CONSTRUCT. frax bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_bindings() public {
        assert(address(h.minter())==address(minter));assert(address(h.frxETH())==address(receipt));assert(address(h.sfrxETH())==address(shares));assert(h.minFrxEthOutBps()==9500);
    }
    /// @notice STR-FRAX-FLOOR-SET. frax floor setter.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_floor_setter(uint16 raw,address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        uint256 n=uint256(raw)%10001;_ownerOnlyAs(caller,abi.encodeCall(SFraxETHStrategy.setMinFrxEthOutBps,(n)));h.setMinFrxEthOutBps(n);assert(h.minFrxEthOutBps()==n);_bad(address(h),abi.encodeCall(SFraxETHStrategy.setMinFrxEthOutBps,(10001)),_revertString("Invalid min frxETH out bps"));assert(h.minFrxEthOutBps()==n);
    }
    /// @notice Same property and domain as test_check_frax_floor_setter.
    function test_fuzz_frax_floor_setter(uint16 raw,address caller) public { test_check_frax_floor_setter(raw,(caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-FRAX-DIRECT, STR-FRAX-RECEIVE. frax direct.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_direct(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(shares.balanceOf(address(strategy))==n);assert(address(strategy).balance==0);assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_frax_direct.
    function test_fuzz_frax_direct(uint64 raw) public { test_check_frax_direct(raw); }
    /// @notice STR-FRAX-SWAP-STAKE. frax swap stake.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_swap_stake(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.swap,n,_route(address(asset),address(receipt),n,n));assert(shares.balanceOf(address(strategy))==n);assert(receipt.balanceOf(address(strategy))==0);assert(receipt.allowance(address(strategy),address(shares))==0);
    }
    /// @notice Same property and domain as test_check_frax_swap_stake.
    function test_fuzz_frax_swap_stake(uint64 raw) public { test_check_frax_swap_stake(raw); }
    /// @notice STR-FRAX-GUARD. frax floor guard.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_floor_guard(uint64 raw) public {
        uint256 n=uint256(raw)+10000;uint256 floor=n*9500/10000;_bad(address(h),abi.encodeCall(DinoFraxHarness.guard,(n,floor-1)),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,floor,floor-1));h.guard(n,floor);h.setMinFrxEthOutBps(0);h.guard(n,0);assert(h.minFrxEthOutBps()==0);
    }
    /// @notice Same property and domain as test_check_frax_floor_guard.
    function test_fuzz_frax_floor_guard(uint64 raw) public { test_check_frax_floor_guard(raw); }
    /// @notice STR-FRAX-UNSUPPORTED. frax unsupported swap.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_unsupported_swap() public {
        shares.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.swap,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));
    }
    /// @notice STR-FRAX-VALUE. frax raw and staked value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_raw_and_staked_value(uint64 raw,uint64 staked) public {
        receipt.mint(address(strategy),raw);shares.mint(address(strategy),staked);assert(strategy.realAssets()==uint256(raw)+staked);
    }
    /// @notice Same property and domain as test_check_frax_raw_and_staked_value.
    function test_fuzz_frax_raw_and_staked_value(uint64 raw,uint64 staked) public { test_check_frax_raw_and_staked_value(raw,staked); }
    /// @notice STR-FRAX-UNWRAP. frax unwrap exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_unwrap_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;shares.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.unwrapAndSwap,n,_route(address(receipt),address(asset),n,n),n);assert(shares.balanceOf(address(strategy))==0);assert(receipt.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_frax_unwrap_exit.
    function test_fuzz_frax_unwrap_exit(uint64 raw) public { test_check_frax_unwrap_exit(raw); }
    /// @notice STR-FRAX-UNWRAP. frax unwrap guards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_unwrap_guards() public {
        shares.mint(address(strategy),10);_bad(address(h),abi.encodeCall(DinoFraxHarness.prep,(5,0)),_revertString("Invalid intermediate amount"));_bad(address(h),abi.encodeCall(DinoFraxHarness.prep,(5,6)),_revertString("Intermediate exceeds max oracle token in"));_bad(address(h),abi.encodeCall(DinoFraxHarness.prep,(20,11)),_revertString("Insufficient sfrxETH balance"));assert(shares.balanceOf(address(strategy))==10);
    }
    /// @notice STR-FRAX-PROTECTED. frax protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_protected() public {
        shares.mint(address(strategy),1);receipt.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(shares),ATTACKER,1)),_revertString("Protected token"));_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(receipt),ATTACKER,1)),_revertString("Protected token"));
    }
    function deployFrax(uint8 mode) external returns(address){return address(new SFraxETHStrategy(address(myt),_params(),mode==0?address(0):address(minter),mode==1?address(0):address(receipt),mode==2?address(0):address(shares),address(oracle),mode==3?10001:9500,1000));}
    /// @notice STR-FRAX-CONSTRUCT. frax constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployFrax,(0)),_revertString("Zero minter address"));_bad(address(this),abi.encodeCall(this.deployFrax,(1)),_revertString("Zero frxETH address"));_bad(address(this),abi.encodeCall(this.deployFrax,(2)),_revertString("Zero sfrxETH address"));_bad(address(this),abi.encodeCall(this.deployFrax,(3)),_revertString("Invalid min frxETH out bps"));
    }
    /// @notice STR-FRAX-DIRECT. frax zero mint.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frax_zero_mint() public {
        minter.setZeroMint(true);asset.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("No sfrxETH received"));assert(asset.balanceOf(address(strategy))==1);
    }
}

