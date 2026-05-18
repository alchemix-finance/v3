// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {SiUSDStrategy} from "../src/strategies/SiUSDStrategy.sol";

/// @notice Reusable deploy helper for the InfiniFi siUSD strategy on Ethereum mainnet.
contract DeploySiUSDStrategiesScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public usdcMYT = address(0);

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;
    address public constant GATEWAY = 0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;
    address public constant MINT_CONTROLLER = 0x49877d937B9a00d50557bdC3D87287b5c3a4C256;
    address public constant REDEEM_CONTROLLER = 0xCb1747E89a43DEdcF4A2b831a0D94859EFeC7601;

    // TODO: replace with the live mainnet iUSD/USDC oracle before broadcasting.
    address public iUsdUsdcOracle = address(0);
    uint256 public maxOracleStaleness = 365 days;

    struct SiUSDDeployConfig {
        address myt;
        address usdc;
        address iUSD;
        address siUSD;
        address gateway;
        address mintController;
        address redeemController;
        address iUsdUsdcOracle;
        uint256 maxOracleStaleness;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "SiUSD Mainnet USDC",
            protocol: "InfiniFi",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deploySiUSDStrategy(
        AlchemistCurator curator,
        address targetOwner,
        SiUSDDeployConfig memory config
    ) public returns (address strategyAddr) {
        SiUSDStrategy strategy = new SiUSDStrategy(
            config.myt,
            config.params,
            config.usdc,
            config.iUSD,
            config.siUSD,
            config.gateway,
            config.mintController,
            config.redeemController,
            config.iUsdUsdcOracle,
            config.maxOracleStaleness
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function deployBatch(
        AlchemistCurator curator,
        address targetOwner,
        SiUSDDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deploySiUSDStrategy(curator, targetOwner, configs[i]);
        }
    }

    function run() public returns (address strategyAddr) {
        require(usdcMYT != address(0), "Set usdcMYT");
        require(iUsdUsdcOracle != address(0), "Set iUsdUsdcOracle");

        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        SiUSDDeployConfig memory config = SiUSDDeployConfig({
            myt: usdcMYT,
            usdc: USDC,
            iUSD: IUSD,
            siUSD: SIUSD,
            gateway: GATEWAY,
            mintController: MINT_CONTROLLER,
            redeemController: REDEEM_CONTROLLER,
            iUsdUsdcOracle: iUsdUsdcOracle,
            maxOracleStaleness: maxOracleStaleness,
            params: defaultParams()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deploySiUSDStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("SiUSDStrategy deployed at:", strategyAddr);
    }
}
