// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {YieldBouncer} from "../../utils/YieldBouncer.sol";
import {YieldBouncerUSD} from "../../utils/YieldBouncerUSD.sol";
import {YieldBouncerETH} from "../../utils/YieldBouncerETH.sol";
import {IRateSource} from "../../utils/rates/IRateSource.sol";
import {AaveV3RateSource} from "../../utils/rates/AaveV3RateSource.sol";
import {EulerEVaultRateSource} from "../../utils/rates/EulerEVaultRateSource.sol";
import {FluidFTokenRateSource} from "../../utils/rates/FluidFTokenRateSource.sol";
import {MorphoVaultV2RateSource} from "../../utils/rates/MorphoVaultV2RateSource.sol";
import {YearnV3RateSource} from "../../utils/rates/YearnV3RateSource.sol";
import {TokemakAutopoolRateSource} from "../../utils/rates/TokemakAutopoolRateSource.sol";
import {FluidLiteRateSource} from "../../utils/rates/FluidLiteRateSource.sol";

interface IAllocatorLive {
    function vault() external view returns (address);
    function setOperator(address operator, bool value) external;
}

interface IVaultLive {
    function asset() external view returns (address);
}

interface IVaultLiquidity {
    function liquidityAdapter() external view returns (address);
}

interface IStrategyLive {
    function realAssets() external view returns (uint256);
}

interface IFluidResolverLive {
    function getOverallTokenData(address token) external view returns (uint256[16] memory);
}

interface IAavePoolLive {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IYearnV3Live {
    function fullProfitUnlockDate() external view returns (uint256);
}

interface IAutopoolLive {
    function getProfitUnlockSettings() external view returns (uint48, uint48, uint48, uint256);
}

interface IFluidLiteLive {
    function getEffectiveExchangePrice() external view returns (uint256);
    function getFixedRate() external view returns (uint256);
    function getRewardAmountPerYear() external view returns (uint256);
}

library Addr {
    // Base
    address internal constant BASE_ALLOCATOR = 0x347371c17D14Ee7943943995E2A0A9Df4FD83d50;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant STEAKHOUSE_STRATEGY = 0xaeEA02683f652dd1fb4846bE71FB8Cf26f3393d4;
    address internal constant FLUID_STRATEGY = 0x4e7Fb7BAD62D105eE2c4856d45f8FbfaDEEFa896;
    address internal constant STEAKHOUSE_VAULT = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address internal constant GAUNTLET_VAULT = 0x1deEfABEe758AAbdC29a542B24ca3b75aFD56765;
    address internal constant YEARN_OG_VAULT = 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42;
    address internal constant FUSDC = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
    address internal constant FLUID_RESOLVER = 0xca13A15de31235A37134B4717021C35A3CF25C60;
    // Ethereum
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AAVE_STRATEGY = 0xb2d750bfA0B8c8C72945F5533442B467230CB4D7;
    address internal constant YEARN_STRATEGY = 0x8AACC947c2f4E24D2Be4CBa4498f004079F35D87;
    address internal constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant YV_WETH_1 = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;
    address internal constant YV_USDC_1 = 0x696d02Db93291651ED510704c9b286841d506987;
    address internal constant EWETH_2 = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address internal constant TOKE_AUTOUSD = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant FLITE_USD = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;
    // Ethereum alUSD (Mix USDC)
    address internal constant USD_ALLOCATOR = 0x693b7594Ae0633d9c5574D0da46a040f92F5b281;
    address internal constant YVUSD_STRATEGY = 0xdFDC17F784e16D7634AC270911D98755C68Ae220;
    address internal constant FLUID_LITE_STRATEGY = 0x320e38ca23FB11cC1f673b204E301210d3758653;
}

abstract contract ForkHelpers is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BP = 1e14;

    function _baseRpc() internal view returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co"));
    }

    function _ethRpc() internal view returns (string memory) {
        return vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
    }

    /// @dev Simple APR realized by a 4626 share over `dt` seconds of warp.
    function _realized(uint256 p0, uint256 p1, uint256 dt) internal pure returns (uint256) {
        return (p1 - p0) * 1e18 * YEAR / (p0 * dt);
    }

    function _pct(string memory label, uint256 wad) internal {
        emit log_named_decimal_uint(label, wad * 100, 18);
    }
}

