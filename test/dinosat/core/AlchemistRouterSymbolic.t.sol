// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,CoreAlchemistHarness,ERC1967Proxy,AlchemistV3,AlchemistRouter,AlchemistV3Position} from "../common/CoreFixture.sol";

abstract contract RouterFixture is CoreFixture {
    AlchemistRouter internal router;
    function setUp() public virtual override {
        super.setUp(); router=new AlchemistRouter(address(alc)); asset.mint(ALICE,1e30); asset.mint(BOB,1e30);
        vm.prank(BOB); asset.approve(address(router),type(uint256).max);
        vm.prank(ALICE); asset.approve(address(router),type(uint256).max);
        vm.prank(ALICE); vault.approve(address(router),type(uint256).max);
        vm.deal(ALICE,1e30); vm.deal(address(this),1e30); vm.deal(address(asset),1e30);
    }
    function _value(address actor,uint256 amount,bytes memory data) internal returns(bytes memory result) {
        vm.prank(actor); (bool ok,bytes memory r)=address(router).call{value:amount}(data); assert(ok); return r;
    }
    function _cleanAllowances() internal view {
        assert(asset.allowance(address(router),address(vault))==0 && vault.allowance(address(router),address(alc))==0);
    }
    function _approve(uint256 id) internal { _as(ALICE,address(nft),abi.encodeWithSignature("approve(address,uint256)",address(router),id)); }
}

contract AlchemistRouterDepositSymbolic is RouterFixture {
    /// @custom:property ROUTER-INIT
    /// @notice ROUTER-INIT: check constructor and direct eth.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_constructorAndDirectETH() public {
        try new AlchemistRouter(address(0)) { assert(false); } catch {}
        (bool ok,)=address(router).call{value:1}(""); assert(!ok);
        assert(router.alchemist()==address(alc));
    }
    /// @custom:property ROUTER-DEPOSIT
    /// @notice ROUTER-DEPOSIT: check underlying deposit borrow.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_underlyingDepositBorrow(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 before=asset.balanceOf(ALICE);
        uint256 id=abi.decode(_as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,3*amount,amount,3*amount,block.timestamp))),(uint256));
        assert(nft.ownerOf(id)==ALICE && asset.balanceOf(ALICE)==before-3*amount && debt.balanceOf(ALICE)==amount);
        _checkCDP(id,3*amount,amount,0); _cleanAllowances();
    }
    /// @notice ROUTER-DEPOSIT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_underlyingDepositBorrow(uint64 raw) public { test_check_underlyingDepositBorrow(raw); }

    /// @custom:property ROUTER-DEPOSIT
    /// @notice ROUTER-DEPOSIT: check myt deposit existing borrow.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_mytDepositExistingBorrow(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_deposit(3*amount);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,address(router),amount)));
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositMYT,(id,amount,amount,block.timestamp)));
        _checkCDP(id,4*amount,amount,0); assert(debt.balanceOf(ALICE)==amount && alc.mintAllowance(id,address(router))==0); _cleanAllowances();
    }
    /// @notice ROUTER-DEPOSIT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_mytDepositExistingBorrow(uint64 raw) public { test_check_mytDepositExistingBorrow(raw); }

    /// @custom:property ROUTER-DEPOSIT
    /// @notice ROUTER-DEPOSIT: check eth deposit and vault only.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_ethDepositAndVaultOnly(uint64 raw) public {
        uint256 amount=uint256(raw)+1;
        uint256 id=abi.decode(_value(ALICE,3*amount,abi.encodeCall(AlchemistRouter.depositETH,(0,amount,3*amount,block.timestamp))),(uint256));
        _checkCDP(id,3*amount,amount,0); assert(nft.ownerOf(id)==ALICE && debt.balanceOf(ALICE)==amount);
        uint256 before=vault.balanceOf(ALICE);
        _value(ALICE,amount,abi.encodeCall(AlchemistRouter.depositETHToVaultOnly,(amount,block.timestamp)));
        assert(vault.balanceOf(ALICE)==before+amount); _cleanAllowances();
    }
    /// @notice ROUTER-DEPOSIT: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_ethDepositAndVaultOnly(uint64 raw) public { test_check_ethDepositAndVaultOnly(raw); }

    /// @custom:property ROUTER-DEPOSIT
    /// @notice ROUTER-DEPOSIT: check deposit guards and rollback.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_depositGuardsAndRollback() public {
        uint256 before=asset.balanceOf(ALICE); uint256 id=_deposit(100);
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,0,0,0,block.timestamp)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,101,block.timestamp)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,100,0,0,block.timestamp-1)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.depositMYT,(id,100,1000,block.timestamp)));
        _fails(BOB,address(router),abi.encodeCall(AlchemistRouter.depositUnderlying,(id,1,0,0,block.timestamp)));
        assert(asset.balanceOf(ALICE)==before && nft.ownerOf(id)==ALICE); _checkCDP(id,100,0,0); _cleanAllowances();
    }
}

