// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,AlchemistV3} from "../common/CoreFixture.sol";

contract AlchemistDepositBorrowSymbolic is CoreFixture {
    /// @custom:property AV3-DEPOSIT AV3-DEPOSITED AV3-VALUE
    /// @notice AV3-DEPOSITED, AV3-VALUE, AV3-DEPOSIT: check deposit and donation.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_depositAndDonation(uint64 a,uint64 b) public {
        uint256 amount=uint256(a)+1; uint256 donation=uint256(b)+1; uint256 id=_deposit(amount);
        _as(BOB,address(vault),abi.encodeWithSignature("transfer(address,uint256)",address(alc),donation));
        _checkCDP(id,amount,0,0);
        assert(alc.getTotalDeposited()==amount && alc.getTotalUnderlyingValue()==amount);
        assert(vault.balanceOf(address(alc))==amount+donation && nft.ownerOf(id)==ALICE);
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.deposit,(amount,BOB,id)));
        _checkCDP(id,2*amount,0,0); assert(nft.ownerOf(id)==ALICE && alc.getTotalDeposited()==2*amount);
    }
    /// @notice AV3-DEPOSITED, AV3-VALUE, AV3-DEPOSIT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_depositAndDonation(uint64 a,uint64 b) public { test_check_depositAndDonation(a,b); }

    /// @custom:property AV3-DEPOSIT AV3-WITHDRAW
    /// @notice AV3-DEPOSIT, AV3-WITHDRAW: check invalid deposit and withdrawal atomic.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_invalidDepositAndWithdrawalAtomic() public {
        uint256 id=_deposit(100);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(0,ALICE,id)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(1,address(0),0)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(1,ALICE,2)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setDepositCap,(100)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(1,ALICE,id)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.withdraw,(1,BOB,id)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.withdraw,(101,ALICE,id)));
        _checkCDP(id,100,0,0); assert(alc.getTotalDeposited()==100 && vault.balanceOf(address(alc))==100);
    }
    /// @custom:property AV3-WITHDRAW AV3-CAPACITY AV3-VALUE
    /// @notice AV3-CAPACITY, AV3-VALUE, AV3-WITHDRAW: check borrow and maximum withdrawal.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_borrowAndMaximumWithdrawal(uint64 input) public {
        uint256 amount=uint256(input)+2; uint256 collateral=amount*3; uint256 id=_borrow(collateral,amount);
        uint256 required=(amount*15e17+1e18-1)/1e18;
        uint256 free=collateral-required;
        assert(alc.getMaxBorrowable(id)==amount && alc.getMaxWithdrawable(id)==free);
        assert(alc.getTotalLockedUnderlyingValue()==required && alc.totalValue(id)==collateral);
        uint256 before=vault.balanceOf(ALICE);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.withdraw,(free,ALICE,id)));
        assert(vault.balanceOf(ALICE)==before+free && alc.getTotalDeposited()==required);
        _checkCDP(id,required,amount,0);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.withdraw,(1,ALICE,id)));
    }
    /// @notice AV3-CAPACITY, AV3-VALUE, AV3-WITHDRAW: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_borrowAndMaximumWithdrawal(uint64 input) public { test_check_borrowAndMaximumWithdrawal(input); }

    /// @custom:property AV3-CAPACITY AV3-VALUE AV3-DEPOSIT AV3-MINT
    /// @notice AV3-CAPACITY, AV3-VALUE, AV3-DEPOSIT, AV3-MINT: check loss capacity and bad debt guard.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_lossCapacityAndBadDebtGuard(uint64 input) public {
        uint256 amount=uint256(input)+10; uint256 id=_borrow(3*amount,amount);
        vault.setPrice(1e17);
        assert(alc.getMaxBorrowable(id)==0 && alc.getMaxWithdrawable(id)==0);
        assert(alc.getTotalLockedUnderlyingValue()==alc.getTotalUnderlyingValue());
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(amount,ALICE,id)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,1,ALICE)));
        assert(alc.totalDebt()==amount && alc.totalSyntheticsIssued()==amount);
    }
    /// @notice AV3-CAPACITY, AV3-VALUE, AV3-DEPOSIT, AV3-MINT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_lossCapacityAndBadDebtGuard(uint64 input) public { test_check_lossCapacityAndBadDebtGuard(input); }

    /// @custom:property AV3-VALUE AV3-CONVERT
    /// @notice AV3-VALUE, AV3-CONVERT: check zero price explicit domain.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_zeroPriceExplicitDomain() public {
        _deposit(100); vault.setPrice(0);
        assert(alc.getTotalUnderlyingValue()==0 && alc.getTotalLockedUnderlyingValue()==0);
        assert(alc.convertYieldTokensToDebt(100)==0);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.convertDebtTokensToYield,(1)));
    }
    /// @custom:property AV3-MINT
    /// @notice AV3-MINT: check mint accounting and authority.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_mintAccountingAndAuthority(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount);
        _checkCDP(id,3*amount,amount,0);
        assert(alc.totalDebt()==amount && alc.totalSyntheticsIssued()==amount && debt.balanceOf(ALICE)==amount);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.mint,(id,1,BOB)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.mintFrom,(id,1,BOB)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,amount+1,ALICE)));
        _checkCDP(id,3*amount,amount,0);
    }
    /// @notice AV3-MINT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_mintAccountingAndAuthority(uint64 raw) public { test_check_mintAccountingAndAuthority(raw); }

    /// @custom:property AV3-ALLOWANCE AV3-MINT
    /// @notice AV3-MINT, AV3-ALLOWANCE: check allowance consumed then transfer invalidates.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_allowanceConsumedThenTransferInvalidates(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_deposit(6*amount); uint256 second=_deposit(amount);
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,amount)));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,2*amount)));
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.mintFrom,(id,amount,BOB)));
        assert(alc.mintAllowance(id,BOB)==amount && debt.balanceOf(BOB)==amount);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(second,BOB,amount)));
        _as(ALICE,address(nft),abi.encodeWithSignature("transferFrom(address,address,uint256)",ALICE,BOB,id));
        assert(alc.mintAllowance(id,BOB)==0 && alc.mintAllowance(second,BOB)==amount);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.resetMintAllowances,(id)));
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.resetMintAllowances,(id)));
        assert(nft.ownerOf(id)==BOB);
    }
    /// @notice AV3-MINT, AV3-ALLOWANCE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_allowanceConsumedThenTransferInvalidates(uint64 raw) public { test_check_allowanceConsumedThenTransferInvalidates(raw); }

    /// @custom:property AV3-ALLOWANCE
    /// @notice AV3-ALLOWANCE: check owner and nftreset.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_ownerAndNFTReset(uint64 raw) public {
        uint256 id=_deposit(10); uint256 amount=uint256(raw)+1;
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,amount)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.resetMintAllowances,(id)));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.resetMintAllowances,(id))); assert(alc.mintAllowance(id,BOB)==0);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,amount)));
        _as(address(nft),address(alc),abi.encodeCall(AlchemistV3.resetMintAllowances,(id))); assert(alc.mintAllowance(id,BOB)==0);
    }
    /// @notice AV3-ALLOWANCE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_ownerAndNFTReset(uint64 raw) public { test_check_ownerAndNFTReset(raw); }

}