// ---- rate sources against live venues ------------------------------------------------

/// @notice Each source's rate predicts the venue's own share-price growth over one day
///         of warp, and moves in the same block as a deposit.
contract BaseRateSourcesForkTest is ForkHelpers {
    MorphoVaultV2RateSource internal morpho;
    FluidFTokenRateSource internal fluid;
    address internal user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(_baseRpc());
        morpho = new MorphoVaultV2RateSource();
        fluid = new FluidFTokenRateSource();
    }

    function test_morpho_predictsShareGrowth() public {
        address[3] memory vaults = [Addr.STEAKHOUSE_VAULT, Addr.GAUNTLET_VAULT, Addr.YEARN_OG_VAULT];
        uint256[3] memory apr;
        uint256[3] memory p0;
        for (uint256 i = 0; i < 3; i++) {
            apr[i] = morpho.supplyRate(vaults[i]);
            p0[i] = IERC4626(vaults[i]).convertToAssets(1e30);
        }
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days);
        for (uint256 i = 0; i < 3; i++) {
            uint256 realized = _realized(p0[i], IERC4626(vaults[i]).convertToAssets(1e30), 1 days);
            _pct("source APR %", apr[i]);
            _pct("realized APR %", realized);
            assertGt(apr[i], 50 * BP, "below 0.5%");
            assertLt(apr[i], 3_000 * BP, "above 30%");
            assertApproxEqRel(realized, apr[i], 0.05e18, "source vs share growth");
        }
    }

    function test_fluid_matchesResolverAndShareGrowth() public {
        uint256 apr = fluid.supplyRate(Addr.FUSDC);
        uint256 stored = IFluidResolverLive(Addr.FLUID_RESOLVER).getOverallTokenData(Addr.BASE_USDC)[1] * 1e14;
        _pct("source APR %", apr);
        _pct("resolver (stored) APR %", stored);
        assertApproxEqAbs(apr, stored, 2 * BP, "source vs Fluid resolver");

        uint256 p0 = IERC4626(Addr.FUSDC).convertToAssets(1e18);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days);
        uint256 realized = _realized(p0, IERC4626(Addr.FUSDC).convertToAssets(1e18), 1 days);
        _pct("realized APR %", realized);
        assertApproxEqRel(realized, apr, 0.03e18, "source vs share growth");
    }

    /// A deposit below Fluid's storage threshold leaves the stored rate where it was;
    /// the source still sees it. A large one forces a write and the two agree again.
    function test_fluid_smallDepositMovesTheSourceNotTheStoredRate() public {
        uint256 before = fluid.supplyRate(Addr.FUSDC);
        uint256 storedBefore = IFluidResolverLive(Addr.FLUID_RESOLVER).getOverallTokenData(Addr.BASE_USDC)[1];
        _deposit(Addr.FUSDC, 5_000e6);
        uint256 afterSmall = fluid.supplyRate(Addr.FUSDC);
        uint256 storedAfter = IFluidResolverLive(Addr.FLUID_RESOLVER).getOverallTokenData(Addr.BASE_USDC)[1];
        _pct("source before %", before);
        _pct("source after 5,000 %", afterSmall);
        emit log_named_uint("stored before (1e2 %)", storedBefore);
        emit log_named_uint("stored after (1e2 %)", storedAfter);
        assertLt(afterSmall, before, "source did not move");

        _deposit(Addr.FUSDC, 500_000e6);
        uint256 afterLarge = fluid.supplyRate(Addr.FUSDC);
        uint256 storedLarge = IFluidResolverLive(Addr.FLUID_RESOLVER).getOverallTokenData(Addr.BASE_USDC)[1] * 1e14;
        _pct("source after +500,000 %", afterLarge);
        _pct("stored after +500,000 %", storedLarge);
        assertLt(afterLarge, afterSmall);
        assertApproxEqAbs(afterLarge, storedLarge, 2 * BP, "source vs freshly written rate");
    }

    function test_morpho_depositMovesTheRate() public {
        uint256 before = morpho.supplyRate(Addr.STEAKHOUSE_VAULT);
        _deposit(Addr.STEAKHOUSE_VAULT, 2_000_000e6);
        uint256 afterDeposit = morpho.supplyRate(Addr.STEAKHOUSE_VAULT);
        _pct("Steakhouse before %", before);
        _pct("Steakhouse after +2,000,000 %", afterDeposit);
        assertLt(afterDeposit, before);
    }

    function _deposit(address vault4626, uint256 assets) internal {
        deal(Addr.BASE_USDC, user, assets);
        vm.startPrank(user);
        IERC20(Addr.BASE_USDC).approve(vault4626, assets);
        IERC4626(vault4626).deposit(assets, user);
        vm.stopPrank();
    }
}