contract AlchemistRouterRepayExitSymbolic is RouterFixture {
    /// @custom:property ROUTER-REPAY
    /// @notice ROUTER-REPAY: check underlying repay refund ignores donation.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_underlyingRepayRefundIgnoresDonation(uint64 raw,uint64 giftRaw) public {
        uint256 amount=uint256(raw)+1; uint256 gift=uint256(giftRaw)+1; uint256 id=_borrow(3*amount,amount);
        vault.mintFixture(address(router),gift); vm.roll(block.number+1); uint256 before=vault.balanceOf(ALICE);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.repayUnderlying,(id,2*amount,2*amount,block.timestamp)));
        assert(vault.balanceOf(ALICE)==before+amount && vault.balanceOf(address(router))==gift);
        assert(vault.balanceOf(address(trans))==amount && alc.totalDebt()==0); _cleanAllowances();
    }
    /// @notice ROUTER-REPAY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_underlyingRepayRefundIgnoresDonation(uint64 raw,uint64 giftRaw) public { test_check_underlyingRepayRefundIgnoresDonation(raw,giftRaw); }

    /// @custom:property ROUTER-REPAY
    /// @notice ROUTER-REPAY: check eth repay refund.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_ethRepayRefund(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount); vm.roll(block.number+1); uint256 before=vault.balanceOf(ALICE);
        _value(ALICE,2*amount,abi.encodeCall(AlchemistRouter.repayETH,(id,2*amount,block.timestamp)));
        assert(vault.balanceOf(ALICE)==before+amount && alc.totalDebt()==0); _cleanAllowances();
    }
    /// @notice ROUTER-REPAY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_ethRepayRefund(uint64 raw) public { test_check_ethRepayRefund(raw); }

    /// @custom:property ROUTER-WITHDRAW
    /// @notice ROUTER-WITHDRAW: check withdraw underlying custody.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_withdrawUnderlyingCustody(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_deposit(amount); _approve(id); uint256 before=asset.balanceOf(ALICE);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.withdrawUnderlying,(id,amount,amount,block.timestamp)));
        assert(asset.balanceOf(ALICE)==before+amount && nft.ownerOf(id)==ALICE); _checkCDP(id,0,0,0);
    }
    /// @notice ROUTER-WITHDRAW: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_withdrawUnderlyingCustody(uint64 raw) public { test_check_withdrawUnderlyingCustody(raw); }

    /// @custom:property ROUTER-WITHDRAW
    /// @notice ROUTER-WITHDRAW: check withdraw ethcustody.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_withdrawETHCustody(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_deposit(amount); _approve(id); uint256 before=ALICE.balance;
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.withdrawETH,(id,amount,amount,block.timestamp)));
        assert(ALICE.balance==before+amount && nft.ownerOf(id)==ALICE && address(router).balance==0);
    }
    /// @notice ROUTER-WITHDRAW: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_withdrawETHCustody(uint64 raw) public { test_check_withdrawETHCustody(raw); }

    /// @custom:property ROUTER-WITHDRAW ROUTER-CLOSE
    /// @notice ROUTER-WITHDRAW, ROUTER-CLOSE: check exit ownership slippage and expiry.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_exitOwnershipSlippageAndExpiry() public {
        uint256 id=_borrow(3e18,1e18); _approve(id);
        _fails(BOB,address(router),abi.encodeCall(AlchemistRouter.withdrawUnderlying,(id,1,0,block.timestamp)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.withdrawUnderlying,(id,1,2,block.timestamp)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.withdrawETH,(id,1,0,block.timestamp-1)));
        _fails(BOB,address(router),abi.encodeCall(AlchemistRouter.selfLiquidateToUnderlying,(id,0,block.timestamp)));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.selfLiquidateToETH,(id,3e18,block.timestamp)));
        assert(nft.ownerOf(id)==ALICE); _checkCDP(id,3e18,1e18,0);
    }
    /// @custom:property ROUTER-CLOSE
    /// @notice ROUTER-CLOSE: check close only redeems balance delta.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_closeOnlyRedeemsBalanceDelta(uint64 raw,uint64 giftRaw) public {
        uint256 amount=uint256(raw)+1; uint256 gift=uint256(giftRaw)+1; uint256 id=_borrow(3*amount,amount); _approve(id);
        vault.mintFixture(address(router),gift); uint256 before=asset.balanceOf(ALICE);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.selfLiquidateToUnderlying,(id,2*amount,block.timestamp)));
        assert(asset.balanceOf(ALICE)==before+2*amount && vault.balanceOf(address(router))==gift && nft.ownerOf(id)==ALICE);
        _checkCDP(id,0,0,0);
    }
    /// @notice ROUTER-CLOSE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_closeOnlyRedeemsBalanceDelta(uint64 raw,uint64 giftRaw) public { test_check_closeOnlyRedeemsBalanceDelta(raw,giftRaw); }

    /// @custom:property ROUTER-CLOSE
    /// @notice ROUTER-CLOSE: check close eth.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_closeETH(uint64 raw) public {
        uint256 amount=uint256(raw)+1; uint256 id=_borrow(3*amount,amount); _approve(id); uint256 before=ALICE.balance;
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.selfLiquidateToETH,(id,2*amount,block.timestamp)));
        assert(ALICE.balance==before+2*amount && nft.ownerOf(id)==ALICE); _checkCDP(id,0,0,0);
    }
    /// @notice ROUTER-CLOSE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_closeETH(uint64 raw) public { test_check_closeETH(raw); }

    /// @custom:property ROUTER-CLAIM
    /// @notice ROUTER-CLAIM: check claim forwards refund.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_claimForwardsRefund(uint64 raw,uint64 refundRaw,bool eth) public {
        uint256 amount=uint256(raw)+1; uint256 refund=uint256(refundRaw);
        trans.seedClaim(ALICE,vault,debt,amount,refund);
        _as(ALICE,address(trans),abi.encodeWithSignature("approve(address,uint256)",address(router),1));
        _fails(BOB,address(router),abi.encodeCall(AlchemistRouter.claimRedemption,(1,0,block.timestamp,eth)));
        uint256 before=eth?ALICE.balance:asset.balanceOf(ALICE);
        _as(ALICE,address(router),abi.encodeCall(AlchemistRouter.claimRedemption,(1,amount,block.timestamp,eth)));
        assert((eth?ALICE.balance:asset.balanceOf(ALICE))==before+amount && debt.balanceOf(ALICE)==refund);
        assert(vault.balanceOf(address(router))==0 && debt.balanceOf(address(router))==0);
    }
    /// @notice ROUTER-CLAIM: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_claimForwardsRefund(uint64 raw,uint64 refundRaw,bool eth) public { test_check_claimForwardsRefund(raw,refundRaw,eth); }

    /// @custom:property ROUTER-CLAIM
    /// @notice ROUTER-CLAIM: check zero yield claim rolls back.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_zeroYieldClaimRollsBack() public {
        trans.seedClaim(ALICE,vault,debt,0,100);
        _as(ALICE,address(trans),abi.encodeWithSignature("approve(address,uint256)",address(router),1));
        _fails(ALICE,address(router),abi.encodeCall(AlchemistRouter.claimRedemption,(1,0,block.timestamp,false)));
        assert(trans.ownerOf(1)==ALICE && debt.balanceOf(address(trans))==100);
    }
}
