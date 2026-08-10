// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployVelodromeMUSDStrategyScript} from "../../script/DeployVelodromeMUSDStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {VelodromeMUSDStrategy} from "../strategies/VelodromeMUSDStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockMYTForVelodromeDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract MockVelodromeVoterForDeployTest {
    mapping(address => address) public gauges;

    function setGauge(address pool, address gauge) external {
        gauges[pool] = gauge;
    }
}

contract MockVelodromePoolForDeployTest {
    address public token0;
    address public token1;
    uint256 public precision0;
    uint256 public precision1;
    bool public stable;

    constructor(address token0_, address token1_, uint256 precision0_, uint256 precision1_, bool stable_) {
        token0 = token0_;
        token1 = token1_;
        precision0 = precision0_;
        precision1 = precision1_;
        stable = stable_;
    }

    function metadata()
        external
        view
        returns (uint256 decimals0, uint256 decimals1, uint256 reserve0, uint256 reserve1, bool isStable, address t0, address t1)
    {
        return (precision0, precision1, 0, 0, stable, token0, token1);
    }
}

contract MockVelodromeGaugeForDeployTest {
    address public stakingToken;
    address public rewardToken;

    constructor(address stakingToken_, address rewardToken_) {
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
    }
}

contract MockVelodromeRouterForDeployTest {
    address public voter;
    address public expectedPool;

    constructor(address voter_, address expectedPool_) {
        voter = voter_;
        expectedPool = expectedPool_;
    }

    function poolFor(address, address, bool, address) external view returns (address) {
        return expectedPool;
    }
}

contract DeployVelodromeMUSDStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant OPTIMISM_NEW_OWNER = 0x3Dda174aa9E897e18b8E10e6Ce39c2a52398181d;
    address internal constant OPTIMISM_USDC_MYT = 0xAf510a560744880410f0f65e3341A020FBC2cA41;
    address internal constant OPTIMISM_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OPTIMISM_MUSD = 0x9dAbAE7274D28A45F0B65Bf8ED201A5731492ca0;
    address internal constant OPTIMISM_POOL = 0xe07388b2a7bb29d3Ad8989e1074Bd00Bd0d3C43d;
    address internal constant OPTIMISM_GAUGE = 0x7b3f9Ae95D8852078E49168505d6C897E4B11B6E;
    address internal constant OPTIMISM_ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal constant OPTIMISM_FACTORY = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    uint256 internal constant OPTIMISM_FORK_BLOCK = 155386026;

    DeployVelodromeMUSDStrategyScript internal deployScript;
    TestERC20 internal assetToken;
    MockMYTForVelodromeDeployTest internal myt;

    address internal newOwner;
    address internal musd;
    address internal velo;
    MockVelodromeVoterForDeployTest internal voter;
    MockVelodromePoolForDeployTest internal pool;
    MockVelodromeGaugeForDeployTest internal gauge;
    MockVelodromeRouterForDeployTest internal router;
    address internal factory;

    function setUp() public {
        deployScript = new DeployVelodromeMUSDStrategyScript();

        assetToken = new TestERC20(1_000_000e6, 6);
        myt = new MockMYTForVelodromeDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        musd = makeAddr("musd");
        velo = makeAddr("velo");
        factory = makeAddr("factory");

        voter = new MockVelodromeVoterForDeployTest();
        pool = new MockVelodromePoolForDeployTest(address(assetToken), musd, 1e6, 1e18, true);
        gauge = new MockVelodromeGaugeForDeployTest(address(pool), velo);
        router = new MockVelodromeRouterForDeployTest(address(voter), address(pool));
        voter.setGauge(address(pool), address(gauge));
    }

    function test_deployVelodromeMUSDStrategy_setsCoreAddressesAndDefaults() public {
        DeployVelodromeMUSDStrategyScript.VelodromeMUSDDeployConfig memory config = DeployVelodromeMUSDStrategyScript
            .VelodromeMUSDDeployConfig({
            myt: address(myt),
            usdc: address(assetToken),
            musd: musd,
            pool: address(pool),
            gauge: address(gauge),
            router: address(router),
            factory: factory,
            params: _buildParams("Velodrome USDC/msUSD", "Velodrome")
        });

        address strategyAddr = deployScript.deployVelodromeMUSDStrategy(newOwner, config);
        VelodromeMUSDStrategy strategy = VelodromeMUSDStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.usdc()), address(assetToken), "unexpected USDC");
        assertEq(address(strategy.musd()), musd, "unexpected msUSD");
        assertEq(address(strategy.pool()), address(pool), "unexpected pool");
        assertEq(address(strategy.gauge()), address(gauge), "unexpected gauge");
        assertEq(address(strategy.router()), address(router), "unexpected router");
        assertEq(strategy.factory(), factory, "unexpected factory");
        assertEq(address(strategy.velo()), velo, "unexpected VELO reward token");
        assertEq(strategy.swapSlippageBPS(), 300, "swap slippage should init from params");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");

        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "Velodrome USDC/msUSD", "unexpected strategy name");
        assertEq(protocol, "Velodrome", "unexpected protocol");
    }

    function test_run_fork_deploysVelodromeMUSDWithOptimismDefaults() public {
        vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), OPTIMISM_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployVelodromeMUSDStrategyScript forkDeployScript = new DeployVelodromeMUSDStrategyScript();
        address strategyAddr = forkDeployScript.run();
        VelodromeMUSDStrategy strategy = VelodromeMUSDStrategy(strategyAddr);
        IVaultV2 vault = IVaultV2(OPTIMISM_USDC_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        assertEq(address(strategy.MYT()), OPTIMISM_USDC_MYT, "unexpected MYT");
        assertEq(vault.asset(), OPTIMISM_USDC, "unexpected MYT asset");
        assertEq(address(strategy.usdc()), OPTIMISM_USDC, "unexpected USDC");
        assertEq(address(strategy.musd()), OPTIMISM_MUSD, "unexpected msUSD");
        assertEq(address(strategy.pool()), OPTIMISM_POOL, "unexpected pool");
        assertEq(address(strategy.gauge()), OPTIMISM_GAUGE, "unexpected gauge");
        assertEq(address(strategy.router()), OPTIMISM_ROUTER, "unexpected router");
        assertEq(strategy.factory(), OPTIMISM_FACTORY, "unexpected factory");
        assertEq(strategy.swapSlippageBPS(), params.slippageBPS, "unexpected swapSlippageBPS");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertEq(strategy.owner(), OPTIMISM_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(vault.isAdapter(strategyAddr), "deploy script should not register strategy");
        assertEq(params.name, "Velodrome USDC/msUSD", "unexpected name");
        assertEq(params.protocol, "Velodrome", "unexpected protocol");
    }

    function test_defaultParams_usesOptimismVelodromeDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.usdcMYT(), OPTIMISM_USDC_MYT, "unexpected USDC MYT");
        assertEq(deployScript.newOwner(), OPTIMISM_NEW_OWNER, "unexpected new owner");
        assertEq(deployScript.USDC(), OPTIMISM_USDC, "unexpected USDC");
        assertEq(deployScript.MUSD(), OPTIMISM_MUSD, "unexpected msUSD");
        assertEq(deployScript.POOL(), OPTIMISM_POOL, "unexpected pool");
        assertEq(deployScript.GAUGE(), OPTIMISM_GAUGE, "unexpected gauge");
        assertEq(deployScript.ROUTER(), OPTIMISM_ROUTER, "unexpected router");
        assertEq(deployScript.FACTORY(), OPTIMISM_FACTORY, "unexpected factory");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "Velodrome USDC/msUSD", "unexpected name");
        assertEq(params.protocol, "Velodrome", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 100_000e6, "unexpected cap");
        assertEq(params.globalCap, 1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 0, "unexpected estimated yield");
        assertTrue(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 300, "unexpected slippage");
    }

    function _buildParams(string memory name, string memory protocol) internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 100_000e6,
            globalCap: 1e18,
            estimatedYield: 0,
            additionalIncentives: true,
            slippageBPS: 300
        });
    }
}
