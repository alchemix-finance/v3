// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract YearnOGUSDCBaseStrategyTest is BaseStrategyTest {
    address public constant YEARN_OG_USDC_V2 = 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42;
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Yearn OG USDC V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e6,
            globalCap: 0.25e18,
            estimatedYield: 531,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: BASE_USDC, vaultInitialDeposit: 10_000e6, absoluteCap: 10_000e6, relativeCap: 0.25e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, YEARN_OG_USDC_V2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 50_739_775;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co"));
    }

    function test_yearnOgUsdcV2_usesBaseUsdc() public view {
        ERC4626Strategy yearnStrategy = ERC4626Strategy(strategy);

        assertEq(address(yearnStrategy.mytAsset()), BASE_USDC, "unexpected MYT asset");
        assertEq(address(yearnStrategy.vault()), YEARN_OG_USDC_V2, "unexpected Morpho vault");
        assertEq(IERC4626(YEARN_OG_USDC_V2).asset(), BASE_USDC, "Morpho vault asset mismatch");
        assertEq(IERC20Metadata(BASE_USDC).decimals(), 6, "unexpected USDC decimals");
        assertEq(IERC4626(YEARN_OG_USDC_V2).decimals(), 18, "unexpected vault share decimals");
    }

    function test_morphoVaultV2_maxMethodsReturnZero() public view {
        IERC4626 morphoVault = IERC4626(YEARN_OG_USDC_V2);

        // These are gross, revert-free underestimates because gates may revert.
        // Morpho Vault V2's zero values are not deposit or withdrawal limits.
        assertEq(morphoVault.maxDeposit(strategy), 0, "unexpected maxDeposit");
        assertEq(morphoVault.maxMint(strategy), 0, "unexpected maxMint");
        assertEq(morphoVault.maxWithdraw(strategy), 0, "unexpected maxWithdraw");
        assertEq(morphoVault.maxRedeem(strategy), 0, "unexpected maxRedeem");
    }

    function test_forceDeallocate_directDisabledByDefaultAndOwnerCanEnable() public {
        ERC4626Strategy yearnStrategy = ERC4626Strategy(strategy);
        assertFalse(yearnStrategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);

        vm.prank(admin);
        yearnStrategy.setCanForceDeallocate(true);
        assertTrue(yearnStrategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(BASE_USDC, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);
    }

    function test_yearnOgUsdcV2_allocateAndPartiallyDeallocate() public {
        uint256 allocationAmount = 1000e6;
        uint256 requestedDeallocation = 500e6;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAllocation, 0, "strategy should hold assets after allocation");
        assertGt(IERC20(YEARN_OG_USDC_V2).balanceOf(strategy), 0, "strategy should hold Morpho vault shares");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), realAssetsAfterAllocation, 2, "MYT allocation should track strategy value");

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedDeallocation);
        assertGt(deallocationAmount, 0, "deallocation preview should be positive");
        assertLt(deallocationAmount, requestedDeallocation, "preview should include configured slippage");

        uint256 mytUsdcBefore = IERC20(BASE_USDC).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);

        assertGt(IERC20(BASE_USDC).balanceOf(vault), mytUsdcBefore, "MYT should receive USDC");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsAfterAllocation, "strategy value should decrease");
        assertGt(IERC20(YEARN_OG_USDC_V2).balanceOf(strategy), 0, "strategy should retain shares after partial exit");
    }
}
