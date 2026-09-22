// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoSiFlowTest is DinoSiFixture {
    /// @notice STR-SI-CONSTRUCT. si bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_bindings() public {
        assert(address(h.usdc())==address(asset));assert(address(h.iUSD())==address(receipt));assert(address(h.siUSD())==address(shares));assert(address(h.gateway())==address(gateway));
    }
    /// @notice STR-SI-ALLOC. si allocate.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_allocate(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_allocate(IMYTStrategy.ActionType.direct,n,"");assert(shares.balanceOf(address(strategy))==n);assert(asset.allowance(address(strategy),address(gateway))==0);
    }
    /// @notice Same property and domain as test_check_si_allocate.
    function test_fuzz_si_allocate(uint64 raw) public { test_check_si_allocate(raw); }
    /// @notice STR-SI-UNSUPPORTED. si unsupported actions.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_unsupported_actions() public {
        asset.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.swap,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.deallocate,(_data(IMYTStrategy.ActionType.swap,"",0),1,bytes4(0),address(this))),abi.encodeWithSelector(IMYTStrategy.ActionNotSupported.selector));
    }
    /// @notice STR-SI-EXIT. si direct exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_direct_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;shares.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(shares.balanceOf(address(strategy))==0);assert(receipt.balanceOf(address(strategy))==0);assert(shares.allowance(address(strategy),address(gateway))==0);assert(receipt.allowance(address(strategy),address(gateway))==0);
    }
    /// @notice Same property and domain as test_check_si_direct_exit.
    function test_fuzz_si_direct_exit(uint64 raw) public { test_check_si_direct_exit(raw); }
    /// @notice STR-SI-EXIT. si idle exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_idle_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_si_idle_exit.
    function test_fuzz_si_idle_exit(uint64 raw) public { test_check_si_idle_exit(raw); }
    /// @notice STR-SI-VALUE. si value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_value(uint64 idle,uint64 liquid,uint64 staked) public {
        asset.mint(address(strategy),idle);receipt.mint(address(strategy),liquid);shares.mint(address(strategy),staked);assert(strategy.realAssets()==uint256(idle)+liquid+staked);
    }
    /// @notice Same property and domain as test_check_si_value.
    function test_fuzz_si_value(uint64 idle,uint64 liquid,uint64 staked) public { test_check_si_value(idle,liquid,staked); }
    /// @notice STR-SI-PREVIEW. si preview idle.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_preview_idle(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);assert(strategy.previewAdjustedWithdraw(n)==n);
    }
    /// @notice Same property and domain as test_check_si_preview_idle.
    function test_fuzz_si_preview_idle(uint64 raw) public { test_check_si_preview_idle(raw); }
    /// @notice STR-SI-PREVIEW. si preview position.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_preview_position(uint64 raw) public {
        uint256 n=uint256(raw)+1;shares.mint(address(strategy),n);uint256 out=strategy.previewAdjustedWithdraw(n);assert(out<=n);assert(n<=101?out==0:out<=n-101);
    }
    /// @notice Same property and domain as test_check_si_preview_position.
    function test_fuzz_si_preview_position(uint64 raw) public { test_check_si_preview_position(raw); }
    /// @notice STR-SI-PREVIEW. si discount.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_discount(uint64 raw) public {
        uint256 n=uint256(raw);uint256 out=h.discount(n);assert(out<=n);if(out>0){assert(out+101<=n);uint256 fee=n-out-101;assert(fee*10000<=n*25);assert(n*25-fee*10000<10000);}
    }
    /// @notice Same property and domain as test_check_si_discount.
    function test_fuzz_si_discount(uint64 raw) public { test_check_si_discount(raw); }
    /// @notice STR-SI-UNWRAP. si unwrap exit.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_unwrap_exit(uint64 raw) public {
        uint256 n=uint256(raw)+1;shares.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.unwrapAndSwap,n,_route(address(receipt),address(asset),n,n),n);assert(shares.balanceOf(address(strategy))==0);assert(receipt.balanceOf(address(strategy))==0);assert(shares.allowance(address(strategy),address(gateway))==0);
    }
    /// @notice Same property and domain as test_check_si_unwrap_exit.
    function test_fuzz_si_unwrap_exit(uint64 raw) public { test_check_si_unwrap_exit(raw); }
    /// @notice STR-SI-UNWRAP. si unwrap idle receipts.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_unwrap_idle_receipts(uint64 raw) public {
        uint256 n=uint256(raw)+1;receipt.mint(address(strategy),n);(address token,uint256 out)=h.prep(n,n);assert(token==address(receipt));assert(out==n);assert(shares.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_si_unwrap_idle_receipts.
    function test_fuzz_si_unwrap_idle_receipts(uint64 raw) public { test_check_si_unwrap_idle_receipts(raw); }
    /// @notice STR-SI-UNWRAP. si unwrap guards.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_unwrap_guards() public {
        shares.mint(address(strategy),5);_bad(address(h),abi.encodeCall(DinoSiHarness.prep,(4,5)),_revertString("Intermediate exceeds max oracle token in"));(address token,uint256 n)=h.prep(1,0);assert(token==address(receipt)&&n==0);assert(shares.balanceOf(address(strategy))==5);
    }
    /// @notice STR-SI-PROTECTED. si protected.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_protected() public {
        receipt.mint(address(strategy),1);shares.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(receipt),ATTACKER,1)),_revertString("Protected token"));_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(shares),ATTACKER,1)),_revertString("Protected token"));
    }
    function deploySi(uint8 mode) external returns(address){return address(new SiUSDStrategy(address(myt),_params(),mode==0?address(0):mode==6?address(receipt):address(asset),mode==1?address(0):address(receipt),mode==2?address(0):address(shares),mode==3?address(0):address(gateway),mode==4?address(0):address(gateway),mode==5?address(0):address(gateway),address(oracle),1000));}
    /// @notice STR-SI-CONSTRUCT. si constructor asset.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_asset() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(0)),_revertString("Zero USDC address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor receipt.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_receipt() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(1)),_revertString("Zero iUSD address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor shares.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_shares() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(2)),_revertString("Zero siUSD address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor gateway.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_gateway() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(3)),_revertString("Zero gateway address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor mint.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_mint() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(4)),_revertString("Zero mint controller address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor redeem.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_redeem() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(5)),_revertString("Zero redeem controller address"));
    }
    /// @notice STR-SI-CONSTRUCT. si constructor mismatch.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_constructor_mismatch() public {
        _bad(address(this),abi.encodeCall(this.deploySi,(6)),_revertString("Vault asset != MYT asset"));
    }
    /// @notice STR-SI-ALLOC. si zero mint.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_si_zero_mint() public {
        gateway.setZeroMint(true);asset.mint(address(strategy),1);vm.prank(address(myt));_bad(address(strategy),abi.encodeCall(MYTStrategy.allocate,(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0),address(this))),_revertString("No siUSD received"));assert(asset.balanceOf(address(strategy))==1);
    }
}

