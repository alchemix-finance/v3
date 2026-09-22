// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoStrategyArithmeticTest is Test {
    /// @notice STR-ETHER-SIZE. Ceiling gross shares fund the requested net shares. Product below 2^64*10000. This lemma does not prove the external conversions.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_ether_gross(uint64 raw,uint16 feeRaw) public pure {
        uint256 n=uint256(raw)+1;uint256 fee=uint256(feeRaw)%10000;uint256 d=10000-fee;uint256 product=n*10000;uint256 q=product/d+(product%d==0?0:1);assert(q*d>=product);assert((q-1)*d<product);
    }
    /// @notice Same property and domain as test_check_lemma_ether_gross.
    function test_fuzz_lemma_ether_gross(uint64 raw,uint16 feeRaw) public pure { test_check_lemma_ether_gross(raw,feeRaw); }
    /// @notice STR-DAO-MAXABS. Exact ceil plus LP tolerance at configured price one; product below 2^64*1e18.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_max_abs(uint64 raw) public pure {
        uint256 n=uint256(raw);uint256 d=1e18;uint256 product=n*1e18;uint256 q=product/d+(product%d==0?0:1)+1e6;assert(q>=n);assert(q-n==1e6);
    }
    /// @notice Same property and domain as test_check_lemma_dao_max_abs.
    function test_fuzz_lemma_dao_max_abs(uint64 raw) public pure { test_check_lemma_dao_max_abs(raw); }
    /// @notice STR-DAO-MINABS. Ceiling allocation floor at configured 0.95 price. Product below 2^64*1e18.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_min_abs(uint64 raw) public pure {
        uint256 n=uint256(raw);uint256 product=n*95e16;uint256 q=product/1e18+(product%1e18==0?0:1);assert(q*1e18>=product);assert(q==0||(q-1)*1e18<product);
    }
    /// @notice Same property and domain as test_check_lemma_dao_min_abs.
    function test_fuzz_lemma_dao_min_abs(uint64 raw) public pure { test_check_lemma_dao_min_abs(raw); }
    /// @notice STR-DAO-MINVP. Floor virtual-price minimum at VP=1e18. Product below 2^64*1e22, preserving production order.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_min_vp(uint64 raw,uint16 slipRaw) public pure {
        uint256 n=uint256(raw);uint256 slip=uint256(slipRaw)%9999;uint256 product=n*1e18*(10000-slip);uint256 d=1e18*10000;uint256 q=product/d;assert(q*d<=product);assert(product-q*d<d);
    }
    /// @notice Same property and domain as test_check_lemma_dao_min_vp.
    function test_fuzz_lemma_dao_min_vp(uint64 raw,uint16 slipRaw) public pure { test_check_lemma_dao_min_vp(raw,slipRaw); }
    /// @notice STR-DAO-MAXVP. Ceiling virtual-price maximum plus 1e6 tolerance, VP=1e18. Product below 2^64*1e22.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_max_vp(uint64 raw,uint16 slipRaw) public pure {
        uint256 n=uint256(raw);uint256 slip=uint256(slipRaw)%9999;uint256 product=n*1e18*10000;uint256 d=1e18*(10000-slip);uint256 q=product/d+(product%d==0?0:1);assert(q*d>=product);assert(q==0||(q-1)*d<product);uint256 withTolerance=q+1e6;assert(withTolerance-q==1e6);
    }
    /// @notice Same property and domain as test_check_lemma_dao_max_vp.
    function test_fuzz_lemma_dao_max_vp(uint64 raw,uint16 slipRaw) public pure { test_check_lemma_dao_max_vp(raw,slipRaw); }
    /// @notice STR-DAO-VALUE. Value rounds down. Product below 2^128, no assembly or external mock in this lemma.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_value(uint64 raw,uint64 priceRaw) public pure {
        uint256 n=uint256(raw);uint256 p=uint256(priceRaw)+1;uint256 product=n*p;uint256 q=product/1e18;assert(q*1e18<=product);assert(product-q*1e18<1e18);
    }
    /// @notice Same property and domain as test_check_lemma_dao_value.
    function test_fuzz_lemma_dao_value(uint64 raw,uint64 priceRaw) public pure { test_check_lemma_dao_value(raw,priceRaw); }
    /// @notice STR-DAO-SWAP-EXIT. Ceiling LP value of burned shares at explicit NAV two. Product below 2^129.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_lp_spent(uint64 raw,uint64 sharesRaw) public pure {
        uint256 s=uint256(sharesRaw)+1;uint256 spent=uint256(raw)%s;uint256 value=s*2;uint256 product=spent*value;uint256 q=product/s+(product%s==0?0:1);assert(q*s>=product);assert(q==0||(q-1)*s<product);
    }
    /// @notice Same property and domain as test_check_lemma_dao_lp_spent.
    function test_fuzz_lemma_dao_lp_spent(uint64 raw,uint64 sharesRaw) public pure { test_check_lemma_dao_lp_spent(raw,sharesRaw); }
    /// @notice STR-DAO-PREVIEW. Position-only preview cannot exceed amount or capacity after floor haircut.
    /// @dev Technique: exact integer arithmetic model. Production refinement is separate.
    /// @dev Classification: INLINE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_lemma_dao_preview(uint64 raw,uint64 requested) public pure {
        uint256 capacity=uint256(raw);uint256 amount=uint256(requested);uint256 funded=capacity<amount?capacity:amount;uint256 out=funded*9975/10000;assert(out<=funded&&out<=amount);
    }
    /// @notice Same property and domain as test_check_lemma_dao_preview.
    function test_fuzz_lemma_dao_preview(uint64 raw,uint64 requested) public pure { test_check_lemma_dao_preview(raw,requested); }
}