contract EthRateSourcesForkTest is ForkHelpers {
    YearnV3RateSource internal yearn;
    AaveV3RateSource internal aave;
    EulerEVaultRateSource internal euler;
    address internal user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(_ethRpc());
        yearn = new YearnV3RateSource();
        aave = new AaveV3RateSource();
        euler = new EulerEVaultRateSource();
    }

    function test_yearn_predictsShareGrowth_thenCliff() public {
        address[2] memory vaults = [Addr.YV_WETH_1, Addr.YV_USDC_1];
        uint256[2] memory apr;
        uint256[2] memory p0;
        for (uint256 i = 0; i < 2; i++) {
            apr[i] = yearn.supplyRate(vaults[i]);
            p0[i] = IERC4626(vaults[i]).convertToAssets(1e18);
        }
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days);
        for (uint256 i = 0; i < 2; i++) {
            if (IYearnV3Live(vaults[i]).fullProfitUnlockDate() <= t0 + 1 days) continue;   // unlock ends inside the day
            uint256 realized = _realized(p0[i], IERC4626(vaults[i]).convertToAssets(1e18), 1 days);
            _pct("source APR %", apr[i]);
            _pct("realized APR %", realized);
            assertApproxEqRel(realized, apr[i], 0.01e18, "source vs share growth");
        }
        vm.warp(IYearnV3Live(Addr.YV_WETH_1).fullProfitUnlockDate());
        assertEq(yearn.supplyRate(Addr.YV_WETH_1), 0, "no unlock left, no rate");
    }

    function test_yearn_depositDilutes() public {
        uint256 before = yearn.supplyRate(Addr.YV_WETH_1);
        uint256 supply0 = IERC20(Addr.YV_WETH_1).totalSupply();
        if (IERC4626(Addr.YV_WETH_1).maxDeposit(user) < 100 ether) vm.skip(true, "WETH-1 deposit limit");
        deal(Addr.WETH, user, 100 ether);
        vm.startPrank(user);
        IERC20(Addr.WETH).approve(Addr.YV_WETH_1, 100 ether);
        IERC4626(Addr.YV_WETH_1).deposit(100 ether, user);
        vm.stopPrank();
        uint256 supply1 = IERC20(Addr.YV_WETH_1).totalSupply();
        uint256 afterDeposit = yearn.supplyRate(Addr.YV_WETH_1);
        _pct("WETH-1 before %", before);
        _pct("WETH-1 after +100 %", afterDeposit);
        assertApproxEqRel(afterDeposit, before * supply0 / supply1, 1e9);
    }

    function test_aave_matchesIndexGrowth_andMovesOnSupply() public {
        uint256 apr = aave.supplyRate(Addr.AWETH);
        uint256 i0 = IAavePoolLive(Addr.AAVE_POOL).getReserveNormalizedIncome(Addr.WETH);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days);
        uint256 realized = _realized(i0, IAavePoolLive(Addr.AAVE_POOL).getReserveNormalizedIncome(Addr.WETH), 1 days);
        _pct("Aave WETH source %", apr);
        _pct("Aave WETH index growth %", realized);
        assertApproxEqRel(realized, apr, 0.001e18);

        uint256 before = aave.supplyRate(Addr.AWETH);
        deal(Addr.WETH, user, 20_000 ether);
        vm.startPrank(user);
        IERC20(Addr.WETH).approve(Addr.AAVE_POOL, 20_000 ether);
        IAavePoolLive(Addr.AAVE_POOL).supply(Addr.WETH, 20_000 ether, user, 0);
        vm.stopPrank();
        assertLt(aave.supplyRate(Addr.AWETH), before);
    }

    /// autoUSD unlocks a day of profit at a time: warp two hours inside the window.
    function test_tokemak_predictsShareGrowth_thenCliff() public {
        TokemakAutopoolRateSource toke = new TokemakAutopoolRateSource();
        (, uint48 fullUnlock,,) = IAutopoolLive(Addr.TOKE_AUTOUSD).getProfitUnlockSettings();
        uint256 t0 = block.timestamp;
        if (fullUnlock < t0 + 3 hours) vm.skip(true, "autoUSD unlock ends within 3 h of the fork block");
        uint256 apr = toke.supplyRate(Addr.TOKE_AUTOUSD);
        uint256 p0 = IERC4626(Addr.TOKE_AUTOUSD).convertToAssets(1e30);
        vm.warp(t0 + 2 hours);
        uint256 realized = _realized(p0, IERC4626(Addr.TOKE_AUTOUSD).convertToAssets(1e30), 2 hours);
        _pct("autoUSD source %", apr);
        _pct("autoUSD realized %", realized);
        assertApproxEqRel(realized, apr, 0.01e18);
        vm.warp(fullUnlock);
        assertEq(toke.supplyRate(Addr.TOKE_AUTOUSD), 0);
    }

    /// fLiteUSD accrues at max(fixed, reward / TVL) between checkpoints: a day of warp
    /// grows the share price at the source's rate, and a deposit dilutes the reward.
    function test_fluidLite_predictsShareGrowth_andMovesOnDeposit() public {
        FluidLiteRateSource lite = new FluidLiteRateSource();
        IFluidLiteLive v = IFluidLiteLive(Addr.FLITE_USD);
        uint256 apr = lite.supplyRate(Addr.FLITE_USD);
        uint256 p0 = v.getEffectiveExchangePrice();
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + 1 days);
        uint256 realized = _realized(p0, v.getEffectiveExchangePrice(), 1 days);
        _pct("Fluid Lite source %", apr);
        _pct("Fluid Lite realized %", realized);
        assertApproxEqRel(realized, apr, 1e13);
        vm.revertToState(snap);

        deal(Addr.USDC, user, 5_000_000e6);
        vm.startPrank(user);
        IERC20(Addr.USDC).approve(Addr.FLITE_USD, 5_000_000e6);
        IERC4626(Addr.FLITE_USD).deposit(5_000_000e6, user);
        vm.stopPrank();
        uint256 afterDeposit = lite.supplyRate(Addr.FLITE_USD);
        _pct("Fluid Lite after +5,000,000 %", afterDeposit);
        // the deposit checkpoints the price, so the rate is max(fixed, reward / totalAssets) exactly
        uint256 byTvl = v.getRewardAmountPerYear() * 1e18 / IERC4626(Addr.FLITE_USD).totalAssets();
        uint256 fixedApr = v.getFixedRate() * 1e14;
        uint256 expected = (byTvl > fixedApr ? byTvl : fixedApr) * 36_500 / 36_525;
        assertApproxEqRel(afterDeposit, expected, 1e12);
        if (byTvl > fixedApr) assertLt(afterDeposit, apr);
    }

    function test_euler_predictsShareGrowth_andMovesOnDeposit() public {
        uint256 apr = euler.supplyRate(Addr.EWETH_2);
        uint256 p0 = IERC4626(Addr.EWETH_2).convertToAssets(1e18);
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + 1 days);
        uint256 realized = _realized(p0, IERC4626(Addr.EWETH_2).convertToAssets(1e18), 1 days);
        _pct("Euler eWETH-2 source %", apr);
        _pct("Euler eWETH-2 realized %", realized);
        assertApproxEqRel(realized, apr, 0.03e18);
        vm.revertToState(snap);

        deal(Addr.WETH, user, 100 ether);
        vm.startPrank(user);
        IERC20(Addr.WETH).approve(Addr.EWETH_2, 100 ether);
        IERC4626(Addr.EWETH_2).deposit(100 ether, user);
        vm.stopPrank();
        uint256 afterDeposit = euler.supplyRate(Addr.EWETH_2);
        _pct("Euler eWETH-2 after +100 %", afterDeposit);
        assertLt(afterDeposit, apr);
    }
}

