// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3RateSource} from "../../utils/rates/AaveV3RateSource.sol";
import {EulerEVaultRateSource} from "../../utils/rates/EulerEVaultRateSource.sol";
import {FluidFTokenRateSource} from "../../utils/rates/FluidFTokenRateSource.sol";
import {YearnV3RateSource} from "../../utils/rates/YearnV3RateSource.sol";
import {TokemakAutopoolRateSource} from "../../utils/rates/TokemakAutopoolRateSource.sol";
import {FluidLiteRateSource} from "../../utils/rates/FluidLiteRateSource.sol";
import {
    MorphoVaultV2RateSource,
    MorphoMarketParamsLite,
    MorphoMarketLite
} from "../../utils/rates/MorphoVaultV2RateSource.sol";

// ---- Aave ------------------------------------------------------------------------

contract MockAavePool {
    uint256 public liquidityRateRay;

    function set(uint256 r) external {
        liquidityRateRay = r;
    }

    /// @dev ReserveDataLegacy: 15 words, the liquidity rate third.
    function getReserveData(address) external view returns (uint256[15] memory d) {
        d[1] = 1e27;
        d[2] = liquidityRateRay;
    }
}

contract MockAToken {
    address public POOL;
    address public UNDERLYING_ASSET_ADDRESS = address(0xA55E7);

    constructor(address pool) {
        POOL = pool;
    }
}

// ---- Euler -----------------------------------------------------------------------

contract MockEVault {
    uint256 public interestRate;
    uint16 public interestFee;
    uint256 public cash;
    uint256 public totalBorrows;

    function set(uint256 spy, uint16 fee, uint256 c, uint256 b) external {
        (interestRate, interestFee, cash, totalBorrows) = (spy, fee, c, b);
    }
}

// ---- Yearn -----------------------------------------------------------------------

contract MockYearnV3 {
    uint256 public profitUnlockingRate;
    uint256 public fullProfitUnlockDate;
    uint256 public totalSupply;

    function set(uint256 r, uint256 end, uint256 supply) external {
        (profitUnlockingRate, fullProfitUnlockDate, totalSupply) = (r, end, supply);
    }
}

// ---- Tokemak ---------------------------------------------------------------------

contract MockAutopool {
    uint48 public period = 1 days;
    uint48 public fullUnlock;
    uint48 public lastUnlock;
    uint256 public rate;
    uint256 public totalSupply;

    function set(uint256 r, uint48 end, uint256 supply) external {
        (rate, fullUnlock, lastUnlock, totalSupply) = (r, end, end > period ? end - period : 0, supply);
    }

    function getProfitUnlockSettings() external view returns (uint48, uint48, uint48, uint256) {
        return (period, fullUnlock, lastUnlock, rate);
    }
}

// ---- Fluid Lite ------------------------------------------------------------------

contract MockLiteAsset {
    uint8 public decimals = 6;
}

contract MockFluidLite {
    address public asset = address(new MockLiteAsset());
    uint256 public getExchangePrice;
    uint256 public getEffectiveExchangePrice;
    uint256 public getFixedRate;
    uint256 public getRewardAmountPerYear;
    uint256 public totalSupply;

    function set(uint256 p0, uint256 pEff, uint256 fixedRate, uint256 reward, uint256 supply) external {
        (getExchangePrice, getEffectiveExchangePrice, getFixedRate, getRewardAmountPerYear, totalSupply) =
            (p0, pEff, fixedRate, reward, supply);
    }
}

// ---- Fluid -----------------------------------------------------------------------

contract MockFluidLiquidity {
    mapping(bytes32 => uint256) internal store;

    function put(uint256 mappingSlot, address token, uint256 value) external {
        store[keccak256(abi.encode(token, mappingSlot))] = value;
    }

    function readFromStorage(bytes32 slot) external view returns (uint256) {
        return store[slot];
    }
}

contract MockRewardsModel {
    uint256 public rate;
    bool public ended;

    function set(uint256 r, bool e) external {
        (rate, ended) = (r, e);
    }

    function getRate(uint256) external view returns (uint256, bool, uint256) {
        return (rate, ended, 0);
    }
}

