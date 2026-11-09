// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {MorphoBlueMarketStrategy} from "../src/strategies/MorphoBlueMarketStrategy.sol";
import {MarketParams} from "../src/strategies/interfaces/IMorphoBlue.sol";

/// @notice Deploys a direct USDC lending strategy on the Morpho Blue savUSD/USDC (91.5% LLTV) market on Base.
contract DeployMorphoSavUSDUSDCStrategyScript is Script {
    uint256 public constant BASE_CHAIN_ID = 8453;

    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address public constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    address public constant SAVUSD = 0xa6EF20FE18CD529cA15A8a53A29D1832B1F848ff;
    address public constant SAVUSD_USDC_ORACLE = 0xFfa96076474A6e5A8dC481D40109cF1626cfe4A4;
    address public constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 public constant LLTV = 0.915e18;
    bytes32 public constant MARKET_ID = 0x4217fed63c853537fb818f4ba4416bc708c3d7534913532feb34c3511ce2aba6;

    error InvalidBaseChain(uint256 actualChainId);
    error ZeroDeploymentAddress();
    error DeploymentTargetHasNoCode(address target);
    error DeploymentAssetMismatch(address expectedAsset, address actualAsset);
    error MarketIdMismatch(bytes32 expected, bytes32 actual);

    struct MorphoMarketDeployConfig {
        address myt;
        address morpho;
        MarketParams marketParams;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Morpho savUSD/USDC Market",
            protocol: "Morpho Blue",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 645,
            additionalIncentives: true,
            slippageBPS: 50
        });
    }

    function defaultMarketParams() public pure returns (MarketParams memory) {
        return MarketParams({loanToken: USDC, collateralToken: SAVUSD, oracle: SAVUSD_USDC_ORACLE, irm: ADAPTIVE_CURVE_IRM, lltv: LLTV});
    }

    function deployMorphoMarketStrategy(address targetOwner, MorphoMarketDeployConfig memory config) public returns (address strategyAddr) {
        _validateDeployment(targetOwner, config);

        MorphoBlueMarketStrategy strategy = new MorphoBlueMarketStrategy(config.myt, config.params, config.morpho, config.marketParams);
        strategyAddr = address(strategy);

        // Keep allocation disabled until curator configuration and smoke tests are complete.
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        MorphoMarketDeployConfig memory config =
            MorphoMarketDeployConfig({myt: BASE_USDC_MYT, morpho: MORPHO_BLUE, marketParams: defaultMarketParams(), params: defaultParams()});

        bytes32 actualId = keccak256(abi.encode(config.marketParams));
        if (actualId != MARKET_ID) revert MarketIdMismatch(MARKET_ID, actualId);
        if (IERC4626(config.myt).asset() != USDC) revert DeploymentAssetMismatch(USDC, IERC4626(config.myt).asset());

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployMorphoMarketStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("Morpho savUSD/USDC MorphoBlueMarketStrategy deployed at:", strategyAddr);
    }

    function _validateDeployment(address targetOwner, MorphoMarketDeployConfig memory config) internal view {
        if (block.chainid != BASE_CHAIN_ID) revert InvalidBaseChain(block.chainid);
        if (targetOwner == address(0) || config.myt == address(0) || config.morpho == address(0) || config.params.owner == address(0)) {
            revert ZeroDeploymentAddress();
        }
        if (config.myt.code.length == 0) revert DeploymentTargetHasNoCode(config.myt);
        if (config.morpho.code.length == 0) revert DeploymentTargetHasNoCode(config.morpho);

        address asset = IERC4626(config.myt).asset();
        if (asset == address(0)) revert ZeroDeploymentAddress();
        if (asset.code.length == 0) revert DeploymentTargetHasNoCode(asset);
        if (config.marketParams.loanToken != asset) revert DeploymentAssetMismatch(asset, config.marketParams.loanToken);
    }
}
