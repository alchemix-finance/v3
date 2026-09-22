// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,CoreAlchemistHarness,AlchemistV3} from "../common/CoreFixture.sol";
import {AlchemistTokenVault} from "../../../src/AlchemistTokenVault.sol";
contract AlchemistLiquidationSymbolic is CoreFixture {
    /// @custom:property AV3-SELF
    /// @notice AV3-SELF: check self close conserves shares.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_selfCloseConservesShares(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount);
        uint256 before=vault.balanceOf(ALICE);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.selfLiquidate,(id,BOB)));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.selfLiquidate,(id,ALICE)));
        _checkCDP(id,0,0,0);
        assert(vault.balanceOf(ALICE)==before+2*amount && vault.balanceOf(address(trans))==amount);
        assert(alc.getTotalDeposited()==0 && alc.totalDebt()==0 && alc.raw(32)==amount);
        assert(nft.ownerOf(id)==ALICE);
    }
    /// @notice AV3-SELF: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_selfCloseConservesShares(uint64 raw) public { test_check_selfCloseConservesShares(raw); }

    /// @custom:property AV3-SELF AV3-LIQUIDATE
    /// @notice AV3-LIQUIDATE, AV3-SELF: check healthy and zero price no progress reverts.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_healthyAndZeroPriceNoProgressReverts() public {
        uint256 id=_borrow(3e18,1e18);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.liquidate,(id)));
        vault.setPrice(0);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.liquidate,(id)));
        _checkStored(id,3e18,1e18);
    }
    function _checkStored(uint256 id,uint256 c,uint256 d) internal view { assert(alc.stored(id,0)==c && alc.stored(id,1)==d); }
    /// @custom:property AV3-LIQUIDATE AV3-SELF
    /// @notice AV3-LIQUIDATE, AV3-SELF: check loss liquidation and fee vault.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_lossLiquidationAndFeeVault(uint64 raw,uint16 feeRaw,uint64 fundingRaw) public {
        uint256 amount=uint256(raw)+100; uint256 id=_borrow(4*amount,amount);
        uint256 fee=uint256(feeRaw)%10001; uint256 funding=uint256(fundingRaw);
        _ok(address(alc),abi.encodeCall(AlchemistV3.setLiquidatorFee,(fee)));
        AlchemistTokenVault fees=new AlchemistTokenVault(address(asset),address(alc),address(this));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setAlchemistFeeVault,(address(fees)))); asset.mint(address(fees),funding);
        vault.setPrice(1e17);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.selfLiquidate,(id,ALICE)));
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.liquidate,(id)));
        uint256 expected=amount*fee/10000; if(expected>funding) expected=funding;
        assert(asset.balanceOf(BOB)==expected && fees.totalDeposits()==funding-expected);
        assert(alc.totalDebt()<amount && alc.stored(id,1)<=amount && alc.stored(id,0)<=4*amount);
        assert(alc.getTotalDeposited()+vault.balanceOf(address(trans))+vault.balanceOf(FEES)+vault.balanceOf(BOB)-1e30==4*amount);
    }
    /// @notice AV3-LIQUIDATE, AV3-SELF: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_lossLiquidationAndFeeVault(uint64 raw,uint16 feeRaw,uint64 fundingRaw) public { test_check_lossLiquidationAndFeeVault(raw,feeRaw,fundingRaw); }

    /// @custom:property AV3-LIQUIDATE AV3-REPAY
    /// @notice AV3-REPAY, AV3-LIQUIDATE: check earmark force repay fee branch.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_earmarkForceRepayFeeBranch(uint16 feeRaw) public {
        uint256 id=_borrow(2e18,1e18); uint256 fee=uint256(feeRaw)%10001;
        _ok(address(alc),abi.encodeCall(AlchemistV3.setRepaymentFee,(fee)));
        trans.configure(1e18,1e18); vm.roll(block.number+1); vault.setPrice(5e17);
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.liquidate,(id)));
        assert(alc.totalDebt()==0 && alc.cumulativeEarmarked()==0);
        assert(alc.stored(id,0)+vault.balanceOf(address(trans))+(vault.balanceOf(BOB)-1e30)+vault.balanceOf(FEES)==2e18);
    }
    /// @notice AV3-REPAY, AV3-LIQUIDATE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_earmarkForceRepayFeeBranch(uint16 feeRaw) public { test_check_earmarkForceRepayFeeBranch(feeRaw); }

    /// @custom:property AV3-BATCH
    /// @dev Two identical scenes are compared at the internal seam. No public per-item progress guard.
    /// @notice AV3-BATCH: check batch matches internal.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: FUZZ.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_fuzz_batchMatchesInternal(uint64 raw,bool duplicate,bool invalidFirst) public {
        uint256 amount=uint256(raw)+100; uint256 id=_borrow(4*amount,amount); vault.setPrice(1e17);
        uint256 snap=vm.snapshotState();
        uint256[] memory ids=new uint256[](3); ids[0]=invalidFirst?999:id; ids[1]=id; ids[2]=duplicate?id:0;
        (uint256 x,uint256 y,uint256 z)=abi.decode(_as(BOB,address(alc),abi.encodeCall(AlchemistV3.batchLiquidate,(ids))),(uint256,uint256,uint256));
        uint256 collateral=alc.stored(id,0); uint256 remaining=alc.totalDebt(); uint256 balance=vault.balanceOf(address(trans));
        assert(vm.revertToState(snap));
        uint256 sx; uint256 sy; uint256 sz;
        for(uint256 i;i<3;++i) if(ids[i]==id) {
            (uint256 a,uint256 b,uint256 c)=abi.decode(_as(BOB,address(alc),abi.encodeCall(CoreAlchemistHarness.internalLiquidate,(id))),(uint256,uint256,uint256)); sx+=a; sy+=b; sz+=c;
        }
        assert(x==sx && y==sy && z==sz);
        assert(alc.stored(id,0)==collateral && alc.totalDebt()==remaining && vault.balanceOf(address(trans))==balance);
    }
    /// @custom:property AV3-BATCH
    /// @notice AV3-BATCH: check empty and no progress batch.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: FUZZ.
    function test_check_emptyAndNoProgressBatch() public {
        uint256[] memory ids=new uint256[](2); ids[0]=999; ids[1]=_deposit(100);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.batchLiquidate,(ids)));
        ids=new uint256[](0); _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.batchLiquidate,(ids)));
        assert(alc.getTotalDeposited()==100);
    }
}

