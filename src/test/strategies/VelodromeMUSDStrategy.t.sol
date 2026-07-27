// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {VelodromeMUSDStrategy} from "../../strategies/VelodromeMUSDStrategy.sol";
import {IVelodromeGauge, IVelodromePool} from "../../strategies/interfaces/IVelodrome.sol";

contract VelodromeMUSDStrategyHarness is VelodromeMUSDStrategy {
    constructor(address myt, StrategyParams memory params, address usdc_, address musd_, address pool_, address gauge_, address router_, address factory_)
        VelodromeMUSDStrategy(myt, params, usdc_, musd_, pool_, gauge_, router_, factory_)
    {}

    function exposedLpFairValueUsdc(uint256 liquidity) external view returns (uint256) {
        return _lpFairValueUsdc(liquidity);
    }
}

contract VelodromeMUSDStrategyTest is BaseStrategyTest {
    uint256 internal constant INITIAL_VAULT_DEPOSIT = 10_000_000e6;
    uint256 internal constant ABSOLUTE_CAP = 10_000_000e6;
    uint256 internal constant LIVE_POOL_TEST_CAP = 10_000e6;
    uint256 internal constant RELATIVE_CAP = 1e18;
    bytes4 internal constant ABSOLUTE_CAP_EXCEEDED_SELECTOR = 0x4616e4af;
    bytes4 internal constant INSUFFICIENT_LIQUIDITY_BURNED_SELECTOR = 0x749383ad;
    bytes4 internal constant INSUFFICIENT_BALANCE_SELECTOR = 0xcf479181;

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
        return
            TestConfig({vaultAsset: USDC, vaultInitialDeposit: INITIAL_VAULT_DEPOSIT, absoluteCap: ABSOLUTE_CAP, relativeCap: RELATIVE_CAP, decimals: 6});
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
        if (selector != INSUFFICIENT_LIQUIDITY_BURNED_SELECTOR) return false;

        return context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzDeallocate;
    }

    function test_allocate_zapsAndStakesLp() public {
        uint256 amount = 18_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 stakedLp = IVelodromeGauge(GAUGE).balanceOf(strategy);
        assertGt(stakedLp, 0, "no gauge position");
        assertEq(IERC20(POOL).balanceOf(strategy), 0, "LP should be staked");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), amount, 0.01e18, "unexpected fair LP value");
        assertEq(IERC20(USDC).allowance(strategy, ROUTER), 0, "USDC router allowance not cleared");
    }

    function test_deallocate_unstakesAndZapsToUsdc() public {
        uint256 amount = 10_000e6;
        uint256 withdrawal = 2000e6;

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        uint256 stakedBefore = IVelodromeGauge(GAUGE).balanceOf(strategy);
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + withdrawal, "vault did not receive USDC");
        assertLt(IVelodromeGauge(GAUGE).balanceOf(strategy), stakedBefore, "LP was not unstaked");
        assertEq(IERC20(POOL).allowance(strategy, ROUTER), 0, "LP router allowance not cleared");
    }

    function test_deallocate_fullPositionClearsLpAndCostBasis() public {
        uint256 amount = 10_000e6;

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);
        uint256 withdrawal = IMYTStrategy(strategy).previewAdjustedWithdraw(IMYTStrategy(strategy).realAssets());
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);
        IAllocator(allocator).deallocate(strategy, withdrawal);
        vm.stopPrank();

        assertEq(IVelodromeGauge(GAUGE).balanceOf(strategy), 0, "gauge position remains");
        assertEq(IERC20(POOL).balanceOf(strategy), 0, "unstaked LP remains");
        assertEq(VelodromeMUSDStrategy(strategy).lpCostBasisUsdc(), 0, "LP cost basis remains");
        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + withdrawal, "vault did not receive USDC");
        assertEq(IMYTStrategy(strategy).realAssets(), IERC20(USDC).balanceOf(strategy), "non-idle value remains");
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

    function test_fairValue_isNoGreaterThanPegReserveSum() public view {
        (uint256 reserve0, uint256 reserve1,) = IVelodromePool(POOL).getReserves();
        uint256 supply = IVelodromePool(POOL).totalSupply();
        uint256 fairValue = VelodromeMUSDStrategyHarness(strategy).exposedLpFairValueUsdc(supply);
        uint256 pegReserveSum = reserve0 + reserve1 / 1e12;

        assertLe(fairValue, pegReserveSum, "fair value exceeds peg reserve sum");
        assertGt(fairValue, 0, "zero fair value");
    }

    function test_constructor_usesExpectedGaugeRewardToken() public view {
        assertEq(address(VelodromeMUSDStrategy(strategy).velo()), IVelodromeGauge(GAUGE).rewardToken(), "wrong VELO token");
        assertEq(IVelodromeGauge(GAUGE).stakingToken(), POOL, "wrong staking token");
    }
}
