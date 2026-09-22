// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoMoonFlowTest is DinoMoonFixture {
    /// @notice STR-MOON-ALLOC, STR-MOON-VALUE, STR-CONSTRUCT-MOONWELLSTRATEGY. moon deposit value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_deposit_value(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(moon.balanceOf(address(strategy))==n);assert(strategy.realAssets()==n);assert(address(MoonwellStrategy(payable(address(strategy))).mToken())==address(moon));
    }
    /// @notice Same property and domain as test_check_moon_deposit_value.
    function test_fuzz_moon_deposit_value(uint64 raw) public { test_check_moon_deposit_value(raw); }
    /// @notice STR-MOON-ALLOC. moon mint error.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_mint_error() public {
        asset.mint(address(strategy),1);moon.setErrors(9,0,0);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(MoonwellStrategy.MoonwellStrategyMintFailed.selector,9));assert(asset.balanceOf(address(strategy))==1);
    }
    /// @notice STR-MOON-EXIT. moon exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;moon.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(moon.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_moon_exit.
    function test_fuzz_moon_exit(uint64 raw) public { test_check_moon_exit(raw); }
    /// @notice STR-MOON-WRAP, STR-MOON-RECEIVE. moon native exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_native_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;moon.setNative(true);moon.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(address(strategy).balance==0);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_moon_native_exit.
    function test_fuzz_moon_native_exit(uint64 raw) public { test_check_moon_native_exit(raw); }
    /// @notice STR-MOON-EXIT. moon interest error.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_interest_error() public {
        moon.setErrors(0,0,1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("interest"));
    }
    /// @notice STR-MOON-EXIT. moon redeem error.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_redeem_error() public {
        moon.mint(address(strategy),5);moon.setErrors(0,7,0);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),abi.encodeWithSelector(MoonwellStrategy.MoonwellStrategyRedeemFailed.selector,7));assert(moon.balanceOf(address(strategy))==5);
    }
    /// @notice STR-MOON-PREVIEW. moon preview unit rate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_preview_unit_rate(uint64 raw) public {
        uint256 n=uint256(raw)+1;uint256 out=strategy.previewAdjustedWithdraw(n);assert(out<=n);uint256 fee=n-out;assert(fee*10000>=n*25);assert(fee==0||(fee-1)*10000<n*25);
    }
    /// @notice Same property and domain as test_check_moon_preview_unit_rate.
    function test_fuzz_moon_preview_unit_rate(uint64 raw) public { test_check_moon_preview_unit_rate(raw); }
    /// @notice STR-MOON-PREVIEW. moon preview high rate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_preview_high_rate(uint64 raw) public {
        moon.setRate(3e18);uint256 n=uint256(raw)+1;assert(strategy.previewAdjustedWithdraw(n)<=n);
    }
    /// @notice Same property and domain as test_check_moon_preview_high_rate.
    function test_fuzz_moon_preview_high_rate(uint64 raw) public { test_check_moon_preview_high_rate(raw); }
    /// @notice STR-MOON-PREVIEW. moon zero rate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_zero_rate() public {
        moon.setRate(0);_bad(address(strategy),abi.encodeCall(MYTStrategy.previewAdjustedWithdraw,(1)),_panic(0x12));
    }
    /// @notice STR-MOON-REWARD. moon reward delta.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_reward_delta(uint64 raw) public {
        uint256 n=uint256(raw)+1;reward.mint(address(strategy),3);rewards.setReward(n,0,false);assert(strategy.claimRewards(address(reward),_route(address(reward),address(asset),n,n),n)==n);assert(mytAssetBalance()==n);assert(reward.balanceOf(address(strategy))==3);
    }
    /// @notice Same property and domain as test_check_moon_reward_delta.
    function test_fuzz_moon_reward_delta(uint64 raw) public { test_check_moon_reward_delta(raw); }
    /// @notice STR-MOON-REWARD. moon wrong reward.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_wrong_reward() public {
        _bad(address(strategy),abi.encodeCall(MYTStrategy.claimRewards,(address(receipt),bytes(""),0)),_revertString("Invalid Token"));assert(strategy.claimRewards(address(reward),"",0)==0);
    }
    /// @notice STR-MOON-PROTECTED. moon protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_protected() public {
        moon.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(moon),ATTACKER,1)),_revertString("Protected token"));assert(moon.balanceOf(address(strategy))==1);
    }
    /// @notice STR-MOON-WRAP. moon wrap disabled.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_moon_wrap_disabled() public {
        strategy=new MoonwellStrategy(address(myt),_params(),address(asset),address(moon),address(rewards),address(reward),false);asset.mint(address(strategy),1);vm.deal(address(strategy),2);_exit(IMYTStrategy.ActionType.direct,1,"",0);assert(address(strategy).balance==2);
    }
}

