// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseERC4626DeploymentScript} from "../../script/BaseERC4626Deployment.s.sol";
import {DeployGauntletUSDCFrontierStrategyScript} from "../../script/DeployGauntletUSDCFrontierStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

contract DeployGauntletUSDCFrontierStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant BASE_NEW_OWNER = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant GAUNTLET_USDC_FRONTIER_VAULT = 0x1deEfABEe758AAbdC29a542B24ca3b75aFD56765;
    uint256 internal constant BASE_FORK_BLOCK = 50_828_803;

    DeployGauntletUSDCFrontierStrategyScript internal deployScript;
    TestERC20 internal assetToken;
    ERC4626Mock internal targetVault;
    MockMYTVault internal myt;
    address internal newOwner;

    function setUp() public {
        vm.chainId(8453);
        deployScript = new DeployGauntletUSDCFrontierStrategyScript();
        assetToken = new TestERC20(1_000_000e6, 6);
        targetVault = new ERC4626Mock(address(assetToken));
        myt = new MockMYTVault(address(this), address(assetToken));
        newOwner = makeAddr("newOwner");
    }

    function test_deployGauntletUSDCFrontierStrategy_setsCoreAddressesAndSafetyDefaults() public {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig memory config =
            DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig({myt: address(myt), gauntletVault: address(targetVault), params: params});

        ERC4626Strategy strategy = ERC4626Strategy(deployScript.deployGauntletUSDCFrontierStrategy(newOwner, config));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(targetVault), "unexpected target vault");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");

        (, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(name, "Gauntlet USDC Frontier", "unexpected name");
        assertEq(protocol, "Morpho V2", "unexpected protocol");
        assertEq(uint256(riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
    }

    function test_deployGauntletUSDCFrontierStrategy_revertsOffBase() public {
        DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig memory config = _config(address(myt), address(targetVault));
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.InvalidBaseChain.selector, 1));
        deployScript.deployGauntletUSDCFrontierStrategy(newOwner, config);
    }

    function test_deployGauntletUSDCFrontierStrategy_revertsForMissingMYTCode() public {
        address missingMYT = makeAddr("missingMYT");
        DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig memory config = _config(missingMYT, address(targetVault));

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.DeploymentTargetHasNoCode.selector, missingMYT));
        deployScript.deployGauntletUSDCFrontierStrategy(newOwner, config);
    }

    function test_run_fork_deploysAgainstLiveBaseGauntletVault() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")), BASE_FORK_BLOCK);

        MockMYTVault forkMYT = new MockMYTVault(address(this), BASE_USDC);
        vm.setEnv("BASE_USDC_MYT", vm.toString(address(forkMYT)));
        vm.deal(DEPLOYER, 10 ether);

        DeployGauntletUSDCFrontierStrategyScript forkDeployScript = new DeployGauntletUSDCFrontierStrategyScript();
        ERC4626Strategy strategy = ERC4626Strategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), address(forkMYT), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), BASE_USDC, "unexpected MYT asset");
        assertEq(address(strategy.vault()), GAUNTLET_USDC_FRONTIER_VAULT, "unexpected target vault");
        assertEq(IERC4626(GAUNTLET_USDC_FRONTIER_VAULT).asset(), BASE_USDC, "target vault asset mismatch");
        assertEq(strategy.owner(), BASE_NEW_OWNER, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");
        assertEq(strategy.realAssets(), 0, "new strategy should have no assets");
    }

    function test_defaultParams_usesBaseGauntletDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(deployScript.newOwner(), BASE_NEW_OWNER, "unexpected final owner");
        assertEq(deployScript.USDC(), BASE_USDC, "unexpected USDC");
        assertEq(deployScript.GAUNTLET_USDC_FRONTIER_VAULT(), GAUNTLET_USDC_FRONTIER_VAULT, "unexpected target vault");
        assertEq(params.name, "Gauntlet USDC Frontier", "unexpected name");
        assertEq(params.protocol, "Morpho V2", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.cap, 10_000e6, "unexpected cap");
        assertEq(params.globalCap, 0.1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 483, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 100, "unexpected slippage");
    }

    function _config(address testMYT, address vault)
        internal
        view
        returns (DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig memory config)
    {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);
        config = DeployGauntletUSDCFrontierStrategyScript.GauntletUSDCFrontierDeployConfig({myt: testMYT, gauntletVault: vault, params: params});
    }
}
