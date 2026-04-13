// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";

contract AlchemistCuratorTest is Test {
    using MYTTestHelper for *;

    AlchemistCurator public mytCuratorProxy;
    VaultV2 public vault;
    address public operator = address(0x2222222222222222222222222222222222222222); // default operator
    address public admin = address(0x4444444444444444444444444444444444444444); // DAO OSX
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%
    MockMYTStrategy public mytStrategy;

    function setUp() public {
        vm.startPrank(admin);
        mytCuratorProxy = new AlchemistCurator(admin, operator);
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, address(mytCuratorProxy));
        mytStrategy = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW);
        vm.stopPrank();
    }

    // basic success case tests

    function testSubmitSetStrategy() public {
        vm.startPrank(operator);
        mytCuratorProxy.submitSetStrategy(address(mytStrategy), address(vault));
        vm.stopPrank();
    }

    function testSetStrategy() public {
        vm.startPrank(operator);
        mytCuratorProxy.submitSetStrategy(address(mytStrategy), address(vault));
        _vaultFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        mytCuratorProxy.setStrategy(address(mytStrategy), address(vault));
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (mytStrategy.getIdData(), defaultStrategyAbsoluteCap)));
        mytCuratorProxy.increaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        mytCuratorProxy.decreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap / 2);

        // verify absolute cap has decreased
        assertEq(vault.absoluteCap(IMYTStrategy(address(mytStrategy)).adapterId()), defaultStrategyAbsoluteCap - (defaultStrategyAbsoluteCap / 2));
        vm.stopPrank();
    }

    function testDecreaseRelativeCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (mytStrategy.getIdData(), defaultStrategyRelativeCap)));
        mytCuratorProxy.increaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        mytCuratorProxy.decreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap / 2);
        // verify relative cap has decreased
        assertEq(vault.relativeCap(IMYTStrategy(address(mytStrategy)).adapterId()), defaultStrategyRelativeCap / 2);
        vm.stopPrank();
    }

    function testSubmitIncreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitIncreaseRelativeCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (mytStrategy.getIdData(), defaultStrategyAbsoluteCap)));
        mytCuratorProxy.increaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);

        // verify absolute cap has increased
        assertEq(vault.absoluteCap(IMYTStrategy(address(mytStrategy)).adapterId()), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseRelativeCap() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.startPrank(admin);
        mytCuratorProxy.submitIncreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (mytStrategy.getIdData(), defaultStrategyRelativeCap)));
        mytCuratorProxy.increaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);

        // verify relative cap has increased
        assertEq(vault.relativeCap(IMYTStrategy(address(mytStrategy)).adapterId()), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    /// access control tests

    function testDecreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.decreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.decreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.increaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
    }

    function testIncreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.increaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
    }

    function testSubmitIncreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.submitIncreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
    }

    function testSubmitIncreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.submitIncreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
    }

    function testTransferAdminOwnerShipUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.transferAdminOwnerShip(address(0x4444444444444444444444444444444444444444));
    }

    function testAcceptAdminOwnershipUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.acceptAdminOwnership();
    }

    function testSetStrategyUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.setStrategy(address(mytStrategy), address(vault));
    }

    function testSetStrategyInvalidAdapterRevert() public {
        vm.prank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.setStrategy(address(0), address(vault));
    }

    function testSetStrategyInvalidMYTRevert() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.setStrategy(address(mytStrategy), address(0));
        vm.expectRevert();
        mytCuratorProxy.setStrategy(address(mytStrategy), address(0x1234567890123456789012345678901234567890));
        vm.stopPrank();
    }

    /// revert on invalid address tests

    function testSubmitIncreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.submitIncreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitIncreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.submitIncreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.increaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.increaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.decreaseAbsoluteCap(address(mytStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testDecreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.decreaseRelativeCap(address(mytStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    /// helpers

    function _vaultFastForward(bytes memory data) internal {
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function _submitAndSetStrategy(address adapter, address myt) internal {
        vm.startPrank(operator);
        mytCuratorProxy.submitSetStrategy(adapter, myt);
        _vaultFastForward(abi.encodeCall(IVaultV2.addAdapter, adapter));
        mytCuratorProxy.setStrategy(adapter, myt);
        vm.stopPrank();
    }

    /// remove strategy tests

    function testSubmitRemoveStrategy() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        vm.prank(operator);
        mytCuratorProxy.submitRemoveStrategy(address(mytStrategy), address(vault));
    }

    function testRemoveStrategy() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));

        vm.startPrank(operator);
        mytCuratorProxy.submitRemoveStrategy(address(mytStrategy), address(vault));
        _vaultFastForward(abi.encodeCall(IVaultV2.removeAdapter, address(mytStrategy)));
        mytCuratorProxy.removeStrategy(address(mytStrategy), address(vault));
        vm.stopPrank();

        assertFalse(vault.isAdapter(address(mytStrategy)), "adapter should be removed");
        assertEq(mytCuratorProxy.adapterToMYT(address(mytStrategy)), address(0), "adapterToMYT should be cleared");
    }

    function testSubmitRemoveStrategyRevertsOnInvalidAdapter() public {
        vm.prank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.submitRemoveStrategy(address(0), address(vault));
    }

    function testSubmitRemoveStrategyRevertsOnInvalidMYT() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.submitRemoveStrategy(address(mytStrategy), address(0));
        vm.stopPrank();
    }

    function testRemoveStrategyRevertsOnInvalidAdapter() public {
        vm.prank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.removeStrategy(address(0), address(vault));
    }

    function testRemoveStrategyRevertsOnInvalidMYT() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        mytCuratorProxy.removeStrategy(address(mytStrategy), address(0));
        vm.stopPrank();
    }

    function testRemoveStrategyUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.removeStrategy(address(mytStrategy), address(vault));
    }

    function testSubmitRemoveStrategyUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        mytCuratorProxy.submitRemoveStrategy(address(mytStrategy), address(vault));
    }

    function testRemoveStrategyClearsAdapterMapping() public {
        _submitAndSetStrategy(address(mytStrategy), address(vault));
        assertEq(mytCuratorProxy.adapterToMYT(address(mytStrategy)), address(vault));

        bytes32 allocationId = IMYTStrategy(address(mytStrategy)).adapterId();
        assertEq(vault.isAdapter(address(mytStrategy)), true);
        assertEq(vault.adaptersLength(), 1);

        // remove
        vm.startPrank(operator);
        mytCuratorProxy.submitRemoveStrategy(address(mytStrategy), address(vault));
        _vaultFastForward(abi.encodeCall(IVaultV2.removeAdapter, address(mytStrategy)));
        mytCuratorProxy.removeStrategy(address(mytStrategy), address(vault));
        vm.stopPrank();

        // verify vault no longer recognizes the adapter
        assertEq(vault.isAdapter(address(mytStrategy)), false, "adapter should be removed from vault");
        assertEq(vault.adaptersLength(), 0, "adapters length should be 0");

        // verify the removed adapter is not iterated in totalAssets (no realAssets query)
        // allocation caps remain but the adapter is excluded from adapters array
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, TestERC20(mockVaultCollateral).balanceOf(address(vault)), "totalAssets should only reflect idle balance");

        // verify curator mapping cleared
        assertEq(mytCuratorProxy.adapterToMYT(address(mytStrategy)), address(0), "adapterToMYT should be cleared");
    }
}