contract MockFToken {
    address public asset;
    address public liquidity;
    address public model;
    bool public rewardsActive;

    constructor(address a, address l, address m) {
        (asset, liquidity, model) = (a, l, m);
    }

    function setRewards(bool on) external {
        rewardsActive = on;
    }

    function totalAssets() external pure returns (uint256) {
        return 1;
    }

    function getData()
        external
        view
        returns (address, address, address, address, address, bool, uint256, uint256, uint256)
    {
        return (liquidity, address(0), model, address(0), address(0), rewardsActive, 0, 0, 0);
    }
}

// ---- Morpho ----------------------------------------------------------------------

contract MockMorpho {
    mapping(bytes32 => MorphoMarketParamsLite) internal params;
    mapping(bytes32 => MorphoMarketLite) internal markets;
    mapping(bytes32 => mapping(address => uint256)) internal shares;

    function setMarket(bytes32 id, address irm, MorphoMarketLite memory m) external {
        params[id].irm = irm;
        markets[id] = m;
    }

    function setShares(bytes32 id, address user, uint256 s) external {
        shares[id][user] = s;
    }

    function idToMarketParams(bytes32 id) external view returns (MorphoMarketParamsLite memory) {
        return params[id];
    }

    function market(bytes32 id) external view returns (MorphoMarketLite memory) {
        return markets[id];
    }

    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128) {
        return (shares[id][user], 0, 0);
    }
}

contract MockIrm {
    uint256 public ratePerSecond;

    function set(uint256 r) external {
        ratePerSecond = r;
    }

    function borrowRateView(MorphoMarketParamsLite memory, MorphoMarketLite memory) external view returns (uint256) {
        return ratePerSecond;
    }
}

contract MockMarketAdapter {
    address public morpho;
    bytes32[] internal ids;

    constructor(address m) {
        morpho = m;
    }

    function add(bytes32 id) external {
        ids.push(id);
    }

    function marketIdsLength() external view returns (uint256) {
        return ids.length;
    }

    function marketIds(uint256 i) external view returns (bytes32) {
        return ids[i];
    }
}

contract NotAMarketAdapter {}

contract MockVaultV2 {
    address[] internal _adapters;
    uint256 public totalAssets;
    uint256 public performanceFee;
    uint256 public managementFee;
    uint256 public maxRate = type(uint64).max;

    function addAdapter(address a) external {
        _adapters.push(a);
    }

    function set(uint256 ta, uint256 perf, uint256 mgmt, uint256 maxR) external {
        (totalAssets, performanceFee, managementFee, maxRate) = (ta, perf, mgmt, maxR);
    }

    function adaptersLength() external view returns (uint256) {
        return _adapters.length;
    }

    function adapters(uint256 i) external view returns (address) {
        return _adapters[i];
    }
}

