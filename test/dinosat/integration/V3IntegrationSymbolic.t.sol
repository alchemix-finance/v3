// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {CoreFixture,CoreToken,CoreAlchemistHarness,ERC1967Proxy,AlchemistV3,AlchemistV3Position,AlchemistRouter} from "../common/CoreFixture.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {Transmuter} from "../../../src/Transmuter.sol";
import {ITransmuter} from "../../../src/interfaces/ITransmuter.sol";

/// @dev Production VaultV2 with one explicit transaction-boundary seam.
/// Roll/warp do not reset transient storage; only call this between modeled transactions.
contract IntegrationVault is VaultV2 {
    constructor(address owner_,address asset_) VaultV2(owner_,asset_) {}
    function beginTransaction() external { firstTotalAssets=0; }
}
abstract contract IntegrationFixture is CoreFixture {
    IntegrationVault internal realVault; Transmuter internal realTrans; AlchemistRouter internal realRouter;
    function setUp() public virtual override {
        vm.roll(100); vm.warp(1000); asset=new CoreToken(18); debt=new CoreToken(18);
        realVault=new IntegrationVault(address(this),address(asset));
        realTrans=new Transmuter(ITransmuter.TransmuterInitializationParams({syntheticToken:address(debt),feeReceiver:FEES,timeToTransmute:4,transmutationFee:0,exitFee:0,graphSize:32}));
        CoreAlchemistHarness implementation=new CoreAlchemistHarness();
        alc=CoreAlchemistHarness(address(new ERC1967Proxy(address(implementation),abi.encodeCall(AlchemistV3.initialize,(_params(address(asset),address(debt),address(realVault),address(realTrans)))))));
        nft=new AlchemistV3Position(address(alc),address(this));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setAlchemistPositionNFT,(address(nft))));
        _ok(address(realTrans),abi.encodeCall(Transmuter.setAlchemist,(address(alc))));
        _ok(address(realTrans),abi.encodeCall(Transmuter.setDepositCap,(1e30)));
        realRouter=new AlchemistRouter(address(alc));
        asset.mint(ALICE,2e24);
        vm.prank(ALICE); asset.approve(address(realVault),type(uint256).max);
        _as(ALICE,address(realVault),abi.encodeCall(VaultV2.deposit,(1e24,ALICE)));
        vm.prank(ALICE); realVault.approve(address(alc),type(uint256).max);
        vm.prank(ALICE); realVault.approve(address(realRouter),type(uint256).max);
        vm.prank(ALICE); asset.approve(address(realRouter),type(uint256).max);
        vm.prank(ALICE); debt.approve(address(alc),type(uint256).max);
        vm.prank(ALICE); debt.approve(address(realTrans),type(uint256).max);
        _next(1);
    }
    function _next(uint256 blocks_) internal { vm.roll(block.number+blocks_);vm.warp(block.timestamp+blocks_*12);realVault.beginTransaction(); assert(realVault.firstTotalAssets()==0); }
    function _lock(uint256 amount) internal { _as(ALICE,address(realTrans),abi.encodeCall(Transmuter.createRedemption,(amount,ALICE))); }
}
contract V3IntegrationSymbolic is IntegrationFixture {
    /// @custom:property INT-FLOW INT-SUPPLY INT-COVER
    /// @notice INT-FLOW, INT-COVER, INT-SUPPLY: check mature claim conservation.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_matureClaimConservation(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*1e6; uint256 id=_borrow(4*amount,amount); _lock(amount); _next(4);
        uint256 before=realVault.balanceOf(ALICE); uint256 issued=alc.totalSyntheticsIssued();
        (uint256 payout,uint256 fee,uint256 refund,uint256 syntheticFee)=abi.decode(_as(ALICE,address(realTrans),abi.encodeCall(Transmuter.claimRedemption,(1))),(uint256,uint256,uint256,uint256));
        assert(payout==amount && fee==0 && refund==0 && syntheticFee==0);
        assert(realVault.balanceOf(ALICE)==before+payout && realVault.balanceOf(FEES)==fee);
        assert(realVault.balanceOf(address(realTrans))==0 && realTrans.totalLocked()==0);
        assert(alc.totalDebt()==0 && alc.totalSyntheticsIssued()==issued-amount && debt.totalSupply()==0);
        _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.stored(id,0)==3*amount && alc.stored(id,1)==0 && alc.getTotalDeposited()==3*amount);
    }
    /// @notice INT-FLOW, INT-COVER, INT-SUPPLY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_matureClaimConservation(uint48 raw) public { test_check_matureClaimConservation(raw); }

    /// @custom:property INT-FLOW INT-SUPPLY
    /// @notice INT-FLOW, INT-SUPPLY: check early claim fees.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_earlyClaimFees(uint48 raw,uint16 feeRaw) public {
        uint256 amount=(uint256(raw)+1)*4e6; uint256 fee=uint256(feeRaw)%10001;
        _borrow(4*amount,amount); _ok(address(realTrans),abi.encodeCall(Transmuter.setTransmutationFee,(fee))); _ok(address(realTrans),abi.encodeCall(Transmuter.setExitFee,(fee)));
        _lock(amount); _next(1);
        uint256 before=realVault.balanceOf(ALICE);
        (uint256 payout,uint256 yieldFee,uint256 refund,uint256 synthFee)=abi.decode(_as(ALICE,address(realTrans),abi.encodeCall(Transmuter.claimRedemption,(1))),(uint256,uint256,uint256,uint256));
        assert(payout+yieldFee==amount/4 && refund+synthFee==amount*3/4);
        assert(yieldFee==(amount/4)*fee/10000 && synthFee==(3*amount/4)*fee/10000);
        assert(debt.balanceOf(ALICE)==refund && debt.balanceOf(FEES)==synthFee);
        assert(realVault.balanceOf(ALICE)==before+payout && realVault.balanceOf(FEES)==yieldFee);
        assert(debt.totalSupply()==refund+synthFee && alc.totalSyntheticsIssued()==debt.totalSupply());
        assert(realTrans.totalLocked()==0 && alc.cumulativeEarmarked()<=alc.totalDebt());
    }
    /// @notice INT-FLOW, INT-SUPPLY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_earlyClaimFees(uint48 raw,uint16 feeRaw) public { test_check_earlyClaimFees(raw,feeRaw); }

    /// @custom:property INT-COVER INT-FLOW
    /// @notice INT-FLOW, INT-COVER: check repay cover then claim.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_repayCoverThenClaim(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*4e6; uint256 id=_borrow(4*amount,amount); _lock(amount); _next(1);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.repay,(amount,id)));
        // First quarter is earmarked. Only the other three quarters become cover.
        assert(alc.totalDebt()==0 && alc.raw(32)==3*amount/4 && realVault.balanceOf(address(realTrans))==amount);
        _next(3);
        _as(ALICE,address(realTrans),abi.encodeCall(Transmuter.claimRedemption,(1)));
        assert(realVault.balanceOf(address(realTrans))==0 && alc.totalSyntheticsIssued()==0 && debt.totalSupply()==0);
        assert(alc.raw(32)==3*amount/4); // Current implementation retains unapplied historical cover with no debt.
        _next(1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id))); assert(alc.cumulativeEarmarked()==0);
    }
    /// @notice INT-FLOW, INT-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_repayCoverThenClaim(uint48 raw) public { test_check_repayCoverThenClaim(raw); }

    /// @custom:property INT-COVER
    /// @notice INT-COVER: check donation cover not reused.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_donationCoverNotReused(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*4e6; uint256 id=_borrow(4*amount,amount); _lock(amount);
        _as(ALICE,address(realVault),abi.encodeCall(VaultV2.transfer,(address(realTrans),amount/4)));
        _next(1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.raw(32)==0 && alc.cumulativeEarmarked()==0);
        _next(1); _ok(address(alc),abi.encodeCall(AlchemistV3.poke,(id)));
        assert(alc.cumulativeEarmarked()==amount/4 && alc.raw(32)==0);
    }
    /// @notice INT-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_donationCoverNotReused(uint48 raw) public { test_check_donationCoverNotReused(raw); }

    /// @custom:property INT-LOSS
    /// @notice INT-LOSS: check real vault loss and claim.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_realVaultLossAndClaim(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*4e6; _borrow(4*amount,amount); _lock(amount);
        _as(address(realVault),address(asset),abi.encodeCall(CoreToken.burn,(9e23))); _next(4);
        _ok(address(realVault),abi.encodeCall(VaultV2.accrueInterest,()));
        assert(realVault.totalAssets()==1e23 && alc.getMaxBorrowable(1)==0);
        (uint256 cBefore,uint256 dBefore,uint256 eBefore)=alc.getCDP(1);
        bytes32 beforeCDP=keccak256(abi.encode(cBefore,dBefore,eBefore));
        bytes memory reason=_fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(1,ALICE,1)));
        assert(bytes4(reason)==bytes4(keccak256("IllegalState()")));
        reason=_fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(1,1,ALICE)));
        assert(bytes4(reason)==bytes4(keccak256("IllegalState()")));
        (uint256 cAfter,uint256 dAfter,uint256 eAfter)=alc.getCDP(1);
        assert(keccak256(abi.encode(cAfter,dAfter,eAfter))==beforeCDP && nft.ownerOf(1)==ALICE);
        uint256 sharesBefore=alc.getTotalDeposited()+realVault.balanceOf(address(realTrans));
        uint256 supplyBefore=debt.totalSupply();
        (uint256 payout,uint256 fee,uint256 refund,uint256 syntheticFee)=abi.decode(_as(ALICE,address(realTrans),abi.encodeCall(Transmuter.claimRedemption,(1))),(uint256,uint256,uint256,uint256));
        assert(payout+fee<=sharesBefore && alc.getTotalDeposited()+realVault.balanceOf(address(realTrans))+payout+fee==sharesBefore);
        assert(supplyBefore-debt.totalSupply()==amount-refund-syntheticFee);
        assert(alc.totalSyntheticsIssued()==debt.totalSupply());
    }
    /// @notice INT-LOSS: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_realVaultLossAndClaim(uint48 raw) public { test_check_realVaultLossAndClaim(raw); }

    /// @custom:property INT-SUPPLY
    /// @notice INT-SUPPLY: check external supply changes are separate.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_externalSupplyChangesAreSeparate(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*4; _borrow(4*amount,amount);
        _as(ALICE,address(debt),abi.encodeCall(CoreToken.burn,(amount/4)));
        assert(alc.totalSyntheticsIssued()==amount && debt.totalSupply()==3*amount/4);
        // The token faucet models an external bridge supply increase, not a real bridge proof.
        debt.mint(BOB,amount); assert(debt.totalSupply()==7*amount/4 && alc.totalSyntheticsIssued()==amount);
    }
    /// @notice INT-SUPPLY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_externalSupplyChangesAreSeparate(uint48 raw) public { test_check_externalSupplyChangesAreSeparate(raw); }

    /// @custom:property INT-ROUTER INT-FLOW
    /// @notice INT-FLOW, INT-ROUTER: check real vault router round trip.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_realVaultRouterRoundTrip(uint48 raw) public {
        uint256 amount=uint256(raw)+100; uint256 before=asset.balanceOf(ALICE);
        uint256 id=abi.decode(_as(ALICE,address(realRouter),abi.encodeCall(AlchemistRouter.depositUnderlying,(0,amount,0,amount,block.timestamp))),(uint256));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,1)));
        _as(ALICE,address(nft),abi.encodeWithSignature("approve(address,uint256)",address(realRouter),id));
        _as(ALICE,address(realRouter),abi.encodeCall(AlchemistRouter.withdrawUnderlying,(id,amount,amount,block.timestamp)));
        assert(asset.balanceOf(ALICE)==before && nft.ownerOf(id)==ALICE && alc.mintAllowance(id,BOB)==0);
        assert(realVault.allowance(address(realRouter),address(alc))==0 && asset.allowance(address(realRouter),address(realVault))==0);
    }
    /// @notice INT-FLOW, INT-ROUTER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_realVaultRouterRoundTrip(uint48 raw) public { test_check_realVaultRouterRoundTrip(raw); }

    /// @custom:property INT-ROUTER INT-SUPPLY
    /// @notice INT-SUPPLY, INT-ROUTER: check real claim through router.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_realClaimThroughRouter(uint48 raw) public {
        uint256 amount=(uint256(raw)+1)*4e6; _borrow(4*amount,amount); _lock(amount); _next(2);
        _as(ALICE,address(realTrans),abi.encodeWithSignature("approve(address,uint256)",address(realRouter),1));
        uint256 before=asset.balanceOf(ALICE);
        _as(ALICE,address(realRouter),abi.encodeCall(AlchemistRouter.claimRedemption,(1,amount/2,block.timestamp,false)));
        assert(asset.balanceOf(ALICE)==before+amount/2 && debt.balanceOf(ALICE)==amount/2);
        assert(realVault.balanceOf(address(realRouter))==0 && debt.balanceOf(address(realRouter))==0 && realTrans.totalLocked()==0);
    }
    /// @notice INT-SUPPLY, INT-ROUTER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_realClaimThroughRouter(uint48 raw) public { test_check_realClaimThroughRouter(raw); }

}
