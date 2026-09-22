// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract Dino4626FlowTest is Dino4626Fixture {
    /// @notice STR-4626-CONSTRUCT. vault bindings.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_vault_bindings() public {
        assert(address(ERC4626Strategy(address(strategy)).vault())==address(vault));assert(address(ERC4626Strategy(address(strategy)).mytAsset())==address(asset));assert(!ERC4626Strategy(address(strategy)).canForceDeallocate());
    }
    /// @notice STR-4626-FORCE. force setter.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_force_setter(address caller) public {
        // Justification: the property concerns every caller except the deployed owner.
        vm.assume(caller!=address(this));
        _ownerOnlyAs(caller,abi.encodeCall(ERC4626Strategy.setCanForceDeallocate,(true)));ERC4626Strategy(address(strategy)).setCanForceDeallocate(true);assert(ERC4626Strategy(address(strategy)).canForceDeallocate());asset.mint(address(strategy),1);vm.prank(address(myt));strategy.deallocate(_data(IMYTStrategy.ActionType.direct,"",0),1,bytes4(0xe4d38cd8),address(this));assert(asset.allowance(address(strategy),address(myt))==1);
    }
    /// @notice Same property and domain as test_check_force_setter.
    function test_fuzz_force_setter(address caller) public { test_check_force_setter((caller==address(this)?ATTACKER:caller)); }
    /// @notice STR-4626-ALLOC, STR-4626-VALUE. allocate and value.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_allocate_and_value(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);assert(_allocate(IMYTStrategy.ActionType.direct,n,"")==int256(n));assert(vault.balanceOf(address(strategy))==n);assert(asset.balanceOf(address(strategy))==0);assert(strategy.realAssets()==n);
    }
    /// @notice Same property and domain as test_check_allocate_and_value.
    function test_fuzz_allocate_and_value(uint64 raw) public { test_check_allocate_and_value(raw); }
    /// @notice STR-4626-EXIT. exit active.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_exit_active(uint64 raw,uint64 idleRaw) public {
        uint256 n=uint256(raw)+1;uint256 idle=uint256(idleRaw);asset.mint(address(strategy),idle);vault.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n+idle,"",0);assert(vault.balanceOf(address(strategy))==0);assert(vault.withdrawCalls()==1);
    }
    /// @notice Same property and domain as test_check_exit_active.
    function test_fuzz_exit_active(uint64 raw,uint64 idleRaw) public { test_check_exit_active(raw,idleRaw); }
    /// @notice STR-4626-EXIT. exit idle.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_exit_idle(uint64 raw) public {
        uint256 n=uint256(raw)+1;asset.mint(address(strategy),n);_exit(IMYTStrategy.ActionType.direct,n,"",0);assert(vault.withdrawCalls()==0);assert(asset.balanceOf(address(strategy))==0);
    }
    /// @notice Same property and domain as test_check_exit_idle.
    function test_fuzz_exit_idle(uint64 raw) public { test_check_exit_idle(raw); }
    /// @notice STR-4626-PREVIEW. preview fee.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_preview_fee(uint64 raw) public {
        uint256 n=uint256(raw)+2;vault.setFee(1);uint256 out=strategy.previewAdjustedWithdraw(n);assert(out<=n-1);assert(out*10000<=(n-1)*9975);assert((n-1)*9975-out*10000<10000);
    }
    /// @notice Same property and domain as test_check_preview_fee.
    function test_fuzz_preview_fee(uint64 raw) public { test_check_preview_fee(raw); }
    /// @notice STR-4626-PREVIEW. preview excess fee reverts.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_preview_excess_fee_reverts() public {
        vault.setFee(3);_bad(address(strategy),abi.encodeCall(MYTStrategy.previewAdjustedWithdraw,(2)),_panic(0x11));vault.setFee(0);assert(strategy.previewAdjustedWithdraw(2)==1);
    }
    /// @notice STR-4626-PROTECTED. protected shares.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_protected_shares() public {
        vault.mint(address(strategy),1);_bad(address(strategy),abi.encodeCall(MYTStrategy.rescueTokens,(address(vault),ATTACKER,1)),_revertString("Protected token"));assert(vault.balanceOf(address(strategy))==1);
    }
    function deployWrongVault() external returns(address){Dino4626 bad=new Dino4626(address(receipt));return address(new ERC4626Strategy(address(myt),_params(),address(bad)));}
    /// @notice STR-4626-CONSTRUCT. reject wrong vault asset.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_reject_wrong_vault_asset() public {
        _bad(address(this),abi.encodeCall(this.deployWrongVault,()),_revertString("Vault asset != MYT asset"));
    }
}

