// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceTestBase, GovernanceAsset, GovernanceAdapter, GovernanceRecordingVault} from "./GovernanceFixtures.sol";
import {AlchemistAllocator} from "src/AlchemistAllocator.sol";
import {AlchemistCurator} from "src/AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "src/AlchemistStrategyClassifier.sol";
import {AlchemistGate} from "src/AlchemistGate.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";

abstract contract PermissionFixture is GovernanceTestBase {
    GovernanceRecordingVault internal vault;
    GovernanceAdapter internal adapter;
    AlchemistStrategyClassifier internal classifier;
    function _fixture() internal {
        vault = new GovernanceRecordingVault(); adapter = new GovernanceAdapter(1);
        classifier = new AlchemistStrategyClassifier(ADMIN);
        vault.configure(bytes32(uint256(1)), 1e24, 1e18, 0);
    }
}

contract GovernanceAllocatorAccess is PermissionFixture {
 AlchemistAllocator internal subject;
 function setUp() public { _fixture(); subject = new AlchemistAllocator(address(vault), ADMIN, OPERATOR, address(classifier)); }
    /// @custom:property AlchemistAllocator-AC-01
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_allocateGuard() public {
        bytes memory data = abi.encodeWithSignature("allocate(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-02
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_deallocateGuard() public {
        bytes memory data = abi.encodeWithSignature("deallocate(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-03
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_allocateWithSwapGuard() public {
        bytes memory data = abi.encodeWithSignature("allocateWithSwap(address,uint256,bytes)", address(adapter), uint256(7), hex"1122");
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-04
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_deallocateWithSwapGuard() public {
        bytes memory data = abi.encodeWithSignature("deallocateWithSwap(address,uint256,bytes)", address(adapter), uint256(7), hex"1122");
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-05
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_deallocateWithUnwrapAndSwapGuard() public {
        bytes memory data = abi.encodeWithSignature("deallocateWithUnwrapAndSwap(address,uint256,bytes,uint256)", address(adapter), uint256(7), hex"1122", uint256(3));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-06
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_setLiquidityAdapterGuard() public {
        bytes memory data = abi.encodeWithSignature("setLiquidityAdapter(address,bytes)", address(adapter), hex"1122");
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-07
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_setMaxRateGuard() public {
        bytes memory data = abi.encodeWithSignature("setMaxRate(uint256)", uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistAllocator-AC-08 AlchemistAllocator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_transferAdminOwnerShipGuard() public {
        
        bytes memory data = abi.encodeWithSignature("transferAdminOwnerShip(address)", ALICE);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.pendingAdmin() == ALICE);
    }
    /// @custom:property AlchemistAllocator-AC-09 AlchemistAllocator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_acceptAdminOwnershipGuard() public {
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        bytes memory data = abi.encodeWithSignature("acceptAdminOwnership()");
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ALICE, data);
        assert(subject.pendingAdmin() == address(0)); vm.prank(ALICE); subject.setOperator(BOB, true); assert(subject.operators(BOB));
    }
    /// @custom:property AlchemistAllocator-AC-10 AlchemistAllocator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_setOperatorGuard() public {
        
        bytes memory data = abi.encodeWithSignature("setOperator(address,bool)", ALICE, true);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.operators(ALICE));
    }
    /// @custom:property AlchemistAllocator-AC-11 AlchemistAllocator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_setPermissionedCallGuard() public {
        
        bytes memory data = abi.encodeWithSignature("setPermissionedCall(bytes4,bool)", bytes4(0x11223344), true);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.permissionedCalls(bytes4(0x11223344)));
    }
    /// @custom:property AlchemistAllocator-AC-12 AlchemistAllocator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_proxyGuard() public {
        vm.prank(ADMIN); subject.setPermissionedCall(bytes4(0x11223344), true);
        bytes memory data = abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"11223344");
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), OPERATOR, data);
        assert(vault.lastSender() == address(subject));
    }
    /// @custom:property AlchemistAllocator-ADMIN AlchemistAllocator-SETUP
    /// @custom:classification DIRECT: two-step handover and independent operator role.
    function test_check_adminHandover() public {
        assert(subject.operators(OPERATOR) && !subject.operators(ADMIN));
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        vm.prank(ADMIN); subject.transferAdminOwnerShip(address(0));
        assert(subject.pendingAdmin() == address(0));
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        vm.prank(ALICE); subject.acceptAdminOwnership();
        _reject(address(subject), ADMIN, abi.encodeWithSignature("setOperator(address,bool)", BOB, true), _error("PD"));
        vm.prank(ALICE); subject.setOperator(BOB, true);
        assert(subject.operators(BOB));
        vm.prank(ALICE); subject.setOperator(BOB, false); assert(!subject.operators(BOB));
        _reject(address(subject), ALICE, abi.encodeWithSignature("setOperator(address,bool)", address(0), true), _error("zero"));
    }
    /// @custom:property AlchemistAllocator-PROXY
    /// @custom:classification ENUMERATE: fixed calldata lengths 0,3,4,36; real target call.
    function test_check_proxyForwarding(uint96 value, uint256 argument) public {
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"112233"), _error("SEL"));
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"11223344"), _error("PD"));
        vm.prank(ADMIN); subject.setPermissionedCall(bytes4(0x11223344), true);
        bytes memory payload = abi.encodeWithSelector(bytes4(0x11223344), argument);
        vm.deal(OPERATOR, value);
        vm.prank(OPERATOR); subject.proxy{value:value}(address(vault), payload);
        assert(keccak256(vault.lastCall()) == keccak256(payload));
        assert(vault.lastValue() == value && vault.lastSender() == address(subject));
        uint256 count = vault.calls(); vault.setFail(true);
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), payload), _error("failed"));
        assert(vault.calls() == count);
    }

    /// @custom:property AlchemistAllocator-AC-01
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_allocateGuard() public { test_check_allocateGuard(); }
    /// @custom:property AlchemistAllocator-AC-02
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_deallocateGuard() public { test_check_deallocateGuard(); }
    /// @custom:property AlchemistAllocator-AC-03
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_allocateWithSwapGuard() public { test_check_allocateWithSwapGuard(); }
    /// @custom:property AlchemistAllocator-AC-04
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_deallocateWithSwapGuard() public { test_check_deallocateWithSwapGuard(); }
    /// @custom:property AlchemistAllocator-AC-05
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_deallocateWithUnwrapAndSwapGuard() public { test_check_deallocateWithUnwrapAndSwapGuard(); }
    /// @custom:property AlchemistAllocator-AC-06
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setLiquidityAdapterGuard() public { test_check_setLiquidityAdapterGuard(); }
    /// @custom:property AlchemistAllocator-AC-07
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setMaxRateGuard() public { test_check_setMaxRateGuard(); }
    /// @custom:property AlchemistAllocator-AC-08 AlchemistAllocator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_transferAdminOwnerShipGuard() public { test_check_transferAdminOwnerShipGuard(); }
    /// @custom:property AlchemistAllocator-AC-09 AlchemistAllocator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_acceptAdminOwnershipGuard() public { test_check_acceptAdminOwnershipGuard(); }
    /// @custom:property AlchemistAllocator-AC-10 AlchemistAllocator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setOperatorGuard() public { test_check_setOperatorGuard(); }
    /// @custom:property AlchemistAllocator-AC-11 AlchemistAllocator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setPermissionedCallGuard() public { test_check_setPermissionedCallGuard(); }
    /// @custom:property AlchemistAllocator-AC-12 AlchemistAllocator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_proxyGuard() public { test_check_proxyGuard(); }
    /// @custom:property AlchemistAllocator-ADMIN AlchemistAllocator-SETUP
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_adminHandover() public { test_check_adminHandover(); }
    /// @custom:property AlchemistAllocator-PROXY
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_proxyForwarding(uint96 value, uint256 argument) public { test_check_proxyForwarding(value, argument); }
}

