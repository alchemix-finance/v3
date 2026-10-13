// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployRe7ETHMidasStrategyScript} from "../../script/DeployRe7ETHMidasStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {Re7ETHMidasStrategy} from "../strategies/Re7ETHMidasStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForRe7ETHMidasDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract MockAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract MockMidasDataFeed {
    uint256 public nav = 1e18;
    address public aggregator;

    constructor() {
        aggregator = address(new MockAggregator());
    }

    function getDataInBase18() external view returns (uint256) {
        return nav;
    }
}

contract MockMidasRedemptionVault {
    address internal immutable wethFeed;

    constructor(address _wethFeed) {
        wethFeed = _wethFeed;
    }

    function tokensConfig(address) external view returns (address, uint256, uint256, bool) {
        return (wethFeed, 0, type(uint256).max, true);
    }
}

contract DeployRe7ETHMidasStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant OPTIMISM_WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant OPTIMISM_FORK_BLOCK = 158_100_000;

    DeployRe7ETHMidasStrategyScript internal deployScript;
    TestERC20 internal weth;
    TestERC20 internal re7ETH;
    MockMidasDataFeed internal dataFeed;
    MockMidasRedemptionVault internal redemptionVault;
    MockMYTForRe7ETHMidasDeployTest internal myt;
    address internal depositVault;
    address internal newOwner;

    function setUp() public {
        deployScript = new DeployRe7ETHMidasStrategyScript();
        weth = new TestERC20(1_000_000e18, 18);
        re7ETH = new TestERC20(0, 18);
        dataFeed = new MockMidasDataFeed();
        redemptionVault = new MockMidasRedemptionVault(address(dataFeed));
        myt = new MockMYTForRe7ETHMidasDeployTest(address(weth));
        depositVault = makeAddr("depositVault");
        newOwner = makeAddr("newOwner");
    }

    function test_deployRe7ETHMidasStrategy_setsCoreAddressesAndDefaults() public {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployRe7ETHMidasStrategyScript.Re7ETHMidasDeployConfig memory config = DeployRe7ETHMidasStrategyScript.Re7ETHMidasDeployConfig({
            myt: address(myt),
            re7ETH: address(re7ETH),
            depositVault: depositVault,
            redemptionVault: address(redemptionVault),
            dataFeed: address(dataFeed),
            params: params
        });

        Re7ETHMidasStrategy strategy = Re7ETHMidasStrategy(deployScript.deployRe7ETHMidasStrategy(newOwner, config));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT");
        assertEq(strategy.weth(), address(weth), "unexpected MYT asset");
        assertEq(strategy.re7ETH(), address(re7ETH), "unexpected Re7ETH");
        assertEq(address(strategy.depositVault()), depositVault, "unexpected deposit vault");
        assertEq(address(strategy.redemptionVault()), address(redemptionVault), "unexpected redemption vault");
        assertEq(address(strategy.dataFeed()), address(dataFeed), "unexpected data feed");
        assertEq(address(strategy.aggregator()), dataFeed.aggregator(), "unexpected aggregator");
        assertEq(strategy.lastNav(), 1e18, "lastNav should be seeded from the aggregator");
        assertEq(strategy.maxNavStaleness(), 7 days, "unexpected staleness default");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");

        (, string memory name, string memory protocol,,,,,,) = strategy.params();
        assertEq(name, "Re7 ETH Midas", "unexpected strategy name");
        assertEq(protocol, "Midas", "unexpected protocol");
    }

    function test_run_fork_deploysRe7ETHMidasWithOptimismDefaults() public {
        vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), OPTIMISM_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployRe7ETHMidasStrategyScript forkDeployScript = new DeployRe7ETHMidasStrategyScript();
        Re7ETHMidasStrategy strategy = Re7ETHMidasStrategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), forkDeployScript.ethMYT(), "unexpected MYT");
        assertEq(strategy.weth(), OPTIMISM_WETH, "unexpected MYT asset");
        assertEq(strategy.re7ETH(), forkDeployScript.RE7_ETH(), "unexpected Re7ETH");
        assertEq(address(strategy.depositVault()), forkDeployScript.RE7_ETH_DEPOSIT_VAULT(), "unexpected deposit vault");
        assertEq(address(strategy.redemptionVault()), forkDeployScript.RE7_ETH_REDEMPTION_VAULT(), "unexpected redemption vault");
        assertEq(address(strategy.dataFeed()), forkDeployScript.RE7_ETH_DATA_FEED(), "unexpected data feed");
        assertEq(strategy.owner(), forkDeployScript.newOwner(), "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
    }

    function test_defaultParams_usesRe7ETHMidasOptimismDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(params.owner, deployScript.deployerAddr(), "unexpected owner");
        assertEq(params.name, "Re7 ETH Midas", "unexpected name");
        assertEq(params.protocol, "Midas", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.cap, 20e18, "unexpected cap");
        assertEq(params.globalCap, 0.25e18, "unexpected global cap");
        assertEq(params.estimatedYield, 200, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }
}
