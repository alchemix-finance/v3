// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {YieldBouncer} from "../src/utils/YieldBouncer.sol";
import {YieldBouncerUSD} from "../src/utils/YieldBouncerUSD.sol";
import {YieldBouncerETH} from "../src/utils/YieldBouncerETH.sol";
import {AaveV3RateSource} from "../src/utils/rates/AaveV3RateSource.sol";
import {EulerEVaultRateSource} from "../src/utils/rates/EulerEVaultRateSource.sol";
import {FluidFTokenRateSource} from "../src/utils/rates/FluidFTokenRateSource.sol";
import {MorphoVaultV2RateSource} from "../src/utils/rates/MorphoVaultV2RateSource.sol";
import {YearnV3RateSource} from "../src/utils/rates/YearnV3RateSource.sol";
import {TokemakAutopoolRateSource} from "../src/utils/rates/TokemakAutopoolRateSource.sol";
import {FluidLiteRateSource} from "../src/utils/rates/FluidLiteRateSource.sol";

/// @notice Deploys one bouncer per MYT, from `deployerAddr`, plus the rate sources its pairs need:
///         `runBase()` the Base USD bouncer, `runMainnet()` the alUSD and alETH bouncers sharing
///         one set of sources. Each bouncer gets its feeds, rate references and first pair grant
///         before the two step handover to its allocator's admin, which then calls
///         `setOperator(bouncer, true)` and `acceptOwnership()`.
contract DeployYieldBouncerScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public constant BASE_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address public constant BASE_ALLOCATOR = 0x347371c17D14Ee7943943995E2A0A9Df4FD83d50;          // USDC MYT
    address public constant MAINNET_USD_ALLOCATOR = 0x693b7594Ae0633d9c5574D0da46a040f92F5b281;   // alUSD MYT
    address public constant MAINNET_ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;   // alETH MYT
    address public constant BASE_ADMIN = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address public constant MAINNET_ADMIN = 0xF56D660138815fC5d7a06cd0E1630225E788293D;

    /// @dev Replace before broadcasting.
    address public constant BASE_BOT_USD = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public constant MAINNET_BOT_USD = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public constant MAINNET_BOT_ETH = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    uint16 public constant RATE_BAND_BPS = 500;   // reference = the live rate at deploy, ±500 APR bps

    // Base USDC MYT
    address public constant STEAKHOUSE_STRATEGY = 0xaeEA02683f652dd1fb4846bE71FB8Cf26f3393d4;
    address public constant FLUID_STRATEGY = 0x4e7Fb7BAD62D105eE2c4856d45f8FbfaDEEFa896;
    address public constant STEAKHOUSE_VAULT = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address public constant FUSDC = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
    // mainnet alUSD MYT
    address public constant YVUSD_STRATEGY = 0xdFDC17F784e16D7634AC270911D98755C68Ae220;
    address public constant FLUID_LITE_STRATEGY = 0x320e38ca23FB11cC1f673b204E301210d3758653;
    address public constant YV_USDC_1 = 0x696d02Db93291651ED510704c9b286841d506987;
    address public constant FLITE_USD = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;
    // mainnet alETH MYT
    address public constant AAVE_STRATEGY = 0xb2d750bfA0B8c8C72945F5533442B467230CB4D7;
    address public constant YEARN_STRATEGY = 0x8AACC947c2f4E24D2Be4CBa4498f004079F35D87;
    address public constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address public constant YV_WETH_1 = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;

    /// @dev One strategy's rate feed: the source kind and the venue it reads.
    struct Feed {
        address strategy;
        string source;
        address venue;
    }

    /// @dev Rate feeds each MYT registers, keyed "usd" or "eth"; edit as strategies are added.
    mapping(string denomination => Feed[] feeds) internal baseFeeds;
    mapping(string denomination => Feed[] feeds) internal mainnetFeeds;

    struct RateSources {
        address aave;
        address euler;
        address fluid;
        address morpho;
        address yearn;
        address tokemak;
        address fluidlite;
    }

    struct Deployed {
        address usdBouncer;
        address ethBouncer;        // 0 where the chain has no ETH MYT
        RateSources sources;
    }

    constructor() {
        baseFeeds["usd"].push(Feed(STEAKHOUSE_STRATEGY, "morpho", STEAKHOUSE_VAULT));
        baseFeeds["usd"].push(Feed(FLUID_STRATEGY, "fluid", FUSDC));
        mainnetFeeds["usd"].push(Feed(YVUSD_STRATEGY, "yearn", YV_USDC_1));
        mainnetFeeds["usd"].push(Feed(FLUID_LITE_STRATEGY, "fluidlite", FLITE_USD));
        mainnetFeeds["eth"].push(Feed(AAVE_STRATEGY, "aave", AWETH));
        mainnetFeeds["eth"].push(Feed(YEARN_STRATEGY, "yearn", YV_WETH_1));
    }

    /// @notice YieldBouncerUSD on the Base USDC MYT, its feeds registered, draws from the liquidity adapter on.
    function runBase() external returns (Deployed memory deployed) {
        _requireChain(BASE);
        vm.startBroadcast(deployerAddr);
        YieldBouncer bouncer = deployUSD(BASE_ALLOCATOR, true);
        deployed.sources = _registerFeeds(bouncer, deployed.sources, baseFeeds["usd"]);
        _setRateRefs(bouncer, baseFeeds["usd"]);
        bouncer.grantPair(BASE_BOT_USD, STEAKHOUSE_STRATEGY, FLUID_STRATEGY, _baseLimits());
        bouncer.transferOwnership(BASE_ADMIN);
        vm.stopBroadcast();
        deployed.usdBouncer = address(bouncer);
        _log(deployed, BASE_ADMIN);
    }

    /// @notice YieldBouncerUSD on alUSD and YieldBouncerETH on alETH, sharing one set of rate sources.
    function runMainnet() external returns (Deployed memory deployed) {
        _requireChain(ETHEREUM);
        vm.startBroadcast(deployerAddr);
        YieldBouncer usd = deployUSD(MAINNET_USD_ALLOCATOR, false);
        YieldBouncer eth = deployETH(MAINNET_ETH_ALLOCATOR);
        deployed.sources = _registerFeeds(usd, deployed.sources, mainnetFeeds["usd"]);
        deployed.sources = _registerFeeds(eth, deployed.sources, mainnetFeeds["eth"]);
        _setRateRefs(usd, mainnetFeeds["usd"]);
        _setRateRefs(eth, mainnetFeeds["eth"]);
        usd.grantPair(MAINNET_BOT_USD, YVUSD_STRATEGY, FLUID_LITE_STRATEGY, _mainnetUsdLimits());
        eth.grantPair(MAINNET_BOT_ETH, AAVE_STRATEGY, YEARN_STRATEGY, _mainnetEthLimits());
        usd.transferOwnership(MAINNET_ADMIN);
        eth.transferOwnership(MAINNET_ADMIN);
        vm.stopBroadcast();
        deployed.usdBouncer = address(usd);
        deployed.ethBouncer = address(eth);
        _log(deployed, MAINNET_ADMIN);
    }

    /// @notice The bouncer, still owned by the deployer so the script can set its rates and grants.
    /// @param liquidityMovable Whether bounces may draw from the vault's liquidity adapter.
    function deployUSD(address allocator, bool liquidityMovable) public returns (YieldBouncer bouncer) {
        bouncer = new YieldBouncerUSD(allocator);
        if (liquidityMovable) bouncer.setSourceGuard(true, bouncer.DEFAULT_MAX_MOVE_BPS());
    }

    /// @notice The bouncer, still owned by the deployer so the script can set its rates and grants.
    function deployETH(address allocator) public returns (YieldBouncer bouncer) {
        bouncer = new YieldBouncerETH(allocator);
    }

    /// @notice Deploy each named rate source once.
    function deployRateSources(string[] memory names) public returns (RateSources memory sources) {
        return _deployRateSources(sources, names);
    }

    function getBaseFeeds(string memory denomination) external view returns (Feed[] memory) {
        return baseFeeds[denomination];
    }

    function getMainnetFeeds(string memory denomination) external view returns (Feed[] memory) {
        return mainnetFeeds[denomination];
    }

    function allocatorAdmin(address allocator) public view returns (address) {
        return address(uint160(uint256(vm.load(allocator, bytes32(0)))));
    }

    /// @dev Reference each strategy at its live rate, so bounces stay within RATE_BAND_BPS of the rate at deploy.
    function _setRateRefs(YieldBouncer bouncer, Feed[] memory feeds) internal {
        for (uint256 index = 0; index < feeds.length; index++) {
            address strategy = feeds[index].strategy;
            bouncer.setRateRef(strategy, bouncer.rateOf(strategy), RATE_BAND_BPS);
        }
    }

    /// @dev Steakhouse → Fluid, one way: up to 100,000 USDC in, never more back out than went in.
    function _baseLimits() internal pure returns (YieldBouncer.Limits memory limits) {
        limits = YieldBouncer.Limits({
            maxNetToB: 100_000e6,
            maxNetToA: 0,
            maxClip: 25_000e6,
            minIntervalBlocks: 150,
            maxLossBps: 2,
            minSpreadBps: 5,
            expiresAtBlock: 0
        });
    }

    /// @dev yvUSD ↔ Fluid Lite, 100,000 USDC each way. Fluid Lite's exit fee needs the wider loss bound.
    function _mainnetUsdLimits() internal pure returns (YieldBouncer.Limits memory limits) {
        limits = YieldBouncer.Limits({
            maxNetToB: 100_000e6,
            maxNetToA: 100_000e6,
            maxClip: 25_000e6,
            minIntervalBlocks: 150,
            maxLossBps: 6,
            minSpreadBps: 5,
            expiresAtBlock: 0
        });
    }

    /// @dev Aave WETH ↔ yvWETH, 25 ETH each way.
    function _mainnetEthLimits() internal pure returns (YieldBouncer.Limits memory limits) {
        limits = YieldBouncer.Limits({
            maxNetToB: 25 ether,
            maxNetToA: 25 ether,
            maxClip: 5 ether,
            minIntervalBlocks: 150,
            maxLossBps: 2,
            minSpreadBps: 5,
            expiresAtBlock: 0
        });
    }

    /// @dev Deploys the sources the feeds name, once, and registers every feed on the bouncer.
    function _registerFeeds(YieldBouncer bouncer, RateSources memory sources, Feed[] memory feeds)
        internal
        returns (RateSources memory)
    {
        string[] memory names = new string[](feeds.length);
        for (uint256 index = 0; index < feeds.length; index++) names[index] = feeds[index].source;
        sources = _deployRateSources(sources, names);
        for (uint256 index = 0; index < feeds.length; index++) {
            bouncer.setRateSource(feeds[index].strategy, _sourceOf(sources, feeds[index].source), feeds[index].venue);
        }
        return sources;
    }

    function _sourceOf(RateSources memory sources, string memory name) internal pure returns (address) {
        bytes32 key = keccak256(bytes(name));
        if (key == keccak256("aave")) return sources.aave;
        if (key == keccak256("euler")) return sources.euler;
        if (key == keccak256("fluid")) return sources.fluid;
        if (key == keccak256("morpho")) return sources.morpho;
        if (key == keccak256("yearn")) return sources.yearn;
        if (key == keccak256("tokemak")) return sources.tokemak;
        return sources.fluidlite;
    }

    /// @dev Deploys the named sources not yet in `sources`, so a source shared by two MYTs deploys once.
    function _deployRateSources(RateSources memory sources, string[] memory names)
        internal
        returns (RateSources memory)
    {
        for (uint256 index = 0; index < names.length; index++) {
            bytes32 name = keccak256(bytes(names[index]));
            if (name == keccak256("aave")) {
                if (sources.aave == address(0)) sources.aave = address(new AaveV3RateSource());
            } else if (name == keccak256("euler")) {
                if (sources.euler == address(0)) sources.euler = address(new EulerEVaultRateSource());
            } else if (name == keccak256("fluid")) {
                if (sources.fluid == address(0)) sources.fluid = address(new FluidFTokenRateSource());
            } else if (name == keccak256("morpho")) {
                if (sources.morpho == address(0)) sources.morpho = address(new MorphoVaultV2RateSource());
            } else if (name == keccak256("yearn")) {
                if (sources.yearn == address(0)) sources.yearn = address(new YearnV3RateSource());
            } else if (name == keccak256("tokemak")) {
                if (sources.tokemak == address(0)) sources.tokemak = address(new TokemakAutopoolRateSource());
            } else if (name == keccak256("fluidlite")) {
                if (sources.fluidlite == address(0)) sources.fluidlite = address(new FluidLiteRateSource());
            } else {
                revert(string.concat("unknown rate source: ", names[index]));
            }
        }
        return sources;
    }

    function _requireChain(uint256 chainId) internal view {
        if (block.chainid != chainId) revert(string.concat("wrong chain ", vm.toString(block.chainid)));
    }

    function _log(Deployed memory deployed, address newOwner) internal pure {
        console.log("YieldBouncerUSD:", deployed.usdBouncer);
        if (deployed.ethBouncer != address(0)) console.log("YieldBouncerETH:", deployed.ethBouncer);
        console.log("pending owner:", newOwner);
        RateSources memory sources = deployed.sources;
        if (sources.aave != address(0)) console.log("AaveV3RateSource:", sources.aave);
        if (sources.euler != address(0)) console.log("EulerEVaultRateSource:", sources.euler);
        if (sources.fluid != address(0)) console.log("FluidFTokenRateSource:", sources.fluid);
        if (sources.morpho != address(0)) console.log("MorphoVaultV2RateSource:", sources.morpho);
        if (sources.yearn != address(0)) console.log("YearnV3RateSource:", sources.yearn);
        if (sources.tokemak != address(0)) console.log("TokemakAutopoolRateSource:", sources.tokemak);
        if (sources.fluidlite != address(0)) console.log("FluidLiteRateSource:", sources.fluidlite);
    }
}
