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

interface IFluidFTokenData {
    function getData()
        external
        view
        returns (
            address liquidity,
            address lendingFactory,
            address lendingRewardsRateModel,
            address permit2,
            address rebalancer,
            bool rewardsActive,
            uint256 liquidityBalance,
            uint256 liquidityExchangePrice,
            uint256 tokenExchangePrice
        );
}

contract FluidUSDCBaseStrategyTest is ERC4626StrategyUnitTestBase {
    // FluidLiquidityError(uint256) — observed on dust-sized Fluid deposits.
    bytes4 internal constant ALLOWED_FLUID_REVERT_SELECTOR = 0xdcab82e2;

    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.fluidUSDCBase();
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;

        return isFuzzOrHandler && selector == ALLOWED_FLUID_REVERT_SELECTOR;
    }

    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isAllocationFuzz = context == RevertContext.HandlerAllocate || context == RevertContext.FuzzAllocate;
        return isAllocationFuzz && selector == ErrorsLib.RelativeCapExceeded.selector;
    }

    function test_fluidUsdcBase_isLendingFTokenNotLite() public view {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 fluidVault = IERC4626(candidate.targetVault);
        (,,,,, bool rewardsActive, uint256 liquidityBalance, uint256 liquidityExchangePrice, uint256 tokenExchangePrice) =
            IFluidFTokenData(candidate.targetVault).getData();

        assertEq(IERC20Metadata(candidate.targetVault).name(), "Fluid USD Coin", "unexpected fToken name");
        assertEq(IERC20Metadata(candidate.targetVault).symbol(), "fUSDC", "unexpected fToken symbol");
        assertEq(IERC20Metadata(candidate.asset).decimals(), candidate.assetDecimals, "unexpected asset decimals");
        assertEq(fluidVault.asset(), candidate.asset, "unexpected underlying asset");
        assertFalse(rewardsActive, "Fluid rewards should be inactive");
        assertGt(liquidityBalance, 0, "Fluid liquidity balance should be positive");
        assertGt(tokenExchangePrice, liquidityExchangePrice, "token exchange price should include accrued yield");
        assertGt(fluidVault.maxDeposit(strategy), candidate.initialDeposit, "Fluid deposit capacity too low");
    }

    function test_fluidUsdcBase_allocateAndPartiallyDeallocate() public {
        ERC4626Candidate memory candidate = _candidate();
        uint256 allocationAmount = 500e6;
        uint256 requestedDeallocation = 250e6;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAllocation, 0, "strategy should hold assets after allocation");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), 0, "strategy should hold Fluid shares");
        assertGe(IERC4626(candidate.targetVault).maxWithdraw(strategy), requestedDeallocation, "insufficient Fluid liquidity");
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

contract FluidUSDCBaseInvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.fluidUSDCBase();
    }
}