contract AlchemistLiquidationLemmas is CoreFixture {
    /// @custom:property AV3-LIQMATH
    /// @notice AV3-LIQMATH: check insolvent.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_insolvent(uint64 c,uint64 extra,uint16 bps) public {
        uint256 d=uint256(c)+extra; uint256 f=uint256(bps)%10001;
        (uint256 seize,uint256 burn,uint256 fee,uint256 outside)=abi.decode(_ok(address(alc),abi.encodeCall(AlchemistV3.calculateLiquidation,(c,d,15e17,2e18,15e17,f))),(uint256,uint256,uint256,uint256));
        assert(seize==c && burn==d && fee==0 && outside==d*f/10000);
    }
    /// @notice AV3-LIQMATH: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_insolvent(uint64 c,uint64 extra,uint16 bps) public { test_check_insolvent(c,extra,bps); }

    /// @custom:property AV3-LIQMATH
    /// @notice AV3-LIQMATH: check global stress.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_globalStress(uint64 raw,uint16 bps) public {
        uint256 d=uint256(raw)+1; uint256 f=uint256(bps)%10001;
        (uint256 seize,uint256 burn,uint256 fee,uint256 outside)=abi.decode(_ok(address(alc),abi.encodeCall(AlchemistV3.calculateLiquidation,(2*d,d,15e17,1e18,15e17,f))),(uint256,uint256,uint256,uint256));
        assert(seize==d && burn==d && fee==0 && outside==d*f/10000);
    }
    /// @notice AV3-LIQMATH: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_globalStress(uint64 raw,uint16 bps) public { test_check_globalStress(raw,bps); }

    /// @custom:property AV3-LIQMATH
    /// @notice AV3-LIQMATH: check surplus branch.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_surplusBranch(uint64 raw,uint16 bps) public {
        uint256 d=uint256(raw)+100; uint256 c=d+d/4; uint256 f=uint256(bps)%10001;
        (uint256 seize,uint256 burn,uint256 fee,uint256 outside)=abi.decode(_ok(address(alc),abi.encodeCall(AlchemistV3.calculateLiquidation,(c,d,15e17,2e18,15e17,f))),(uint256,uint256,uint256,uint256));
        uint256 expectedFee=(c-d)*f/10000; uint256 expectedBurn=(15e17*d/1e18-(c-expectedFee))*1e18/5e17;
        assert(fee==expectedFee && burn==expectedBurn && seize==burn+fee && outside==0);
        assert(seize<=c && burn<=d);
    }
    /// @notice AV3-LIQMATH: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_surplusBranch(uint64 raw,uint16 bps) public { test_check_surplusBranch(raw,bps); }

    /// @custom:property AV3-LIQMATH
    /// @notice AV3-LIQMATH: check healthy math.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_healthyMath(uint64 raw) public {
        uint256 d=uint256(raw)+1;
        (uint256 a,uint256 b,uint256 c,uint256 e)=alc.calculateLiquidation(3*d,d,15e17,2e18,15e17,0);
        assert(a==0 && b==0 && c==0 && e==0);
    }
    /// @notice AV3-LIQMATH: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_healthyMath(uint64 raw) public { test_check_healthyMath(raw); }

}
