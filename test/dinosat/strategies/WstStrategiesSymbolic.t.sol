// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoWstFlowTest is DinoWstFixture {
    /// @notice STR-WST-MAIN-ALLOC, STR-WST-MAIN-RECEIVE, STR-CONSTRUCT-WSTETHETHEREUMSTRATEGY. wst direct.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_direct(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(wrapped.balanceOf(address(strategy))==n);assert(asset.balanceOf(address(strategy))==0);assert(address(strategy).balance==0);
    }
    /// @notice Same property and domain as test_check_wst_direct.
    function test_fuzz_wst_direct(uint64 raw) public { test_check_wst_direct(raw); }
    /// @notice STR-WST-MAIN-SWAP. wst swap.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_swap(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.swap,n,_route(address(asset),address(wrapped),n,n));assert(wrapped.balanceOf(address(strategy))==n);
    }
    /// @notice Same property and domain as test_check_wst_swap.
    function test_fuzz_wst_swap(uint64 raw) public { test_check_wst_swap(raw); }
    /// @notice STR-WST-MAIN-VALUE. wst value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_value(uint64 raw) public {
        wrapped.setRate(2e18);wrapped.mint(address(strategy),raw);assert(strategy.realAssets()==uint256(raw)*2);
    }
    /// @notice Same property and domain as test_check_wst_value.
    function test_fuzz_wst_value(uint64 raw) public { test_check_wst_value(raw); }
    /// @notice STR-WST-MAIN-PREP. wst prep.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_prep(uint64 raw,uint64 maxRaw) public {
        uint256 n=uint256(raw);uint256 cap=uint256(maxRaw);wrapped.setRate(2e18);wrapped.mint(address(strategy),n);uint256 out=h.prep(cap);assert(out<=n);assert(out*2<=cap);assert(out==n||out==cap/2);
    }
    /// @notice Same property and domain as test_check_wst_prep.
    function test_fuzz_wst_prep(uint64 raw,uint64 maxRaw) public { test_check_wst_prep(raw,maxRaw); }
    /// @notice STR-WST-MAIN-CEIL. wst ceil.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_ceil(uint64 raw) public {
        uint256 n=uint256(raw)+1;wrapped.setRate(3e18);uint256 q=h.ceilWrapped(n);assert(q*3>=n);assert((q-1)*3<n);
    }
    /// @notice Same property and domain as test_check_wst_ceil.
    function test_fuzz_wst_ceil(uint64 raw) public { test_check_wst_ceil(raw); }
    /// @notice STR-WST-MAIN-PROTECTED. wst protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_wst_protected() public {
        wrapped.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(wrapped),ATTACKER,1)),_revertString("Protected token"));assert(wrapped.balanceOf(address(strategy))==1);
    }
}

contract DinoWstL2FlowTest is DinoWstL2Fixture {
    /// @notice STR-WST-L2-NODIRECT, STR-CONSTRUCT-WSTETHL2STRATEGY. l2 unsupported direct.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_l2_unsupported_direct() public {
        asset.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));assert(asset.balanceOf(address(strategy))==1);assert(address(h.wsteth())==address(wrapped));
    }
    /// @notice STR-WST-L2-VALUE. l2 swap value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_l2_swap_value(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.swap,n,_route(address(asset),address(wrapped),n,n));assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_l2_swap_value.
    function test_fuzz_l2_swap_value(uint64 raw) public { test_check_l2_swap_value(raw); }
    /// @notice STR-WST-L2-PREP. l2 prep.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_l2_prep(uint64 raw,uint64 maxRaw) public {
        wrapped.mint(address(strategy),raw);uint256 out=h.prep(maxRaw);assert(out<=raw&&out<=maxRaw);assert(out==raw||out==maxRaw);
    }
    /// @notice Same property and domain as test_check_l2_prep.
    function test_fuzz_l2_prep(uint64 raw,uint64 maxRaw) public { test_check_l2_prep(raw,maxRaw); }
    /// @notice STR-WST-L2-PROTECTED. l2 protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_l2_protected() public {
        wrapped.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(wrapped),ATTACKER,1)),_revertString("Protected token"));assert(wrapped.balanceOf(address(strategy))==1);
    }
}

