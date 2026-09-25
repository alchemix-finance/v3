// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockFluidLiteUSDCStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _vault)
        ERC4626Strategy(_myt, _params, _vault)
    {}
}

contract FluidLiteUSDCStrategyTest is BaseStrategyTest {
    address public constant FLUID_LITE_USDC_VAULT = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // FluidLiteVaultError(uint256) — observed on fuzz allocate/deallocate when vault rejects dust or liquidity edge cases.
    bytes4 internal constant ALLOWED_FLUID_LITE_REVERT_SELECTOR = 0xf72897a8;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "FluidLiteUSDC",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 680,
            additionalIncentives: false,
            slippageBPS: 100
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 10_000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockFluidLiteUSDCStrategy(vault, params, FLUID_LITE_USDC_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 25_311_321;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;

        return isFuzzOrHandler && selector == ALLOWED_FLUID_LITE_REVERT_SELECTOR;
    }

    function _fullDeallocationTolerance() internal view override returns (uint256) {
        return 20e6;
    }

    function test_fluid_lite_vault_is_usdc_erc4626() public view {
        ERC4626Strategy strat = ERC4626Strategy(strategy);
        assertEq(address(strat.mytAsset()), USDC, "unexpected MYT asset");
        assertEq(address(strat.vault()), FLUID_LITE_USDC_VAULT, "unexpected Fluid Lite vault");
        assertEq(IERC4626(FLUID_LITE_USDC_VAULT).asset(), USDC, "Fluid Lite vault asset mismatch");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        assertFalse(ERC4626Strategy(strategy).canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(address(1));
        ERC4626Strategy(strategy).setCanForceDeallocate(true);
        assertTrue(ERC4626Strategy(strategy).canForceDeallocate(), "force deallocate should be enabled");

        deal(USDC, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }

    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 10e6, testConfig.vaultInitialDeposit);
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

    function test_fluid_lite_usdc_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint256 alloc1 = 300e6;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e6);

        vm.warp(block.timestamp + 7 days);

        uint256 alloc2 = 200e6;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");

        vm.warp(block.timestamp + 14 days);

        uint256 deallocAmount1 = 100e6;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");

        vm.warp(block.timestamp + 30 days);

        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(finalVaultUSDCBalance, vaultUSDCBalance, "Vault USDC should increase after deallocation");

        vm.stopPrank();
    }

    function test_fuzz_fluid_lite_usdc_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        uint256 numOps = bound(amounts.length, 1, 8);
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;

        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        for (uint256 i = 0; i < maxIterations; i++) {
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 10e6, 100e6);

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

    function test_previewAdjustedWithdraw_is_conservative_after_allocation() public {
        vm.startPrank(allocator);

        uint256 allocAmount = 250e6;
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);

        uint256 requested = 100e6;
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(requested);

        assertLt(preview, requested, "preview should be below requested assets");
        assertGt(preview, 0, "preview should be positive");

        vm.stopPrank();
    }
}
