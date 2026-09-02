// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract YearnOGUSDCV2StrategyTest is BaseStrategyTest {
    // Yearn OG USDC V2 on Base
    address public constant YEARN_OG_USDC_V2_VAULT = 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42;
    // Native USDC on Base
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Yearn OG USDC V2",
            protocol: "Yearn",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 1000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, YEARN_OG_USDC_V2_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 50_768_896;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("BASE_RPC_URL");
    }

    function test_yearnOgv2VaultUsesMytAsset() public view {
        assertEq(address(ERC4626Strategy(strategy).mytAsset()), USDC, "unexpected MYT asset");
        assertEq(address(ERC4626Strategy(strategy).vault()), YEARN_OG_USDC_V2_VAULT, "unexpected Yearn OG vault");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        ERC4626Strategy yearnOgv2Strategy = ERC4626Strategy(strategy);
        assertFalse(yearnOgv2Strategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        yearnOgv2Strategy.setCanForceDeallocate(true);
        assertTrue(yearnOgv2Strategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(USDC, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }

    // End-to-end test: Full lifecycle with time accumulation for Yearn OG USDC V2
    function test_yearn_og_usdc_v2_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();

        // Initial allocation
        uint256 alloc1 = 500e6; // 500 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e5);

        // Warp forward 7 days
        vm.warp(block.timestamp + 7 days);

        // Additional allocation
        uint256 alloc2 = 300e6; // 300 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        assertGe(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2 - 1e5, "Allocation is less than 2 previous deposits");

        // Warp forward 14 days
        vm.warp(block.timestamp + 14 days);

        // Partial deallocation (withdraw 200 USDC)
        uint256 deallocAmount1 = 200e6;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");

        // Warp forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Check vault USDC balance reflects accumulated value
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");

        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            // Only if > 1 USDC
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(finalVaultUSDCBalance, vaultUSDCBalance, "Vault USDC should increase after deallocation");

        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_yearn_og_usdc_v2_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        uint256 numOps = bound(amounts.length, 1, 8);
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;

        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        for (uint256 i = 0; i < maxIterations; i++) {
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 10e6, 100e6); // 10-100 USDC

            if (isAllocate) {
                IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                if (currentAllocation > 0) {
                    uint256 maxDealloc = currentAllocation < 10e6 ? currentAllocation : 10e6;
                    uint256 deallocAmount = bound(amount, 0, maxDealloc);
                    if (deallocAmount > 0) {
                        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount);
                        if (deallocPreview > 0) {
                            IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                        }
                    }
                }
            }

            uint256 timeDelay = i < timeDelays.length ? bound(timeDelays[i], 1 hours, 30 days) : 1 hours;
            vm.warp(block.timestamp + timeDelay);
        }

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);

        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");

        vm.stopPrank();
    }

    // Test: Yearn OG vault yield accumulation over time
    function test_yearn_og_usdc_v2_yield_accumulation() public {
        vm.startPrank(allocator);

        uint256 allocAmount = 400e6; // 400 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();

        uint256[] memory realAssetsSnapshots = new uint256[](5);
        uint256 minExpected = initialRealAssets * 95 / 100;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 30 days);

            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);

            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();

            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            minExpected = realAssetsSnapshots[i];

            if (i == 1) {
                uint256 smallDealloc = 50e6; // 50 USDC
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, initialRealAssets / 100, "All real assets should be deallocated");

        vm.stopPrank();
    }
}

contract YearnOGUSDCV2InvariantTest is E2EInvariantStrategyTest {
    address constant YEARN_OG_USDC_V2_VAULT = 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("BASE_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 50_768_896;
    }

    function getAsset() internal pure override returns (address) {
        return USDC;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
            name: "Yearn OG USDC V2",
            protocol: "Yearn",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault_, params, YEARN_OG_USDC_V2_VAULT));
    }

    function _enableForceDeallocate(address strategy) internal override {
        ERC4626Strategy(strategy).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 shares = IERC4626(YEARN_OG_USDC_V2_VAULT).convertToShares(amount);
        uint256 bal = IERC20(YEARN_OG_USDC_V2_VAULT).balanceOf(strategy);
        shares = shares > bal ? bal : shares;
        if (shares == 0) return;
        vm.prank(strategy);
        IERC20(YEARN_OG_USDC_V2_VAULT).transfer(address(0xdead), shares);
    }
}
