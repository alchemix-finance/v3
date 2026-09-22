// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,AlchemistV3} from "../common/CoreFixture.sol";

contract AlchemistEarmarkSymbolic is CoreFixture {
    /// @custom:property AV3-PREVIEW AV3-SURVIVAL
    /// @notice AV3-PREVIEW, AV3-SURVIVAL: check preview then commit.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_previewThenCommit(uint64 raw,uint64 scheduledRaw) public {
        uint256 amount=uint256(raw)+1e18; uint256 schedule=uint256(scheduledRaw)%amount+1;
        uint256 id=_borrow(4*amount,amount); trans.configure(amount,schedule); vm.roll(block.number+1);
        (uint256 c,uint256 d,uint256 e)=alc.getCDP(id); uint256 projected=alc.getUnrealizedCumulativeEarmarked();
        assert(c==4*amount && e==schedule && projected==schedule);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==c && alc.stored(id,1)==d && alc.stored(id,2)==e);
        assert(projected==alc.cumulativeEarmarked() && d==amount && e<=d);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==c && alc.stored(id,1)==d && alc.stored(id,2)==e);
    }
    /// @notice AV3-PREVIEW, AV3-SURVIVAL: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_previewThenCommit(uint64 raw,uint64 scheduledRaw) public { test_check_previewThenCommit(raw,scheduledRaw); }

    /// @custom:property AV3-REDEEM AV3-SURVIVAL AV3-PREVIEW
    /// @notice AV3-PREVIEW, AV3-REDEEM, AV3-SURVIVAL: check redemption applied ratio.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_redemptionAppliedRatio(uint64 raw,uint64 requestRaw,uint16 feeRaw) public {
        uint256 amount=uint256(raw)+1e18; uint256 request=uint256(requestRaw)%amount+1;
        uint256 fee=uint256(feeRaw)%10001; uint256 id=_borrow(4*amount,amount);
        _ok(address(alc),abi.encodeCall(AlchemistV3.setProtocolFee,(fee)));
        trans.configure(amount,amount); vm.roll(block.number+1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        uint256 remainder=amount-request; uint256 ratio=remainder<=5256001?0:remainder*Q/amount;
        uint256 product=amount*ratio; uint256 surviving=product/Q+(product%Q==0?0:1);
        uint256 effective=amount-surviving;
        uint256 paid=abi.decode(_as(address(trans),address(alc),abi.encodeCall(AlchemistV3.redeem,(request))),(uint256));
        uint256 fees=effective*fee/10000;
        assert(paid==effective && alc.totalDebt()==amount-effective && alc.cumulativeEarmarked()==amount-effective);
        assert(vault.balanceOf(address(trans))==effective && vault.balanceOf(FEES)==fees);
        assert(alc.getTotalDeposited()==4*amount-effective-fees);
        (uint256 c,uint256 d,uint256 e)=alc.getCDP(id);
        assert(c==4*amount-effective-fees && d==amount-effective && e==d);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==c && alc.stored(id,1)==d && alc.stored(id,2)==e && e<=d && d<=amount);
    }
    /// @notice AV3-PREVIEW, AV3-REDEEM, AV3-SURVIVAL: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_redemptionAppliedRatio(uint64 raw,uint64 requestRaw,uint16 feeRaw) public { test_check_redemptionAppliedRatio(raw,requestRaw,feeRaw); }

    /// @custom:property AV3-REDEEM AV3-PACKED
    /// @notice AV3-REDEEM, AV3-PACKED: check dust boundary.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_dustBoundary(uint8 side) public {
        uint256 amount=1e18; uint256 remainder=5256000+uint256(side)%3; _borrow(4*amount,amount);
        trans.configure(amount,amount); vm.roll(block.number+1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(1)));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.redeem,(amount-remainder)));
        if(remainder<=5256001) assert(alc.totalDebt()==0 && alc.raw(29)==((uint256(1)<<129)|Q));
        else assert(alc.totalDebt()>0 && alc.raw(29)>>129==0);
    }
    /// @notice AV3-REDEEM, AV3-PACKED: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_dustBoundary(uint8 side) public { test_check_dustBoundary(side); }

    /// @custom:property AV3-COVER AV3-SURVIVAL
    /// @notice AV3-COVER, AV3-SURVIVAL: check cover consumed once.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_coverConsumedOnce(uint64 raw) public {
        uint256 cover=uint256(raw)+1; uint256 amount=4*cover; uint256 id=_borrow(3*amount,amount);
        _as(BOB,address(vault),abi.encodeWithSignature("transfer(address,uint256)",address(trans),cover));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.setTransmuterTokenBalance,(cover)));
        assert(alc.raw(32)==cover);
        trans.configure(amount,cover); vm.roll(block.number+1);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.raw(32)==0 && alc.cumulativeEarmarked()==0);
        vm.roll(block.number+1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.cumulativeEarmarked()>=cover && alc.raw(32)==0);
    }
    /// @notice AV3-COVER, AV3-SURVIVAL: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_coverConsumedOnce(uint64 raw) public { test_check_coverConsumedOnce(raw); }

    /// @custom:property AV3-COVER
    /// @notice AV3-COVER: check balance down does not erase historical cover.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_balanceDownDoesNotEraseHistoricalCover(uint64 raw) public {
        uint256 amount=uint256(raw)+1;
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.setTransmuterTokenBalance,(amount)));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.setTransmuterTokenBalance,(0)));
        assert(alc.raw(32)==amount && alc.lastTransmuterTokenBalance()==0);
    }
    /// @notice AV3-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_balanceDownDoesNotEraseHistoricalCover(uint64 raw) public { test_check_balanceDownDoesNotEraseHistoricalCover(raw); }

    /// @custom:property AV3-SURVIVAL AV3-PREVIEW AV3-DEPOSIT AV3-MINT
    /// @notice AV3-PREVIEW, AV3-DEPOSIT, AV3-MINT, AV3-SURVIVAL: check cross epoch historical redemption.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_crossEpochHistoricalRedemption(uint32 raw) public {
        uint256 amount=uint256(raw)+1e18; uint256 id=_borrow(10*amount,amount);
        trans.configure(amount,amount); vm.roll(block.number+1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.redeem,(amount)));
        _as(address(trans),address(vault),abi.encodeWithSignature("transfer(address,uint256)",BOB,amount));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.reduceSyntheticsIssued,(amount)));
        _as(ALICE,address(debt),abi.encodeWithSignature("burn(uint256)",amount));
        trans.configure(0,0); vm.roll(block.number+1);
        (uint256 c,uint256 d,)=alc.getCDP(id); assert(c==9*amount && d==0);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(amount,ALICE,id)));
        _checkCDP(id,c+amount,0,0);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,amount,ALICE)));
        _checkCDP(id,c+amount,amount,0);
        trans.configure(amount,amount); vm.roll(block.number+1);
        (uint256 pc,uint256 pd,uint256 pe)=alc.getCDP(id);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==pc && alc.stored(id,1)==pd && alc.stored(id,2)==pe);
        assert(pd==amount && pe<=pd);
    }
    /// @notice AV3-PREVIEW, AV3-DEPOSIT, AV3-MINT, AV3-SURVIVAL: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_crossEpochHistoricalRedemption(uint32 raw) public { test_check_crossEpochHistoricalRedemption(raw); }

    /// @custom:property AV3-SURVIVAL AV3-PREVIEW AV3-REDEEM
    /// @notice Check an account that crosses both epochs without an intermediate sync.
    /// @dev Technique: exact full-redemption transition through original code. Classification: DECOMPOSE.
    /// @dev Domain: uint64 debt plus 1e18 limits products below 256 bits.
    function test_check_unsyncedCrossedEpoch(uint64 raw) public {
        uint256 amount=uint256(raw)+1e18; uint256 id=_borrow(4*amount,amount);
        trans.configure(amount,amount); vm.roll(block.number+1);
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.redeem,(amount)));
        assert(alc.stored(id,1)==amount); // Account still has the old checkpoint.
        _checkCDP(id,3*amount,0,0);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==3*amount && alc.stored(id,1)==0 && alc.stored(id,2)==0);
    }
    /// @custom:property AV3-REDEEM
    /// @notice Check the fee-skip branch when redemption consumes all tracked shares.
    /// @dev Technique: exact loss boundary with original transitions. Classification: DECOMPOSE.
    function test_check_feeSkippedWithoutRemainingCollateral() public {
        uint256 amount=1e18; uint256 id=_borrow(4*amount,amount);
        _ok(address(alc),abi.encodeCall(AlchemistV3.setProtocolFee,(10000)));
        vault.setPrice(25e16); trans.configure(amount,amount); vm.roll(block.number+1);
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.redeem,(amount)));
        assert(alc.getTotalDeposited()==0 && vault.balanceOf(address(trans))==4*amount && vault.balanceOf(FEES)==0);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id))); _checkCDP(id,0,0,0);
    }
}
