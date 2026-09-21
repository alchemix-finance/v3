// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseERC4626DeploymentScript} from "../../script/BaseERC4626Deployment.s.sol";
import {DeployFluidUSDCBaseStrategyScript} from "../../script/DeployFluidUSDCBaseStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

contract DeployFluidUSDCBaseStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant BASE_NEW_OWNER = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant FLUID_USDC_VAULT = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
    address internal constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    uint256 internal constant BASE_FORK_BLOCK = 51_125_700;

    DeployFluidUSDCBaseStrategyScript internal deployScript;
    TestERC20 internal assetToken;
    ERC4626Mock internal targetVault;
    MockMYTVault internal myt;
    address internal newOwner;

    function setUp() public {
        vm.chainId(8453);
        deployScript = new DeployFluidUSDCBaseStrategyScript();
        assetToken = new TestERC20(1_000_000e6, 6);
        targetVault = new ERC4626Mock(address(assetToken));
        myt = new MockMYTVault(address(this), address(assetToken));
        newOwner = makeAddr("newOwner");
    }

    function test_deployFluidUSDCBaseStrategy_setsCoreAddressesAndSafetyDefaults() public {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);

        DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig memory config =
            DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig({myt: address(myt), fluidVault: address(targetVault), params: params});

        ERC4626Strategy strategy = ERC4626Strategy(deployScript.deployFluidUSDCBaseStrategy(newOwner, config));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(targetVault), "unexpected target vault");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");

        (, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(name, "Fluid USDC Base", "unexpected name");
        assertEq(protocol, "Fluid", "unexpected protocol");
        assertEq(uint256(riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
    }

    function test_deployFluidUSDCBaseStrategy_revertsOffBase() public {
        DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig memory config = _config(address(myt), address(targetVault));
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.InvalidBaseChain.selector, 1));
        deployScript.deployFluidUSDCBaseStrategy(newOwner, config);
    }

    function test_deployFluidUSDCBaseStrategy_revertsForMissingMYTCode() public {
        address missingMYT = makeAddr("missingMYT");
        DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig memory config = _config(missingMYT, address(targetVault));

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.DeploymentTargetHasNoCode.selector, missingMYT));
        deployScript.deployFluidUSDCBaseStrategy(newOwner, config);
    }

    function test_run_fork_deploysAgainstLiveBaseFluidVault() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")), BASE_FORK_BLOCK);

        vm.deal(DEPLOYER, 10 ether);

        DeployFluidUSDCBaseStrategyScript forkDeployScript = new DeployFluidUSDCBaseStrategyScript();
        ERC4626Strategy strategy = ERC4626Strategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), BASE_USDC_MYT, "unexpected MYT");
        assertEq(address(strategy.mytAsset()), BASE_USDC, "unexpected MYT asset");
        assertEq(address(strategy.vault()), FLUID_USDC_VAULT, "unexpected target vault");
        assertEq(IERC4626(FLUID_USDC_VAULT).asset(), BASE_USDC, "target vault asset mismatch");
        assertEq(IERC20Metadata(FLUID_USDC_VAULT).symbol(), "fUSDC", "unexpected fToken symbol");
        assertEq(strategy.owner(), BASE_NEW_OWNER, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");
        assertEq(strategy.realAssets(), 0, "new strategy should have no assets");
    }

    function test_defaultParams_usesBaseFluidDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(deployScript.newOwner(), BASE_NEW_OWNER, "unexpected final owner");
        assertEq(deployScript.USDC(), BASE_USDC, "unexpected USDC");
        assertEq(deployScript.FLUID_USDC_VAULT(), FLUID_USDC_VAULT, "unexpected target vault");
        assertEq(params.name, "Fluid USDC Base", "unexpected name");
        assertEq(params.protocol, "Fluid", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 10_000e6, "unexpected cap");
        assertEq(params.globalCap, 0.25e18, "unexpected global cap");
        assertEq(params.estimatedYield, 489, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }

    function _config(address testMYT, address vault) internal view returns (DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig memory config) {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);
        config = DeployFluidUSDCBaseStrategyScript.FluidUSDCBaseDeployConfig({myt: testMYT, fluidVault: vault, params: params});
    }
}
