// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {ErrorsLib} from "lib/vault-v2/src/libraries/ErrorsLib.sol";

import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";
import {ERC4626Candidates} from "./base/ERC4626Candidates.sol";

interface IYearnV3VaultMetadata {
    function apiVersion() external view returns (string memory);
    function isShutdown() external view returns (bool);
    function deposit_limit() external view returns (uint256);
}

contract YearnUSDCHorizonStrategyTest is ERC4626StrategyUnitTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnUSDCHorizon();
    }

    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isAllocationFuzz = context == RevertContext.HandlerAllocate || context == RevertContext.FuzzAllocate;
        return isAllocationFuzz && selector == ErrorsLib.RelativeCapExceeded.selector;
    }

    function test_yearnUsdcHorizon_metadataAndCapacity() public view {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 yearnVault = IERC4626(candidate.targetVault);
        IYearnV3VaultMetadata metadata = IYearnV3VaultMetadata(candidate.targetVault);

        assertEq(IERC20Metadata(candidate.asset).decimals(), candidate.assetDecimals, "unexpected asset decimals");
        assertEq(metadata.apiVersion(), "3.0.4", "unexpected Yearn API version");
        assertFalse(metadata.isShutdown(), "Yearn vault is shut down");
        assertGt(metadata.deposit_limit(), yearnVault.totalAssets(), "Yearn vault deposit limit reached");
    }

    function test_yearnUsdcHorizon_allocateAndPartiallyDeallocate() public {
        ERC4626Candidate memory candidate = _candidate();
        uint256 allocationAmount = 500e6;
        uint256 requestedDeallocation = 250e6;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAllocation, 0, "strategy should hold assets after allocation");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), 0, "strategy should hold Yearn shares");
        assertGe(IERC4626(candidate.targetVault).maxWithdraw(strategy), requestedDeallocation, "insufficient Yearn liquidity");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), realAssetsAfterAllocation, 2, "MYT allocation should track strategy value");

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedDeallocation);
        assertGt(deallocationAmount, 0, "deallocation preview should be positive");
        assertLt(deallocationAmount, requestedDeallocation, "preview should include configured slippage");

        uint256 mytUsdcBefore = IERC20(candidate.asset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);

        assertGt(IERC20(candidate.asset).balanceOf(vault), mytUsdcBefore, "MYT should receive USDC");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsAfterAllocation, "strategy value should decrease");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), 0, "strategy should retain shares after partial exit");
    }
}

contract YearnUSDCHorizonInvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnUSDCHorizon();
    }
}
