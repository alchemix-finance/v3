// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySiUSDStrategiesScript} from "../../script/DeploySiUSDStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {SiUSDStrategy} from "../strategies/SiUSDStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForSiUSDDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract MockDeployOracle {
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract DeploySiUSDStrategiesScriptTest is Test {
    uint256 internal constant MAX_ORACLE_STALENESS_A = 6 hours;
    uint256 internal constant MAX_ORACLE_STALENESS_B = 12 hours;

    DeploySiUSDStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForSiUSDDeployTest internal myt;

    address internal newOwner;
    address internal iUSD;
    address internal siUSD;
    address internal gateway;
    address internal mintControllerA;
    address internal mintControllerB;
    address internal redeemControllerA;
    address internal redeemControllerB;
    MockDeployOracle internal iUsdUsdcOracleA;
    MockDeployOracle internal iUsdUsdcOracleB;

    function setUp() public {
        deployScript = new DeploySiUSDStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e6, 6);
        myt = new MockMYTForSiUSDDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        iUSD = makeAddr("iUSD");
        siUSD = makeAddr("siUSD");
        gateway = makeAddr("gateway");
        mintControllerA = makeAddr("mintControllerA");
        mintControllerB = makeAddr("mintControllerB");
        redeemControllerA = makeAddr("redeemControllerA");
        redeemControllerB = makeAddr("redeemControllerB");
        iUsdUsdcOracleA = new MockDeployOracle(18);
        iUsdUsdcOracleB = new MockDeployOracle(18);
    }

    function test_deploySiUSDStrategy_setsCoreAddressesAndName() public {
        DeploySiUSDStrategiesScript.SiUSDDeployConfig memory config = DeploySiUSDStrategiesScript.SiUSDDeployConfig({
            myt: address(myt),
            usdc: address(assetToken),
            iUSD: iUSD,
            siUSD: siUSD,
            gateway: gateway,
            mintController: mintControllerA,
            redeemController: redeemControllerA,
            iUsdUsdcOracle: address(iUsdUsdcOracleA),
            maxOracleStaleness: MAX_ORACLE_STALENESS_A,
            params: _buildParams("SiUSD Mainnet USDC", "InfiniFi")
        });

        address strategyAddr = deployScript.deploySiUSDStrategy(curator, newOwner, config);
        SiUSDStrategy strategy = SiUSDStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.usdc()), address(assetToken), "unexpected usdc");
        assertEq(address(strategy.iUSD()), iUSD, "unexpected iUSD");
        assertEq(address(strategy.siUSD()), siUSD, "unexpected siUSD");
        assertEq(address(strategy.gateway()), gateway, "unexpected gateway");
        assertEq(address(strategy.mintController()), mintControllerA, "unexpected mint controller");
        assertEq(address(strategy.redeemController()), redeemControllerA, "unexpected redeem controller");
        assertEq(address(strategy.pricedTokenEthOracle()), address(iUsdUsdcOracleA), "unexpected iUSD oracle");
        assertEq(strategy.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS_A, "unexpected max oracle staleness");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "SiUSD Mainnet USDC", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeploySiUSDStrategiesScript.SiUSDDeployConfig[] memory configs =
            new DeploySiUSDStrategiesScript.SiUSDDeployConfig[](2);

        configs[0] = DeploySiUSDStrategiesScript.SiUSDDeployConfig({
            myt: address(myt),
            usdc: address(assetToken),
            iUSD: iUSD,
            siUSD: siUSD,
            gateway: gateway,
            mintController: mintControllerA,
            redeemController: redeemControllerA,
            iUsdUsdcOracle: address(iUsdUsdcOracleA),
            maxOracleStaleness: MAX_ORACLE_STALENESS_A,
            params: _buildParams("SiUSD Mainnet USDC", "InfiniFi")
        });

        configs[1] = DeploySiUSDStrategiesScript.SiUSDDeployConfig({
            myt: address(myt),
            usdc: address(assetToken),
            iUSD: makeAddr("iUSDB"),
            siUSD: makeAddr("siUSDB"),
            gateway: makeAddr("gatewayB"),
            mintController: mintControllerB,
            redeemController: redeemControllerB,
            iUsdUsdcOracle: address(iUsdUsdcOracleB),
            maxOracleStaleness: MAX_ORACLE_STALENESS_B,
            params: _buildParams("SiUSD Alternate USDC", "InfiniFi")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        SiUSDStrategy strategy0 = SiUSDStrategy(deployed[0]);
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.usdc()), address(assetToken), "strategy0 unexpected usdc");
        assertEq(address(strategy0.iUSD()), iUSD, "strategy0 unexpected iUSD");
        assertEq(address(strategy0.siUSD()), siUSD, "strategy0 unexpected siUSD");
        assertEq(address(strategy0.gateway()), gateway, "strategy0 unexpected gateway");
        assertEq(address(strategy0.mintController()), mintControllerA, "strategy0 unexpected mint controller");
        assertEq(address(strategy0.redeemController()), redeemControllerA, "strategy0 unexpected redeem controller");
        assertEq(address(strategy0.pricedTokenEthOracle()), address(iUsdUsdcOracleA), "strategy0 unexpected iUSD oracle");
        assertEq(strategy0.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS_A, "strategy0 unexpected max oracle staleness");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "SiUSD Mainnet USDC", "strategy0 unexpected name");

        SiUSDStrategy strategy1 = SiUSDStrategy(deployed[1]);
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.usdc()), address(assetToken), "strategy1 unexpected usdc");
        assertEq(address(strategy1.iUSD()), configs[1].iUSD, "strategy1 unexpected iUSD");
        assertEq(address(strategy1.siUSD()), configs[1].siUSD, "strategy1 unexpected siUSD");
        assertEq(address(strategy1.gateway()), configs[1].gateway, "strategy1 unexpected gateway");
        assertEq(address(strategy1.mintController()), configs[1].mintController, "strategy1 unexpected mint controller");
        assertEq(
            address(strategy1.redeemController()),
            configs[1].redeemController,
            "strategy1 unexpected redeem controller"
        );
        assertEq(address(strategy1.pricedTokenEthOracle()), configs[1].iUsdUsdcOracle, "strategy1 unexpected iUSD oracle");
        assertEq(strategy1.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS_B, "strategy1 unexpected max oracle staleness");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "SiUSD Alternate USDC", "strategy1 unexpected name");
    }

    function _buildParams(string memory name, string memory protocol)
        internal
        view
        returns (IMYTStrategy.StrategyParams memory)
    {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1_000e6,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
