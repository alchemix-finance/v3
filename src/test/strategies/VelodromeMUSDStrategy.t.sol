// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {VelodromeMUSDStrategy} from "../../strategies/VelodromeMUSDStrategy.sol";
import {IVelodromeGauge, IVelodromePool, IVelodromeRouter} from "../../strategies/interfaces/IVelodrome.sol";

contract VelodromeMUSDStrategyHarness is VelodromeMUSDStrategy {
    constructor(address myt, StrategyParams memory params, address usdc_, address musd_, address pool_, address gauge_, address router_, address factory_)
        VelodromeMUSDStrategy(myt, params, usdc_, musd_, pool_, gauge_, router_, factory_)
    {}

    function exposedLpFairValueUsdc(uint256 liquidity) external view returns (uint256) {
        return _lpFairValueUsdc(liquidity);
    }
}

contract VelodromeMUSDStrategyTest is BaseStrategyTest {
    /// @dev Vault is oversized so MEDIUM global risk (40%) stays above the absolute cap.
    ///      Absolute cap clamps BaseStrategy fuzz to live-pool-safe sizes.
    uint256 internal constant INITIAL_VAULT_DEPOSIT = 1_000_000e6;
    uint256 internal constant LIVE_POOL_TEST_CAP = 100_000e6;
    uint256 internal constant ABSOLUTE_CAP = LIVE_POOL_TEST_CAP;
    uint256 internal constant RELATIVE_CAP = 1e18;
    uint256 internal constant MUSD_PRECISION = 1e18;
    uint256 internal constant USDC_PRECISION = 1e6;
    bytes4 internal constant ABSOLUTE_CAP_EXCEEDED_SELECTOR = 0x4616e4af;
    bytes4 internal constant INSUFFICIENT_LIQUIDITY_BURNED_SELECTOR = 0x749383ad;
    bytes4 internal constant INSUFFICIENT_BALANCE_SELECTOR = 0xcf479181;
    /// @dev Velodrome router InsufficientOutputAmount — TWAP/peg mins under live impact.
    bytes4 internal constant INSUFFICIENT_OUTPUT_AMOUNT_SELECTOR = 0x42301c23;

    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant MUSD = 0x9dAbAE7274D28A45F0B65Bf8ED201A5731492ca0;
    address internal constant POOL = 0xe07388b2a7bb29d3Ad8989e1074Bd00Bd0d3C43d;
    address internal constant GAUGE = 0x7b3f9Ae95D8852078E49168505d6C897E4B11B6E;
    address internal constant ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal constant FACTORY = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Velodrome USDC/msUSD",
            protocol: "Velodrome",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 0,
            additionalIncentives: true,
            slippageBPS: 300
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: INITIAL_VAULT_DEPOSIT, absoluteCap: ABSOLUTE_CAP, relativeCap: RELATIVE_CAP, decimals: 6});
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new VelodromeMUSDStrategyHarness(vault_, params, USDC, MUSD, POOL, GAUGE, ROUTER, FACTORY));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function _getMinAllocateAmount() internal pure override returns (uint256) {
        return 1e6;
    }

    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        if (selector == INSUFFICIENT_BALANCE_SELECTOR) {
            return context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzDeallocate;
        }
        if (selector != ABSOLUTE_CAP_EXCEEDED_SELECTOR) return false;

        return context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzAllocate
            || context == RevertContext.FuzzDeallocate;
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        if (selector == INSUFFICIENT_LIQUIDITY_BURNED_SELECTOR) {
            return context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzDeallocate;
        }
        if (selector == INSUFFICIENT_OUTPUT_AMOUNT_SELECTOR) {
            return context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
                || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;
        }
        return false;
    }

    function test_fuzz_allocate(uint256 amount) public {
        amount = bound(amount, 100e6, LIVE_POOL_TEST_CAP);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 stakedLp = IVelodromeGauge(GAUGE).balanceOf(strategy);
        assertGt(stakedLp, 0, "no gauge position");
        assertEq(IERC20(POOL).balanceOf(strategy), 0, "LP should be staked");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), amount, 0.05e18, "unexpected fair LP value");
        assertLe(IMYTStrategy(strategy).realAssets(), amount, "realAssets above deposited amount");
        assertEq(IERC20(USDC).allowance(strategy, ROUTER), 0, "USDC router allowance not cleared");
        assertEq(IERC20(MUSD).allowance(strategy, ROUTER), 0, "msUSD router allowance not cleared");
        assertEq(IERC20(POOL).allowance(strategy, GAUGE), 0, "LP gauge allowance not cleared");
    }

    function test_fuzz_deallocate(uint256 amount) public {
        amount = bound(amount, 100e6, LIVE_POOL_TEST_CAP);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        // Force an LP exit: leftover idle USDC after allocate can cover small withdrawals.
        uint256 idle = IERC20(USDC).balanceOf(strategy);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        if (realAssets <= idle + 1e6) {
            vm.stopPrank();
            return;
        }
        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(idle + (realAssets - idle) / 5);
        require(withdrawal > idle, "withdrawal still idle-only");

        uint256 stakedBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + withdrawal, "vault did not receive USDC");
        assertLt(IVelodromeGauge(GAUGE).balanceOf(strategy), stakedBefore, "LP was not unstaked");
        assertEq(IERC20(POOL).allowance(strategy, ROUTER), 0, "LP router allowance not cleared");
        assertEq(IERC20(MUSD).allowance(strategy, ROUTER), 0, "msUSD router allowance not cleared");
        assertLe(IERC20(MUSD).balanceOf(strategy), MUSD_PRECISION / USDC_PRECISION, "msUSD dust not swept");
    }

    function test_deallocate_fullPositionClearsLpAndCostBasis(uint256 amount) public {
        amount = bound(amount, 100e6, LIVE_POOL_TEST_CAP);
        // Preview-sized full exits can leave wei-level LP from slip/buffer rounding.
        uint256 dustToleranceUsdc = 1e6;

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        vm.stopPrank();

        uint256 lpLeft = IVelodromeGauge(GAUGE).balanceOf(strategy) + IERC20(POOL).balanceOf(strategy);
        assertLe(
            VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(lpLeft), dustToleranceUsdc, "LP dust value too high"
        );
        assertLe(VelodromeMUSDStrategy(strategy).lpCostBasisUsdc(), dustToleranceUsdc, "LP cost basis dust too high");
        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + withdrawal, "vault did not receive USDC");
        assertApproxEqAbs(
            IMYTStrategy(strategy).realAssets(), IERC20(USDC).balanceOf(strategy), dustToleranceUsdc, "non-idle value remains"
        );
    }

    function test_fuzz_partialDeallocationReducesCostBasisProportionally(uint256 amount, uint256 withdrawal) public {
        amount = bound(amount, 100e6, LIVE_POOL_TEST_CAP);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        uint256 lpBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        uint256 basisBefore = VelodromeMUSDStrategy(strategy).lpCostBasisUsdc();
        uint256 idleAfterAllocation = IERC20(USDC).balanceOf(strategy);

        withdrawal = bound(withdrawal, 1e6, IMYTStrategy(strategy).previewAdjustedWithdraw(amount) / 2);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        vm.stopPrank();

        uint256 lpAfter = IVelodromeGauge(GAUGE).balanceOf(strategy);
        uint256 expectedBasisReduction = Math.mulDiv(basisBefore, lpBefore - lpAfter, lpBefore, Math.Rounding.Ceil);
        uint256 basisAfter = VelodromeMUSDStrategy(strategy).lpCostBasisUsdc();
        uint256 idleAfterDeallocation = IERC20(USDC).balanceOf(strategy);

        assertEq(basisBefore, amount - idleAfterAllocation, "allocation cost basis mismatch");
        assertEq(basisAfter, basisBefore - expectedBasisReduction, "cost basis reduction mismatch");
        assertLe(IMYTStrategy(strategy).realAssets(), idleAfterDeallocation + basisAfter, "position exceeds cost basis");
    }

    function test_fuzz_deallocate_usesIdleUsdcBeforeUnstaking(uint256 amount, uint256 idleAmount, uint256 withdrawal) public {
        amount = bound(amount, 1e6, LIVE_POOL_TEST_CAP - 1e6);
        idleAmount = bound(idleAmount, 1e6, LIVE_POOL_TEST_CAP - amount);
        withdrawal = bound(withdrawal, 1, idleAmount);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        vm.stopPrank();

        uint256 stakedBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        uint256 basisBefore = VelodromeMUSDStrategy(strategy).lpCostBasisUsdc();
        uint256 existingIdle = IERC20(USDC).balanceOf(strategy);
        deal(USDC, strategy, existingIdle + idleAmount);
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);

        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, withdrawal);

        assertEq(IVelodromeGauge(GAUGE).balanceOf(strategy), stakedBefore, "idle withdrawal unstaked LP");
        assertEq(VelodromeMUSDStrategy(strategy).lpCostBasisUsdc(), basisBefore, "idle withdrawal changed cost basis");
        assertEq(IERC20(USDC).balanceOf(strategy), existingIdle + idleAmount - withdrawal, "wrong idle balance");
        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + withdrawal, "vault did not receive idle USDC");
    }

    /// @dev Writes fresh pool observations while time passes, mimicking the arb/organic flow
    ///      that keeps the TWAP tracking reality between spaced operations on mainnet.
    ///      Without this, the fork's TWAP stays frozen at pre-trade skew and blocks follow-ups.
    function _advanceTimeWithTwapPokes(uint256 duration) internal {
        address poker = makeAddr("twapPoker");
        uint256 steps = 3; // pool records one observation per 30 min; granularity is 2
        uint256 pokeAmount = 100e6;

        deal(USDC, poker, pokeAmount * steps);
        vm.startPrank(poker);
        IERC20(USDC).approve(ROUTER, pokeAmount * steps);
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: USDC, to: MUSD, stable: true, factory: FACTORY});

        for (uint256 i = 0; i < steps; i++) {
            vm.warp(block.timestamp + duration / steps);
            IVelodromeRouter(ROUTER).swapExactTokensForTokens(pokeAmount, 0, routes, poker, block.timestamp);
        }
        vm.stopPrank();
    }

    /// @dev Simulates arbitrage closing the msUSD discount created by our exit sweeps:
    ///      buys msUSD until its marginal price recovers to the pre-trade level. On mainnet
    ///      this happens organically; on a frozen fork nothing trades between our txs.
    function _arbRestoreMusdPrice(uint256 targetMusdOutPer1Usdc) internal {
        address arb = makeAddr("arbBot");
        uint256 arbChunk = 10_000e6;
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: USDC, to: MUSD, stable: true, factory: FACTORY});

        for (uint256 i = 0; i < 30; i++) {
            if (IVelodromePool(POOL).getAmountOut(1e6, USDC) <= targetMusdOutPer1Usdc) break;
            deal(USDC, arb, arbChunk);
            vm.startPrank(arb);
            IERC20(USDC).approve(ROUTER, arbChunk);
            IVelodromeRouter(ROUTER).swapExactTokensForTokens(arbChunk, 0, routes, arb, block.timestamp);
            vm.stopPrank();
        }
    }

    /// @dev Deepen the live pool without moving price: add liquidity proportional to reserves.
    function _seedPoolLiquidity(uint256 usdcAmount) internal {
        address lp = makeAddr("poolWhale");
        (uint256 r0, uint256 r1,) = IVelodromePool(POOL).getReserves();
        uint256 musdAmount = Math.mulDiv(usdcAmount, r1, r0);

        deal(USDC, lp, usdcAmount);
        deal(MUSD, lp, musdAmount);

        vm.startPrank(lp);
        IERC20(USDC).approve(ROUTER, usdcAmount);
        IERC20(MUSD).approve(ROUTER, musdAmount);
        IVelodromeRouter(ROUTER).addLiquidity(USDC, MUSD, true, usdcAmount, musdAmount, 0, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Production usage profile: 3 spaced `chunk` allocations (over ~a day), then a full
    ///      exit in at most 3 deallocations (over ~an hour). Verifies the position does not
    ///      get stuck behind the swap mins / exit floor at the default slippageBPS.
    function _runProductionProfile(uint256 chunk) internal {
        uint256 total = 3 * chunk;
        uint256 dustToleranceUsdc = 1e6;
        // Max acceptable round-trip loss: slippageBPS on the full position.
        uint256 maxLoss = total * 300 / 10_000;

        // Deepen the vault so the MEDIUM local risk cap (25% of totalAssets) clears the
        // position, then raise the vault absolute cap (test default clamps sizes to 100k).
        uint256 requiredVaultAssets = 4 * total + 100_000e6;
        uint256 currentVaultAssets = IVaultV2(vault).totalAssets();
        if (currentVaultAssets < requiredVaultAssets) {
            _magicDepositToVault(vault, vaultDepositor, requiredVaultAssets - currentVaultAssets);
        }
        bytes memory idData = IMYTStrategy(strategy).getIdData();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, total)));
        IVaultV2(vault).increaseAbsoluteCap(idData, total);
        vm.stopPrank();

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(admin);
            IAllocator(allocator).allocate(strategy, chunk);
            _advanceTimeWithTwapPokes(2 hours);
        }

        // Exit in up to 3 chunks (~1/3 each) spread over an hour; arbs restore the
        // msUSD price between chunks like they would on mainnet.
        for (uint256 i = 0; i < 3; i++) {
            uint256 realAssets = IMYTStrategy(strategy).realAssets();
            if (realAssets <= dustToleranceUsdc) break;
            uint256 target = realAssets / (3 - i);
            uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
            if (withdrawal == 0) break;
            uint256 preMarginalOut = IVelodromePool(POOL).getAmountOut(1e6, USDC);
            vm.prank(admin);
            IAllocator(allocator).deallocate(strategy, withdrawal);
            _arbRestoreMusdPrice(preMarginalOut);
            _advanceTimeWithTwapPokes(30 minutes);
        }

        // Flush leftover idle USDC (exit overshoot) back to the vault.
        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        VelodromeMUSDStrategy(strategy).withdrawToVault();

        uint256 lpLeft = IVelodromeGauge(GAUGE).balanceOf(strategy) + IERC20(POOL).balanceOf(strategy);
        assertLe(
            VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(lpLeft), dustToleranceUsdc, "LP dust value too high"
        );
        assertLe(VelodromeMUSDStrategy(strategy).lpCostBasisUsdc(), dustToleranceUsdc, "LP cost basis dust too high");
        assertLe(IMYTStrategy(strategy).realAssets(), dustToleranceUsdc, "position not fully exited");
        assertGe(IERC20(USDC).balanceOf(vault), vaultUsdcBefore - maxLoss, "round-trip loss exceeds slippage budget");
    }

    function test_productionProfile_threeAllocationsThenFullExit() public {
        _runProductionProfile(100_000e6);
    }

    /// @dev Same profile at larger chunks against a deepened pool. Validates the strategy
    ///      math scales; NOT evidence that 250k chunks are safe at today's live pool depth.
    function test_productionProfile_deepPool_largerChunks() public {
        _seedPoolLiquidity(1_000_000e6);
        _runProductionProfile(250_000e6);
    }

    function test_fairValue_isNoGreaterThanPegReserveSum() public view {
        (uint256 reserve0, uint256 reserve1,) = IVelodromePool(POOL).getReserves();
        uint256 supply = IVelodromePool(POOL).totalSupply();
        uint256 fairValue = VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(supply);
        uint256 pegReserveSum = reserve0 + reserve1 / 1e12;

        assertLe(fairValue, pegReserveSum, "fair value exceeds peg reserve sum");
        assertGt(fairValue, 0, "zero fair value");
    }

    function test_setSwapSlippageBPS_isIndependentOfPreviewHaircut() public {
        VelodromeMUSDStrategy strat = VelodromeMUSDStrategy(strategy);
        assertEq(strat.swapSlippageBPS(), 300, "should seed from slippageBPS");

        vm.expectRevert();
        strat.setSwapSlippageBPS(100); // caller is not the owner

        vm.prank(strat.owner());
        vm.expectRevert("Slippage too high");
        strat.setSwapSlippageBPS(5000);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 10_000e6);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 previewBefore = IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets);

        // Swap execution tolerance must not affect withdraw previews.
        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(100);
        assertEq(strat.swapSlippageBPS(), 100, "swap slippage not updated");
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets), previewBefore, "swap slippage changed preview");

        // The preview haircut still follows the base params.slippageBPS.
        vm.prank(strat.owner());
        strat.setSlippageBPS(100);
        assertGt(IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets), previewBefore, "preview should follow slippageBPS");
    }

    function test_constructor_usesExpectedGaugeRewardToken() public view {
        assertEq(address(VelodromeMUSDStrategy(strategy).velo()), IVelodromeGauge(GAUGE).rewardToken(), "wrong VELO token");
        assertEq(IVelodromeGauge(GAUGE).stakingToken(), POOL, "wrong staking token");
    }
}
