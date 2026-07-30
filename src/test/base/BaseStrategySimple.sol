// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {RevertContext} from "./StrategyTypes.sol";
import {StrategyOps} from "./StrategyOps.sol";
import "forge-std/console.sol";

/// @notice Simple base tests shared by strategy suites.
/// @dev Add deterministic or straightforward tests here; keep assertions readable and strategy-agnostic.
abstract contract BaseStrategySimple is StrategyOps {
    function _assertDeallocateChange(int256 change, uint256 amountToDeallocate) internal view virtual {
        // Default expectation: deallocate change tracks requested amount.
        assertApproxEqRel(change, -int256(amountToDeallocate), 1e16); // 1% slippage tolerance
    }

    function _getForceDeallocateSwapParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.swap;
        params.swapParams = IMYTStrategy.SwapParams({txData: hex"1234", minIntermediateOut: 0});
        return abi.encode(params);
    }

    function _getForceDeallocateUnwrapAndSwapParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.unwrapAndSwap;
        params.swapParams = IMYTStrategy.SwapParams({txData: hex"1234", minIntermediateOut: 1});
        return abi.encode(params);
    }

    function test_strategy_allocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 0;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_allocate_reverts_due_to_paused_allocation() public {
        bytes memory params = getVaultParams();
        vm.startPrank(admin);
        IMYTStrategy(strategy).setKillSwitch(true);
        vm.stopPrank();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, 100 * 10 ** testConfig.decimals);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector, strategy));
        IMYTStrategy(strategy).allocate(params, 100 * 10 ** testConfig.decimals, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 100 * 10 ** testConfig.decimals;
        uint256 amountToDeallocate = 0;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory deallocParams = getDeallocateVaultParams(amountToDeallocate);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        IMYTStrategy(strategy).deallocate(deallocParams, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_forceDeallocate_swap_reverts() public {
        vm.startPrank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(_getForceDeallocateSwapParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
        vm.stopPrank();
    }

    function test_strategy_forceDeallocate_unwrapAndSwap_reverts() public {
        vm.startPrank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(_getForceDeallocateUnwrapAndSwapParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate(uint256 amountToAllocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        console.log(minAlloc, maxAlloc);
        bytes memory allocParams = getVaultParams();
        vm.startPrank(vault);
        // only allocate if we are whithin caps
        if (amountToAllocate > 0) {
            deal(testConfig.vaultAsset, strategy, amountToAllocate);
            IMYTStrategy(strategy).allocate(allocParams, amountToAllocate, "", address(vault));
        } else {
            console.log("Allocation was skipped due to caps!");
        }
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 targetDeallocate = _effectiveDeallocateAmount(amountToAllocate);
        if (targetDeallocate == 0) {
            vm.stopPrank();
            return;
        }
        uint256 amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDeallocate);
        amountToDeallocate = bound(amountToDeallocate, 0, IMYTStrategy(strategy).realAssets());
        if (amountToDeallocate == 0) return; // we are not interested in deallocating from empty vaults

        bytes32 adapterId = IMYTStrategy(strategy).adapterId();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, adapterId), abi.encode(initialRealAssets));

        (bytes32[] memory strategyIds, int256 change) =
            IMYTStrategy(strategy).deallocate(getDeallocateVaultParams(amountToDeallocate), amountToDeallocate, "", address(vault));

        vm.clearMockedCalls();

        _assertDeallocateChange(change, amountToDeallocate);

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(strategy).adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 idleAssets = TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(strategy));
        assertGe(idleAssets, amountToDeallocate, "Strategy idle assets should cover deallocated amount");
        assertGe(finalRealAssets, idleAssets, "Real assets should include idle assets");
        vm.stopPrank();
    }

    function test_strategy_withdrawToVault(uint256 amount) public {
        amount = bound(amount, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        vm.startPrank(admin);
        deal(testConfig.vaultAsset, strategy, amount);
        uint256 initialAmountLeftOver = TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(strategy));
        uint256 initialAmountInVault = TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(vault));
        require(initialAmountLeftOver == amount, "Initial amount left over is not equal to amount");
        IMYTStrategy(strategy).withdrawToVault();
        vm.assertEq(TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(strategy)), initialAmountLeftOver - amount);
        vm.assertEq(TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(vault)), initialAmountInVault + amount);
        vm.stopPrank();
    }

    function test_allocator_allocate_direct(uint256 amountToAllocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);

        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        _prepareVaultAssets(amountToAllocate);
        bool allocated = _allocateOrSkipWhitelisted(amountToAllocate, RevertContext.FuzzAllocate);
        if (!allocated) {
            vm.stopPrank();
            return;
        }

        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = IVaultV2(vault).accrueInterestView();

        uint256 directRealAssets = IMYTStrategy(strategy).realAssets();
        assertGt(directRealAssets, 0, "Direct allocate should produce non-zero real assets");
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertGe(newTotalAssets, 0, "Vault total assets must remain non-negative");
        assertEq(IVaultV2(vault).allocation(allocationId), directRealAssets, "Allocation should track strategy real assets");
        vm.stopPrank();
    }

    function test_allocator_deallocate_direct(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);

        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        _prepareVaultAssets(amountToAllocate);
        bool allocated = _allocateOrSkipWhitelisted(amountToAllocate, RevertContext.FuzzAllocate);
        if (!allocated) {
            vm.stopPrank();
            return;
        }
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();

        uint256 targetDeallocate = _effectiveDeallocateAmount(amountToAllocate);
        if (targetDeallocate == 0) {
            vm.stopPrank();
            return;
        }
        amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDeallocate);
        bool deallocated = _deallocateOrSkipWhitelisted(amountToDeallocate, RevertContext.FuzzDeallocate);
        if (!deallocated) {
            vm.stopPrank();
            return;
        }

        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = IVaultV2(vault).accrueInterestView();

        assertLe(IMYTStrategy(strategy).realAssets(), currentRealAssets, "Direct deallocate should not increase real assets");
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertGe(newTotalAssets, 0, "Vault total assets must remain non-negative");
        assertLe(IVaultV2(vault).allocation(allocationId), amountToAllocate, "Allocation should not increase on deallocation");
        vm.stopPrank();
    }
}
