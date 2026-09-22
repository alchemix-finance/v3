// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceTestBase} from "./GovernanceFixtures.sol";
import {AlchemistStrategyClassifier} from "src/AlchemistStrategyClassifier.sol";
import {AlchemistGate} from "src/AlchemistGate.sol";

contract GovernanceClassifier is GovernanceTestBase {
    AlchemistStrategyClassifier internal subject;
    function setUp() public { subject = new AlchemistStrategyClassifier(ADMIN); }
    /// @custom:property AlchemistStrategyClassifier-AC-01 AlchemistStrategyClassifier-AC-02 CLASS-OWNER
    /// @custom:classification DIRECT: actual handover, cancellation and obsolete-admin rejection.
    function test_check_ownership() public {
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.transferOwnership, (ALICE)), _error("PD"));
        assert(subject.admin() == ADMIN && subject.pendingAdmin() == address(0));
        vm.prank(ADMIN); subject.transferOwnership(ALICE);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.acceptOwnership, ()), _error("PD"));
        assert(subject.admin() == ADMIN && subject.pendingAdmin() == ALICE);
        vm.prank(ADMIN); subject.transferOwnership(address(0));
        assert(subject.admin() == ADMIN && subject.pendingAdmin() == address(0));
        vm.prank(ADMIN); subject.transferOwnership(ALICE);
        vm.prank(ALICE); subject.acceptOwnership();
        assert(subject.admin() == ALICE && subject.pendingAdmin() == address(0));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setRiskClass, (uint8(3), uint256(1), uint256(2))), _error("PD"));
        vm.prank(ALICE); subject.setRiskClass(3, 1, 2);
        assert(subject.getGlobalCap(3) == 1);
        try new AlchemistStrategyClassifier(address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("IA"))); }
    }
    /// @custom:property AlchemistStrategyClassifier-AC-03 AlchemistStrategyClassifier-AC-04 CLASS-CAPS
    /// @custom:classification DIRECT: arbitrary cap words and every uint8 class, independent unrelated key.
    function test_check_capStorage(uint8 risk, uint256 global, uint256 local, uint256 id) public {
        uint8 other = risk ^ 1;
        (uint256 beforeGlobal, uint256 beforeLocal) = subject.riskClasses(other);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.setRiskClass, (risk, global, local)), _error("PD"));
        assert(subject.getStrategyRiskLevel(id) == 0);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.assignStrategyRiskLevel, (id, risk)), _error("PD"));
        vm.prank(ADMIN); subject.setRiskClass(risk, global, local);
        vm.prank(ADMIN); subject.assignStrategyRiskLevel(id, risk);
        assert(subject.getGlobalCap(risk) == global && subject.getIndividualCap(id) == local);
        assert(subject.strategyRiskLevel(id) == risk && subject.getStrategyRiskLevel(id) == risk);
        (uint256 afterGlobal, uint256 afterLocal) = subject.riskClasses(other);
        assert(beforeGlobal == afterGlobal && beforeLocal == afterLocal);
        assert(subject.getStrategyRiskLevel(id ^ 1) == 0);
    }
    /// @custom:property CLASS-CAPS
    /// @custom:classification DIRECT: constructor defaults, including unassigned class zero.
    function test_check_defaults() public view {
        assert(subject.getGlobalCap(0) == 1e18 && subject.getIndividualCap(0) == 1e18);
        assert(subject.getGlobalCap(1) == 4e17 && subject.getGlobalCap(2) == 1e17);
        (uint256 g, uint256 l) = subject.riskClasses(1); assert(g == 4e17 && l == 25e16);
    }

    /// @custom:property AlchemistStrategyClassifier-AC-01 AlchemistStrategyClassifier-AC-02 CLASS-OWNER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_ownership() public { test_check_ownership(); }
    /// @custom:property AlchemistStrategyClassifier-AC-03 AlchemistStrategyClassifier-AC-04 CLASS-CAPS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_capStorage(uint8 risk, uint256 global, uint256 local, uint256 id) public { test_check_capStorage(risk, global, local, id); }
    /// @custom:property CLASS-CAPS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_defaults() public { test_check_defaults(); }
}

contract GovernanceGate is GovernanceTestBase {
    AlchemistGate internal subject;
    function setUp() public { subject = new AlchemistGate(ADMIN); }
    /// @custom:property AlchemistGate-AC-01 GATE-AUTH
    /// @custom:classification DIRECT: full address-key domain, independent pair remains unchanged.
    function test_check_authorization(address vault, address recipient, bool value) public {
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.setAuthorization, (vault, recipient, value)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(!subject.authorized(vault, recipient));
        vm.prank(ADMIN); subject.setAuthorization(vault, recipient, value);
        assert(subject.authorized(vault, recipient) == value);
        assert(!subject.authorized(vault, address(uint160(recipient) ^ 1)));
    }
    /// @custom:property AlchemistGate-AC-02 AlchemistGate-AC-03 GATE-OWNER
    /// @custom:classification ENUMERATE: transfer, zero target, renounce and initial owner branches.
    function test_check_ownership() public {
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.transferOwnership, (ALICE)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.renounceOwnership, ()), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(subject.owner() == ADMIN);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.transferOwnership, (address(0))), abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        vm.prank(ADMIN); subject.transferOwnership(ALICE);
        assert(subject.owner() == ALICE);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setAuthorization, (BOB, BOB, true)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ADMIN));
        vm.prank(ALICE); subject.setAuthorization(BOB, BOB, true);
        vm.prank(ALICE); subject.renounceOwnership();
        assert(subject.owner() == address(0) && subject.authorized(BOB, BOB));
        try new AlchemistGate(address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)))); }
    }

    /// @custom:property AlchemistGate-AC-01 GATE-AUTH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_authorization(address vault, address recipient, bool value) public { test_check_authorization(vault, recipient, value); }
    /// @custom:property AlchemistGate-AC-02 AlchemistGate-AC-03 GATE-OWNER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_ownership() public { test_check_ownership(); }
}
