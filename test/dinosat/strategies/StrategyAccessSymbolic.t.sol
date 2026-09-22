// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
abstract contract DinoAccessAssertions is DinoFixture {
    /// @notice STR-BASE-SETRISKCLASS. owner risk.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_risk(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.setRiskClass,(IMYTStrategy.RiskClass.HIGH)));strategy.setRiskClass(IMYTStrategy.RiskClass.HIGH);(,,,IMYTStrategy.RiskClass r,,,,,)=strategy.params();assert(r==IMYTStrategy.RiskClass.HIGH);
    }
    /// @notice Same property and domain as test_check_owner_risk.
    function test_fuzz_owner_risk(address caller) public { test_check_owner_risk((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-SETADDITIONALINCENTIVES. owner incentives.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_incentives(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.setAdditionalIncentives,(true)));strategy.setAdditionalIncentives(true);(,,,,,,,bool v,)=strategy.params();assert(v);
    }
    /// @notice Same property and domain as test_check_owner_incentives.
    function test_fuzz_owner_incentives(address caller) public { test_check_owner_incentives((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-SETKILLSWITCH. owner kill.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_kill(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.setKillSwitch,(true)));strategy.setKillSwitch(true);assert(strategy.killSwitch());strategy.setKillSwitch(false);assert(!strategy.killSwitch());
    }
    /// @notice Same property and domain as test_check_owner_kill.
    function test_fuzz_owner_kill(address caller) public { test_check_owner_kill((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-SETALLOWANCEHOLDER. owner spender.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_spender(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.setAllowanceHolder,(address(0xCAFE))));strategy.setAllowanceHolder(address(0xCAFE));assert(strategy.allowanceHolder()==address(0xCAFE));
    }
    /// @notice Same property and domain as test_check_owner_spender.
    function test_fuzz_owner_spender(address caller) public { test_check_owner_spender((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-SETSLIPPAGEBPS. owner slippage.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_slippage(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.setSlippageBPS,(9988)));strategy.setSlippageBPS(9988);assert(_slip()==9988);
    }
    /// @notice Same property and domain as test_check_owner_slippage.
    function test_fuzz_owner_slippage(address caller) public { test_check_owner_slippage((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-QUEUE. owner queue.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_queue(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.claimWithdrawalQueue,(42)));assert(strategy.claimWithdrawalQueue(42)==0);
    }
    /// @notice Same property and domain as test_check_owner_queue.
    function test_fuzz_owner_queue(address caller) public { test_check_owner_queue((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-WITHDRAW. owner withdraw.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_withdraw(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.withdrawToVault,()));asset.mint(address(strategy),17);assert(strategy.withdrawToVault()==17);assert(asset.balanceOf(address(strategy))==0);assert(mytAssetBalance()==17);
    }
    /// @notice Same property and domain as test_check_owner_withdraw.
    function test_fuzz_owner_withdraw(address caller) public { test_check_owner_withdraw((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-RESCUE. owner rescue.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_rescue(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.rescueTokens,(address(reward),ATTACKER,3)));reward.mint(address(strategy),7);strategy.rescueTokens(address(reward),ATTACKER,3);assert(reward.balanceOf(ATTACKER)==3);assert(reward.balanceOf(address(strategy))==4);
    }
    /// @notice Same property and domain as test_check_owner_rescue.
    function test_fuzz_owner_rescue(address caller) public { test_check_owner_rescue((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-REWARDS. Non-owner rejected by owner error. Paused owner rejected before child rewards. Positive child claims are separate tests.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_owner_rewards(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)));
        strategy.setKillSwitch(true);_bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes("x"),0)),_revertString("emergency"));strategy.setKillSwitch(false);assert(strategy.claimRewards(address(reward),"x",0)==0);
    }
    /// @notice Same property and domain as test_check_owner_rewards.
    function test_fuzz_owner_rewards(address caller) public { test_check_owner_rewards((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-BASE-ALLOCATE. Non-vault caller cannot enter production dispatcher. Authorized execution witnesses belong to each child flow suite.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_vault_allocate(address caller) public {
        // Justification: the immutable MYT is the only permitted caller.
        vm.assume(caller!=address(myt));
        bytes memory d=_data(IMYTStrategy.ActionType.direct,"",0);vm.prank(caller);
        (bool ok,bytes memory reason)=address(strategy).call(abi.encodeCall(MYTStrategy.allocate,(d,1,bytes4(0),ATTACKER)));
        assert(!ok);assert(keccak256(reason)==keccak256(_revertString("PD")));assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_vault_allocate.
    function test_fuzz_vault_allocate(address caller) public { test_check_vault_allocate((caller==address(myt)?ATTACKER:caller)); }
    /// @notice STR-BASE-DEALLOCATE. Non-vault caller cannot enter production dispatcher. Authorized execution witnesses belong to each child flow suite.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_vault_deallocate(address caller) public {
        // Justification: the immutable MYT is the only permitted caller.
        vm.assume(caller!=address(myt));
        bytes memory d=_data(IMYTStrategy.ActionType.direct,"",0);vm.prank(caller);
        (bool ok,bytes memory reason)=address(strategy).call(abi.encodeCall(MYTStrategy.deallocate,(d,1,bytes4(0),ATTACKER)));
        assert(!ok);assert(keccak256(reason)==keccak256(_revertString("PD")));assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_vault_deallocate.
    function test_fuzz_vault_deallocate(address caller) public { test_check_vault_deallocate((caller==address(myt)?ATTACKER:caller)); }
    /// @notice STR-BASE-ALLOCATE, STR-BASE-DEALLOCATE, STR-BASE-PREVIEW. zero amounts.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_zero_amounts() public {
        vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),0,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,1,0));
        vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),0,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,1,0));
        _bad(address(strategy),abi.encodeCall(MYTStrategy.previewAdjustedWithdraw,(0)),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,1,0));
    }
    /// @notice STR-BASE-ALLOCATE. pause allocation.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_pause_allocation() public {
        strategy.setKillSwitch(true);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector,address(strategy)));
    }
    /// @notice STR-BASE-FORCE, STR-BASE-DEALLOCATE. force swap rejected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_force_swap_rejected(bool unwrap) public {
        vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(unwrap?IMYTStrategy.ActionType.unwrapAndSwap:IMYTStrategy.ActionType.swap,"",0),1,bytes4(0xe4d38cd8),address(this))),abi.encodeWithSelector(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector));
    }
    /// @notice Same property and domain as test_check_force_swap_rejected.
    function test_fuzz_force_swap_rejected(bool unwrap) public { test_check_force_swap_rejected(unwrap); }
    /// @notice STR-BASE-RESCUE. protected asset rescue.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_protected_asset_rescue() public {
        asset.mint(address(strategy),9);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(asset),ATTACKER,1)),_revertString("Protected token"));assert(asset.balanceOf(address(strategy))==9);
    }
    /// @notice STR-BASE-SETSLIPPAGEBPS, STR-BASE-SETALLOWANCEHOLDER. setter boundaries.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_setter_boundaries() public {
        _bad(address(strategy),abi.encodeCall(MYTStrategy.setSlippageBPS,(9999)),_revertString("Slippage too high"));assert(_slip()==25);
        strategy.setSlippageBPS(9998);assert(_slip()==9998);_bad(address(strategy),abi.encodeCall(MYTStrategy.setAllowanceHolder,(address(0))),"");assert(strategy.allowanceHolder()==address(swapper));
    }
    /// @notice STR-BASE-GETESTIMATEDYIELD, STR-BASE-GETCAP, STR-BASE-GETGLOBALCAP, STR-BASE-IDS, STR-BASE-GETIDDATA, STR-BASE-CONSTRUCT. metadata and id.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_metadata_and_id() public {
        assert(strategy.getEstimatedYield()==789);assert(strategy.getCap()==123);assert(strategy.getGlobalCap()==456);
        bytes32[] memory ids=strategy.ids();assert(ids.length==1);assert(ids[0]==strategy.adapterId());assert(keccak256(strategy.getIdData())==strategy.adapterId());
        assert(strategy.owner()==address(this));assert(address(strategy.MYT())==address(myt));
    }
    /// @notice STR-BASE-ALLOCATION. allocation getter.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_allocation_getter(uint64 raw) public {
        myt.setAllocation(strategy.adapterId(),uint256(raw));assert(strategy.allocation()==uint256(raw));
    }
    /// @notice Same property and domain as test_check_allocation_getter.
    function test_fuzz_allocation_getter(uint64 raw) public { test_check_allocation_getter(raw); }
    /// @notice STR-BASE-CONSTRUCT. ownable transition.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_ownable_transition(address newOwner) public {
        // Justification: a transfer requires a nonzero address distinct from the current owner.
        vm.assume(newOwner!=address(0)&&newOwner!=address(this));vm.prank(newOwner);(bool ok,bytes memory reason)=address(strategy).call(abi.encodeWithSignature("transferOwnership(address)",newOwner));assert(!ok);assert(keccak256(reason)==keccak256(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)",newOwner)));
        strategy.transferOwnership(newOwner);assert(strategy.owner()==newOwner);_bad(address(strategy),abi.encodeCall(MYTStrategy.setKillSwitch,(true)),abi.encodeWithSignature("OwnableUnauthorizedAccount(address)",address(this)));
        vm.prank(newOwner);strategy.setKillSwitch(true);assert(strategy.killSwitch());vm.prank(newOwner);strategy.renounceOwnership();assert(strategy.owner()==address(0));
    }
    /// @notice Same property and domain as test_check_ownable_transition.
    function test_fuzz_ownable_transition(address newOwner) public { test_check_ownable_transition((newOwner==address(0)||newOwner==address(this)?ATTACKER:newOwner)); }
}

contract DinoBaseAccessTest is DinoBaseFixture,DinoAccessAssertions {}
contract DinoOracleAccessTest is DinoOracleFixture,DinoAccessAssertions {}
contract Dino4626AccessTest is Dino4626Fixture,DinoAccessAssertions {}
contract DinoYearnAccessTest is DinoYearnFixture,DinoAccessAssertions {}
contract DinoAaveAccessTest is DinoAaveFixture,DinoAccessAssertions {}
contract DinoMoonAccessTest is DinoMoonFixture,DinoAccessAssertions {}
contract DinoWstAccessTest is DinoWstFixture,DinoAccessAssertions {}
contract DinoWstL2AccessTest is DinoWstL2Fixture,DinoAccessAssertions {}
contract DinoFraxAccessTest is DinoFraxFixture,DinoAccessAssertions {}
contract DinoEtherAccessTest is DinoEtherFixture,DinoAccessAssertions {}
contract DinoSiAccessTest is DinoSiFixture,DinoAccessAssertions {}
contract DinoDAOAccessTest is DinoDAOFixture,DinoAccessAssertions {}
contract DinoTokeAccessTest is DinoTokeFixture,DinoAccessAssertions {}
