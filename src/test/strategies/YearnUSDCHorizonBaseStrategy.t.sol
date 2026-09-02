// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {ErrorsLib} from "lib/vault-v2/src/libraries/ErrorsLib.sol";

interface IYearnV3VaultMetadata {
    function apiVersion() external view returns (string memory);
    function isShutdown() external view returns (bool);
    function deposit_limit() external view returns (uint256);
}

contract YearnUSDCHorizonBaseStrategyTest is BaseStrategyTest {
    address public constant YEARN_USDC_HORIZON_VAULT = 0xc3BD0A2193c8F027B82ddE3611D18589ef3f62a9;
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "USDC Horizon yVault",
            protocol: "Yearn V3",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 454,
            additionalIncentives: false,
            slippageBPS: 100
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: BASE_USDC, vaultInitialDeposit: 10_000e6, absoluteCap: 10_000e6, relativeCap: 0.1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, YEARN_USDC_HORIZON_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 50_742_730;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co"));
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxWithdrawable = IERC4626(YEARN_USDC_HORIZON_VAULT).maxWithdraw(strategy);
        return requestedAssets < maxWithdrawable ? requestedAssets : maxWithdrawable;
    }

    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        return selector == ErrorsLib.RelativeCapExceeded.selector && (context == RevertContext.HandlerAllocate || context == RevertContext.FuzzAllocate);
    }

    function test_yearnUsdcHorizon_usesBaseUsdc() public view {
        ERC4626Strategy yearnStrategy = ERC4626Strategy(strategy);
        IYearnV3VaultMetadata yearnVault = IYearnV3VaultMetadata(YEARN_USDC_HORIZON_VAULT);

        assertEq(address(yearnStrategy.mytAsset()), BASE_USDC, "unexpected MYT asset");
        assertEq(address(yearnStrategy.vault()), YEARN_USDC_HORIZON_VAULT, "unexpected Yearn vault");
        assertEq(IERC4626(YEARN_USDC_HORIZON_VAULT).asset(), BASE_USDC, "Yearn vault asset mismatch");
        assertEq(IERC20Metadata(BASE_USDC).decimals(), 6, "unexpected USDC decimals");
        assertEq(IERC20Metadata(YEARN_USDC_HORIZON_VAULT).decimals(), 6, "unexpected vault share decimals");
        assertEq(yearnVault.apiVersion(), "3.0.4", "unexpected Yearn API version");
        assertFalse(yearnVault.isShutdown(), "Yearn vault is shut down");
        assertGt(yearnVault.deposit_limit(), IERC4626(YEARN_USDC_HORIZON_VAULT).totalAssets(), "Yearn vault deposit limit reached");
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

    function test_yearnUsdcHorizon_allocateAndPartiallyDeallocate() public {
        uint256 allocationAmount = 500e6;
        uint256 requestedDeallocation = 250e6;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAllocation, 0, "strategy should hold assets after allocation");
        assertGt(IERC20(YEARN_USDC_HORIZON_VAULT).balanceOf(strategy), 0, "strategy should hold Yearn vault shares");
        assertGe(IERC4626(YEARN_USDC_HORIZON_VAULT).maxWithdraw(strategy), requestedDeallocation, "insufficient Yearn liquidity");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), realAssetsAfterAllocation, 2, "MYT allocation should track strategy value");

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedDeallocation);
        assertGt(deallocationAmount, 0, "deallocation preview should be positive");
        assertLt(deallocationAmount, requestedDeallocation, "preview should include configured slippage");

        uint256 mytUsdcBefore = IERC20(BASE_USDC).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);

        assertGt(IERC20(BASE_USDC).balanceOf(vault), mytUsdcBefore, "MYT should receive USDC");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsAfterAllocation, "strategy value should decrease");
        assertGt(IERC20(YEARN_USDC_HORIZON_VAULT).balanceOf(strategy), 0, "strategy should retain shares after partial exit");
    }
}
