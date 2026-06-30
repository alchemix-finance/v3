// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployTokeAutoUSDStrategyScript} from "../../script/DeployTokeAutoUSDStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {TokeAutoStrategy} from "../strategies/TokeAutoStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockMYTForTokeAutoUSDDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployTokeAutoUSDStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address internal constant MAINNET_TOKE_AUTO_USD_REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    address internal constant MAINNET_TOKE_REWARDS_TOKEN = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    address internal constant MAINNET_AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant USDC_MYT = 0x9B44efCa3e2a707B63Dc00CE79d646E5E5D24bA5;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_311_321;
    uint256 internal constant DEFAULT_EXEC_TOLERANCE_BPS = 25;

    DeployTokeAutoUSDStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForTokeAutoUSDDeployTest internal myt;

    address internal newOwner;
    address internal autoVault;
    address internal rewarder;
    address internal tokeRewardsToken;
    address internal autopilotRouter;

    function setUp() public {
        deployScript = new DeployTokeAutoUSDStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e6, 6);
        myt = new MockMYTForTokeAutoUSDDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        autoVault = makeAddr("autoVault");
        rewarder = makeAddr("rewarder");
        tokeRewardsToken = makeAddr("tokeRewardsToken");
        autopilotRouter = makeAddr("autopilotRouter");
    }

    function test_deployTokeAutoUSDStrategy_setsCoreAddressesAndDefaults() public {
        DeployTokeAutoUSDStrategyScript.TokeAutoUSDDeployConfig memory config = DeployTokeAutoUSDStrategyScript.TokeAutoUSDDeployConfig({
            myt: address(myt),
            asset: address(assetToken),
            autoVault: autoVault,
            rewarder: rewarder,
            tokeRewardsToken: tokeRewardsToken,
            autopilotRouter: autopilotRouter,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: _buildParams("TokeAutoUSD Mainnet", "TokeAuto")
        });

        address strategyAddr = deployScript.deployTokeAutoUSDStrategy(curator, newOwner, config);
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected asset");
        assertEq(address(strategy.autoVault()), autoVault, "unexpected autoVault");
        assertEq(address(strategy.rewarder()), rewarder, "unexpected rewarder");
        assertEq(strategy.tokeRewardsToken(), tokeRewardsToken, "unexpected rewards token");
        assertEq(address(strategy.autopilotRouter()), autopilotRouter, "unexpected autopilot router");
        assertEq(strategy.execToleranceBps(), DEFAULT_EXEC_TOLERANCE_BPS, "unexpected exec tolerance");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "TokeAutoUSD Mainnet", "unexpected strategy name");
        assertEq(protocol, "TokeAuto", "unexpected protocol");
    }

    function test_deployTokeAutoUSDStrategy_blocksForceDeallocateByDefault() public {
        DeployTokeAutoUSDStrategyScript.TokeAutoUSDDeployConfig memory config = DeployTokeAutoUSDStrategyScript.TokeAutoUSDDeployConfig({
            myt: address(myt),
            asset: address(assetToken),
            autoVault: autoVault,
            rewarder: rewarder,
            tokeRewardsToken: tokeRewardsToken,
            autopilotRouter: autopilotRouter,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: _buildParams("TokeAutoUSD Mainnet", "TokeAuto")
        });

        address strategyAddr = deployScript.deployTokeAutoUSDStrategy(curator, newOwner, config);
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(address(myt));
        strategy.deallocate(abi.encode(params), 1, IVaultV2.forceDeallocate.selector, address(myt));
    }

    function test_run_fork_deploysTokeAutoUSDWithMainnetDefaults() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployTokeAutoUSDStrategyScript forkDeployScript = new DeployTokeAutoUSDStrategyScript();
        address strategyAddr = forkDeployScript.run();
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);
        IVaultV2 vault = IVaultV2(USDC_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        assertEq(address(strategy.MYT()), USDC_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_USDC, "unexpected MYT asset");
        assertEq(address(strategy.mytAsset()), MAINNET_USDC, "unexpected asset");
        assertEq(address(strategy.autoVault()), MAINNET_TOKE_AUTO_USD_VAULT, "unexpected autoVault");
        assertEq(address(strategy.rewarder()), MAINNET_TOKE_AUTO_USD_REWARDER, "unexpected rewarder");
        assertEq(strategy.tokeRewardsToken(), MAINNET_TOKE_REWARDS_TOKEN, "unexpected rewards token");
        assertEq(address(strategy.autopilotRouter()), MAINNET_AUTOPILOT_ROUTER, "unexpected autopilot router");
        assertEq(strategy.execToleranceBps(), forkDeployScript.DEFAULT_EXEC_TOLERANCE_BPS(), "unexpected exec tolerance");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(vault.isAdapter(strategyAddr), "deploy script should not register strategy");
        assertEq(params.name, "TokeAutoUSD Mainnet", "unexpected name");
        assertEq(params.protocol, "TokeAuto", "unexpected protocol");
    }

    function test_defaultParams_usesMainnetTokeAutoUSDDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), CURATOR_ADDR, "unexpected curator");
        assertEq(deployScript.usdcMYT(), USDC_MYT, "unexpected USDC MYT");
        assertEq(deployScript.USDC(), MAINNET_USDC, "unexpected USDC");
        assertEq(deployScript.TOKE_AUTO_USD_VAULT(), MAINNET_TOKE_AUTO_USD_VAULT, "unexpected autoVault");
        assertEq(deployScript.TOKE_AUTO_USD_REWARDER(), MAINNET_TOKE_AUTO_USD_REWARDER, "unexpected rewarder");
        assertEq(deployScript.TOKE_REWARDS_TOKEN(), MAINNET_TOKE_REWARDS_TOKEN, "unexpected rewards token");
        assertEq(deployScript.AUTOPILOT_ROUTER(), MAINNET_AUTOPILOT_ROUTER, "unexpected autopilot router");
        assertEq(deployScript.DEFAULT_EXEC_TOLERANCE_BPS(), DEFAULT_EXEC_TOLERANCE_BPS, "unexpected exec tolerance");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "TokeAutoUSD Mainnet", "unexpected name");
        assertEq(params.protocol, "TokeAuto", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 1000e6, "unexpected cap");
        assertEq(params.globalCap, 0.3e18, "unexpected global cap");
        assertEq(params.estimatedYield, 750, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }

    function _buildParams(string memory name, string memory protocol) internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1000e6,
            globalCap: 0.3e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
