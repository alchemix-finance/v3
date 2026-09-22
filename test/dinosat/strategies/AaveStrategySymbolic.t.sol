// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoAaveFlowTest is DinoAaveFixture {
    /// @notice STR-AAVE-ALLOC, STR-AAVE-VALUE, STR-CONSTRUCT-AAVESTRATEGY. aave deposit value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_deposit_value(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(receipt.balanceOf(address(strategy))==n);assert(strategy.realAssets()==n);assert(address(AaveStrategy(address(strategy)).poolProvider())==address(pool));
    }
    /// @notice Same property and domain as test_check_aave_deposit_value.
    function test_fuzz_aave_deposit_value(uint64 raw) public { test_check_aave_deposit_value(raw); }
    /// @notice STR-AAVE-EXIT. aave active exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_active_exit(uint64 raw,uint64 idleRaw) public {
        uint256 n=uint256(raw)+1;uint256 idle=uint256(idleRaw);receipt.mint(address(strategy),n);asset.mint(address(strategy),idle);_exit(IMYTStrategy.ActionType.direct,n+idle,"",0);assert(receipt.balanceOf(address(strategy))==0);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_aave_active_exit.
    function test_fuzz_aave_active_exit(uint64 raw,uint64 idleRaw) public { test_check_aave_active_exit(raw,idleRaw); }
    /// @notice STR-AAVE-EXIT. aave idle exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_idle_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(receipt.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_aave_idle_exit.
    function test_fuzz_aave_idle_exit(uint64 raw) public { test_check_aave_idle_exit(raw); }
    /// @notice STR-AAVE-EXIT. aave rejects report.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_rejects_report() public {
        receipt.mint(address(strategy),5);pool.setCuts(1,0);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector,5,4));assert(receipt.balanceOf(address(strategy))==5);
    }
    /// @notice STR-AAVE-EXIT. aave rejects delta.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_rejects_delta() public {
        receipt.mint(address(strategy),5);pool.setCuts(0,1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.InsufficientBalance.selector,5,4));assert(receipt.balanceOf(address(strategy))==5);
    }
    /// @notice STR-AAVE-PREVIEW. aave preview.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_preview(uint64 raw) public {
        uint256 n=uint256(raw)+1;uint256 out=strategy.previewAdjustedWithdraw(n);assert(out<=n);uint256 fee=n-out;assert(fee*10000<=n*25);assert(n*25-fee*10000<10000);
    }
    /// @notice Same property and domain as test_check_aave_preview.
    function test_fuzz_aave_preview(uint64 raw) public { test_check_aave_preview(raw); }
    /// @notice STR-AAVE-REWARD. aave rewards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_rewards(uint64 raw) public {
        uint256 n=uint256(raw)+1;reward.mint(address(strategy),3);rewards.setReward(n,0,false);uint256 got=strategy.claimRewards(address(receipt),_route(address(reward),address(asset),n,n),n);assert(got==n);assert(mytAssetBalance()==n);assert(reward.balanceOf(address(strategy))==3);assert(rewards.lastClaimAsset()==address(receipt));
    }
    /// @notice Same property and domain as test_check_aave_rewards.
    function test_fuzz_aave_rewards(uint64 raw) public { test_check_aave_rewards(raw); }
    /// @notice STR-AAVE-REWARD. aave no rewards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_no_rewards() public {
        assert(strategy.claimRewards(address(receipt),"",0)==0);assert(mytAssetBalance()==0);
    }
    /// @notice STR-AAVE-PROTECTED. aave protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_protected() public {
        receipt.mint(address(strategy),3);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(receipt),ATTACKER,1)),_revertString("Protected token"));assert(receipt.balanceOf(address(strategy))==3);
    }
    /// @notice STR-AAVE-SWAP. aave admin swap.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_aave_admin_swap(uint64 raw,address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        uint256 n=uint256(raw)+1;bytes memory d=_route(address(asset),address(receipt),n,n);_ownerOnlyAs(caller,abi.encodeCall(AaveStrategy.adminDexSwap,(address(receipt),address(asset),n,n,d)));asset.mint(address(strategy),n);assert(AaveStrategy(address(strategy)).adminDexSwap(address(receipt),address(asset),n,n,d)==n);assert(asset.allowance(address(strategy),address(swapper))==0);
    }
    /// @notice Same property and domain as test_check_aave_admin_swap.
    function test_fuzz_aave_admin_swap(uint64 raw,address caller) public { test_check_aave_admin_swap(raw,(caller==address(this)?ATTACKER:caller)); }
}

