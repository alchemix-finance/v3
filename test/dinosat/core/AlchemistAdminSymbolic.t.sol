// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {AlchemistTokenVault} from "../../../src/AlchemistTokenVault.sol";
import {CoreFixture,CoreAlchemistHarness,CoreToken,ERC1967Proxy,AlchemistV3,AlchemistInitializationParams} from "../common/CoreFixture.sol";

contract AlchemistAdminSymbolic is CoreFixture {
    /// @custom:property AV3-INIT
    /// @notice AV3-INIT: check initialization locked.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: ENUMERATE.
    function test_check_initializationLocked() public {
        AlchemistInitializationParams memory p=_params(address(asset),address(debt),address(vault),address(trans));
        CoreAlchemistHarness implementation=new CoreAlchemistHarness();
        _fails(address(this),address(implementation),abi.encodeCall(AlchemistV3.initialize,(p)));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.initialize,(p)));
        assert(alc.admin()==address(this) && alc.underlyingConversionFactor()==1);
        assert(alc.raw(28)==Q && alc.raw(29)==Q);
    }
    /// @custom:property AV3-TRANSFER
    /// @notice AV3-TRANSFER: check two step admin.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_twoStepAdmin(address next) public {
        // Exclude zero and the existing admin/proxy roles to test a distinct pending admin.
        vm.assume(next!=address(0) && next!=address(this) && next!=address(alc));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.setPendingAdmin,(next)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setPendingAdmin,(next)));
        assert(alc.admin()==address(this) && alc.pendingAdmin()==next);
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.acceptAdmin,()));
        _as(next,address(alc),abi.encodeCall(AlchemistV3.acceptAdmin,()));
        assert(alc.admin()==next && alc.pendingAdmin()==address(0));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setProtocolFee,(0)));
    }
    /// @custom:property AV3-TRANSFER
    /// @notice AV3-TRANSFER: check zero pending cannot accept.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_zeroPendingCannotAccept() public { _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.acceptAdmin,())); assert(alc.admin()==address(this)); }
    /// @custom:property AV3-PAUSE
    /// @notice AV3-PAUSE: check guardian pause.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_guardianPause(bool paused) public {
        _ok(address(alc),abi.encodeCall(AlchemistV3.setGuardian,(BOB,true)));
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.pauseDeposits,(paused)));
        _as(BOB,address(alc),abi.encodeCall(AlchemistV3.pauseLoans,(paused)));
        assert(alc.depositsPaused()==paused && alc.loansPaused()==paused);
        _ok(address(alc),abi.encodeCall(AlchemistV3.setGuardian,(BOB,false)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.pauseDeposits,(!paused)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.pauseLoans,(!paused)));
    }
    /// @notice AV3-PAUSE: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_guardianPause(bool paused) public { test_check_guardianPause(paused); }

    /// @custom:property AV3-PAUSE AV3-DEPOSIT AV3-MINT
    /// @notice AV3-PAUSE, AV3-DEPOSIT, AV3-MINT: check pause enforced.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_pauseEnforced() public {
        uint256 id=_deposit(3e18);
        _ok(address(alc),abi.encodeCall(AlchemistV3.pauseDeposits,(true)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.pauseLoans,(true)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(1e18,ALICE,id)));
        _fails(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,1e18,ALICE)));
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.approveMint,(id,BOB,1e18)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.mintFrom,(id,1e18,BOB)));
        _checkCDP(id,3e18,0,0);
    }
    /// @custom:property AV3-ADMIN
    /// @notice AV3-ADMIN: check nft one time and cap.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_nftOneTimeAndCap() public {
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setAlchemistPositionNFT,(address(0))));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setAlchemistPositionNFT,(BOB)));
        _deposit(10);
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setDepositCap,(9)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setDepositCap,(10)));
        assert(alc.depositCap()==10 && alc.alchemistPositionNFT()==address(nft));
    }
    /// @custom:property AV3-ADMIN
    /// @notice AV3-ADMIN: check fee vault asset match.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_feeVaultAssetMatch() public {
        AlchemistTokenVault wrong=new AlchemistTokenVault(address(debt),address(alc),address(this));
        AlchemistTokenVault right=new AlchemistTokenVault(address(asset),address(alc),address(this));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setAlchemistFeeVault,(address(wrong))));
        assert(alc.alchemistFeeVault()==address(0));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setAlchemistFeeVault,(address(right))));
        assert(alc.alchemistFeeVault()==address(right));
    }
    /// @custom:property AV3-RATIOS
    /// @notice AV3-RATIOS: check ratio setters.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_ratioSetters(uint64 delta) public {
        uint256 minimum=12e17+uint256(delta)%3e17;
        _ok(address(alc),abi.encodeCall(AlchemistV3.setMinimumCollateralization,(minimum)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setGlobalMinimumCollateralization,(minimum)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setCollateralizationLowerBound,(minimum-1)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setLiquidationTargetCollateralization,(minimum)));
        assert(alc.globalMinimumCollateralization()>=alc.minimumCollateralization());
        assert(alc.collateralizationLowerBound()<alc.minimumCollateralization());
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setGlobalMinimumCollateralization,(minimum-1)));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setLiquidationTargetCollateralization,(2e18+1)));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setCollateralizationLowerBound,(minimum)));
        _fails(address(this),address(alc),abi.encodeCall(AlchemistV3.setMinimumCollateralization,(1e18-1)));
    }
    /// @notice AV3-RATIOS: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_ratioSetters(uint64 delta) public { test_check_ratioSetters(delta); }

    /// @custom:property AV3-RATIOS
    /// @dev Discovery assertion: accepted minimum decrease may violate this desired ordering.
    /// @notice AV3-RATIOS: check accepted sequence preserves ratio ordering.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    function test_check_acceptedSequencePreservesRatioOrdering() public {
        _ok(address(alc),abi.encodeCall(AlchemistV3.setCollateralizationLowerBound,(14e17)));
        _ok(address(alc),abi.encodeCall(AlchemistV3.setMinimumCollateralization,(12e17)));
        assert(alc.collateralizationLowerBound()<alc.minimumCollateralization());
    }
    /// @custom:property AV3-SUPPLY AV3-REDEEM AV3-COVER
    /// @notice AV3-REDEEM, AV3-SUPPLY, AV3-COVER: check transmuter exclusive.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_transmuterExclusive(uint96 raw) public {
        uint256 amount=uint256(raw)+1;
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.redeem,(amount)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.reduceSyntheticsIssued,(amount)));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.setTransmuterTokenBalance,(amount)));
        assert(alc.totalDebt()==0 && alc.totalSyntheticsIssued()==0 && alc.raw(32)==0);
    }
    /// @notice AV3-REDEEM, AV3-SUPPLY, AV3-COVER: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_transmuterExclusive(uint96 raw) public { test_check_transmuterExclusive(raw); }

    /// @custom:property AV3-SUPPLY
    /// @notice AV3-SUPPLY: check supply reduction.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_supplyReduction(uint64 value) public {
        uint256 amount=uint256(value)+1; _borrow(3*amount,amount);
        _fails(address(trans),address(alc),abi.encodeCall(AlchemistV3.reduceSyntheticsIssued,(amount+1)));
        _as(address(trans),address(alc),abi.encodeCall(AlchemistV3.reduceSyntheticsIssued,(amount)));
        assert(alc.totalSyntheticsIssued()==0 && alc.totalDebt()==amount);
    }
    /// @notice AV3-SUPPLY: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_supplyReduction(uint64 value) public { test_check_supplyReduction(value); }

}