contract AlchemistRepaymentSymbolic is CoreFixture {
    /// @custom:property AV3-BURN AV3-MINT
    /// @notice AV3-MINT, AV3-BURN: check burn accounting and block guards.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_burnAccountingAndBlockGuards(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.burn,(amount,id)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.repay,(amount,id)));
        vm.roll(block.number+1);
        uint256 burned=abi.decode(_as(ALICE,address(alc),abi.encodeCall(AlchemistV3.burn,(amount+1,id))),(uint256));
        assert(burned==amount && alc.totalDebt()==0 && alc.totalSyntheticsIssued()==0 && debt.totalSupply()==0);
        _checkCDP(id,3*amount,0,0);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,1,ALICE)));
    }
    /// @notice AV3-MINT, AV3-BURN: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_burnAccountingAndBlockGuards(uint64 raw) public { test_check_burnAccountingAndBlockGuards(raw); }

    /// @custom:property AV3-BURN
    /// @notice AV3-BURN: check locked burn limit.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_lockedBurnLimit(uint64 raw) public {
        uint256 amount=uint256(raw)+2; uint256 id=_borrow(3*amount,amount);
        trans.configure(amount,0); vm.roll(block.number+1);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.burn,(1,id)));
        assert(alc.totalDebt()==amount && debt.balanceOf(ALICE)==amount);
    }
    /// @notice AV3-BURN: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_lockedBurnLimit(uint64 raw) public { test_check_lockedBurnLimit(raw); }

    /// @custom:property AV3-BURN AV3-REPAY AV3-COVER
    /// @notice AV3-BURN, AV3-REPAY, AV3-COVER: check unearmarked repay credit cap.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_unearmarkedRepayCreditCap(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount); vm.roll(block.number+1);
        uint256 paid=abi.decode(_as(ALICE,address(alc),abi.encodeCall(AlchemistV3.repay,(2*amount,id))),(uint256));
        assert(paid==amount && vault.balanceOf(address(trans))==amount && alc.raw(32)==amount);
        assert(alc.totalDebt()==0 && alc.totalSyntheticsIssued()==amount && alc.cumulativeEarmarked()==0);
        _checkCDP(id,3*amount,0,0);
    }
    /// @notice AV3-BURN, AV3-REPAY, AV3-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_unearmarkedRepayCreditCap(uint64 raw) public { test_check_unearmarkedRepayCreditCap(raw); }

    /// @custom:property AV3-REPAY AV3-COVER
    /// @notice AV3-REPAY, AV3-COVER: check earmarked repay fee.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_earmarkedRepayFee(uint64 raw,uint16 feeRaw) public {
        uint256 amount=uint256(raw)+100; uint256 fee=uint256(feeRaw)%10001;
        uint256 id=_borrow(4*amount,amount); alc.setProtocolFee(fee);
        trans.configure(amount,amount); vm.roll(block.number+1);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        uint256 earmarked=alc.cumulativeEarmarked(); assert(earmarked==amount);
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.burn,(1,id)));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.repay,(amount,id)));
        uint256 fees=amount*fee/10000;
        _checkCDP(id,4*amount-fees,0,0);
        assert(vault.balanceOf(FEES)==fees && vault.balanceOf(address(trans))==amount);
        assert(alc.raw(32)==0 && alc.cumulativeEarmarked()==0 && alc.getTotalDeposited()==4*amount-fees);
    }
    /// @notice AV3-REPAY, AV3-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_earmarkedRepayFee(uint64 raw,uint16 feeRaw) public { test_check_earmarkedRepayFee(raw,feeRaw); }

}
