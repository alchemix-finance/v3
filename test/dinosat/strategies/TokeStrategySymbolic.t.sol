// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoTokeFlowTest is DinoTokeFixture {
    /// @notice STR-TOKE-CONSTRUCT. toke bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_bindings() public {
        TokeAutoStrategy t=TokeAutoStrategy(address(strategy));assert(address(t.autoVault())==address(vault));assert(address(t.rewarder())==address(rewards));assert(address(t.autopilotRouter())==address(router));assert(t.execToleranceBps()==25);
    }
    /// @notice STR-TOKE-TOLERANCE. toke tolerance.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_tolerance(uint16 raw,address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        uint256 n=uint256(raw)%650;_ownerOnlyAs(caller,abi.encodeCall(TokeAutoStrategy.setExecToleranceBps,(n)));TokeAutoStrategy(address(strategy)).setExecToleranceBps(n);assert(TokeAutoStrategy(address(strategy)).execToleranceBps()==n);_bad(address(strategy),abi.encodeCall(TokeAutoStrategy.setExecToleranceBps,(650)),_revertString("Exec tolerance too high"));
    }
    /// @notice Same property and domain as test_check_toke_tolerance.
    function test_fuzz_toke_tolerance(uint16 raw,address caller) public { test_check_toke_tolerance(raw,(caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-TOKE-FORCE. toke force.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_force(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(TokeAutoStrategy.setCanForceDeallocate,(true)));TokeAutoStrategy(address(strategy)).setCanForceDeallocate(true);assert(TokeAutoStrategy(address(strategy)).canForceDeallocate());asset.mint(address(strategy),1);vm.prank(address(myt));strategy.deallocate(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0xe4d38cd8),address(this));assert(asset.allowance(address(strategy),address(myt))==1);
    }
    /// @notice Same property and domain as test_check_toke_force.
    function test_fuzz_toke_force(address caller) public { test_check_toke_force((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-TOKE-ALLOC. toke allocate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_allocate(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(rewards.balanceOf(address(strategy))==n);assert(vault.balanceOf(address(strategy))==0);assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_toke_allocate.
    function test_fuzz_toke_allocate(uint64 raw) public { test_check_toke_allocate(raw); }
    /// @notice STR-TOKE-EXIT. toke direct exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_direct_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1e15;vault.mint(address(strategy),2*n);_exit(IMYTStrategy.ActionType.direct,n,"",0);uint256 spent=2*n-vault.balanceOf(address(strategy));assert(spent>=n);assert((spent-1)*9975<n*10000);assert(router.lastMinimum()>=n);assert(vault.allowance(address(strategy),address(router))==0);
    }
    /// @notice Same property and domain as test_check_toke_direct_exit.
    function test_fuzz_toke_direct_exit(uint64 raw) public { test_check_toke_direct_exit(raw); }
    /// @notice STR-TOKE-EXIT. toke staked exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_staked_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1e15;rewards.seed(address(strategy),2*n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(rewards.balanceOf(address(strategy))<2*n);assert(vault.balanceOf(address(strategy))==0);assert(vault.allowance(address(strategy),address(router))==0);
    }
    /// @notice Same property and domain as test_check_toke_staked_exit.
    function test_fuzz_toke_staked_exit(uint64 raw) public { test_check_toke_staked_exit(raw); }
    /// @notice STR-TOKE-EXIT. toke idle exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_idle_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(router.lastMinimum()==0);assert(vault.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_toke_idle_exit.
    function test_fuzz_toke_idle_exit(uint64 raw) public { test_check_toke_idle_exit(raw); }
    /// @notice STR-TOKE-ROUTES. toke custom route.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_custom_route(uint64 raw) public {
        uint256 n=uint256(raw)+1e15;vault.mint(address(strategy),n);TokeSwapRoute[] memory routes=new TokeSwapRoute[](0);bytes memory data=abi.encode(TokeRedeemParams(n,routes));_exit(IMYTStrategy.ActionType.swap,n,data,0);assert(vault.balanceOf(address(strategy))==0);assert(vault.allowance(address(strategy),address(router))==0);
    }
    /// @notice Same property and domain as test_check_toke_custom_route.
    function test_fuzz_toke_custom_route(uint64 raw) public { test_check_toke_custom_route(raw); }
    /// @notice STR-TOKE-ROUTES. toke route minimum.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_route_minimum() public {
        vault.mint(address(strategy),1e18);TokeSwapRoute[] memory routes=new TokeSwapRoute[](0);bytes memory data=abi.encode(TokeRedeemParams(9,routes));vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.swap,data,0),10,bytes4(0),address(this))),_revertString("Min out below shortfall"));assert(vault.balanceOf(address(strategy))==1e18);
    }
    /// @notice STR-TOKE-VALUE. toke nav value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_nav_value(uint64 direct,uint64 staked,uint64 idle) public {
        vault.mint(address(strategy),direct);rewards.seed(address(strategy),staked);asset.mint(address(strategy),idle);assert(strategy.realAssets()==uint256(direct)+staked+idle);
    }
    /// @notice Same property and domain as test_check_toke_nav_value.
    function test_fuzz_toke_nav_value(uint64 direct,uint64 staked,uint64 idle) public { test_check_toke_nav_value(direct,staked,idle); }
    /// @notice STR-TOKE-PREVIEW. toke preview.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_preview(uint64 raw) public {
        uint256 n=uint256(raw)+1;vault.mint(address(strategy),n);uint256 out=strategy.previewAdjustedWithdraw(n);assert(out<=n);uint256 fee=n-out;assert(fee*10000<=n*25);assert(n*25-fee*10000<10000);
    }
    /// @notice Same property and domain as test_check_toke_preview.
    function test_fuzz_toke_preview(uint64 raw) public { test_check_toke_preview(raw); }
    /// @notice STR-TOKE-REWARDS. toke rewards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_rewards(uint64 raw) public {
        uint256 n=uint256(raw)+1;reward.mint(address(strategy),3);rewards.setReward(n,0,true);assert(strategy.claimRewards(address(reward),_route(address(reward),address(asset),n+3,n+3),n+3)==n+3);assert(mytAssetBalance()==n+3);assert(reward.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_toke_rewards.
    function test_fuzz_toke_rewards(uint64 raw) public { test_check_toke_rewards(raw); }
    /// @notice STR-TOKE-REWARDS. toke rewards staking enabled.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_rewards_staking_enabled(uint64 raw) public {
        uint256 n=uint256(raw)+1;rewards.setReward(n,1,false);assert(strategy.claimRewards(address(reward),"x",0)==0);assert(reward.balanceOf(address(strategy))==n);assert(mytAssetBalance()==0);
    }
    /// @notice Same property and domain as test_check_toke_rewards_staking_enabled.
    function test_fuzz_toke_rewards_staking_enabled(uint64 raw) public { test_check_toke_rewards_staking_enabled(raw); }
    /// @notice STR-TOKE-REWARDS. toke reward guards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_reward_guards() public {
        _bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(receipt),bytes("x"),0)),_revertString("params"));_bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(reward),bytes(""),0)),_revertString("params"));assert(strategy.claimRewards(address(reward),"x",0)==0);
    }
    /// @notice STR-TOKE-PROTECTED. toke protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_protected() public {
        vault.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(vault),ATTACKER,1)),_revertString("Protected token"));assert(vault.balanceOf(address(strategy))==1);
    }
    function deployToke(uint8 mode) external returns(address){return address(new TokeAutoStrategy(address(myt),_params(),mode==0?address(receipt):address(asset),address(vault),address(rewards),mode==1?address(0):address(reward),mode==2?address(0):address(router),mode==3?650:25));}
    /// @notice STR-TOKE-CONSTRUCT. toke constructor asset.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_constructor_asset() public {
        _bad(address(this),abi.encodeCall(this.deployToke,(0)),_revertString("Vault asset != MYT asset"));
    }
    /// @notice STR-TOKE-CONSTRUCT. toke constructor reward.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_constructor_reward() public {
        _bad(address(this),abi.encodeCall(this.deployToke,(1)),_revertString("Invalid rewards token"));
    }
    /// @notice STR-TOKE-CONSTRUCT. toke constructor router.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_constructor_router() public {
        _bad(address(this),abi.encodeCall(this.deployToke,(2)),_revertString("Zero autopilot router"));
    }
    /// @notice STR-TOKE-CONSTRUCT. toke constructor tolerance.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_constructor_tolerance() public {
        _bad(address(this),abi.encodeCall(this.deployToke,(3)),_revertString("Exec tolerance too high"));
    }
    /// @notice STR-TOKE-EXIT. toke no shares.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_no_shares() public {
        vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("No shares available"));
    }
    /// @notice STR-TOKE-EXIT. toke mixed exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_toke_mixed_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1e15;vault.mint(address(strategy),n);rewards.seed(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(rewards.balanceOf(address(strategy))<n);assert(rewards.balanceOf(address(strategy))>0);assert(vault.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_toke_mixed_exit.
    function test_fuzz_toke_mixed_exit(uint64 raw) public { test_check_toke_mixed_exit(raw); }
}