contract AlchemistFeeAndAccessSymbolic is CoreFixture {
    /// @custom:property AV3-FEES
    /// @notice AV3-FEES: check fee domains.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_feeDomains(uint128 value) public {
        bytes4[3] memory selectors=[AlchemistV3.setProtocolFee.selector,AlchemistV3.setLiquidatorFee.selector,AlchemistV3.setRepaymentFee.selector];
        for(uint256 i;i<3;++i) {
            _fails(BOB,address(alc),abi.encodeWithSelector(selectors[i],value));
            (bool ok,)=address(alc).call(abi.encodeWithSelector(selectors[i],value)); assert(ok==(value<=10000));
        }
        assert(alc.protocolFee()==(value<=10000?value:0));
        assert(alc.liquidatorFee()==(value<=10000?value:0));
        assert(alc.repaymentFee()==(value<=10000?value:0));
    }
    /// @notice AV3-FEES: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_feeDomains(uint128 value) public { test_check_feeDomains(value); }

    /// @custom:property AV3-ADMIN AV3-RATIOS
    /// @notice AV3-ADMIN, AV3-RATIOS: check admin setters reject strangers.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DECOMPOSE.
    /// @dev Domain: typed bounds limit proof cost, not the protocol input range. Larger values remain outside this symbolic claim.
    function test_check_adminSettersRejectStrangers(uint128 value) public {
        bytes4[5] memory selectors=[AlchemistV3.setDepositCap.selector,AlchemistV3.setMinimumCollateralization.selector,AlchemistV3.setGlobalMinimumCollateralization.selector,AlchemistV3.setCollateralizationLowerBound.selector,AlchemistV3.setLiquidationTargetCollateralization.selector];
        for(uint256 i;i<5;++i) _fails(BOB,address(alc),abi.encodeWithSelector(selectors[i],value));
        bytes4[4] memory addresses=[AlchemistV3.setAlchemistPositionNFT.selector,AlchemistV3.setAlchemistFeeVault.selector,AlchemistV3.setProtocolFeeReceiver.selector,AlchemistV3.setTokenAdapter.selector];
        for(uint256 i;i<4;++i) _fails(BOB,address(alc),abi.encodeWithSelector(addresses[i],ALICE));
        _fails(BOB,address(alc),abi.encodeCall(AlchemistV3.setGuardian,(BOB,true)));
        assert(alc.admin()==address(this) && alc.protocolFeeReceiver()==FEES && !alc.guardians(BOB));
    }
    /// @notice AV3-ADMIN, AV3-RATIOS: fuzz companion with constructive input domains.
    /// @dev Technique: same implementation assertions. Classification: FUZZ.
    function test_fuzz_adminSettersRejectStrangers(uint128 value) public { test_check_adminSettersRejectStrangers(value); }

    /// @custom:property AV3-ADMIN
    /// @notice AV3-ADMIN: check address setters.
    /// @dev Technique: real implementation transitions and independent state oracles. Classification: DIRECT.
    function test_check_addressSetters(address value) public {
        (bool a,)=address(alc).call(abi.encodeCall(AlchemistV3.setTokenAdapter,(value)));
        (bool b,)=address(alc).call(abi.encodeCall(AlchemistV3.setProtocolFeeReceiver,(value)));
        (bool c,)=address(alc).call(abi.encodeCall(AlchemistV3.setGuardian,(value,true)));
        assert(a==(value!=address(0)) && b==a && c==a);
        if(a) assert(alc.tokenAdapter()==value && alc.protocolFeeReceiver()==value && alc.guardians(value));
    }
}