/// @notice Rate maths of each source against hand-computed values on mock venues.
///         The fork suite checks the same sources against live venues.
contract RateSourcesTest is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BP = 1e14;

    function test_aave_rayToWad() public {
        MockAavePool pool = new MockAavePool();
        pool.set(12_988_654_293_292_277_599_496_057);    // live aEthWETH 2026-10-27: 1.2988…%
        AaveV3RateSource src = new AaveV3RateSource();
        assertEq(src.supplyRate(address(new MockAToken(address(pool)))), 12_988_654_293_292_277);
    }

    function test_euler_utilizationAndFee() public {
        MockEVault v = new MockEVault();
        // live eWETH-2 2026-10-27: SPY 6.42e17 (1e27 scale), fee 0, cash 150.28, borrows 608.27
        v.set(642_028_245_126_825_840, 0, 150_277_379_035_102_440_126, 608_268_240_334_185_017_656);
        EulerEVaultRateSource src = new EulerEVaultRateSource();
        uint256 r = src.supplyRate(address(v));
        assertApproxEqAbs(r, 16_236 * BP / 100, 1 * BP);  // 2.0247% × 80.19% = 1.6236%
        v.set(642_028_245_126_825_840, 1_000, 150_277_379_035_102_440_126, 608_268_240_334_185_017_656);
        assertApproxEqRel(src.supplyRate(address(v)), r * 9 / 10, 1e9);
        v.set(1e18, 0, 0, 0);
        assertEq(src.supplyRate(address(v)), 0);
    }

    function test_yearn_unlockRate_dilution_cliff() public {
        MockYearnV3 v = new MockYearnV3();
        uint256 t0 = block.timestamp;
        // live WETH-1 2026-10-27: 4.6975e24 per second (1e12 scale), supply 7,179.67
        v.set(4_697_531_682_367_749_605_964_743, t0 + 3 days, 7_179_673_232_310_300_355_151);
        YearnV3RateSource src = new YearnV3RateSource();
        uint256 r = src.supplyRate(address(v));
        assertApproxEqAbs(r, 2063 * BP / 10, 1 * BP);       // 2.063%
        // a deposit adding 10% to supply dilutes the unlock by the same factor
        v.set(4_697_531_682_367_749_605_964_743, t0 + 3 days, uint256(7_179_673_232_310_300_355_151) * 11 / 10);
        assertApproxEqRel(src.supplyRate(address(v)), r * 10 / 11, 1e9);
        vm.warp(t0 + 3 days);
        assertEq(src.supplyRate(address(v)), 0);
    }

    function _fluid(uint256 supplyRaw, uint256 borrowRaw, uint256 fee, uint256 rateData)
        internal
        returns (MockFToken f, MockFluidLiquidity l, MockRewardsModel m)
    {
        l = new MockFluidLiquidity();
        m = new MockRewardsModel();
        f = new MockFToken(address(0xC0FFEE), address(l), address(m));
        uint256 price = 1e12;                                        // exchange prices 1.0
        l.put(5, f.asset(), (fee << 16) | (price << 91) | (price << 155));
        l.put(6, f.asset(), rateData);
        // BigMath with exponent 0: value << 8
        l.put(7, f.asset(), (supplyRaw << 8) | ((borrowRaw << 8) << 128));
    }

    /// v2 curve of USDC on Base, 2026-10-27: 0 → 0%, 85% → 5%, 93% → 8%, 100% → 15%.
    function _usdcBaseCurve() internal pure returns (uint256) {
        return 2 | (0 << 4) | (8_500 << 20) | (500 << 36) | (9_300 << 52) | (800 << 68) | (1_500 << 84);
    }

    function test_fluid_v2Curve_liveShape() public {
        // supply 7,660,773.337759, borrow 6,859,370.687548, fee 10%
        (MockFToken f,,) = _fluid(7_660_773_337_759, 6_859_370_687_548, 1_000, _usdcBaseCurve());
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        // utilization 89.5389%: borrow 5% + 3% × 4.5389/8 = 6.7021%; supply = 6.7021% × 0.895389 × 0.9 = 5.40087%
        // (same integer steps worked in Python; the live resolver read 5.41% from its stored, older rate)
        assertEq(src.supplyRate(address(f)), 54_008_708_285_925_607);
    }

    function test_fluid_kinksAndEnds() public {
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        uint256 curve = _usdcBaseCurve();
        // at kink 1 exactly: borrow 5%, supply = 5% × 0.85 × 1.0 (no fee)
        (MockFToken f,,) = _fluid(100e6, 85e6, 0, curve);
        assertEq(src.supplyRate(address(f)), 425 * BP);
        // at kink 2: 8% × 0.93
        (f,,) = _fluid(100e6, 93e6, 0, curve);
        assertEq(src.supplyRate(address(f)), 744 * BP);
        // fully borrowed: 15%
        (f,,) = _fluid(100e6, 100e6, 0, curve);
        assertEq(src.supplyRate(address(f)), 1_500 * BP);
        // nothing supplied
        (f,,) = _fluid(0, 0, 0, curve);
        assertEq(src.supplyRate(address(f)), 0);
    }

    function test_fluid_v1Curve() public {
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        // v1: 0 → 1%, kink 80% → 6%, 100% → 50%
        uint256 curve = 1 | (100 << 4) | (8_000 << 20) | (600 << 36) | (5_000 << 52);
        (MockFToken f,,) = _fluid(100e6, 40e6, 0, curve);          // 40%: 1% + 5% × 0.5 = 3.5%, × 0.4
        assertEq(src.supplyRate(address(f)), 140 * BP);
        (f,,) = _fluid(100e6, 90e6, 0, curve);                      // 90%: 6% + 44% × 0.5 = 28%, × 0.9
        assertEq(src.supplyRate(address(f)), 2_520 * BP);
    }

    function test_fluid_unknownVersionReverts() public {
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        (MockFToken f,,) = _fluid(100e6, 40e6, 0, 3);
        vm.expectRevert(abi.encodeWithSelector(FluidFTokenRateSource.UnknownRateVersion.selector, 3));
        src.supplyRate(address(f));
    }

    function test_fluid_bigMathExponent() public {
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        (MockFToken f, MockFluidLiquidity l,) = _fluid(0, 0, 0, _usdcBaseCurve());
        // supply = 25 << 4 = 400e6 raw; borrow = 340e6 (85%) as 85 << 22 is not exact, use coefficient 340e6, exponent 0
        l.put(7, f.asset(), ((uint256(25e6) << 8) | 4) | ((uint256(340e6) << 8) << 128));
        assertEq(src.supplyRate(address(f)), 425 * BP);
    }

    function test_fluid_rewardsAddWhileActive() public {
        FluidFTokenRateSource src = new FluidFTokenRateSource();
        (MockFToken f,, MockRewardsModel m) = _fluid(100e6, 85e6, 0, _usdcBaseCurve());
        m.set(2e12, false);                                         // 2% per year on the 1e12 = 1% scale
        assertEq(src.supplyRate(address(f)), 425 * BP);             // rewards inactive on the fToken
        f.setRewards(true);
        assertEq(src.supplyRate(address(f)), 625 * BP);
        m.set(2e12, true);
        assertEq(src.supplyRate(address(f)), 425 * BP);
    }

    function _morpho()
        internal
        returns (MorphoVaultV2RateSource src, MockVaultV2 v, MockMorpho morpho, MockMarketAdapter ad, MockIrm irm)
    {
        src = new MorphoVaultV2RateSource();
        v = new MockVaultV2();
        morpho = new MockMorpho();
        ad = new MockMarketAdapter(address(morpho));
        irm = new MockIrm();
        v.addAdapter(address(ad));
    }

    function test_morpho_weightedNetOfFees() public {
        (MorphoVaultV2RateSource src, MockVaultV2 v, MockMorpho morpho, MockMarketAdapter ad, MockIrm irm) = _morpho();
        MockIrm irm2 = new MockIrm();
        // market 1: borrow 10% APR, 90% utilized, fee 0 → supply 9%; we hold 600 of 1,000
        irm.set(uint256(10e16) / YEAR);
        morpho.setMarket("m1", address(irm), MorphoMarketLite(1_000e6, 1_000e12, 900e6, 900e12, 0, 0));
        morpho.setShares("m1", address(ad), 600e12);
        // market 2: borrow 5%, 50% utilized, market fee 10% → supply 2.25%; we hold 300
        irm2.set(uint256(5e16) / YEAR);
        morpho.setMarket("m2", address(irm2), MorphoMarketLite(1_000e6, 1_000e12, 500e6, 500e12, 0, 1e17));
        morpho.setShares("m2", address(ad), 300e12);
        ad.add("m1");
        ad.add("m2");
        // vault 1,000 incl. 100 idle; perf fee 5%
        v.set(1_000e6, 5e16, 0, type(uint64).max);
        // gross = (600 × 9% + 300 × 2.25%) / 1,000 = 6.075%; net = × 0.95 = 5.77125%
        assertApproxEqAbs(src.supplyRate(address(v)), 577_125 * BP / 1_000, BP / 100);

        // management fee 1% per year comes off the top
        v.set(1_000e6, 5e16, uint256(1e16) / YEAR, type(uint64).max);
        assertApproxEqAbs(src.supplyRate(address(v)), 477_125 * BP / 1_000, BP / 100);

        // maxRate caps it: 3% per year
        v.set(1_000e6, 5e16, 0, uint256(3e16) / YEAR);
        assertApproxEqAbs(src.supplyRate(address(v)), 300 * BP, BP / 100);
    }

    function test_morpho_unknownAdapterReverts() public {
        (MorphoVaultV2RateSource src, MockVaultV2 v,,,) = _morpho();
        v.set(1_000e6, 0, 0, type(uint64).max);
        NotAMarketAdapter odd = new NotAMarketAdapter();
        v.addAdapter(address(odd));
        vm.expectRevert(abi.encodeWithSelector(MorphoVaultV2RateSource.UnknownAdapter.selector, address(odd)));
        src.supplyRate(address(v));
    }

    function test_morpho_tooManyMarketsReverts() public {
        (MorphoVaultV2RateSource src, MockVaultV2 v,, MockMarketAdapter ad,) = _morpho();
        v.set(1_000e6, 0, 0, type(uint64).max);
        for (uint256 i = 0; i < 65; i++) {
            ad.add(bytes32(i));
        }
        vm.expectRevert(abi.encodeWithSelector(MorphoVaultV2RateSource.TooManyMarkets.selector, 65, 64));
        src.supplyRate(address(v));
    }

    function test_tokemak_unlockRate_dilution_cliff() public {
        MockAutopool p = new MockAutopool();
        uint48 t0 = uint48(block.timestamp);
        // live autoUSD 2026-11-03: 2.8163e24 per second (1e9 scale), supply 7,669,507.9
        p.set(2_816_295_410_107_913_315_138_888, t0 + 16 hours, 7_669_507_907_801_318_853_466_139);
        TokemakAutopoolRateSource src = new TokemakAutopoolRateSource();
        uint256 r = src.supplyRate(address(p));
        assertApproxEqAbs(r, 1158 * BP / 10, 1 * BP);       // 1.158%
        p.set(2_816_295_410_107_913_315_138_888, t0 + 16 hours, uint256(7_669_507_907_801_318_853_466_139) * 2);
        assertApproxEqRel(src.supplyRate(address(p)), r / 2, 1e9);
        vm.warp(t0 + 16 hours);
        assertEq(src.supplyRate(address(p)), 0);
    }

    /// Live fLiteUSD 2026-11-03: fixed 6.00%, reward 3,000,000 USDC/yr on ~38.68M.
    /// Expected values recomputed off-chain with the vault's own integer maths.
    function test_fluidLite_rewardBinds_dilutes_thenFixedFloor() public {
        MockFluidLite v = new MockFluidLite();
        FluidLiteRateSource src = new FluidLiteRateSource();
        uint256 p0 = 1_055_874_513_206_277_275;
        uint256 pEff = 1_055_876_568_613_160_457;
        uint256 supply = 36_630_653e18;
        uint256 reward = 3_000_000e6;

        v.set(p0, pEff, 600, reward, supply);
        assertEq(src.supplyRate(address(v)), 77_511_489_298_381_349);           // 7.751% (365-day basis)

        v.set(p0, pEff, 600, reward, supply * 6 / 5);                           // +20% deposits
        assertEq(src.supplyRate(address(v)), 64_592_907_748_651_124);

        v.set(p0, pEff, 600, reward, supply * 2);                               // past the crossover
        uint256 floor = 59_958_815_520_002_943;                                  // 6% on p0, per 365 d, vs pEff
        assertEq(src.supplyRate(address(v)), floor);

        v.set(p0, pEff, 600, reward, 99e18);                                    // reward needs 100 shares
        assertEq(src.supplyRate(address(v)), floor);

        v.set(pEff, pEff, 600, 0, supply);                                      // fresh checkpoint: 6% × 365/365.25
        assertEq(src.supplyRate(address(v)), uint256(6e16) * 36_500 / 36_525);

        v.set(p0, pEff, 0, 0, supply);
        assertEq(src.supplyRate(address(v)), 0);
    }
}
