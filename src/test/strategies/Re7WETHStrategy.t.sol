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

contract Re7WETHStrategyTest is BaseStrategyTest {
    address public constant RE7_WETH_VAULT = 0x3d63934715b6D4c4DFbBC1a00Fe2A2145079DD76;
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Re7 WETH Morpho V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 20e18, absoluteCap: 20e18, relativeCap: 0.25e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, RE7_WETH_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 154_316_176;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxWithdrawable = IERC4626MaxWithdraw(RE7_WETH_VAULT).maxWithdraw(strategy);
        return requestedAssets < maxWithdrawable ? requestedAssets : maxWithdrawable;
    }

    function test_re7VaultUsesMytAsset() public view {
        assertEq(address(ERC4626Strategy(strategy).mytAsset()), WETH, "unexpected MYT asset");
        assertEq(address(ERC4626Strategy(strategy).vault()), RE7_WETH_VAULT, "unexpected Re7 vault");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        ERC4626Strategy re7Strategy = ERC4626Strategy(strategy);
        assertFalse(re7Strategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        re7Strategy.setCanForceDeallocate(true);
        assertTrue(re7Strategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(WETH, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }

    // End-to-end test: Full lifecycle with time accumulation for Re7 WETH
    function test_re7_weth_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        // Initial allocation
        uint256 alloc1 = 2e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e15, "allocation should track first deposit");

        // Warp forward 7 days
        vm.warp(block.timestamp + 7 days);

        // Additional allocation (total stays within relative cap)
        uint256 alloc2 = 1e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2, 1e15, "Allocation should track both deposits");

        // Warp forward 14 days
        vm.warp(block.timestamp + 14 days);

        // Partial deallocation
        uint256 deallocAmount1 = 1e18;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");

        // Warp forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Check vault WETH balance reflects accumulated value
        uint256 vaultWETHBalance = IERC20(WETH).balanceOf(vault);
        assertGt(vaultWETHBalance, 0, "Vault should have WETH");

        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        uint256 finalVaultWETHBalance = IERC20(WETH).balanceOf(vault);
        assertGt(finalVaultWETHBalance, vaultWETHBalance, "Vault WETH should increase after deallocation");

        vm.stopPrank();
    }

    // Test: Re7 WETH yield accumulation over time
    function test_re7_weth_yield_accumulation() public {
        vm.startPrank(allocator);

        uint256 allocAmount = 3e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();

        uint256[] memory realAssetsSnapshots = new uint256[](4);
        uint256 minExpected = initialRealAssets * 95 / 100;
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 30 days);

            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);

            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();

            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            minExpected = realAssetsSnapshots[i];

            if (i == 1) {
                uint256 smallDealloc = 5e17;
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                if (deallocPreview > 0) {
                    IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                }
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, initialRealAssets / 100, "All real assets should be deallocated");

        vm.stopPrank();
    }
}

contract Re7WETHInvariantTest is E2EInvariantStrategyTest {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant RE7_WETH_VAULT = 0x3d63934715b6D4c4DFbBC1a00Fe2A2145079DD76;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 154_316_176;
    }

    function getAsset() internal pure override returns (address) {
        return WETH;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
            name: "Re7 WETH Morpho V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault_, params, RE7_WETH_VAULT));
    }

    function _enableForceDeallocate(address strategy) internal override {
        ERC4626Strategy(strategy).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 shares = IERC4626(RE7_WETH_VAULT).convertToShares(amount);
        uint256 bal = IERC20(RE7_WETH_VAULT).balanceOf(strategy);
        shares = shares > bal ? bal : shares;
        if (shares == 0) return;
        vm.prank(strategy);
        IERC20(RE7_WETH_VAULT).transfer(address(0xdead), shares);
    }
}
