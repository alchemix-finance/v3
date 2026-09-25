// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";
import {IBaseRewarder} from "../src/strategies/interfaces/ITokemac.sol";
import {BaseERC4626DeploymentScript} from "./BaseERC4626Deployment.s.sol";

interface ITokeRewarderStakingToken {
    function stakingToken() external view returns (address);
}

/// @notice Deploys the Tokemak baseUSD Autopool strategy on Base.
contract DeployTokeAutoUSDBaseStrategyScript is BaseERC4626DeploymentScript {
    error TokeRewarderStakingTokenMismatch(address rewarder, address expectedAutoVault, address actualStakingToken);
    error TokeRewarderRewardTokenMismatch(address rewarder, address expectedRewardToken, address actualRewardToken);

    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address public constant TOKE_BASE_USD_VAULT = 0x9c6864105AEC23388C89600046213a44C384c831;
    address public constant TOKE_BASE_USD_REWARDER = 0x4103A467166bbbDA3694AB739b391db6c6630595;
    address public constant TOKE_REWARDS_TOKEN = 0x223C0d94dbc8c0E5df1f6B2C75F06c0229c91950;
    address public constant AUTOPILOT_ROUTER = 0x4D2b87339b1f9e480aA84c770fa3604D7D40f8DF;
    uint256 public constant DEFAULT_EXEC_TOLERANCE_BPS = 25;

    struct TokeAutoUSDBaseDeployConfig {
        address myt;
        address asset;
        address autoVault;
        address rewarder;
        address tokeRewardsToken;
        address autopilotRouter;
        uint256 execToleranceBps;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "TokeAutoUSD Base",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1000e6,
            globalCap: 0.3e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function deployTokeAutoUSDBaseStrategy(address targetOwner, TokeAutoUSDBaseDeployConfig memory config) public returns (address strategyAddr) {
        // Chain, code and MYT<->autopool asset checks (autopool exposes ERC4626 asset()).
        address asset = _validateERC4626Deployment(targetOwner, config.myt, config.autoVault, config.params.owner);
        if (asset != config.asset) revert DeploymentAssetMismatch(config.myt, config.asset, asset);
        _validateTokeWiring(config);

        TokeAutoStrategy strategy = new TokeAutoStrategy(
            config.myt, config.params, config.asset, config.autoVault, config.rewarder, config.tokeRewardsToken, config.autopilotRouter, config.execToleranceBps
        );
        strategyAddr = address(strategy);

        // Seed lastGoodSharePrice from live Withdraw NAV while this script still owns
        // the adapter, before killSwitch / ownership transfer. Reverts if Tokemak's
        // report is unusable. Do not deploy into a frozen-at-zero cold start.
        strategy.snapshotSharePrice();
        // Keep allocation disabled until curator configuration and smoke tests are complete.
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        TokeAutoUSDBaseDeployConfig memory config = TokeAutoUSDBaseDeployConfig({
            myt: BASE_USDC_MYT,
            asset: USDC,
            autoVault: TOKE_BASE_USD_VAULT,
            rewarder: TOKE_BASE_USD_REWARDER,
            tokeRewardsToken: TOKE_REWARDS_TOKEN,
            autopilotRouter: AUTOPILOT_ROUTER,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: defaultParams()
        });

        _validateBaseAsset(newOwner, config.myt, config.autoVault, config.params.owner, USDC);

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployTokeAutoUSDBaseStrategy(newOwner, config);
        vm.stopBroadcast();

        console.log("TokeAutoStrategy baseUSD deployed at:", strategyAddr);
    }

    /// @dev Rewarder must stake exactly this autopool and pay the configured TOKE token; router must exist.
    function _validateTokeWiring(TokeAutoUSDBaseDeployConfig memory config) internal view {
        if (config.rewarder == address(0) || config.tokeRewardsToken == address(0) || config.autopilotRouter == address(0)) {
            revert ZeroDeploymentAddress();
        }
        if (config.rewarder.code.length == 0) revert DeploymentTargetHasNoCode(config.rewarder);
        if (config.autopilotRouter.code.length == 0) revert DeploymentTargetHasNoCode(config.autopilotRouter);
        if (config.tokeRewardsToken.code.length == 0) revert DeploymentTargetHasNoCode(config.tokeRewardsToken);

        address stakingToken = ITokeRewarderStakingToken(config.rewarder).stakingToken();
        if (stakingToken != config.autoVault) revert TokeRewarderStakingTokenMismatch(config.rewarder, config.autoVault, stakingToken);

        address rewardToken = IBaseRewarder(config.rewarder).rewardToken();
        if (rewardToken != config.tokeRewardsToken) revert TokeRewarderRewardTokenMismatch(config.rewarder, config.tokeRewardsToken, rewardToken);
    }
}
