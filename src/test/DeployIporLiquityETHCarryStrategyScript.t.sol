// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {DeployIporLiquityETHCarryStrategyScript} from "../../script/DeployIporLiquityETHCarryStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IporFusionStrategy} from "../strategies/IporFusionStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForIporDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract MockIporWithdrawManager {
    address public plasmaVault;
    uint256 public withdrawFee;

    constructor(address _plasmaVault, uint256 _withdrawFee) {
        plasmaVault = _plasmaVault;
        withdrawFee = _withdrawFee;
    }

    function getPlasmaVaultAddress() external view returns (address) {
        return plasmaVault;
    }

    function getWithdrawFee() external view returns (uint256) {
        return withdrawFee;
    }

    function getSharesToRelease() external pure returns (uint256) {
        return 0;
    }
}

contract DeployIporLiquityETHCarryStrategyScriptTest is Test {
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant MAINNET_FORK_BLOCK = 26_094_670;

    DeployIporLiquityETHCarryStrategyScript internal deployScript;
    TestERC20 internal weth;
    ERC4626Mock internal plasmaVault;
    MockIporWithdrawManager internal withdrawManager;
    MockMYTForIporDeployTest internal myt;
    address internal newOwner;

    function setUp() public {
        deployScript = new DeployIporLiquityETHCarryStrategyScript();
        weth = new TestERC20(1_000_000e18, 18);
        plasmaVault = new ERC4626Mock(address(weth));
        withdrawManager = new MockIporWithdrawManager(address(plasmaVault), 2e15);
        myt = new MockMYTForIporDeployTest(address(weth));
        newOwner = makeAddr("newOwner");
    }

    function _localConfig() internal view returns (DeployIporLiquityETHCarryStrategyScript.IporDeployConfig memory config) {
        config = deployScript.defaultConfig();
        config.myt = address(myt);
        config.plasmaVault = address(plasmaVault);
        config.withdrawManager = address(withdrawManager);
        config.params.owner = address(deployScript);
    }

    function test_deployIporStrategy_setsCoreAddressesAndDefaults() public {
        IporFusionStrategy strategy = IporFusionStrategy(deployScript.deployIporStrategy(newOwner, _localConfig()));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), address(weth), "unexpected MYT asset");
        assertEq(address(strategy.vault()), address(plasmaVault), "unexpected PlasmaVault");
        assertEq(address(strategy.withdrawManager()), address(withdrawManager), "unexpected WithdrawManager");
        assertEq(strategy.maxWithdrawFee(), deployScript.MAX_WITHDRAW_FEE(), "unexpected maxWithdrawFee");
        assertEq(strategy.redeemBufferBps(), deployScript.REDEEM_BUFFER_BPS(), "unexpected redeemBufferBps");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");

        (, string memory name, string memory protocol,,,,,,) = strategy.params();
        assertEq(name, "IPOR Fusion Liquity ETH Carry", "unexpected strategy name");
        assertEq(protocol, "IPOR Fusion", "unexpected protocol");
    }

    function test_deployIporStrategy_reverts_whenWithdrawManagerTargetsOtherVault() public {
        DeployIporLiquityETHCarryStrategyScript.IporDeployConfig memory config = _localConfig();
        config.withdrawManager = address(new MockIporWithdrawManager(address(0xBEEF), 2e15));

        vm.expectRevert(
            abi.encodeWithSelector(IporFusionStrategy.WithdrawManagerVaultMismatch.selector, address(plasmaVault), address(0xBEEF))
        );
        deployScript.deployIporStrategy(newOwner, config);
    }

    function test_run_fork_deploysWithMainnetDefaults() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(deployScript.deployerAddr(), 10 ether);

        DeployIporLiquityETHCarryStrategyScript forkDeployScript = new DeployIporLiquityETHCarryStrategyScript();
        IporFusionStrategy strategy = IporFusionStrategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), forkDeployScript.ethMYT(), "unexpected MYT");
        assertEq(address(strategy.mytAsset()), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.vault()), forkDeployScript.IPOR_PLASMA_VAULT(), "unexpected PlasmaVault");
        assertEq(address(strategy.withdrawManager()), forkDeployScript.IPOR_WITHDRAW_MANAGER(), "unexpected WithdrawManager");
        assertEq(strategy.owner(), forkDeployScript.newOwner(), "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertEq(strategy.currentWithdrawFee(), 2e15, "live withdraw fee should be 0.2%");
        assertLe(strategy.currentWithdrawFee(), strategy.maxWithdrawFee(), "live fee must be within guard");
    }

    function test_defaultParams_usesMainnetDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(params.owner, deployScript.deployerAddr(), "unexpected owner");
        assertEq(params.name, "IPOR Fusion Liquity ETH Carry", "unexpected name");
        assertEq(params.protocol, "IPOR Fusion", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.cap, 100e18, "unexpected cap");
        assertEq(params.globalCap, 0.1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 300, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 20, "unexpected slippage");
    }
}
