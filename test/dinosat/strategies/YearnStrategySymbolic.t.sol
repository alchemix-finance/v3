// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoYearnFlowTest is DinoYearnFixture {
    /// @notice STR-YEARN-EXIT, STR-CONSTRUCT-YEARNV3STRATEGY. yearn normal.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_yearn_normal(uint64 raw) public {
        uint256 n=uint256(raw)+1;vault.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(vault.lastLoss()==25);assert(vault.withdrawCalls()==1);assert(vault.redeemCalls()==0);
    }
    /// @notice Same property and domain as test_check_yearn_normal.
    function test_fuzz_yearn_normal(uint64 raw) public { test_check_yearn_normal(raw); }
    /// @notice STR-YEARN-EXIT. yearn dust.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_yearn_dust(uint64 raw) public {
        uint256 n=uint256(raw)+2;vault.setLoss(1);vault.mint(address(strategy),n+4);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(vault.redeemCalls()==1);assert(vault.lastLoss()==10000);assert(asset.balanceOf(address(strategy))==3);
    }
    /// @notice Same property and domain as test_check_yearn_dust.
    function test_fuzz_yearn_dust(uint64 raw) public { test_check_yearn_dust(raw); }
    /// @notice STR-YEARN-EXIT. yearn insufficient dust.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_yearn_insufficient_dust() public {
        vault.setLoss(2);vault.mint(address(strategy),5);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.direct,"",0),5,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.InsufficientBalance.selector,5,3));assert(vault.balanceOf(address(strategy))==5);assert(asset.balanceOf(address(strategy))==0);
    }
}