// ---- the bouncer on the live allocators -----------------------------------------------

/// @notice Deploys a YieldBouncer against a live allocator, makes it an operator as
///         the allocator admin, and moves between two live strategies. Direction
///         follows whichever strategy pays more at the fork block.
abstract contract YieldBouncerLiveTest is ForkHelpers {
    YieldBouncer internal bouncer;
    address internal bot = makeAddr("bot");
    address internal lo;          // lower rate at the fork block
    address internal hi;          // higher rate at the fork block
    address internal vault;
    address internal asset;

    function _rpc() internal view virtual returns (string memory);
    function _allocator() internal pure virtual returns (address);
    function _pair() internal pure virtual returns (address s0, address s1);
    function _feeds() internal virtual returns (IRateSource src0, address venue0, IRateSource src1, address venue1);
    function _small() internal pure virtual returns (uint256);
    function _searchCeiling() internal pure virtual returns (uint256);

    /// @dev Real-time lending venues land within a few wei; a venue with an exit fee needs more.
    function _maxLossBps() internal pure virtual returns (uint16) {
        return 2;
    }

    function _deploy(address allocator) internal virtual returns (YieldBouncer) {
        return new YieldBouncerUSD(allocator);
    }

    function setUp() public {
        vm.createSelectFork(_rpc());
        bouncer = _deploy(_allocator());
        // Steakhouse (Base) and yvUSD (alUSD) are their vaults' liquidity adapters:
        // allow draws at the ceiling, stamped a day back so the budget is full at the
        // fork block (warping forward would leave strategy oracles stale)
        uint256 t0 = block.timestamp;
        vm.warp(t0 - bouncer.LIQ_ADAPTER_WINDOW());
        bouncer.setSourceGuard(true, bouncer.MAX_MOVE_BPS_CAP());
        bouncer.setLiquidityPerDay(uint128(bouncer.LIQ_ADAPTER_MAX()));
        vm.warp(t0);
        vault = IAllocatorLive(_allocator()).vault();
        asset = IVaultLive(vault).asset();
        address admin = address(uint160(uint256(vm.load(_allocator(), bytes32(0)))));
        vm.prank(admin);
        IAllocatorLive(_allocator()).setOperator(address(bouncer), true);

        (address s0, address s1) = _pair();
        (IRateSource src0, address v0, IRateSource src1, address v1) = _feeds();
        bouncer.setRateSource(s0, address(src0), v0);
        bouncer.setRateSource(s1, address(src1), v1);
        // reference = the live rate at the fork block, ±500 bp: wide enough for the
        // outside deposits some scenarios use to push a rate under the other
        bouncer.setRateRef(s0, bouncer.rateOf(s0), 500);
        bouncer.setRateRef(s1, bouncer.rateOf(s1), 500);
        (lo, hi) = bouncer.rateOf(s0) < bouncer.rateOf(s1) ? (s0, s1) : (s1, s0);
        bouncer.grantPair(bot, lo, hi, YieldBouncer.Limits({
            maxNetToB: _searchCeiling() * 10,
            maxNetToA: _searchCeiling() * 10,
            maxClip: _searchCeiling() * 10,
            minIntervalBlocks: 1,
            maxLossBps: _maxLossBps(),
            minSpreadBps: 1,
            expiresAtBlock: 0
        }));
        _pct("lower-rate strategy %", bouncer.rateOf(lo));
        _pct("higher-rate strategy %", bouncer.rateOf(hi));
        emit log_named_address("lower", lo);
        emit log_named_address("higher", hi);
    }

    function _real(address s) internal view returns (uint256) {
        return IStrategyLive(s).realAssets();
    }

    function test_live_smallMove_idleNeutral_exactLegs() public {
        uint256 rLo = bouncer.rateOf(lo);
        uint256 rHi = bouncer.rateOf(hi);
        if (rHi < rLo + BP) vm.skip(true, "rates within 1 bp at this block");
        if (_real(lo) < 2 * _small()) vm.skip(true, "no position in the lower-rate strategy");
        uint256 idle0 = IERC20(asset).balanceOf(vault);
        uint256 lo0 = _real(lo);
        uint256 hi0 = _real(hi);

        vm.prank(bot);
        uint256 g = gasleft();
        (uint256 rFrom, uint256 rTo, int256 net) = bouncer.bounce(lo, hi, _small());
        emit log_named_uint("bounce gas", g - gasleft());

        _pct("from: before %", rLo);
        _pct("from: after %", rFrom);
        _pct("to:   before %", rHi);
        _pct("to:   after %", rTo);
        assertEq(net, int256(_small()));
        assertEq(IERC20(asset).balanceOf(vault), idle0, "vault idle moved");
        assertApproxEqRel(lo0 - _real(lo), _small(), uint256(_maxLossBps()) * BP, "from leg");
        assertApproxEqRel(_real(hi) - hi0, _small(), uint256(_maxLossBps()) * BP, "to leg");
        assertLe(rTo, rHi, "destination rate rose");
        assertGe(rTo, rFrom);
        assertEq(rTo, bouncer.rateOf(hi));
        assertEq(bouncer.room(bot, lo, hi), _searchCeiling() * 10 - _small());
    }

    function test_live_wrongDirectionReverts() public {
        if (bouncer.rateOf(hi) < bouncer.rateOf(lo) + BP) vm.skip(true, "rates within 1 bp at this block");
        if (_real(hi) < 2 * _small()) vm.skip(true, "no position in the higher-rate strategy");
        vm.prank(bot);
        vm.expectPartialRevert(YieldBouncer.SpreadTooThin.selector);
        bouncer.bounce(hi, lo, _small());
    }

    /// Bisects the largest move from the lower- to the higher-rate strategy that
    /// passes, and reports what stops the next unit: the rate check or a cap.
    function test_live_findsTheCrossing() public {
        uint256 ceiling = _searchCeiling();
        if (_real(lo) < ceiling) ceiling = _real(lo) * 9 / 10;
        if (bouncer.rateOf(hi) < bouncer.rateOf(lo) + BP) vm.skip(true, "rates within 1 bp at this block");
        (bool okCeiling,) = _try(ceiling);
        if (okCeiling) {
            emit log_named_decimal_uint("passes even at the search ceiling", ceiling, 0);
            return;
        }
        uint256 low = 0;
        uint256 high = ceiling;
        while (high - low > _small()) {
            uint256 mid = (low + high) / 2;
            (bool ok,) = _try(mid);
            if (ok) low = mid;
            else high = mid;
        }
        (, bytes4 why) = _try(high);
        emit log_named_uint("largest passing move (raw units)", low);
        emit log_named_uint("first refused move (raw units)", high);
        emit log_named_bytes32("refused with selector", bytes32(why));
        assertGt(low, 0, "nothing passes");
        (bool okLow,) = _try(low);
        assertTrue(okLow);
    }

    /// A move the allocate leg or the rate check refuses leaves idle and both
    /// positions where they were.
    function test_live_refusedMoveLeavesNothingBehind() public {
        uint256 big = _real(lo) * 9 / 10;
        if (big > _searchCeiling() * 10) big = _searchCeiling() * 10;
        (bool ok,) = _try(big);
        if (ok) vm.skip(true, "the whole position moves at this block");
        uint256 idle0 = IERC20(asset).balanceOf(vault);
        uint256 lo0 = _real(lo);
        uint256 hi0 = _real(hi);
        vm.prank(bot);
        vm.expectRevert();
        bouncer.bounce(lo, hi, big);
        assertEq(IERC20(asset).balanceOf(vault), idle0);
        assertEq(_real(lo), lo0);
        assertEq(_real(hi), hi0);
        assertEq(bouncer.pairOf(bot, lo, hi).net, 0);
    }

    function test_live_pausedBotStops() public {
        vm.prank(bot);
        bouncer.setPaused(true);
        vm.prank(bot);
        vm.expectRevert(YieldBouncer.MoverPaused.selector);
        bouncer.bounce(lo, hi, _small());
    }

    function _try(uint256 assets) internal returns (bool ok, bytes4 why) {
        return _tryMove(bot, lo, hi, assets);
    }

    /// @dev Runs one move and rolls it back.
    function _tryMove(address who, address from, address to, uint256 assets) internal returns (bool ok, bytes4 why) {
        uint256 snap = vm.snapshotState();
        vm.prank(who);
        try bouncer.bounce(from, to, assets) {
            ok = true;
        } catch (bytes memory err) {
            if (err.length >= 4) why = bytes4(err);
        }
        vm.revertToState(snap);
    }
}

