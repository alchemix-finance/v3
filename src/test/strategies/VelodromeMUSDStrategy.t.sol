// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {VelodromeMUSDStrategy} from "../../strategies/VelodromeMUSDStrategy.sol";
import {IVelodromeGauge, IVelodromePool, IVelodromeRouter} from "../../strategies/interfaces/IVelodrome.sol";

/// @dev Etched over the live gauge so getReward can credit a fixed VELO amount.
contract MockVelodromeGaugeRewards {
    IERC20 public immutable rewardToken;
    uint256 public immutable rewardAmount;

    constructor(address rewardToken_, uint256 rewardAmount_) {
        rewardToken = IERC20(rewardToken_);
        rewardAmount = rewardAmount_;
    }

    function getReward(address account) external {
        if (rewardAmount > 0) {
            rewardToken.transfer(account, rewardAmount);
        }
    }
}

/// @dev AllowanceHolder stand-in: pulls approved VELO and pays a fixed USDC amount.
contract MockUsdcSwapExecutor {
    IERC20 public immutable velo;
    IERC20 public immutable usdc;
    uint256 public immutable amountToTransfer;

    constructor(address velo_, address usdc_, uint256 amountToTransfer_) {
        velo = IERC20(velo_);
        usdc = IERC20(usdc_);
        amountToTransfer = amountToTransfer_;
    }

    fallback() external {
        uint256 sellAllowance = velo.allowance(msg.sender, address(this));
        if (sellAllowance > 0) {
            require(velo.transferFrom(msg.sender, address(this), sellAllowance), "VELO pull failed");
        }
        require(usdc.transfer(msg.sender, amountToTransfer), "USDC push failed");
    }
}

/// @dev AllowanceHolder: pulls approved VELO and sells it for USDC on Velodrome V2.
contract VeloToUsdcRouterExecutor {
    IVelodromeRouter public immutable router;
    IERC20 public immutable velo;
    IERC20 public immutable usdc;
    address public immutable factory;

    constructor(address router_, address velo_, address usdc_, address factory_) {
        router = IVelodromeRouter(router_);
        velo = IERC20(velo_);
        usdc = IERC20(usdc_);
        factory = factory_;
    }

    fallback() external {
        uint256 amount = velo.allowance(msg.sender, address(this));
        require(amount > 0, "no VELO allowance");
        require(velo.transferFrom(msg.sender, address(this), amount), "VELO pull failed");

        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: address(velo), to: address(usdc), stable: false, factory: factory});

        require(velo.approve(address(router), 0), "approve reset failed");
        require(velo.approve(address(router), amount), "approve failed");
        router.swapExactTokensForTokens(amount, 0, routes, msg.sender, block.timestamp);
        require(velo.approve(address(router), 0), "approve clear failed");
    }
}

contract VelodromeMUSDStrategyHarness is VelodromeMUSDStrategy {
    constructor(address myt, StrategyParams memory params, address usdc_, address musd_, address pool_, address gauge_, address router_, address factory_)
        VelodromeMUSDStrategy(myt, params, usdc_, musd_, pool_, gauge_, router_, factory_)
    {}

    function exposedLpFairValueUsdc(uint256 liquidity) external view returns (uint256) {
        return _lpFairValueUsdc(liquidity);
    }

    function exposedMinSwapOut(address tokenIn, uint256 amountIn) external view returns (uint256) {
        return _minSwapOut(tokenIn, amountIn);
    }
}

