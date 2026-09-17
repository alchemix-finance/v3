// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {console} from "forge-std/console.sol";

import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";
import {ERC4626Candidates} from "./base/ERC4626Candidates.sol";

interface IYearnV3VaultMetadata {
    function apiVersion() external view returns (string memory);
    function isShutdown() external view returns (bool);
    function deposit_limit() external view returns (uint256);
}

interface IYearnV3VaultDebt {
    function update_debt(address strategy, uint256 targetDebt) external returns (uint256);
    function totalIdle() external view returns (uint256);
    function strategies(address strategy) external view returns (uint256 activation, uint256 lastReport, uint256 currentDebt, uint256 maxDebt);
    function add_strategy(address newStrategy, bool addToQueue) external;
    function update_max_debt_for_strategy(address strategy, uint256 newMaxDebt) external;
}

interface ITokenizedStrategy {
    function isShutdown() external view returns (bool);
}

contract YvWETH2StrategyTest is ERC4626StrategyUnitTestBase {
    address internal constant YV_WETH_1_VAULT = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;
    address internal constant YEARN_DEBT_ALLOCATOR = 0x1e9eB053228B1156831759401dE0E115356b8671;
    address internal constant YEARN_STRATEGY_TIMELOCK = 0x88Ba032be87d5EF1fbE87336B7090767F367BF73;
    address internal constant LIVE_YV_WETH_1_STRATEGY = 0x8AACC947c2f4E24D2Be4CBa4498f004079F35D87;
    address internal constant YV_WETH_1_STETH_ACCUMULATOR = 0x470e0e048F85CFD72EEf325895e02c8D297E7435;
    address internal constant SPARK_WSTETH_YVUSD_LOOPER = 0x13f6Cb609959a43c3bE29407766A683b42e26D28;
    address internal constant MORPHO_Y_WETH_COMPOUNDER = 0xd9BA99D93ea94a65b5BC838a0106cA3AbC82Ec4F;
    uint256 internal constant YEARN_QUEUED_MAX_DEBT = 10_000e18;
    // TokenizedStrategy 3.0.4: keccak256("yearn.base.strategy.storage") - 1, then +12 to the packed
    // `emergencyAdmin` / `entered` / `shutdown` slot.
    bytes32 internal constant MORPHO_SHUTDOWN_SLOT = 0xd2841a5d2692465040bd5e06a6f3b37483952c866e0f304dc0e03f76a1f8a0bc;

    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnWETH2();
    }

    function _liveYvWeth1PositionAssets() internal view returns (uint256) {
        uint256 shares = IERC20(YV_WETH_1_VAULT).balanceOf(LIVE_YV_WETH_1_STRATEGY);
        require(shares > 0, "live yvWETH-1 strategy has no shares at this fork");
        return IERC4626(YV_WETH_1_VAULT).convertToAssets(shares);
    }

    function _seedLiveYvWeth2Deposit() internal returns (uint256 liveAmount) {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 yearnVault = IERC4626(candidate.targetVault);
        liveAmount = _liveYvWeth1PositionAssets();
        require(yearnVault.maxDeposit(strategy) >= liveAmount, "yvWETH-2 cannot accept the live deposit");

        _magicDepositToVault(vault, vaultDepositor, liveAmount);
        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), liveAmount);

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        assertApproxEqAbs(realAssets, liveAmount, 1e15, "strategy should track the live deposit");
        assertApproxEqAbs(yearnVault.maxWithdraw(strategy), realAssets, 1e15, "idle yvWETH-2 deposits should be instantly withdrawable");
        assertGt(IYearnV3VaultDebt(candidate.targetVault).totalIdle(), 0, "deposit should sit idle until Yearn allocates debt");
    }

    function _moveYvWeth2IdleTo(address targetStrategy) internal {
        IYearnV3VaultDebt yearnWeth2 = IYearnV3VaultDebt(_candidate().targetVault);
        (,, uint256 currentDebt, uint256 maxDebt) = yearnWeth2.strategies(targetStrategy);
        uint256 idle = yearnWeth2.totalIdle();
        uint256 targetDebt = currentDebt + idle;
        assertGt(idle, 0, "no idle WETH to allocate");
        assertLe(targetDebt, maxDebt, "target max_debt cannot absorb the live deposit");
        assertGt(IERC4626(targetStrategy).maxDeposit(address(yearnWeth2)), 0, "target strategy is not depositing");

        vm.prank(YEARN_DEBT_ALLOCATOR);
        yearnWeth2.update_debt(targetStrategy, targetDebt);

        assertLt(yearnWeth2.totalIdle(), 1e15, "Yearn should have moved idle WETH into the target strategy");
        (,, uint256 debtAfter,) = yearnWeth2.strategies(targetStrategy);
        assertGt(debtAfter, currentDebt, "target strategy debt should increase");
    }

    function _unshutdownMorphoCompounder() internal {
        ITokenizedStrategy morpho = ITokenizedStrategy(MORPHO_Y_WETH_COMPOUNDER);
        assertTrue(morpho.isShutdown(), "Morpho compounder should start shutdown");

        bytes32 packed = vm.load(MORPHO_Y_WETH_COMPOUNDER, MORPHO_SHUTDOWN_SLOT);
        // Packed TokenizedStrategy slot: emergencyAdmin (160) | entered (8) | shutdown (8).
        vm.store(MORPHO_Y_WETH_COMPOUNDER, MORPHO_SHUTDOWN_SLOT, packed & bytes32(~(uint256(0xff) << 168)));

        assertFalse(morpho.isShutdown(), "failed to clear Morpho shutdown flag");
        assertGt(IERC4626(MORPHO_Y_WETH_COMPOUNDER).maxDeposit(_candidate().targetVault), 0, "Morpho still has no deposit capacity");
    }

    function _logWithdrawCapacity(string memory label, address nestedStrategy) internal view {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 yearnVault = IERC4626(candidate.targetVault);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdraw = yearnVault.maxWithdraw(strategy);
        uint256 withdrawableBps = realAssets == 0 ? 0 : maxWithdraw * 10_000 / realAssets;

        console.log(label);
        console.log("realAssets", realAssets);
        console.log("yvWETH-2 maxWithdraw(strategy)", maxWithdraw);
        console.log("withdrawable bps (10000 = 100%)", withdrawableBps);
        console.log("nested maxWithdraw(yvWETH-2)", IERC4626(nestedStrategy).maxWithdraw(candidate.targetVault));
        console.log("yvWETH-1 maxWithdraw(yvWETH-2)", IERC4626(YV_WETH_1_VAULT).maxWithdraw(candidate.targetVault));
    }

    function _assertDeallocateAboveMaxWithdrawReverts() internal {
        IERC4626 yearnVault = IERC4626(_candidate().targetVault);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdraw = yearnVault.maxWithdraw(strategy);

        vm.prank(allocator);
        vm.expectRevert();
        IVaultV2(vault).deallocate(strategy, getVaultParams(), realAssets);

        uint256 aboveMax = maxWithdraw == 0 ? 1 : maxWithdraw + 1;
        vm.prank(allocator);
        vm.expectRevert();
        IVaultV2(vault).deallocate(strategy, getVaultParams(), aboveMax);

        if (maxWithdraw == 0) return;

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(maxWithdraw);
        uint256 mytWethBefore = IERC20(_candidate().asset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);
        assertGt(IERC20(_candidate().asset).balanceOf(vault), mytWethBefore, "instant capacity should deallocate");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssets, "strategy value should decrease after partial exit");
    }

    function test_yearnWeth2_metadataAndCapacity() public view {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 yearnVault = IERC4626(candidate.targetVault);
        IYearnV3VaultMetadata metadata = IYearnV3VaultMetadata(candidate.targetVault);

        assertEq(IERC20Metadata(candidate.asset).decimals(), candidate.assetDecimals, "unexpected asset decimals");
        assertEq(yearnVault.asset(), candidate.asset, "Yearn vault asset is not WETH");
        assertEq(metadata.apiVersion(), "3.0.2", "unexpected Yearn API version");
        assertFalse(metadata.isShutdown(), "Yearn vault is shut down");
        assertGt(metadata.deposit_limit(), yearnVault.totalAssets(), "Yearn vault deposit limit reached");
        assertGt(yearnVault.maxDeposit(strategy), 0, "Yearn vault has no deposit capacity");
    }

    function test_yearnWeth2_allocateAndPartiallyDeallocate() public {
        ERC4626Candidate memory candidate = _candidate();
        uint256 allocationAmount = 50e18;
        uint256 requestedDeallocation = 20e18;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAllocation, 0, "strategy should hold assets after allocation");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), 0, "strategy should hold Yearn shares");
        assertGe(IERC4626(candidate.targetVault).maxWithdraw(strategy), requestedDeallocation, "insufficient Yearn liquidity");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), realAssetsAfterAllocation, 1e15, "MYT allocation should track strategy value");

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedDeallocation);
        assertGt(deallocationAmount, 0, "deallocation preview should be positive");
        assertLt(deallocationAmount, requestedDeallocation, "preview should include configured slippage");

        uint256 mytWethBefore = IERC20(candidate.asset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);

        assertGt(IERC20(candidate.asset).balanceOf(vault), mytWethBefore, "MYT should receive WETH");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsAfterAllocation, "strategy value should decrease");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), 0, "strategy should retain shares after partial exit");
    }

    function test_yearnWeth2_liquidityAdapter_depositAndWithdraw() public {
        ERC4626Candidate memory candidate = _candidate();
        uint256 depositAmount = 25e18;
        address depositor = makeAddr("yvWeth2Depositor");

        vm.prank(admin);
        IAllocator(allocator).setLiquidityAdapter(strategy, getVaultParams());
        assertEq(IVaultV2(vault).liquidityAdapter(), strategy, "yvWETH-2 should be the liquidity adapter");

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 yearnSharesBefore = IERC20(candidate.targetVault).balanceOf(strategy);

        deal(candidate.asset, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(candidate.asset).approve(vault, depositAmount);
        IVaultV2(vault).deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 realAssetsAfterDeposit = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterDeposit, realAssetsBefore, "deposit should allocate into yvWETH-2");
        assertGt(IERC20(candidate.targetVault).balanceOf(strategy), yearnSharesBefore, "strategy should mint Yearn shares");
        assertApproxEqAbs(realAssetsAfterDeposit - realAssetsBefore, depositAmount, 1e15, "liquidity adapter should receive the deposit");

        // Idle WETH from setUp is consumed first on withdraw, so park it in the adapter first.
        uint256 idleWeth = IERC20(candidate.asset).balanceOf(vault);
        if (idleWeth > 0) {
            vm.prank(allocator);
            IVaultV2(vault).allocate(strategy, getVaultParams(), idleWeth);
        }

        uint256 withdrawAmount = depositAmount;
        uint256 userWethBefore = IERC20(candidate.asset).balanceOf(depositor);
        uint256 realAssetsBeforeWithdraw = IMYTStrategy(strategy).realAssets();

        vm.prank(depositor);
        IVaultV2(vault).withdraw(withdrawAmount, depositor, depositor);

        assertEq(IERC20(candidate.asset).balanceOf(depositor), userWethBefore + withdrawAmount, "depositor should receive WETH");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsBeforeWithdraw, "withdraw should deallocate from yvWETH-2");
        assertEq(IVaultV2(vault).liquidityAdapter(), strategy, "liquidity adapter should remain yvWETH-2");
    }

    /// @notice Deposit the live yvWETH-1 production size into yvWETH-2, then impersonate Yearn:
    ///         1) yvWETH-2 `update_debt` into yvWETH-1 (funds land idle there, still 100% instant)
    ///         2) yvWETH-1 `update_debt` into the stETH Accumulator (queue head, currently illiquid)
    ///         After (2), anything above `maxWithdraw` reverts because ERC4626Strategy uses 3-arg
    ///         Yearn `withdraw` (`max_loss = 0`).
    function test_yearnWeth2_liveDeposit_notFullyWithdrawableAfterDebtToYvWeth1() public {
        ERC4626Candidate memory candidate = _candidate();
        IERC4626 yearnVault = IERC4626(candidate.targetVault);
        IYearnV3VaultDebt yearnWeth2 = IYearnV3VaultDebt(candidate.targetVault);
        IYearnV3VaultDebt yearnWeth1 = IYearnV3VaultDebt(YV_WETH_1_VAULT);

        uint256 liveAmount = _liveYvWeth1PositionAssets();
        uint256 yearnCapacity = yearnVault.maxDeposit(strategy);
        require(yearnCapacity >= liveAmount, "yvWETH-2 cannot accept the live deposit");

        _magicDepositToVault(vault, vaultDepositor, liveAmount);

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), liveAmount);

        uint256 realAssetsAfterDeposit = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdrawWhileIdle = yearnVault.maxWithdraw(strategy);
        assertApproxEqAbs(realAssetsAfterDeposit, liveAmount, 1e15, "strategy should track the live deposit");
        assertApproxEqAbs(maxWithdrawWhileIdle, realAssetsAfterDeposit, 1e15, "idle yvWETH-2 deposits should be instantly withdrawable");
        assertGt(yearnWeth2.totalIdle(), 0, "deposit should sit idle until Yearn allocates debt");

        (,, uint256 yvWeth1Debt, uint256 yvWeth1MaxDebt) = yearnWeth2.strategies(YV_WETH_1_VAULT);
        uint256 yvWeth2Idle = yearnWeth2.totalIdle();
        uint256 yvWeth1TargetDebt = yvWeth1Debt + yvWeth2Idle;
        assertLe(yvWeth1TargetDebt, yvWeth1MaxDebt, "yvWETH-1 max_debt cannot absorb the live deposit");

        vm.prank(YEARN_DEBT_ALLOCATOR);
        yearnWeth2.update_debt(YV_WETH_1_VAULT, yvWeth1TargetDebt);

        uint256 realAssetsAfterYvWeth1 = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdrawAfterYvWeth1 = yearnVault.maxWithdraw(strategy);
        console.log("live yvWETH-1 position (WETH)", liveAmount);
        console.log("realAssets after yvWETH-2 -> yvWETH-1", realAssetsAfterYvWeth1);
        console.log("maxWithdraw after yvWETH-2 -> yvWETH-1", maxWithdrawAfterYvWeth1);
        console.log("withdrawable bps after hop 1", maxWithdrawAfterYvWeth1 * 10_000 / realAssetsAfterYvWeth1);

        assertLt(yearnWeth2.totalIdle(), 1e15, "Yearn should have moved idle WETH into yvWETH-1");
        assertApproxEqAbs(maxWithdrawAfterYvWeth1, realAssetsAfterYvWeth1, 1e15, "funds idle in yvWETH-1 stay instantly withdrawable");

        (,, uint256 stethDebt, uint256 stethMaxDebt) = yearnWeth1.strategies(YV_WETH_1_STETH_ACCUMULATOR);
        uint256 yvWeth1Idle = yearnWeth1.totalIdle();
        uint256 stethTargetDebt = stethDebt + yvWeth1Idle;
        assertGt(yvWeth1Idle, 0, "yvWETH-1 should be holding the new idle WETH");
        assertLe(stethTargetDebt, stethMaxDebt, "stETH Accumulator max_debt cannot absorb yvWETH-1 idle");

        vm.prank(YEARN_DEBT_ALLOCATOR);
        yearnWeth1.update_debt(YV_WETH_1_STETH_ACCUMULATOR, stethTargetDebt);

        uint256 realAssetsAfterSteth = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdrawAfterSteth = yearnVault.maxWithdraw(strategy);
        uint256 withdrawableBps = maxWithdrawAfterSteth * 10_000 / realAssetsAfterSteth;

        console.log("realAssets after yvWETH-1 -> stETH Accumulator", realAssetsAfterSteth);
        console.log("maxWithdraw after yvWETH-1 -> stETH Accumulator", maxWithdrawAfterSteth);
        console.log("withdrawable bps after hop 2 (10000 = 100%)", withdrawableBps);
        console.log("yvWETH-1 idle after stETH debt update", yearnWeth1.totalIdle());
        console.log("yvWETH-1 maxWithdraw(yvWETH-2)", IERC4626(YV_WETH_1_VAULT).maxWithdraw(candidate.targetVault));
        console.log("stETH Accumulator maxWithdraw(yvWETH-1)", IERC4626(YV_WETH_1_STETH_ACCUMULATOR).maxWithdraw(YV_WETH_1_VAULT));

        assertLt(yearnWeth1.totalIdle(), 1e15, "Yearn should have moved yvWETH-1 idle into stETH Accumulator");
        assertLt(maxWithdrawAfterSteth, realAssetsAfterSteth, "live deposit should no longer be fully instant after stETH deployment");
        assertGt(maxWithdrawAfterSteth, 0, "some instant liquidity should remain from yvWETH-1's liquid strategies");

        vm.prank(allocator);
        vm.expectRevert();
        IVaultV2(vault).deallocate(strategy, getVaultParams(), realAssetsAfterSteth);

        vm.prank(allocator);
        vm.expectRevert();
        IVaultV2(vault).deallocate(strategy, getVaultParams(), maxWithdrawAfterSteth + 1);

        uint256 deallocationAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(maxWithdrawAfterSteth);
        uint256 mytWethBefore = IERC20(candidate.asset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocationAmount);
        assertGt(IERC20(candidate.asset).balanceOf(vault), mytWethBefore, "instant capacity should deallocate");
        assertLt(IMYTStrategy(strategy).realAssets(), realAssetsAfterSteth, "strategy value should decrease after partial exit");
    }

    /// @notice Apply the queued Yearn timelock `add_strategy` for Spark wstETH → yvUSD, then move the
    ///         live-sized idle deposit into it and report vault-level instant withdraw capacity.
    function test_yearnWeth2_liveDeposit_withdrawCapacityAfterSparkWstethLooper() public {
        uint256 liveAmount = _seedLiveYvWeth2Deposit();
        IYearnV3VaultDebt yearnWeth2 = IYearnV3VaultDebt(_candidate().targetVault);

        (uint256 activationBefore,,,) = yearnWeth2.strategies(SPARK_WSTETH_YVUSD_LOOPER);
        assertEq(activationBefore, 0, "Spark looper should still be pending at this fork");

        vm.startPrank(YEARN_STRATEGY_TIMELOCK);
        yearnWeth2.add_strategy(SPARK_WSTETH_YVUSD_LOOPER, true);
        yearnWeth2.update_max_debt_for_strategy(SPARK_WSTETH_YVUSD_LOOPER, YEARN_QUEUED_MAX_DEBT);
        vm.stopPrank();

        (uint256 activationAfter,,, uint256 maxDebt) = yearnWeth2.strategies(SPARK_WSTETH_YVUSD_LOOPER);
        assertGt(activationAfter, 0, "Spark looper should be added");
        assertEq(maxDebt, YEARN_QUEUED_MAX_DEBT, "unexpected Spark max_debt");

        _moveYvWeth2IdleTo(SPARK_WSTETH_YVUSD_LOOPER);
        _logWithdrawCapacity("hop 3 Spark wstETH -> yvUSD looper", SPARK_WSTETH_YVUSD_LOOPER);
        console.log("live yvWETH-1 position (WETH)", liveAmount);

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdraw = IERC4626(_candidate().targetVault).maxWithdraw(strategy);
        assertLt(maxWithdraw, realAssets, "Spark looper should not be fully instantly withdrawable");
        _assertDeallocateAboveMaxWithdrawReverts();
    }

    /// @notice Re-enable the shutdown Morpho Y-WETH Compounder (already in the queue with 10k max_debt)
    ///         and move the live-sized idle deposit into it to measure instant withdraw capacity.
    function test_yearnWeth2_liveDeposit_withdrawCapacityAfterMorphoCompounder() public {
        uint256 liveAmount = _seedLiveYvWeth2Deposit();
        IYearnV3VaultDebt yearnWeth2 = IYearnV3VaultDebt(_candidate().targetVault);

        (uint256 activation,,, uint256 maxDebt) = yearnWeth2.strategies(MORPHO_Y_WETH_COMPOUNDER);
        assertGt(activation, 0, "Morpho compounder should already be a yvWETH-2 strategy");
        assertEq(maxDebt, YEARN_QUEUED_MAX_DEBT, "unexpected Morpho max_debt");

        _unshutdownMorphoCompounder();
        _moveYvWeth2IdleTo(MORPHO_Y_WETH_COMPOUNDER);
        _logWithdrawCapacity("hop 3 Morpho Y-WETH Compounder", MORPHO_Y_WETH_COMPOUNDER);
        console.log("live yvWETH-1 position (WETH)", liveAmount);

        // Yearn's 1-arg maxWithdraw uses max_loss = 0 and skips the *entire* remaining queue the
        // moment a leg carries any unrealized loss. Surface whether the Morpho leg has one.
        {
            uint256 vaultShares = IERC20(MORPHO_Y_WETH_COMPOUNDER).balanceOf(_candidate().targetVault);
            uint256 shareValue = IERC4626(MORPHO_Y_WETH_COMPOUNDER).convertToAssets(vaultShares);
            (,, uint256 morphoDebt,) = yearnWeth2.strategies(MORPHO_Y_WETH_COMPOUNDER);
            console.log("morpho leg: share value", shareValue);
            console.log("morpho leg: current debt", morphoDebt);
            console.log("morpho leg: unrealized loss", morphoDebt > shareValue ? morphoDebt - shareValue : 0);
        }

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 maxWithdraw = IERC4626(_candidate().targetVault).maxWithdraw(strategy);
        assertLt(maxWithdraw, realAssets, "Morpho compounder should not be fully instantly withdrawable");
        _assertDeallocateAboveMaxWithdrawReverts();
    }
}

contract YvWETH2InvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnWETH2();
    }
}