contract YieldBouncerBaseLiveTest is YieldBouncerLiveTest {
    function _rpc() internal view override returns (string memory) {
        return _baseRpc();
    }

    function _allocator() internal pure override returns (address) {
        return Addr.BASE_ALLOCATOR;
    }

    function _pair() internal pure override returns (address, address) {
        return (Addr.STEAKHOUSE_STRATEGY, Addr.FLUID_STRATEGY);
    }

    function _feeds() internal override returns (IRateSource, address, IRateSource, address) {
        return (new MorphoVaultV2RateSource(), Addr.STEAKHOUSE_VAULT, new FluidFTokenRateSource(), Addr.FUSDC);
    }

    function _small() internal pure override returns (uint256) {
        return 1_000e6;
    }

    function _searchCeiling() internal pure override returns (uint256) {
        return 500_000e6;
    }

    /// Steakhouse is the live liquidity adapter: with draws off it cannot be the source.
    function test_live_liquidityAdapterRefusedWhenOff() public {
        address steak = Addr.STEAKHOUSE_STRATEGY;
        assertEq(IVaultLiquidity(vault).liquidityAdapter(), steak);
        bouncer.setSourceGuard(false, bouncer.DEFAULT_MAX_MOVE_BPS());
        address other = steak == lo ? hi : lo;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.FromLiquidityAdapter.selector, steak));
        bouncer.bounce(steak, other, _small());
    }

    /// The agreed first grant: Steakhouse → Fluid up to 100,000 USDC, never more out of
    /// Fluid than went in. When Steakhouse pays more at the fork block, outside deposits
    /// into the Steakhouse vault first push its rate 20 bp under Fluid's, so the
    /// scenario runs whichever way the live rates sit.
    function test_live_offWeightSteakhouseToFluid() public {
        address steak = Addr.STEAKHOUSE_STRATEGY;
        address fluid = Addr.FLUID_STRATEGY;
        address bot2 = makeAddr("bot2");
        bouncer.grantPair(bot2, steak, fluid, YieldBouncer.Limits({
            maxNetToB: 100_000e6,
            maxNetToA: 0,
            // above the band, so the band (or the spread) is what stops the next unit;
            // at maxClip = band a full-band pass is refused by ClipTooLarge first
            maxClip: 200_000e6,
            minIntervalBlocks: 1,
            maxLossBps: 2,
            minSpreadBps: 1,
            expiresAtBlock: 0
        }));
        _pct("Steakhouse at the fork block %", bouncer.rateOf(steak));
        _pct("Fluid at the fork block %", bouncer.rateOf(fluid));
        address outsider = makeAddr("outsider");
        uint256 pushed;
        for (uint256 i = 0; i < 20 && bouncer.rateOf(steak) + 20 * BP > bouncer.rateOf(fluid); i++) {
            deal(Addr.BASE_USDC, outsider, 2_000_000e6);
            vm.startPrank(outsider);
            IERC20(Addr.BASE_USDC).approve(Addr.STEAKHOUSE_VAULT, 2_000_000e6);
            IERC4626(Addr.STEAKHOUSE_VAULT).deposit(2_000_000e6, outsider);
            vm.stopPrank();
            pushed += 2_000_000e6;
        }
        emit log_named_decimal_uint("outside deposits into Steakhouse (USDC)", pushed, 6);
        uint256 rSteak = bouncer.rateOf(steak);
        uint256 rFluid = bouncer.rateOf(fluid);
        _pct("Steakhouse before the move %", rSteak);
        _pct("Fluid before the move %", rFluid);
        assertGe(rFluid, rSteak + 20 * BP, "could not set up the spread");

        // the band refuses any move back toward Steakhouse from net 0
        vm.prank(bot2);
        vm.expectRevert(abi.encodeWithSelector(YieldBouncer.NetLimitExceeded.selector, -int256(1_000e6), int256(0)));
        bouncer.bounce(fluid, steak, 1_000e6);

        // the largest move that passes, to 1 USDC
        uint256 low = 0;
        uint256 high = 100_000e6 + 1;
        (bool okTop,) = _tryMove(bot2, steak, fluid, 100_000e6);
        if (okTop) low = 100_000e6;
        while (high - low > 1e6) {
            uint256 mid = (low + high) / 2;
            (bool ok,) = _tryMove(bot2, steak, fluid, mid);
            if (ok) low = mid;
            else high = mid;
        }
        (, bytes4 why) = _tryMove(bot2, steak, fluid, low + 1e6);
        emit log_named_decimal_uint("largest passing move (USDC)", low, 6);
        emit log_named_bytes32("next USDC refused with", bytes32(why));
        assertGt(low, 0, "nothing passes");
        assertTrue(why == YieldBouncer.SpreadTooThin.selector || why == YieldBouncer.NetLimitExceeded.selector);

        uint256 idle0 = IERC20(asset).balanceOf(vault);
        vm.prank(bot2);
        (uint256 rFrom, uint256 rTo, int256 net) = bouncer.bounce(steak, fluid, low);
        _pct("RATE IMPACT Steakhouse after %", rFrom);
        _pct("RATE IMPACT Fluid after %", rTo);
        assertEq(net, int256(low));
        assertEq(IERC20(asset).balanceOf(vault), idle0, "vault idle moved");
        assertGe(rTo, rFrom);
        assertEq(bouncer.room(bot2, steak, fluid), 100_000e6 - low);
        assertEq(bouncer.room(bot2, fluid, steak), low);
    }
}

