// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {FixedPointMath} from "../../../src/libraries/FixedPointMath.sol";

/// @dev Exact abstract specifications for core mulDivUp call sites.
/// All products are restricted to fit uint256. Tests use uint96 factors (product <2^192).
/// These helpers are specifications, not replacements for production bytecode.
library CoreArithmeticSpec {
    function ceilProduct(uint256 x,uint256 y,uint256 d) internal pure returns(uint256) {
        uint256 product=x*y; return product/d+(product%d==0?0:1);
    }
    // AlchemistV3: getMaxWithdrawable, withdraw, _addDebt and _requiredLockedShares.
    function lockedShares(uint256 debtShares,uint256 minimum) internal pure returns(uint256) { return ceilProduct(debtShares,minimum,1e18); }
    // AlchemistV3: _maxRepaymentFeeInYield and _isUnderCollateralized.
    function requiredDebtValue(uint256 debt,uint256 ratio) internal pure returns(uint256) {return ceilProduct(debt,ratio,1e18);}
    // AlchemistV3: _sync.
    function redeemedShareDebit(uint256 redeemedDebt,uint256 globalSharesDelta,uint256 globalDebtDelta) internal pure returns(uint256) {return ceilProduct(redeemedDebt,globalSharesDelta,globalDebtDelta);}
    // AlchemistV3: _earmark and _calculateUnrealizedDebt, same cover-consumption rounding.
    function coverSharesUsed(uint256 usedDebt,uint256 pendingShares,uint256 coverDebt) internal pure returns(uint256) {return ceilProduct(usedDebt,pendingShares,coverDebt);}
}
contract AlchemistArithmeticLemmas {
    /// @notice AV3-CAPACITY, AV3-WITHDRAW, AV3-MINT, AV3-VALUE: refine each lock helper against the actual math library.
    /// @custom:property AV3-CAPACITY AV3-WITHDRAW AV3-MINT AV3-VALUE
    /// @dev Technique: T4 inline mulDiv with original-library refinement. Classification: INLINE.
    /// @dev Domain: uint96 products fit 192 bits. This is an explicit bounded lemma.
    function test_check_lockRefinement(uint96 a,uint96 b) public view {
        uint256 expected=CoreArithmeticSpec.lockedShares(a,b);
        assert(FixedPointMath.mulDivUp(a,b,1e18)==expected);
        assert(CoreArithmeticSpec.requiredDebtValue(a,b)==expected);
    }
    /// @notice AV3-SURVIVAL, AV3-COVER, AV3-PREVIEW: refine exact ceil rounding against the actual library.
    /// @custom:property AV3-SURVIVAL AV3-COVER AV3-PREVIEW
    /// @dev Technique: T4 inline mulDiv with original-library refinement. Classification: INLINE.
    /// @dev Domain: uint96 factors and nonzero constructed denominator avoid product overflow.
    function test_check_deltaRefinement(uint96 a,uint96 b,uint96 rawD) public view {
        uint256 d=uint256(rawD)+1;
        uint256 expected=CoreArithmeticSpec.redeemedShareDebit(a,b,d);
        assert(FixedPointMath.mulDivUp(a,b,d)==expected);
        assert(CoreArithmeticSpec.coverSharesUsed(a,b,d)==expected);
        uint256 product=uint256(a)*b;
        assert(expected*d>=product && expected*d-product<d);
    }
    /// @notice AV3-SURVIVAL, AV3-COVER: fuzz the same bounded refinement without assumptions.
    /// @custom:property AV3-SURVIVAL AV3-COVER
    /// @dev Technique: exact bounded differential oracle. Classification: FUZZ.
    function test_fuzz_deltaRefinement(uint96 a,uint96 b,uint96 d) public view {test_check_deltaRefinement(a,b,d);}
}
