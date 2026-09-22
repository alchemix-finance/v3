// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoSignedCandidateTest is DinoBaseFixture {
    /// @notice STR-BASE-ALLOCATE. Candidate: a nonnegative new valuation should not report negative change when old allocation is zero. Input exceeds the ordinary proof domain.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_allocation_signed_range() public {
        h.setValue(uint256(1)<<255);int256 change=_allocate(IMYTStrategy.ActionType.direct,1,"");assert(change>=0);
    }
    /// @notice STR-BASE-DEALLOCATE. Candidate: nonnegative remaining valuation should not report a negative change when old allocation is zero.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_deallocation_signed_range() public {
        h.setValue((uint256(1)<<255)+1);vm.prank(address(myt));(,int256 change)=strategy.deallocate(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this));assert(change>=0);
    }
}

contract DinoSiCapCandidateTest is DinoSiFixture {
    /// @notice STR-SI-UNWRAP. Candidate: production intermediate preparation should not return more than the oracle input cap.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_si_intermediate_cap() public {
        receipt.mint(address(strategy),100);(,uint256 sold)=h.prep(10,5);assert(sold<=10);
    }
}

contract DinoEtherRescueCandidateTest is DinoEtherFixture {
    /// @notice STR-ETHER-ALLOC. Candidate policy: owner rescue should protect deployed weETH principal. Owner is a trusted actor, so this is not an unauthorized-user exploit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_ether_principal_protection() public {
        we.mint(address(strategy),5);(bool ok,)=address(strategy).call(abi.encodeCall(MYTStrategy.rescueTokens,(address(we),ATTACKER,5)));assert(!ok);assert(we.balanceOf(address(strategy))==5);
    }
    /// @notice STR-ETHER-ALLOC. Candidate trust boundary: Ether.fi adapter does not independently reject a deposit adapter that mints zero receipt tokens.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_ether_zero_mint() public {
        manager.setZeroMint(true);asset.mint(address(strategy),1);_allocate(IMYTStrategy.ActionType.direct,1,"");assert(we.balanceOf(address(strategy))>0);
    }
}

contract DinoTokeFloorCandidateTest is DinoTokeFixture {
    /// @notice STR-TOKE-EXIT. Candidate trust boundary: a router that ignores minOut can return only shortfall. This tests local enforcement of the NAV floor.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_toke_router_floor() public {
        vault.mint(address(strategy),1e15);router.set(true,1e15-1);_exit(IMYTStrategy.ActionType.direct,1,"",0);assert(mytAssetBalance()>=router.lastMinimum());
    }
}

contract DinoRescueReturnCandidateTest is DinoBaseFixture {
    /// @notice STR-BASE-RESCUE. Candidate: successful rescue reports token movement even when ERC20 transfer returns false.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_rescue_false_return() public {
        reward.mint(address(strategy),5);reward.setFalseTransfer(true);strategy.rescueTokens(address(reward),ATTACKER,5);assert(reward.balanceOf(ATTACKER)==5);
    }
}

contract DinoAaveMintCandidateTest is DinoAaveFixture {
    /// @notice STR-AAVE-ALLOC. Candidate trust boundary: Aave adapter does not independently reject a pool that consumes assets but mints zero receipt tokens.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_candidate_aave_zero_mint() public {
        pool.setZeroMint(true);asset.mint(address(strategy),1);_allocate(IMYTStrategy.ActionType.direct,1,"");assert(receipt.balanceOf(address(strategy))>0);
    }
}

