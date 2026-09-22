// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoOraclePricingTest is DinoOracleFixture {
    /// @notice STR-ORACLE-SETPRICEDTOKENORACLE, STR-ORACLE-SETMAXORACLESTALENESS, STR-ORACLE-CONSTRUCT. oracle settings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_settings(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(OraclePricedSwapStrategy.setPricedTokenOracle,(address(oracle))));_ownerOnlyAs(caller,abi.encodeCall(OraclePricedSwapStrategy.setMaxOracleStaleness,(55)));
        DinoOracle other=new DinoOracle();other.setDecimals(8);h.setPricedTokenOracle(address(other));assert(address(h.pricedTokenOracle())==address(other)&&h.pricedTokenOracleDecimals()==8);h.setMaxOracleStaleness(55);assert(h.MAX_ORACLE_STALENESS()==55);
        _bad(address(h),abi.encodeCall(OraclePricedSwapStrategy.setPricedTokenOracle,(address(0))),_revertString("Zero oracle address"));_bad(address(h),abi.encodeCall(OraclePricedSwapStrategy.setMaxOracleStaleness,(0)),_revertString("Zero oracle staleness"));
    }
    /// @notice Same property and domain as test_check_oracle_settings.
    function test_fuzz_oracle_settings(address caller) public { test_check_oracle_settings((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-ORACLE-FRESH. fresh boundary.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_fresh_boundary(uint64 priceRaw) public {
        uint256 p=uint256(priceRaw)+1;oracle.set(int256(p),9000);assert(h.answer()==p);oracle.set(int256(p),8999);_bad(address(h),abi.encodeCall(DinoOracleHarness.answer,()),_revertString("Stale oracle answer"));oracle.set(int256(p),10001);_bad(address(h),abi.encodeCall(DinoOracleHarness.answer,()),_revertString("Stale oracle answer"));
    }
    /// @notice Same property and domain as test_check_fresh_boundary.
    function test_fuzz_fresh_boundary(uint64 priceRaw) public { test_check_fresh_boundary(priceRaw); }
    /// @notice STR-ORACLE-FRESH. invalid answer.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_invalid_answer() public {
        oracle.set(0,10000);_bad(address(h),abi.encodeCall(DinoOracleHarness.answer,()),_revertString("Invalid oracle answer"));oracle.set(-1,10000);_bad(address(h),abi.encodeCall(DinoOracleHarness.answer,()),_revertString("Invalid oracle answer"));oracle.set(1,0);_bad(address(h),abi.encodeCall(DinoOracleHarness.answer,()),_revertString("Invalid oracle answer"));oracle.set(1,10000);assert(h.answer()==1);
    }
    /// @notice STR-ORACLE-TO-ASSET, STR-ORACLE-FROM-ASSET-DOWN, STR-ORACLE-FROM-ASSET-UP. Exact production conversion with fixed decimals and rate two. Down cannot create assets; up funds the requested amount.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_pricing_18_18_18(uint64 raw) public {
        asset.setDecimals(18);receipt.setDecimals(18);oracle.setDecimals(18);oracle.set(int256(2*10**18),10000);h.setPricedTokenOracle(address(oracle));
        uint256 n=uint256(raw)+1;uint256 lo=h.down(n);uint256 hi=h.up(n);assert(hi>=lo&&hi-lo<=1);assert(h.toAsset(lo)<=n);assert(h.toAsset(hi)>=n);
    }
    /// @notice Same property and domain as test_check_pricing_18_18_18.
    function test_fuzz_pricing_18_18_18(uint64 raw) public { test_check_pricing_18_18_18(raw); }
    /// @notice STR-ORACLE-TO-ASSET, STR-ORACLE-FROM-ASSET-DOWN, STR-ORACLE-FROM-ASSET-UP. Exact production conversion with fixed decimals and rate two. Down cannot create assets; up funds the requested amount.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_pricing_18_18_8(uint64 raw) public {
        asset.setDecimals(18);receipt.setDecimals(18);oracle.setDecimals(8);oracle.set(int256(2*10**8),10000);h.setPricedTokenOracle(address(oracle));
        uint256 n=uint256(raw)+1;uint256 lo=h.down(n);uint256 hi=h.up(n);assert(hi>=lo&&hi-lo<=1);assert(h.toAsset(lo)<=n);assert(h.toAsset(hi)>=n);
    }
    /// @notice Same property and domain as test_check_pricing_18_18_8.
    function test_fuzz_pricing_18_18_8(uint64 raw) public { test_check_pricing_18_18_8(raw); }
    /// @notice STR-ORACLE-TO-ASSET, STR-ORACLE-FROM-ASSET-DOWN, STR-ORACLE-FROM-ASSET-UP. Exact production conversion with fixed decimals and rate two. Down cannot create assets; up funds the requested amount.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_pricing_6_18_8(uint64 raw) public {
        asset.setDecimals(6);receipt.setDecimals(18);oracle.setDecimals(8);oracle.set(int256(2*10**8),10000);h.setPricedTokenOracle(address(oracle));
        uint256 n=uint256(raw)+1;uint256 lo=h.down(n);uint256 hi=h.up(n);assert(hi>=lo&&hi-lo<=1);assert(h.toAsset(lo)<=n);assert(h.toAsset(hi)>=n);
    }
    /// @notice Same property and domain as test_check_pricing_6_18_8.
    function test_fuzz_pricing_6_18_8(uint64 raw) public { test_check_pricing_6_18_8(raw); }
    /// @notice STR-ORACLE-TO-ASSET, STR-ORACLE-FROM-ASSET-DOWN, STR-ORACLE-FROM-ASSET-UP. Exact production conversion with fixed decimals and rate two. Down cannot create assets; up funds the requested amount.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_pricing_6_18_18(uint64 raw) public {
        asset.setDecimals(6);receipt.setDecimals(18);oracle.setDecimals(18);oracle.set(int256(2*10**18),10000);h.setPricedTokenOracle(address(oracle));
        uint256 n=uint256(raw)+1;uint256 lo=h.down(n);uint256 hi=h.up(n);assert(hi>=lo&&hi-lo<=1);assert(h.toAsset(lo)<=n);assert(h.toAsset(hi)>=n);
    }
    /// @notice Same property and domain as test_check_pricing_6_18_18.
    function test_fuzz_pricing_6_18_18(uint64 raw) public { test_check_pricing_6_18_18(raw); }
    /// @notice STR-ORACLE-TO-ASSET, STR-ORACLE-FROM-ASSET-DOWN, STR-ORACLE-FROM-ASSET-UP. decimal overflow.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_decimal_overflow() public {
        receipt.setDecimals(78);_bad(address(h),abi.encodeCall(DinoOracleHarness.down,(1)),_panic(0x11));receipt.setDecimals(18);assert(h.down(1)==1);
    }
    /// @notice STR-ORACLE-CEIL. ceil minimal.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ceil_minimal(uint64 raw,uint16 denominatorRaw) public {
        uint256 n=uint256(raw)+1;uint256 d=uint256(denominatorRaw)%9999+2;uint256 q=h.ceil(n,10000,d);assert(q*d>=n*10000);assert((q-1)*d<n*10000);
    }
    /// @notice Same property and domain as test_check_ceil_minimal.
    function test_fuzz_ceil_minimal(uint64 raw,uint16 denominatorRaw) public { test_check_ceil_minimal(raw,denominatorRaw); }
    /// @notice STR-ORACLE-VALUE. oracle value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_value(uint64 raw,uint64 idleRaw) public {
        receipt.mint(address(h),raw);asset.mint(address(h),idleRaw);assert(h.realAssets()==uint256(raw)+idleRaw);
    }
    /// @notice Same property and domain as test_check_oracle_value.
    function test_fuzz_oracle_value(uint64 raw,uint64 idleRaw) public { test_check_oracle_value(raw,idleRaw); }
    /// @notice STR-ORACLE-PREVIEW. preview idle.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_preview_idle(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(h),n);oracle.set(0,0);assert(h.previewAdjustedWithdraw(n)==n);
    }
    /// @notice Same property and domain as test_check_preview_idle.
    function test_fuzz_preview_idle(uint64 raw) public { test_check_preview_idle(raw); }
    /// @notice STR-ORACLE-PREVIEW. preview position.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_preview_position(uint64 raw,uint64 idleRaw) public {
        uint256 n=uint256(raw)+1;uint256 idle=uint256(idleRaw);receipt.mint(address(h),n);asset.mint(address(h),idle);uint256 out=h.previewAdjustedWithdraw(n+idle);assert(out<=n+idle);assert(out>=idle);assert((out-idle)*10000<=n*9975);assert(n*9975-(out-idle)*10000<10000);
    }
    /// @notice Same property and domain as test_check_preview_position.
    function test_fuzz_preview_position(uint64 raw,uint64 idleRaw) public { test_check_preview_position(raw,idleRaw); }
    /// @notice STR-ORACLE-ALLOC. oracle swap allocation.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_swap_allocation(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(h),n);_allocate(IMYTStrategy.ActionType.swap,n,_route(address(asset),address(receipt),n,n));assert(receipt.balanceOf(address(h))==n);assert(asset.allowance(address(h),address(swapper))==0);
    }
    /// @notice Same property and domain as test_check_oracle_swap_allocation.
    function test_fuzz_oracle_swap_allocation(uint64 raw) public { test_check_oracle_swap_allocation(raw); }
    /// @notice STR-ORACLE-EXIT. oracle swap exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_swap_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;receipt.mint(address(h),n);_exit(IMYTStrategy.ActionType.swap,n,_route(address(receipt),address(asset),n,n),0);assert(receipt.balanceOf(address(h))==0);assert(asset.balanceOf(address(h))==0);
    }
    /// @notice Same property and domain as test_check_oracle_swap_exit.
    function test_fuzz_oracle_swap_exit(uint64 raw) public { test_check_oracle_swap_exit(raw); }
    /// @notice STR-ORACLE-UNWRAP. oracle unwrap exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_unwrap_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;receipt.mint(address(h),n);_exit(IMYTStrategy.ActionType.unwrapAndSwap,n,_route(address(receipt),address(asset),n,n),n);assert(receipt.balanceOf(address(h))==0);
    }
    /// @notice Same property and domain as test_check_oracle_unwrap_exit.
    function test_fuzz_oracle_unwrap_exit(uint64 raw) public { test_check_oracle_unwrap_exit(raw); }
    /// @notice STR-ORACLE-EXIT, STR-ORACLE-UNWRAP. Swap idle path avoids conversion preparation. Full base dispatcher still values remaining holdings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_exit_idle(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(h),n);_exit(IMYTStrategy.ActionType.swap,n,"",0);assert(asset.balanceOf(address(h))==0);
    }
    /// @notice Same property and domain as test_check_oracle_exit_idle.
    function test_fuzz_oracle_exit_idle(uint64 raw) public { test_check_oracle_exit_idle(raw); }
    function deployOracleConfig(address feed,uint256 age) external returns(address){return address(new WstETHL2Strategy(address(myt),_params(),address(receipt),feed,age));}
    /// @notice STR-ORACLE-CONSTRUCT. oracle constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployOracleConfig,(address(0),1)),_revertString("Zero oracle address"));_bad(address(this),abi.encodeCall(this.deployOracleConfig,(address(oracle),0)),_revertString("Zero oracle staleness"));
    }
    /// @notice STR-ORACLE-UNWRAP. oracle zero intermediate token.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_oracle_zero_intermediate_token() public {
        h.setZeroIntermediate(true);receipt.mint(address(h),1);vm.prank(address(myt));_bad(address(h),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.unwrapAndSwap,"",1),1,bytes4(0),address(this))),_revertString("No intermediate token"));assert(receipt.balanceOf(address(h))==1);
    }
}