contract YieldBouncerEthLiveTest is YieldBouncerLiveTest {
    function _rpc() internal view override returns (string memory) {
        return _ethRpc();
    }

    function _allocator() internal pure override returns (address) {
        return Addr.ETH_ALLOCATOR;
    }

    function _pair() internal pure override returns (address, address) {
        return (Addr.AAVE_STRATEGY, Addr.YEARN_STRATEGY);
    }

    function _feeds() internal override returns (IRateSource, address, IRateSource, address) {
        return (new AaveV3RateSource(), Addr.AWETH, new YearnV3RateSource(), Addr.YV_WETH_1);
    }

    /// @dev Our Aave position on mainnet is about 0.22 WETH (2026-10-27).
    function _small() internal pure override returns (uint256) {
        return 0.05 ether;
    }

    function _searchCeiling() internal pure override returns (uint256) {
        return 2_000 ether;
    }

    function _deploy(address allocator) internal override returns (YieldBouncer) {
        return new YieldBouncerETH(allocator);
    }
}

/// @notice alUSD's one lending pair with both sides fed: Yearn yvUSD ↔ Fluid Lite USD.
///         The Fluid Lite strategy books its shares net of the vault's 5 bps withdrawal
///         fee (realAssets = previewRedeem), so a move into it lands 5 bps short.
contract YieldBouncerUsdLiveTest is YieldBouncerLiveTest {
    function _rpc() internal view override returns (string memory) {
        return _ethRpc();
    }

    function _allocator() internal pure override returns (address) {
        return Addr.USD_ALLOCATOR;
    }

    function _pair() internal pure override returns (address, address) {
        return (Addr.YVUSD_STRATEGY, Addr.FLUID_LITE_STRATEGY);
    }

    function _feeds() internal override returns (IRateSource, address, IRateSource, address) {
        return (new YearnV3RateSource(), Addr.YV_USDC_1, new FluidLiteRateSource(), Addr.FLITE_USD);
    }

    function _small() internal pure override returns (uint256) {
        return 1_000e6;
    }

    function _searchCeiling() internal pure override returns (uint256) {
        return 2_000_000e6;
    }

    function _maxLossBps() internal pure override returns (uint16) {
        return 6;
    }
}
