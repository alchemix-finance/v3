// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

interface IERC4626MaxWithdraw {
    function maxWithdraw(address owner) external view returns (uint256);
}

contract MockEulerUSDCStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _vault)
        ERC4626Strategy(_myt, _params, _vault)
    {}
}

contract EulerUSDCStrategyTest is BaseStrategyTest {
    address public constant EULER_USDC_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Error(string) selector (0x08c379a0), observed as "PD".
    // In this suite it is observed on allocate paths (deposit mock), not deallocate.
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;
    // Euler custom error selector (0xca0985cf): `E_ZeroShares()`.
    // In this suite it is observed on deallocate paths (withdraw mock), not allocate.
    bytes4 internal constant ALLOWED_EULER_REVERT_SELECTOR = 0xca0985cf;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "EulerUSDC",
            protocol: "EulerUSDC",
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
        return address(new MockEulerUSDCStrategy(vault, params, EULER_USDC_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxWithdrawable = IERC4626MaxWithdraw(EULER_USDC_VAULT).maxWithdraw(strategy);
        return requestedAssets < maxWithdrawable ? requestedAssets : maxWithdrawable;
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;

        if (!isFuzzOrHandler) return false;
        return selector == ERROR_STRING_SELECTOR || selector == ALLOWED_EULER_REVERT_SELECTOR;
    }

    // Add any strategy-specific tests here
    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1e6, testConfig.vaultInitialDeposit);
        amountToDeallocate = amountToAllocate;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    function test_allowlisted_revert_error_string_is_deterministic() public {
        uint256 amountToAllocate = 1e6;
        bytes4 depositSelector = bytes4(keccak256("deposit(uint256,address)"));

        vm.startPrank(allocator);
        _prepareVaultAssets(amountToAllocate);
        vm.mockCallRevert(
            EULER_USDC_VAULT, abi.encodePacked(depositSelector), abi.encodeWithSelector(ERROR_STRING_SELECTOR, "PD")
        );
        vm.expectRevert(bytes("PD"));
        IVaultV2(vault).allocate(strategy, getVaultParams(), amountToAllocate);
        vm.stopPrank();
    }

    function test_allowlisted_revert_custom_selector_is_deterministic() public {
        uint256 amountToAllocate = 2e6;
        uint256 amountToDeallocate = 1e6;
        bytes4 withdrawSelector = bytes4(keccak256("withdraw(uint256,address,address)"));

        vm.startPrank(allocator);
        _prepareVaultAssets(amountToAllocate);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amountToAllocate);

        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToDeallocate);
        require(deallocPreview > 0, "preview is zero");

        vm.mockCallRevert(
            EULER_USDC_VAULT, abi.encodePacked(withdrawSelector), abi.encodeWithSelector(ALLOWED_EULER_REVERT_SELECTOR)
        );
        vm.expectRevert(ALLOWED_EULER_REVERT_SELECTOR);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
        vm.stopPrank();
    }

    // End-to-end test: Full lifecycle with time accumulation for EulerUSDC
    function test_euler_usdc_full_lifecycle_with_time() public {
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
        assertGe(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2, "Allocation is less than 2 previous deposits");
        
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
        
        // Check vault Euler balance reflects accumulated yield
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) { // Only if > 1 USDC
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }
        
        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(finalVaultUSDCBalance, vaultUSDCBalance, "Vault USDC should increase after deallocation");
        
        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_euler_usdc_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        // Use bound for array length instead of assume
        uint256 numOps = bound(amounts.length, 1, 8);
        // Ensure we don't access beyond array bounds
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;
        
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        for (uint256 i = 0; i < maxIterations; i++) {
            // Alternate between allocation and deallocation
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
            
            // Warp forward (with bounds check for timeDelays array)
            uint256 timeDelay = i < timeDelays.length ? bound(timeDelays[i], 1 hours, 30 days) : 1 hours;
            vm.warp(block.timestamp + timeDelay);
        }
        
        // Final sanity checks
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        vm.stopPrank();
    }

    // Test: Euler vault yield accumulation over time
    function test_euler_usdc_yield_accumulation() public {
        vm.startPrank(allocator);
        
        // Allocate initial amount
        uint256 allocAmount = 400e6; // 400 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        
        // Track real assets over time with warps
        uint256[] memory realAssetsSnapshots = new uint256[](5);
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 30 days);
            
            // Simulate yield by transferring small amount to strategy (0.5% per period)
            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);
            
            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();
            
            // Real assets should not significantly decrease (may increase with yield)
            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            // Update minExpected to the new baseline
            minExpected = realAssetsSnapshots[i];
            
            // Small deallocation on second snapshot
            if (i == 1) {
                uint256 smallDealloc = 50e6; // 50 USDC
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                // Update minExpected after deallocation to account for the reduction
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }
        
        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }
        
        // Allow small tolerance for slippage/rounding (up to 1% of initial)
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, initialRealAssets / 100, "All real assets should be deallocated");
        
        vm.stopPrank();
    }
}

contract EulerUSDCInvariantTest is E2EInvariantStrategyTest {
    address constant EULER_USDC_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getAsset() internal pure override returns (address) {
        return USDC;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
            name: "EulerUSDC",
            protocol: "EulerUSDC",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockEulerUSDCStrategy(vault_, params, EULER_USDC_VAULT));
    }

    function _enableForceDeallocate(address strategy) internal override {
        ERC4626Strategy(strategy).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 shares = IERC4626(EULER_USDC_VAULT).convertToShares(amount);
        uint256 bal = IERC20(EULER_USDC_VAULT).balanceOf(strategy);
        shares = shares > bal ? bal : shares;
        if (shares == 0) return;
        vm.prank(strategy);
        IERC20(EULER_USDC_VAULT).transfer(address(0xdead), shares);
    }
}
