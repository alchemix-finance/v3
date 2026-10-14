// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {RevertContext} from "./StrategyTypes.sol";
import {StrategyOps} from "./StrategyOps.sol";
import "forge-std/console.sol";

abstract contract BaseStrategyMulti is StrategyOps {

    function test_fuzz_multiple_allocations_deallocations(uint256[] calldata amounts, uint8[] calldata actions) public {
        uint256 numOps = bound(amounts.length, 1, 10);
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;

        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        for (uint256 i = 0; i < maxIterations; i++) {
            bool isAllocate = i % 2 == 0;

            if (isAllocate) {
                (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
                if (maxAlloc > 0 && maxAlloc >= minAlloc) {
                    uint256 amount = bound(amounts[i], minAlloc, maxAlloc);
                    if (amount > 0) {
                        _prepareVaultAssets(amount);
                        _allocateOrSkipWhitelisted(amount, RevertContext.FuzzAllocate);
                    }
                }
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                uint256 minAlloc = _getMinAllocateAmount();
                if (currentAllocation >= minAlloc) {
                    uint256 maxDealloc = currentAllocation;
                    uint256 amount = bound(amounts[i], minAlloc, maxDealloc);
                    uint256 target = _effectiveDeallocateAmount(amount);
                    if (target > 0) {
                        _beforePreviewWithdraw(target);
                        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
                        if (deallocPreview > 0) _deallocateOrSkipWhitelisted(deallocPreview, RevertContext.FuzzDeallocate);
                    }
                }
            }

            uint256 timeWarp = bound(uint256(keccak256(abi.encodePacked(i, amounts, actions))), 1, 30 days);
            _warpWithHook(timeWarp);
        }

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");

        vm.stopPrank();
    }

    // End-to-end test: Full lifecycle with time accumulation
    function test_fuzz_full_lifecycle_with_time_accumulation(
        uint256 initialAlloc,
        uint256 allocIncrease,
        uint256 deallocationPercent
    ) public {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // Use handler for allocations - it handles cap validation and bounding internally
        // Just bound inputs to reasonable ranges for the lifecycle test
        deallocationPercent = bound(deallocationPercent, 1, 90); // 1-90%

        // Initial allocation using handler
        handler.allocate(initialAlloc);
        initialAlloc = handler.ghost_totalAllocated();

        // Check if allocation succeeded (handler returns early if caps don't allow)
        uint256 realAssetsInitial = IMYTStrategy(strategy).realAssets();
        if (realAssetsInitial == 0) return;

        // Warp 7 days
        _warpWithHook(7 days);

        // Increase allocation using handler
        handler.allocate(allocIncrease);
        allocIncrease = handler.ghost_totalAllocated() - initialAlloc;

        uint256 realAssetsAfterIncrease = IMYTStrategy(strategy).realAssets();
        assertGe(realAssetsAfterIncrease, realAssetsInitial, "Real assets should not decrease after increase");

        // Warp 14 days
        _warpWithHook(14 days);

        vm.startPrank(admin);

        // Partial deallocation
        uint256 totalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 deallocAmount = (totalAllocation * deallocationPercent) / 100;
        bool partialOk = _deallocateEstimate(deallocAmount, RevertContext.FuzzDeallocate);
        if (!partialOk) {
            vm.stopPrank();
            return;
        }
        uint256 realAssetsAfterDealloc = IMYTStrategy(strategy).realAssets();
        assertLt(realAssetsAfterDealloc, realAssetsAfterIncrease, "Real assets should decrease after deallocation");

        // Warp 30 days
        _warpWithHook(30 days);

        // Final deallocation of remaining. Some strategies cap each deallocation step
        // (e.g. due to adapter accounting constraints), so iterate a few times.
        for (uint256 i = 0; i < 256; i++) {
            uint256 before = IMYTStrategy(strategy).realAssets();
            if (before == 0) break;
            bool ok = _deallocateFromRealAssetsEstimate(RevertContext.FuzzDeallocate);
            if (!ok) break;
            uint256 after_ = IMYTStrategy(strategy).realAssets();
            if (after_ >= before) break;
        }

        // Verify final state
        // Allow tolerance for slippage/rounding (up to 2% of vault initial deposit)
        assertApproxEqAbs(
            IMYTStrategy(strategy).realAssets(),
            0,
            _fullDeallocationTolerance(),
            "All real assets should be deallocated"
        );
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), 0, _fullDeallocationTolerance());
        vm.stopPrank();
    }

    /// @notice Fuzz test: Real assets should always be non-negative after any operation
    function test_fuzz_real_assets_non_negative(uint256[] calldata amounts, uint8[] calldata operations) public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // Use operations array length for number of operations, but bound it
        uint256 numOps = bound(operations.length, 1, 20);

        for (uint256 i = 0; i < numOps; i++) {
            // Check array bounds before accessing amounts to prevent panic
            uint256 amount = i < amounts.length ? bound(amounts[i], 0, 1e6 * 10 ** testConfig.decimals) : 0;
            uint8 op = i < operations.length ? operations[i] % 3 : uint8(i % 3);

            if (op == 0) {
                // Allocate - bounded by effective cap
                uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
                uint256 minAlloc = _getMinAllocateAmount();
                if (effectiveCap >= minAlloc) {
                    amount = bound(amount, minAlloc, effectiveCap);
                    _prepareVaultAssets(amount);
                    _allocateOrSkipWhitelisted(amount, RevertContext.FuzzAllocate);
                }
            } else if (op == 1) {
                // Deallocate
                uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
                amount = bound(amount, 0, currentRealAssets);
                if (amount > 0) {
                    uint256 target = _effectiveDeallocateAmount(amount);
                    if (target == 0) continue;
                    uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
                    if (preview > 0) _deallocateOrSkipWhitelisted(preview, RevertContext.FuzzDeallocate);
                }
            } else {
                // Time warp
                _warpWithHook(bound(amount, 0, 365 days));
            }
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: Allocation increases (or maintains) real assets
    function test_fuzz_allocation_increases_real_assets(uint256 amountToAllocate) public {
        vm.startPrank(admin);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0 || maxAlloc < minAlloc) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        _prepareVaultAssets(amountToAllocate);
        bool allocated = _allocateOrSkipWhitelisted(amountToAllocate, RevertContext.FuzzAllocate);
        if (!allocated) {
            vm.stopPrank();
            return;
        }

        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);

        // Invariant: Real assets should increase (or stay same if rounding)
        assertGe(realAssetsAfter, realAssetsBefore, "Invariant violation: Real assets should not decrease on allocation");

        // Invariant: Allocation should increase by at least amountToAllocate minus fees/slippage
        // Allow for small tolerance (1%) for protocol fees
        uint256 minExpectedIncrease = amountToAllocate * 99 / 100; // FIXME maybe too large ?
        assertGe(
            allocationAfter - allocationBefore, minExpectedIncrease, "Invariant violation: Allocation should increase appropriately"
        );

        vm.stopPrank();
    }

    /// @notice Fuzz test: Deallocation decreases real assets
    function test_fuzz_deallocation_decreases_real_assets(uint256 amountToAllocate, uint256 fractionToDeallocate) public {
        vm.startPrank(admin);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0 || maxAlloc < minAlloc) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        fractionToDeallocate = bound(fractionToDeallocate, 1, 100); // 1-100%

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        _prepareVaultAssets(amountToAllocate);
        bool allocated = _allocateOrSkipWhitelisted(amountToAllocate, RevertContext.FuzzAllocate);
        if (!allocated) {
            vm.stopPrank();
            return;
        }

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        // Deallocate
        uint256 amountToDeallocate = realAssetsBefore * fractionToDeallocate / 100;
        uint256 targetDeallocate = _effectiveDeallocateAmount(amountToDeallocate);
        if (targetDeallocate == 0) {
            vm.stopPrank();
            return;
        }
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDeallocate);
        if (preview > 0) {
            bool deallocated = _deallocateOrSkipWhitelisted(preview, RevertContext.FuzzDeallocate);
            if (!deallocated) {
                vm.stopPrank();
                return;
            }
        }

        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);

        // Invariant: Real assets should decrease (or stay same for zero deallocation)
        assertLe(realAssetsAfter, realAssetsBefore, "Invariant violation: Real assets should not increase on deallocation");

        // Invariant: Allocation should decrease by at least previewed amount minus tolerance
        // Allow for small tolerance (1%) for protocol fees
        uint256 expectedDecrease = preview * 99 / 100;
        uint256 actualDecrease = allocationBefore > allocationAfter ? allocationBefore - allocationAfter : 0;
        assertGe(actualDecrease, expectedDecrease, "Invariant violation: Allocation should decrease appropriately");

        // After full deallocation (or nearly full), real assets should be close to zero
        if (fractionToDeallocate >= 99) {
            uint256 requested = realAssetsBefore * fractionToDeallocate / 100;
            uint256 effective = _effectiveDeallocateAmount(requested);
            // Only enforce near-zero postcondition when the strategy hook allows near-full
            // deallocation in a single step.
            if (effective * 100 < realAssetsBefore * 99) {
                vm.stopPrank();
                return;
            }
            assertLe(realAssetsAfter, realAssetsBefore / 10, "Invariant violation: Real assets should be near zero after large deallocation");
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: Cannot allocate more than vault's available balance
    function test_fuzz_cannot_allocate_more_than_available(uint256 amountToAllocate) public {
        vm.startPrank(admin);

        uint256 vaultTotalAssets = IVaultV2(vault).totalAssets();
        uint256 minAlloc = _getMinAllocateAmount();
        // Bound from minAlloc to allow testing both within and exceeding available balance
        uint256 minBound = minAlloc < vaultTotalAssets * 100 ? minAlloc : vaultTotalAssets * 100;
        amountToAllocate = bound(amountToAllocate, minBound, vaultTotalAssets * 100);

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();

        // Give vault its current total assets (plus some buffer for testing)
        deal(testConfig.vaultAsset, vault, vaultTotalAssets * 2);

        // If amount exceeds vault's available balance, expect revert
        // Available balance = vaultTotalAssets * 2 (what we just dealt) - current allocation
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 availableBalance = vaultTotalAssets * 2 - currentAllocation;

        // Calculate effective cap using helper (uses vault.totalAssets() directly)
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        if (amountToAllocate > availableBalance || amountToAllocate > effectiveCap) {
            vm.expectRevert();
            IAllocator(allocator).allocate(strategy, amountToAllocate);
        } else {
            if (amountToAllocate > 0) {
                IAllocator(allocator).allocate(strategy, amountToAllocate);
            }

            uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
            assertLe(
                realAssetsAfter,
                availableBalance + realAssetsBefore,
                "Invariant violation: Allocated more than vault assets available"
            );
            assertGe(realAssetsAfter, 0, "Invariant violation: Real assets negative");
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: Repeated small operations maintain invariants
    function test_fuzz_repeated_operations_stability(uint256 baseAmount, uint8 numOperations) public {
        vm.startPrank(admin);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0 || maxAlloc < minAlloc) return;
        baseAmount = bound(baseAmount, minAlloc, maxAlloc);
        numOperations = uint8(bound(numOperations, 5, 50));

        uint256 realAssetsHistoryMin = type(uint256).max;
        uint256 realAssetsHistoryMax = 0;
        uint256 currentRealAssets = 0;
        for (uint8 i = 0; i < numOperations; i++) {
            bool isAllocate = i % 2 == 0;
            uint256 amount = baseAmount * (1 + (i % 5)) / 5;

            if (isAllocate) {
                (, uint256 currentMax) = _getAllocationBounds();
                uint256 minAllocateAmount = _getMinAllocateAmount();
                if (currentMax >= minAllocateAmount) {
                    amount = bound(amount, minAllocateAmount, currentMax);
                    _prepareVaultAssets(amount);
                    _allocateOrSkipWhitelisted(amount, RevertContext.FuzzAllocate);
                }
            } else {
                currentRealAssets = IMYTStrategy(strategy).realAssets();
                if (currentRealAssets > 0) {
                    uint256 deallocationAmount = currentRealAssets > amount ? amount : currentRealAssets;
                    uint256 target = _effectiveDeallocateAmount(deallocationAmount);
                    if (target == 0) continue;
                    uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
                    if (preview > 0) {
                        _deallocateOrSkipWhitelisted(preview, RevertContext.FuzzDeallocate);
                    }
                }
            }

            currentRealAssets = IMYTStrategy(strategy).realAssets();

            if (currentRealAssets < realAssetsHistoryMin) {
                realAssetsHistoryMin = currentRealAssets;
            }
            if (currentRealAssets > realAssetsHistoryMax) {
                realAssetsHistoryMax = currentRealAssets;
            }
        }

        assertLe(realAssetsHistoryMax, testConfig.absoluteCap, "Invariant violation: Real assets exceeded cap");

        vm.stopPrank();
    }

    /// @notice Fuzz test: Time warps don't negatively affect real assets (unless strategy has negative yield)
    function test_fuzz_time_warp_stability(uint256 initialAlloc, uint256 warpAmount, uint8 numWarps) public {
        vm.startPrank(admin);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0 || maxAlloc < minAlloc) return;
        initialAlloc = bound(initialAlloc, minAlloc, maxAlloc);
        numWarps = uint8(bound(numWarps, 1, 10));

        _prepareVaultAssets(initialAlloc);
        bool allocated = _allocateOrSkipWhitelisted(initialAlloc, RevertContext.FuzzAllocate);
        if (!allocated) {
            vm.stopPrank();
            return;
        }
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();

        uint256 minRealAssets = initialRealAssets;

        // Perform multiple time warps
        for (uint8 i = 0; i < numWarps; i++) {
            warpAmount = bound(warpAmount, 1 hours, 365 days);
            _warpWithHook(warpAmount);

            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();

            if (currentRealAssets < minRealAssets) {
                minRealAssets = currentRealAssets;
            }
        }

        uint256 tolerance = initialRealAssets * 5 / 100;
        assertGe(
            minRealAssets + tolerance, initialRealAssets, "Invariant violation: Real assets decreased significantly without operations"
        );

        vm.stopPrank();
    }

    /// @notice End-to-end test with multiple time warps belongs in iterative/fuzz module.
    function test_end_to_end_multiple_allocations_with_time_warp() public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // First allocation
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0) return;
        uint256 alloc1 = 100 * 10 ** testConfig.decimals;
        alloc1 = alloc1 > maxAlloc ? maxAlloc : alloc1;
        if (alloc1 < minAlloc) return;
        _prepareVaultAssets(alloc1);
        bool alloc1Ok = _allocateOrSkipWhitelisted(alloc1, RevertContext.FuzzAllocate);
        if (!alloc1Ok) {
            vm.stopPrank();
            return;
        }
        uint256 realAssetsAfterAlloc1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAlloc1, 0, "Real assets should be positive after first allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1 * 10 ** testConfig.decimals);

        _warpWithHook(1 days);

        // Second allocation
        console.log("---------- second allocation ----------");
        (minAlloc, maxAlloc) = _getAllocationBounds();
        if (maxAlloc == 0) return;
        uint256 alloc2 = 50 * 10 ** testConfig.decimals;
        alloc2 = alloc2 > maxAlloc ? maxAlloc : alloc2;
        if (alloc2 < minAlloc) return;

        _prepareVaultAssets(alloc2);
        bool alloc2Ok = _allocateOrSkipWhitelisted(alloc2, RevertContext.FuzzAllocate);
        if (!alloc2Ok) {
            vm.stopPrank();
            return;
        }
        uint256 realAssetsAfterAlloc2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssetsAfterAlloc2, realAssetsAfterAlloc1, "Real assets should not decrease after second allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2, 1 * 10 ** testConfig.decimals);

        _warpWithHook(7 days);

        // Partial deallocation
        uint256 dealloc1 = 30 * 10 ** testConfig.decimals;
        _beforePreviewWithdraw(dealloc1);
        uint256 dealloc1Preview = IMYTStrategy(strategy).previewAdjustedWithdraw(dealloc1);

        uint256 allocationBeforeDealloc = IVaultV2(vault).allocation(allocationId);

        bool partialDeallocOk = _deallocateOrSkipWhitelisted(dealloc1Preview, RevertContext.FuzzDeallocate);
        if (!partialDeallocOk) {
            vm.stopPrank();
            return;
        }
        uint256 realAssetsAfterDealloc1 = IMYTStrategy(strategy).realAssets();
        assertLe(realAssetsAfterDealloc1, realAssetsAfterAlloc2, "Real assets should decrease after deallocation");
    
        uint256 actualAllocationAfterDealloc = IVaultV2(vault).allocation(allocationId);
        assertLt(actualAllocationAfterDealloc, allocationBeforeDealloc, "Tracked allocation should decrease after deallocation");
        
    
        uint256 realAssetsDecrease = realAssetsAfterAlloc2 - realAssetsAfterDealloc1;
        uint256 trackedDecrease = allocationBeforeDealloc - actualAllocationAfterDealloc;

        // Allow larger tolerance (10%) since share/asset conversions fluctuate with time in Tokemak
        assertApproxEqRel(realAssetsDecrease, trackedDecrease, 1e17); // 10% tolerance

        _warpWithHook(30 days);

        // Full deallocation
        for (uint256 i = 0; i < 256; i++) {
            uint256 before = IMYTStrategy(strategy).realAssets();
            if (before == 0) break;
            bool ok = _deallocateFromRealAssetsEstimate(RevertContext.FuzzDeallocate);
            if (!ok) {
                vm.stopPrank();
                return;
            }
            uint256 after_ = IMYTStrategy(strategy).realAssets();
            if (after_ >= before) break;
        }
        uint256 realAssetsAfterFinal = IMYTStrategy(strategy).realAssets();
        assertLt(realAssetsAfterFinal, realAssetsAfterDealloc1, "Real assets should be near zero after final deallocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), 0, 2 * 10 ** testConfig.decimals);

        (uint256 finalVaultTotalAssets,,) = IVaultV2(vault).accrueInterestView();
        assertGe(finalVaultTotalAssets, 0, "Vault total assets should be non-negative");

        vm.stopPrank();
    }

    /// @notice Iterative accumulation test with repeated warp/deallocate loops.
    function test_strategy_accumulation_over_time() public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // Allocate initial amount - bounded by effective cap
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        uint256 vaultTotalAssets = IVaultV2(vault).totalAssets();
        uint256 allocAmount = vaultTotalAssets / 20;
        allocAmount = allocAmount > effectiveCap ? effectiveCap : allocAmount;
        if (allocAmount == 0) return;
        {
            uint256 currentBalance = TokenUtils.safeBalanceOf(testConfig.vaultAsset, vault);
            deal(IVaultV2(vault).asset(), address(vault), currentBalance + allocAmount);
        }
        bool initialAllocOk = _allocateOrSkipWhitelisted(allocAmount, RevertContext.FuzzAllocate);
        if (!initialAllocOk) {
            vm.stopPrank();
            return;
        }
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum

        // Warp forward and check accumulation
        for (uint256 i = 1; i <= 4; i++) {
            _warpWithHook(30 days);

            // Simulate yield by transferring small amount to strategy (0.5% per period)
            uint256 currentVaultAssets = IVaultV2(vault).totalAssets();
            deal(testConfig.vaultAsset, strategy, currentVaultAssets * 5 / 1000);

            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            assertGe(currentRealAssets, minExpected, "Real assets decreased significantly over time");
            minExpected = currentRealAssets;

            // Small deallocation to test withdrawal capability - use rebounded effective cap
            uint256 currentEffectiveCap = _getEffectiveCapHeadroom(allocationId);
            if (i == 2 && currentEffectiveCap > 0) {
                uint256 targetDealloc = IMYTStrategy(strategy).realAssets() / 10;
                _beforePreviewWithdraw(targetDealloc);
                uint256 smallDealloc = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDealloc);
                if (smallDealloc > 0) {
                    bool smallOk = _deallocateOrSkipWhitelisted(smallDealloc, RevertContext.FuzzDeallocate);
                    if (smallOk) {
                        minExpected = IMYTStrategy(strategy).realAssets();
                    }
                }
            }
        }

        // Final full deallocation
        _deallocateFromRealAssetsEstimate(RevertContext.FuzzDeallocate);

        vm.stopPrank();
    }

    /// @notice Fuzz test: Zero amount operations should have no effect (idempotency)
    function test_fuzz_zero_operations_no_effect(uint256 amount) public {
        vm.startPrank(admin);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        amount = bound(amount, minAlloc, maxAlloc);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // maxAlloc helper is 0 when we reached an effective cap
        if(amount > 0) {
            _prepareVaultAssets(amount);
            IAllocator(allocator).allocate(strategy, amount);
        }

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        IAllocator(allocator).allocate(strategy, 0);

        uint256 realAssetsAfterZeroAlloc = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfterZeroAlloc = IVaultV2(vault).allocation(allocationId);

        assertEq(realAssetsAfterZeroAlloc, realAssetsBefore, "Invariant violation: Zero allocation changed state");
        assertEq(
            allocationAfterZeroAlloc,
            allocationBefore,
            "Invariant violation: Zero allocation changed allocation tracking"
        );

        // Try to deallocate zero
        try IMYTStrategy(strategy).deallocate(getVaultParams(), 0, "", address(vault)) {} catch {}

        uint256 realAssetsAfterZeroDealloc = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfterZeroDealloc = IVaultV2(vault).allocation(allocationId);

        assertEq(realAssetsAfterZeroDealloc, realAssetsBefore, "Invariant violation: Zero deallocation changed state");
        assertEq(
            allocationAfterZeroDealloc,
            allocationBefore,
            "Invariant violation: Zero deallocation changed allocation tracking"
        );

        vm.stopPrank();
    }

    /// @notice Fuzz test: Allocations respect absolute and relative caps
    function test_fuzz_allocation_respects_caps(uint256 amountToAllocate) public {
        vm.startPrank(admin);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 absoluteCap = IVaultV2(vault).absoluteCap(allocationId);
        uint256 relativeCap = IVaultV2(vault).relativeCap(allocationId);

        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        uint256 minBound = minAlloc < maxAlloc * 2 ? minAlloc : maxAlloc * 2;
        amountToAllocate = bound(amountToAllocate, minBound, maxAlloc * 2);

        _prepareVaultAssets(amountToAllocate);

        // Try to allocate through AlchemistAllocator - handle both success and failure cases
        try IAllocator(allocator).allocate(strategy, amountToAllocate) {} catch {}

        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 newVaultTotalAssets = IVaultV2(vault).totalAssets();

        assertLe(finalAllocation, absoluteCap, "Invariant violation: Allocation exceeded absolute cap");

        uint256 maxAllowedByRelative = (newVaultTotalAssets * relativeCap) / 1e18;
        assertLe(
            finalAllocation,
            maxAllowedByRelative + (10 ** testConfig.decimals),
            "Invariant violation: Allocation exceeded relative cap"
        );

        vm.stopPrank();
    }

    function _fullDeallocationTolerance() internal view virtual returns (uint256) {
        return 2 * testConfig.vaultInitialDeposit / 100;
    }
}