contract GovernanceCuratorAccess is PermissionFixture {
 AlchemistCurator internal subject;
 function setUp() public { _fixture(); subject = new AlchemistCurator(ADMIN, OPERATOR); vm.prank(OPERATOR); subject.setStrategy(address(adapter), address(vault)); }
    /// @custom:property AlchemistCurator-AC-01
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitSetStrategyGuard() public {
        bytes memory data = abi.encodeWithSignature("submitSetStrategy(address,address)", address(adapter), address(vault));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-02
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_setStrategyGuard() public {
        bytes memory data = abi.encodeWithSignature("setStrategy(address,address)", address(adapter), address(vault));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-03
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitRemoveStrategyGuard() public {
        bytes memory data = abi.encodeWithSignature("submitRemoveStrategy(address,address)", address(adapter), address(vault));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-04
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_removeStrategyGuard() public {
        bytes memory data = abi.encodeWithSignature("removeStrategy(address,address)", address(adapter), address(vault));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), OPERATOR, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-05
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_decreaseAbsoluteCapGuard() public {
        bytes memory data = abi.encodeWithSignature("decreaseAbsoluteCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-06
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_decreaseRelativeCapGuard() public {
        bytes memory data = abi.encodeWithSignature("decreaseRelativeCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-07
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_increaseAbsoluteCapGuard() public {
        bytes memory data = abi.encodeWithSignature("increaseAbsoluteCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-08
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_increaseRelativeCapGuard() public {
        bytes memory data = abi.encodeWithSignature("increaseRelativeCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-09
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitIncreaseAbsoluteCapGuard() public {
        bytes memory data = abi.encodeWithSignature("submitIncreaseAbsoluteCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-10
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitIncreaseRelativeCapGuard() public {
        bytes memory data = abi.encodeWithSignature("submitIncreaseRelativeCap(address,uint256)", address(adapter), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-11
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitSetAllocatorGuard() public {
        bytes memory data = abi.encodeWithSignature("submitSetAllocator(address,address,bool)", address(vault), ALICE, true);
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-12
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitSetForceDeallocatePenaltyGuard() public {
        bytes memory data = abi.encodeWithSignature("submitSetForceDeallocatePenalty(address,address,uint256)", address(adapter), address(vault), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-13
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitSetPerformanceFeeRecipientGuard() public {
        bytes memory data = abi.encodeWithSignature("submitSetPerformanceFeeRecipient(address,address)", address(vault), ALICE);
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-14
    /// @custom:classification DIRECT: actual guarded call and authorized control.
    function test_check_submitSetPerformanceFeeGuard() public {
        bytes memory data = abi.encodeWithSignature("submitSetPerformanceFee(address,uint256)", address(vault), uint256(7));
        uint256 beforeCalls = vault.calls();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == beforeCalls);
        _success(address(subject), ADMIN, data);
        assert(vault.calls() == beforeCalls + 1);
    }
    /// @custom:property AlchemistCurator-AC-15 AlchemistCurator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_transferAdminOwnerShipGuard() public {
        
        bytes memory data = abi.encodeWithSignature("transferAdminOwnerShip(address)", ALICE);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.pendingAdmin() == ALICE);
    }
    /// @custom:property AlchemistCurator-AC-16 AlchemistCurator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_acceptAdminOwnershipGuard() public {
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        bytes memory data = abi.encodeWithSignature("acceptAdminOwnership()");
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ALICE, data);
        assert(subject.pendingAdmin() == address(0)); vm.prank(ALICE); subject.setOperator(BOB, true); assert(subject.operators(BOB));
    }
    /// @custom:property AlchemistCurator-AC-17 AlchemistCurator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_setOperatorGuard() public {
        
        bytes memory data = abi.encodeWithSignature("setOperator(address,bool)", ALICE, true);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.operators(ALICE));
    }
    /// @custom:property AlchemistCurator-AC-18 AlchemistCurator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_setPermissionedCallGuard() public {
        
        bytes memory data = abi.encodeWithSignature("setPermissionedCall(bytes4,bool)", bytes4(0x11223344), true);
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), ADMIN, data);
        assert(subject.permissionedCalls(bytes4(0x11223344)));
    }
    /// @custom:property AlchemistCurator-AC-19 AlchemistCurator-ADMIN
    /// @custom:classification DIRECT: implementation state transition.
    function test_check_proxyGuard() public {
        vm.prank(ADMIN); subject.setPermissionedCall(bytes4(0x11223344), true);
        bytes memory data = abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"11223344");
        uint256 count = vault.calls();
        address pending = subject.pendingAdmin();
        _reject(address(subject), OUTSIDER, data, _error("PD"));
        assert(vault.calls() == count && subject.pendingAdmin() == pending);
        _success(address(subject), OPERATOR, data);
        assert(vault.lastSender() == address(subject));
    }
    /// @custom:property AlchemistCurator-ADMIN AlchemistCurator-SETUP
    /// @custom:classification DIRECT: two-step handover and independent operator role.
    function test_check_adminHandover() public {
        assert(subject.operators(OPERATOR) && !subject.operators(ADMIN));
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        vm.prank(ADMIN); subject.transferAdminOwnerShip(address(0));
        assert(subject.pendingAdmin() == address(0));
        vm.prank(ADMIN); subject.transferAdminOwnerShip(ALICE);
        vm.prank(ALICE); subject.acceptAdminOwnership();
        _reject(address(subject), ADMIN, abi.encodeWithSignature("setOperator(address,bool)", BOB, true), _error("PD"));
        vm.prank(ALICE); subject.setOperator(BOB, true);
        assert(subject.operators(BOB));
        vm.prank(ALICE); subject.setOperator(BOB, false); assert(!subject.operators(BOB));
        _reject(address(subject), ALICE, abi.encodeWithSignature("setOperator(address,bool)", address(0), true), _error("zero"));
    }
    /// @custom:property AlchemistCurator-PROXY
    /// @custom:classification ENUMERATE: fixed calldata lengths 0,3,4,36; real target call.
    function test_check_proxyForwarding(uint96 value, uint256 argument) public {
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"112233"), _error("SEL"));
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), hex"11223344"), _error("PD"));
        vm.prank(ADMIN); subject.setPermissionedCall(bytes4(0x11223344), true);
        bytes memory payload = abi.encodeWithSelector(bytes4(0x11223344), argument);
        vm.deal(OPERATOR, value);
        vm.prank(OPERATOR); subject.proxy{value:value}(address(vault), payload);
        assert(keccak256(vault.lastCall()) == keccak256(payload));
        assert(vault.lastValue() == value && vault.lastSender() == address(subject));
        uint256 count = vault.calls(); vault.setFail(true);
        _reject(address(subject), OPERATOR, abi.encodeWithSignature("proxy(address,bytes)", address(vault), payload), _error("failed"));
        assert(vault.calls() == count);
    }

    /// @custom:property AlchemistCurator-AC-01
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitSetStrategyGuard() public { test_check_submitSetStrategyGuard(); }
    /// @custom:property AlchemistCurator-AC-02
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setStrategyGuard() public { test_check_setStrategyGuard(); }
    /// @custom:property AlchemistCurator-AC-03
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitRemoveStrategyGuard() public { test_check_submitRemoveStrategyGuard(); }
    /// @custom:property AlchemistCurator-AC-04
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_removeStrategyGuard() public { test_check_removeStrategyGuard(); }
    /// @custom:property AlchemistCurator-AC-05
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_decreaseAbsoluteCapGuard() public { test_check_decreaseAbsoluteCapGuard(); }
    /// @custom:property AlchemistCurator-AC-06
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_decreaseRelativeCapGuard() public { test_check_decreaseRelativeCapGuard(); }
    /// @custom:property AlchemistCurator-AC-07
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_increaseAbsoluteCapGuard() public { test_check_increaseAbsoluteCapGuard(); }
    /// @custom:property AlchemistCurator-AC-08
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_increaseRelativeCapGuard() public { test_check_increaseRelativeCapGuard(); }
    /// @custom:property AlchemistCurator-AC-09
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitIncreaseAbsoluteCapGuard() public { test_check_submitIncreaseAbsoluteCapGuard(); }
    /// @custom:property AlchemistCurator-AC-10
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitIncreaseRelativeCapGuard() public { test_check_submitIncreaseRelativeCapGuard(); }
    /// @custom:property AlchemistCurator-AC-11
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitSetAllocatorGuard() public { test_check_submitSetAllocatorGuard(); }
    /// @custom:property AlchemistCurator-AC-12
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitSetForceDeallocatePenaltyGuard() public { test_check_submitSetForceDeallocatePenaltyGuard(); }
    /// @custom:property AlchemistCurator-AC-13
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitSetPerformanceFeeRecipientGuard() public { test_check_submitSetPerformanceFeeRecipientGuard(); }
    /// @custom:property AlchemistCurator-AC-14
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_submitSetPerformanceFeeGuard() public { test_check_submitSetPerformanceFeeGuard(); }
    /// @custom:property AlchemistCurator-AC-15 AlchemistCurator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_transferAdminOwnerShipGuard() public { test_check_transferAdminOwnerShipGuard(); }
    /// @custom:property AlchemistCurator-AC-16 AlchemistCurator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_acceptAdminOwnershipGuard() public { test_check_acceptAdminOwnershipGuard(); }
    /// @custom:property AlchemistCurator-AC-17 AlchemistCurator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setOperatorGuard() public { test_check_setOperatorGuard(); }
    /// @custom:property AlchemistCurator-AC-18 AlchemistCurator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setPermissionedCallGuard() public { test_check_setPermissionedCallGuard(); }
    /// @custom:property AlchemistCurator-AC-19 AlchemistCurator-ADMIN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_proxyGuard() public { test_check_proxyGuard(); }
    /// @custom:property AlchemistCurator-ADMIN AlchemistCurator-SETUP
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_adminHandover() public { test_check_adminHandover(); }
    /// @custom:property AlchemistCurator-PROXY
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_proxyForwarding(uint96 value, uint256 argument) public { test_check_proxyForwarding(value, argument); }
}