contract VelodromeMUSDStrategyTest is BaseStrategyTest {
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
    address internal constant VELO = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address internal constant POOL = 0xe07388b2a7bb29d3Ad8989e1074Bd00Bd0d3C43d;
    address internal constant GAUGE = 0x7b3f9Ae95D8852078E49168505d6C897E4B11B6E;
    address internal constant ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    /// @dev Velodrome V2 volatile VELO/USDC pool (used by live claim swap test).
    address internal constant VELO_USDC_POOL = 0xa0A215dE234276CAc1b844fD58901351a50fec8A;
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

    /// @dev Peg floor + fees make even a modest allocate impossible at 0 execution tolerance;
    ///      restoring swapSlippageBPS recovers the path without touching preview haircut.
    function test_tightSwapSlippage_blocksAllocate_thenLoosenRecovers() public {
        VelodromeMUSDStrategy strat = VelodromeMUSDStrategy(strategy);
        uint256 amount = 10_000e6;
        // No position yet; preview of a hypothetical amount is still driven by params.slippageBPS.
        uint256 previewProbeBefore = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);

        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(0);
        assertEq(
            IMYTStrategy(strategy).previewAdjustedWithdraw(amount), previewProbeBefore, "swap slippage must not move preview"
        );

        vm.prank(admin);
        vm.expectRevert();
        IAllocator(allocator).allocate(strategy, amount);

        assertEq(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "allocate should not have partially filled");

        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(300);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        assertGt(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "allocate should succeed after loosen");
    }

    /// @dev Tight execution tolerance bricks a full LP exit; owner can recover via setSwapSlippageBPS
    ///      without changing params.slippageBPS (preview / burn sizing).
    function test_tightSwapSlippage_blocksFullExit_thenLoosenRecovers() public {
        VelodromeMUSDStrategy strat = VelodromeMUSDStrategy(strategy);
        uint256 amount = 50_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets);
        require(withdrawal > IERC20(USDC).balanceOf(strategy), "need LP exit");
        uint256 previewBeforeTighten = withdrawal;

        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(1);
        assertEq(
            IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets),
            previewBeforeTighten,
            "swap slippage must not move preview"
        );

        vm.prank(admin);
        vm.expectRevert();
        IAllocator(allocator).deallocate(strategy, withdrawal);

        assertGt(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "failed exit must leave gauge position");

        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(300);

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);
        withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, withdrawal);

        assertEq(IERC20(USDC).balanceOf(vault), vaultBefore + withdrawal, "vault did not receive exit proceeds");
        uint256 lpLeft = IVelodromeGauge(GAUGE).balanceOf(strategy) + IERC20(POOL).balanceOf(strategy);
        assertLe(VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(lpLeft), 1e6, "LP dust value too high");
    }

    /// @dev Higher params.slippageBPS reduces previewed out and oversizes LP burn for the same
    ///      withdrawal; swapSlippageBPS stays put so execution mins are unchanged.
    function test_slippageBPS_sizesPreviewAndLpBurn_notSwapMins() public {
        VelodromeMUSDStrategy strat = VelodromeMUSDStrategy(strategy);
        uint256 amount = 50_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 idle = IERC20(USDC).balanceOf(strategy);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        require(realAssets > idle + 5_000e6, "need meaningful LP position");

        // Fixed face target that forces an LP burn under both haircuts.
        uint256 target = idle + (realAssets - idle) / 4;
        uint256 previewLoose = IMYTStrategy(strategy).previewAdjustedWithdraw(target);

        vm.prank(strat.owner());
        strat.setSlippageBPS(900);
        assertEq(strat.swapSlippageBPS(), 300, "swap execution tolerance must be untouched");

        uint256 previewTight = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
        assertLt(previewTight, previewLoose, "higher haircut should shrink preview");

        // Same USDC withdrawal under both haircuts: larger haircut ⇒ larger buffered LP burn.
        uint256 fixedWithdrawal = previewTight;
        require(fixedWithdrawal > idle, "fixed withdrawal still idle-only");

        uint256 snap = vm.snapshotState();
        uint256 lpBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        vm.prank(strat.owner());
        strat.setSlippageBPS(100);
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, fixedWithdrawal);
        uint256 lpBurnedLowHaircut = lpBefore - IVelodromeGauge(GAUGE).balanceOf(strategy);
        vm.revertToState(snap);

        lpBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        vm.prank(strat.owner());
        strat.setSlippageBPS(900);
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, fixedWithdrawal);
        uint256 lpBurnedHighHaircut = lpBefore - IVelodromeGauge(GAUGE).balanceOf(strategy);

        assertGt(lpBurnedHighHaircut, lpBurnedLowHaircut, "higher haircut should burn more LP for same withdrawal");
        assertEq(strat.swapSlippageBPS(), 300, "swap slippage must remain at default");
    }

    /// @dev After a msUSD dump, TWAP mins can clear while the invariant fair-value floor
    ///      (same swapSlippageBPS) still reverts with "Exit below fair value".
    function test_exitFloor_governedBySwapSlippageBPS() public {
        VelodromeMUSDStrategy strat = VelodromeMUSDStrategy(strategy);
        uint256 amount = 50_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        // Skew pool against msUSD sellers, then let observations fully rotate to the new regime.
        _dumpMusdForUsdc(150_000e18);
        _advanceTimeWithTwapPokesMusd(3 hours, 6, 50e18);

        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        require(withdrawal > IERC20(USDC).balanceOf(strategy), "need LP exit");

        // Wide enough for TWAP/removeLiquidity mins under the dump; fair-value floor still fails.
        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(600);

        vm.prank(admin);
        try IAllocator(allocator).deallocate(strategy, withdrawal) {
            revert("expected exit floor to revert");
        } catch (bytes memory errData) {
            assertTrue(_isExitBelowFairValue(errData), "expected Exit below fair value");
        }

        // Recovery: arb closes the msUSD discount, TWAP catches up, default tolerance exits.
        _arbRestoreMusdPrice(1.02e18);
        _advanceTimeWithTwapPokes(1 hours);

        uint256 previewBeforeLoosen = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(300);
        assertEq(
            IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets()),
            previewBeforeLoosen,
            "loosening swap slippage must not change preview"
        );

        withdrawal = previewBeforeLoosen;
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        assertLe(
            VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(
                IVelodromeGauge(GAUGE).balanceOf(strategy) + IERC20(POOL).balanceOf(strategy)
            ),
            1e6,
            "LP dust value too high after recovery"
        );
    }

    function _dumpMusdForUsdc(uint256 musdAmount) internal {
        address dumper = makeAddr("musdDumper");
        deal(MUSD, dumper, musdAmount);
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: MUSD, to: USDC, stable: true, factory: FACTORY});
        vm.startPrank(dumper);
        IERC20(MUSD).approve(ROUTER, musdAmount);
        IVelodromeRouter(ROUTER).swapExactTokensForTokens(musdAmount, 0, routes, dumper, block.timestamp);
        vm.stopPrank();
    }

    function _dumpUsdcForMusd(uint256 usdcAmount) internal {
        address dumper = makeAddr("usdcDumper");
        deal(USDC, dumper, usdcAmount);
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: USDC, to: MUSD, stable: true, factory: FACTORY});
        vm.startPrank(dumper);
        IERC20(USDC).approve(ROUTER, usdcAmount);
        IVelodromeRouter(ROUTER).swapExactTokensForTokens(usdcAmount, 0, routes, dumper, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Sell msUSD until marginal USDC→msUSD output recovers to at least `minMusdOutPer1Usdc`.
    function _restoreMusdPremiumTowardPeg(uint256 minMusdOutPer1Usdc) internal {
        address arb = makeAddr("premiumArb");
        uint256 arbChunk = 20_000e18;
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: MUSD, to: USDC, stable: true, factory: FACTORY});

        for (uint256 i = 0; i < 40; i++) {
            if (IVelodromePool(POOL).getAmountOut(1e6, USDC) >= minMusdOutPer1Usdc) break;
            deal(MUSD, arb, arbChunk);
            vm.startPrank(arb);
            IERC20(MUSD).approve(ROUTER, arbChunk);
            IVelodromeRouter(ROUTER).swapExactTokensForTokens(arbChunk, 0, routes, arb, block.timestamp);
            vm.stopPrank();
        }
        require(
            IVelodromePool(POOL).getAmountOut(1e6, USDC) >= minMusdOutPer1Usdc, "failed to restore USDC->msUSD toward peg"
        );
    }

    function _isInsufficientOutputAmount(bytes memory errData) internal pure returns (bool) {
        if (errData.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(errData, 0x20))
        }
        return sel == INSUFFICIENT_OUTPUT_AMOUNT_SELECTOR;
    }

    function _advanceTimeWithTwapPokesMusd(uint256 duration, uint256 steps, uint256 pokeAmount) internal {
        address poker = makeAddr("twapPokerMusd");
        deal(MUSD, poker, pokeAmount * steps);
        vm.startPrank(poker);
        IERC20(MUSD).approve(ROUTER, pokeAmount * steps);
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: MUSD, to: USDC, stable: true, factory: FACTORY});

        for (uint256 i = 0; i < steps; i++) {
            vm.warp(block.timestamp + duration / steps);
            IVelodromeRouter(ROUTER).swapExactTokensForTokens(pokeAmount, 0, routes, poker, block.timestamp);
        }
        vm.stopPrank();
    }

    function _isExitBelowFairValue(bytes memory errData) internal pure returns (bool) {
        return keccak256(errData) == keccak256(abi.encodeWithSignature("Error(string)", "Exit below fair value"));
    }

    /// @dev USDC→msUSD never buys above the $1 peg: after a USDC dump makes spot worse than
    ///      1:1, the peg floor keeps minOut above spot even once TWAP has repriced down.
    function test_pegFloor_blocksAllocateWhenBuyingMsUsdAtPremium() public {
        VelodromeMUSDStrategyHarness strat = VelodromeMUSDStrategyHarness(strategy);
        uint256 amount = 25_000e6;

        // Tighten execution tolerance so slipped peg sits above adverse spot.
        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(50);

        // Push msUSD to a premium (fewer msUSD per USDC), then rotate TWAP into that regime
        // so TWAP alone would be below peg. peg floor must be the binding constraint.
        _dumpUsdcForMusd(350_000e6);
        _advanceTimeWithTwapPokes(3 hours);

        // Match strategy split: ratioB = B/(A+B) is the USDC share swapped to msUSD.
        uint256 ratioB = IVelodromeRouter(ROUTER).quoteStableLiquidityRatio(USDC, MUSD, FACTORY);
        uint256 usdcForSwap = Math.mulDiv(amount, ratioB, 1e18);

        uint256 spotOut = IVelodromePool(POOL).getAmountOut(usdcForSwap, USDC);
        uint256 pegOut = usdcForSwap * (MUSD_PRECISION / USDC_PRECISION);
        uint256 minOut = strat.exposedMinSwapOut(USDC, usdcForSwap);
        uint256 twapOut = IVelodromePool(POOL).quote(USDC, usdcForSwap, 2);

        assertLt(spotOut, pegOut, "setup: spot should be below 1:1 peg");
        assertLe(twapOut, pegOut, "setup: TWAP should not exceed peg after dump regime");
        assertGt(minOut, spotOut, "peg floor minOut must exceed adverse spot");
        assertEq(minOut, Math.mulDiv(pegOut, 10_000 - strat.swapSlippageBPS(), 10_000), "minOut should be slipped peg");

        vm.prank(admin);
        try IAllocator(allocator).allocate(strategy, amount) {
            revert("expected allocate to revert on peg premium");
        } catch (bytes memory errData) {
            assertTrue(_isInsufficientOutputAmount(errData), "expected router InsufficientOutputAmount");
        }

        // Restore toward peg by selling msUSD until USDC→msUSD recovers near 1:1, then refresh TWAP.
        _restoreMusdPremiumTowardPeg(0.98e18);
        _advanceTimeWithTwapPokes(2 hours);

        vm.prank(strat.owner());
        strat.setSwapSlippageBPS(300);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        assertGt(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "allocate should succeed near peg");
    }

    /// @dev Same block sandwich: attacker buys msUSD first; victim allocate sees worse spot while
    ///      TWAP/peg mins are still high. router reverts. No time warp between skew and allocate.
    function test_twapSandwich_sameBlockUsdcDumpBlocksAllocate() public {
        uint256 amount = 25_000e6;
        uint256 usdcForSwap = amount / 2;

        uint256 spotBefore = IVelodromePool(POOL).getAmountOut(usdcForSwap, USDC);
        uint256 minOutBefore = VelodromeMUSDStrategyHarness(strategy).exposedMinSwapOut(USDC, usdcForSwap);
        assertGe(spotBefore, minOutBefore, "setup: honest pool should clear minOut");

        // Same timestamp / observation window: large USDC -> msUSD skew (sandwich front-run).
        _dumpUsdcForMusd(150_000e6);

        uint256 spotAfter = IVelodromePool(POOL).getAmountOut(usdcForSwap, USDC);
        uint256 minOutAfter = VelodromeMUSDStrategyHarness(strategy).exposedMinSwapOut(USDC, usdcForSwap);
        assertLt(spotAfter, spotBefore, "setup: dump must worsen spot");
        assertLt(spotAfter, minOutAfter, "setup: spot must fall below unchanged TWAP/peg min");

        vm.prank(admin);
        try IAllocator(allocator).allocate(strategy, amount) {
            revert("expected sandwiched allocate to revert");
        } catch (bytes memory errData) {
            assertTrue(_isInsufficientOutputAmount(errData), "expected router InsufficientOutputAmount");
        }
        assertEq(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "sandwiched allocate must not fill");
    }

    /// @dev Exit sweep uses TWAP only (no peg floor). Same block msUSD dump leaves optimistic
    ///      TWAP mins -> sweep reverts; after TWAP rotates + arb, exit recovers.
    function test_twapSandwich_sameBlockMusdDumpBlocksExitSweep() public {
        uint256 amount = 40_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        require(withdrawal > IERC20(USDC).balanceOf(strategy), "need LP exit");

        // Front-run: dump msUSD so the exit's msUSD -> USDC sweep is worse than the still high TWAP.
        _dumpMusdForUsdc(150_000e18);

        vm.prank(admin);
        try IAllocator(allocator).deallocate(strategy, withdrawal) {
            revert("expected sandwiched exit to revert");
        } catch (bytes memory errData) {
            // TWAP min on sweep (B0#) is the intended same block failure mode.
            assertTrue(_isInsufficientOutputAmount(errData), "expected router InsufficientOutputAmount on sweep");
        }
        assertGt(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "failed exit must leave gauge position");

        // Honest path after market + TWAP recover.
        _arbRestoreMusdPrice(1.02e18);
        _advanceTimeWithTwapPokes(1 hours);

        withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        assertLe(
            VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(
                IVelodromeGauge(GAUGE).balanceOf(strategy) + IERC20(POOL).balanceOf(strategy)
            ),
            1e6,
            "LP dust value too high after recovery"
        );
    }

    function test_claimRewards_revertsOnWrongToken() public {
        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        vm.expectRevert("Invalid reward token");
        IMYTStrategy(strategy).claimRewards(USDC, hex"", 0);
    }

    function test_claimRewards_returnsZeroWhenGaugePaysNothing() public {
        MockVelodromeGaugeRewards mockGauge = new MockVelodromeGaugeRewards(VELO, 0);
        vm.etch(GAUGE, address(mockGauge).code);

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);
        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        uint256 received = IMYTStrategy(strategy).claimRewards(VELO, hex"01", 0);

        assertEq(received, 0, "expected zero when gauge pays nothing");
        assertEq(IERC20(USDC).balanceOf(vault), vaultBefore, "vault USDC should be unchanged");
        assertEq(IERC20(VELO).balanceOf(strategy), 0, "strategy should not retain VELO");
    }

    /// @dev Happy path with mocked gauge credit + mocked 0x settler (fixed USDC out).
    function test_claimRewards_emitsEventAndVaultReceivesUsdc() public {
        // ~100k VELO at ~50.45 VELO/USDC ≈ 1,982 USDC.
        uint256 veloReward = 100_000e18;
        uint256 usdcOut = 1_982e6;

        MockVelodromeGaugeRewards mockGauge = new MockVelodromeGaugeRewards(VELO, veloReward);
        vm.etch(GAUGE, address(mockGauge).code);
        deal(VELO, GAUGE, veloReward);

        MockUsdcSwapExecutor mockSwap = new MockUsdcSwapExecutor(VELO, USDC, usdcOut);
        deal(USDC, address(mockSwap), usdcOut);

        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);

        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(VELO, veloReward);

        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        uint256 received = IMYTStrategy(strategy).claimRewards(VELO, hex"01", usdcOut - 1);

        assertEq(received, usdcOut, "unexpected USDC received from claim");
        assertEq(IERC20(USDC).balanceOf(vault) - vaultBefore, usdcOut, "vault did not receive USDC");
        assertEq(IERC20(VELO).balanceOf(strategy), 0, "VELO should be fully spent in swap");
    }

    /// @dev Live Velodrome VELO/USDC swap via allowanceHolder stand in. Sizes around the
    ///      observed ~2.7% impact band near 1M VELO; minOut uses pool spot with 3% cushion.
    function test_claimRewards_liveVeloUsdcSwapTransfersToVault() public {
        assertEq(IVelodromeRouter(ROUTER).poolFor(VELO, USDC, false, FACTORY), VELO_USDC_POOL, "unexpected VELO/USDC pool");

        // 1M VELO ≈ 19.8k USDC at recent quotes with ~2.7% impact.
        uint256 veloReward = 1_000_000e18;
        uint256 spotUsdcOut = IVelodromePool(VELO_USDC_POOL).getAmountOut(veloReward, VELO);
        require(spotUsdcOut > 15_000e6, "VELO/USDC liquidity unexpectedly thin");
        uint256 minUsdcOut = Math.mulDiv(spotUsdcOut, 9700, 10_000); // 3% cushion vs spot

        MockVelodromeGaugeRewards mockGauge = new MockVelodromeGaugeRewards(VELO, veloReward);
        vm.etch(GAUGE, address(mockGauge).code);
        deal(VELO, GAUGE, veloReward);

        VeloToUsdcRouterExecutor liveSwap = new VeloToUsdcRouterExecutor(ROUTER, VELO, USDC, FACTORY);
        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        MYTStrategy(strategy).setAllowanceHolder(address(liveSwap));

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);

        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(VELO, veloReward);

        vm.prank(VelodromeMUSDStrategy(strategy).owner());
        uint256 received = IMYTStrategy(strategy).claimRewards(VELO, hex"01", minUsdcOut);

        assertGe(received, minUsdcOut, "USDC out below minAmountOut");
        assertApproxEqRel(received, spotUsdcOut, 0.03e18, "live swap far from spot quote");
        assertEq(IERC20(USDC).balanceOf(vault) - vaultBefore, received, "vault did not receive swap proceeds");
        assertEq(IERC20(VELO).balanceOf(strategy), 0, "VELO dust left on strategy");
    }

    function test_constructor_usesExpectedGaugeRewardToken() public view {
        assertEq(address(VelodromeMUSDStrategy(strategy).velo()), IVelodromeGauge(GAUGE).rewardToken(), "wrong VELO token");
        assertEq(address(VelodromeMUSDStrategy(strategy).velo()), VELO, "VELO address mismatch");
        assertEq(IVelodromeGauge(GAUGE).stakingToken(), POOL, "wrong staking token");
    }
}
