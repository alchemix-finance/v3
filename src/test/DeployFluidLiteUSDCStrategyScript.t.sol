// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {DeployFluidLiteUSDCStrategyScript} from "../../script/DeployFluidLiteUSDCStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockMYTForFluidLiteDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeployFluidLiteUSDCStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_FLUID_LITE_VAULT = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant USDC_MYT = 0x9B44efCa3e2a707B63Dc00CE79d646E5E5D24bA5;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_311_321;

    DeployFluidLiteUSDCStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    ERC4626Mock internal mockVault;
    MockMYTForFluidLiteDeployTest internal myt;

    address internal newOwner;

    function setUp() public {
        deployScript = new DeployFluidLiteUSDCStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e6, 6);
        mockVault = new ERC4626Mock(address(assetToken));
        myt = new MockMYTForFluidLiteDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
    }

    function test_deployFluidLiteUSDCStrategy_setsCoreAddressesAndDefaults() public {
        DeployFluidLiteUSDCStrategyScript.FluidLiteUSDCDeployConfig memory config =
            DeployFluidLiteUSDCStrategyScript.FluidLiteUSDCDeployConfig({
                myt: address(myt),
                fluidLiteVault: address(mockVault),
                params: _buildParams("Fluid Lite Mainnet USDC", "FluidLite")
            });

        address strategyAddr = deployScript.deployFluidLiteUSDCStrategy(curator, newOwner, config);
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected asset");
        assertEq(address(strategy.vault()), address(mockVault), "unexpected Fluid Lite vault");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(strategyName, "Fluid Lite Mainnet USDC", "unexpected strategy name");
        assertEq(protocol, "FluidLite", "unexpected protocol");
        assertEq(uint256(riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
    }

    function test_run_fork_deploysFluidLiteWithMainnetDefaults() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployFluidLiteUSDCStrategyScript forkDeployScript = new DeployFluidLiteUSDCStrategyScript();
        address strategyAddr = forkDeployScript.run();
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);
        IVaultV2 vault = IVaultV2(USDC_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        assertEq(address(strategy.MYT()), USDC_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_USDC, "unexpected MYT asset");
        assertEq(address(strategy.mytAsset()), MAINNET_USDC, "unexpected asset");
        assertEq(address(strategy.vault()), MAINNET_FLUID_LITE_VAULT, "unexpected Fluid Lite vault");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(vault.isAdapter(strategyAddr), "deploy script should not register strategy");
        assertEq(params.name, "Fluid Lite Mainnet USDC", "unexpected name");
        assertEq(params.protocol, "FluidLite", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
    }

    function test_defaultParams_usesMainnetFluidLiteDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), CURATOR_ADDR, "unexpected curator");
        assertEq(deployScript.usdcMYT(), USDC_MYT, "unexpected USDC MYT");
        assertEq(deployScript.USDC(), MAINNET_USDC, "unexpected USDC");
        assertEq(deployScript.FLUID_LITE_USDC_VAULT(), MAINNET_FLUID_LITE_VAULT, "unexpected Fluid Lite vault");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "Fluid Lite Mainnet USDC", "unexpected name");
        assertEq(params.protocol, "FluidLite", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.cap, 1000e6, "unexpected cap");
        assertEq(params.globalCap, 0.1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 680, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 100, "unexpected slippage");
    }

    function _buildParams(string memory name, string memory protocol) internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 1000e6,
            globalCap: 0.1e18,
            estimatedYield: 680,
            additionalIncentives: false,
            slippageBPS: 100
        });
    }
}
