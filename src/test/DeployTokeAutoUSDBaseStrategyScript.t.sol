// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BaseERC4626DeploymentScript} from "../../script/BaseERC4626Deployment.s.sol";
import {DeployTokeAutoUSDBaseStrategyScript, ITokeRewarderStakingToken} from "../../script/DeployTokeAutoUSDBaseStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IERC4626Like, TokeAutoStrategy} from "../strategies/TokeAutoStrategy.sol";
import {IBaseRewarder} from "../strategies/interfaces/ITokemac.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

contract DeployTokeAutoUSDBaseStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant BASE_NEW_OWNER = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address internal constant TOKE_BASE_USD_VAULT = 0x9c6864105AEC23388C89600046213a44C384c831;
    address internal constant TOKE_BASE_USD_REWARDER = 0x4103A467166bbbDA3694AB739b391db6c6630595;
    address internal constant BASE_TOKE = 0x223C0d94dbc8c0E5df1f6B2C75F06c0229c91950;
    address internal constant BASE_AUTOPILOT_ROUTER = 0x4D2b87339b1f9e480aA84c770fa3604D7D40f8DF;
    uint256 internal constant BASE_FORK_BLOCK = 51_788_600;
    uint256 internal constant DEFAULT_EXEC_TOLERANCE_BPS = 25;

    DeployTokeAutoUSDBaseStrategyScript internal deployScript;
    TestERC20 internal assetToken;
    MockMYTVault internal myt;

    address internal newOwner;
    address internal autoVault;
    address internal rewarder;
    address internal tokeRewardsToken;
    address internal autopilotRouter;

    function setUp() public {
        vm.chainId(8453);
        deployScript = new DeployTokeAutoUSDBaseStrategyScript();
        assetToken = new TestERC20(1_000_000e6, 6);
        myt = new MockMYTVault(address(this), address(assetToken));

        newOwner = makeAddr("newOwner");
        autoVault = makeAddr("autoVault");
        rewarder = makeAddr("rewarder");
        tokeRewardsToken = makeAddr("tokeRewardsToken");
        autopilotRouter = makeAddr("autopilotRouter");

        vm.etch(tokeRewardsToken, hex"01");
        vm.etch(autopilotRouter, hex"01");
        _mockUsableAutoVault(autoVault, rewarder, address(assetToken), tokeRewardsToken);
    }

    function test_deployTokeAutoUSDBaseStrategy_setsCoreAddressesAndDefaults() public {
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), autoVault);

        address strategyAddr = deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected asset");
        assertEq(address(strategy.autoVault()), autoVault, "unexpected autoVault");
        assertEq(address(strategy.rewarder()), rewarder, "unexpected rewarder");
        assertEq(strategy.tokeRewardsToken(), tokeRewardsToken, "unexpected rewards token");
        assertEq(address(strategy.autopilotRouter()), autopilotRouter, "unexpected autopilot router");
        assertEq(strategy.execToleranceBps(), DEFAULT_EXEC_TOLERANCE_BPS, "unexpected exec tolerance");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertEq(strategy.maxNavSpreadBps(), strategy.DEFAULT_MAX_NAV_SPREAD_BPS(), "unexpected nav spread default");
        assertEq(strategy.lastGoodSharePrice(), MYTStrategy(strategyAddr).FIXED_POINT_SCALAR(), "deploy must seed 1:1 PPS");
        assertEq(strategy.lastSnapshotAt(), block.timestamp, "deploy must stamp lastSnapshotAt");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");

        (, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass,,,,,) = strategy.params();
        assertEq(name, "TokeAutoUSD Base", "unexpected name");
        assertEq(protocol, "TokeAuto", "unexpected protocol");
        assertEq(uint256(riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
    }

    function test_deployTokeAutoUSDBaseStrategy_blocksForceDeallocateByDefault() public {
        address strategyAddr = deployScript.deployTokeAutoUSDBaseStrategy(newOwner, _config(address(myt), autoVault));
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(address(myt));
        strategy.deallocate(abi.encode(params), 1, IVaultV2.forceDeallocate.selector, address(myt));
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsOffBase() public {
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), autoVault);
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.InvalidBaseChain.selector, 1));
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsForMissingMYTCode() public {
        address missingMYT = makeAddr("missingMYT");
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(missingMYT, autoVault);

        vm.expectRevert(abi.encodeWithSelector(BaseERC4626DeploymentScript.DeploymentTargetHasNoCode.selector, missingMYT));
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsForAutoVaultAssetMismatch() public {
        TestERC20 otherAsset = new TestERC20(1_000_000e6, 6);
        address mismatchedVault = makeAddr("mismatchedVault");
        _mockUsableAutoVault(mismatchedVault, rewarder, address(otherAsset), tokeRewardsToken);
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), mismatchedVault);

        vm.expectRevert(
            abi.encodeWithSelector(BaseERC4626DeploymentScript.DeploymentAssetMismatch.selector, mismatchedVault, address(assetToken), address(otherAsset))
        );
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsForRewarderStakingTokenMismatch() public {
        address otherVault = makeAddr("otherVault");
        vm.mockCall(rewarder, abi.encodeWithSelector(ITokeRewarderStakingToken.stakingToken.selector), abi.encode(otherVault));
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), autoVault);

        vm.expectRevert(abi.encodeWithSelector(DeployTokeAutoUSDBaseStrategyScript.TokeRewarderStakingTokenMismatch.selector, rewarder, autoVault, otherVault));
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsForRewarderRewardTokenMismatch() public {
        address otherToken = makeAddr("otherToken");
        vm.mockCall(rewarder, abi.encodeWithSelector(IBaseRewarder.rewardToken.selector), abi.encode(otherToken));
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), autoVault);

        vm.expectRevert(
            abi.encodeWithSelector(DeployTokeAutoUSDBaseStrategyScript.TokeRewarderRewardTokenMismatch.selector, rewarder, tokeRewardsToken, otherToken)
        );
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_deployTokeAutoUSDBaseStrategy_revertsWhenReportUnusable() public {
        vm.mockCall(autoVault, abi.encodeWithSelector(IERC4626Like.oldestDebtReporting.selector), abi.encode(type(uint256).max));
        DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config = _config(address(myt), autoVault);

        vm.expectRevert(bytes("Report not usable"));
        deployScript.deployTokeAutoUSDBaseStrategy(newOwner, config);
    }

    function test_run_fork_deploysAgainstLiveBaseUSDAutopool() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")), BASE_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        // Live Tokemak wiring on Base must match the script constants before we deploy against it.
        assertEq(IERC4626(TOKE_BASE_USD_VAULT).asset(), BASE_USDC, "autopool asset mismatch");
        assertEq(IERC20Metadata(TOKE_BASE_USD_VAULT).symbol(), "baseUSD", "unexpected autopool symbol");
        assertEq(ITokeRewarderStakingToken(TOKE_BASE_USD_REWARDER).stakingToken(), TOKE_BASE_USD_VAULT, "rewarder stakes wrong vault");
        assertEq(IBaseRewarder(TOKE_BASE_USD_REWARDER).rewardToken(), BASE_TOKE, "rewarder pays wrong token");
        assertGt(BASE_AUTOPILOT_ROUTER.code.length, 0, "autopilot router has no code");
        assertEq(IVaultV2(BASE_USDC_MYT).asset(), BASE_USDC, "MYT asset mismatch");

        DeployTokeAutoUSDBaseStrategyScript forkDeployScript = new DeployTokeAutoUSDBaseStrategyScript();
        address strategyAddr = forkDeployScript.run();
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);
        IVaultV2 vault = IVaultV2(BASE_USDC_MYT);

        assertEq(address(strategy.MYT()), BASE_USDC_MYT, "unexpected MYT");
        assertEq(address(strategy.mytAsset()), BASE_USDC, "unexpected asset");
        assertEq(address(strategy.autoVault()), TOKE_BASE_USD_VAULT, "unexpected autoVault");
        assertEq(address(strategy.rewarder()), TOKE_BASE_USD_REWARDER, "unexpected rewarder");
        assertEq(strategy.tokeRewardsToken(), BASE_TOKE, "unexpected rewards token");
        assertEq(address(strategy.autopilotRouter()), BASE_AUTOPILOT_ROUTER, "unexpected autopilot router");
        assertEq(strategy.execToleranceBps(), forkDeployScript.DEFAULT_EXEC_TOLERANCE_BPS(), "unexpected exec tolerance");
        assertFalse(strategy.canForceDeallocate(), "force deallocate should default disabled");
        assertEq(strategy.maxNavSpreadBps(), strategy.DEFAULT_MAX_NAV_SPREAD_BPS(), "unexpected nav spread default");
        assertTrue(strategy.reportUsable(), "fork deploy requires a usable Tokemak report");
        assertGt(strategy.lastGoodSharePrice(), 0, "fork deploy must seed lastGoodSharePrice");
        assertEq(strategy.lastSnapshotAt(), block.timestamp, "fork deploy must stamp lastSnapshotAt");
        assertEq(strategy.owner(), BASE_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertFalse(vault.isAdapter(strategyAddr), "deploy script should not register strategy");
        assertEq(strategy.realAssets(), 0, "new strategy should have no assets");
    }

    function test_defaultParams_usesBaseTokeAutoUSDDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.newOwner(), BASE_NEW_OWNER, "unexpected final owner");
        assertEq(deployScript.USDC(), BASE_USDC, "unexpected USDC");
        assertEq(deployScript.BASE_USDC_MYT(), BASE_USDC_MYT, "unexpected USDC MYT");
        assertEq(deployScript.TOKE_BASE_USD_VAULT(), TOKE_BASE_USD_VAULT, "unexpected autoVault");
        assertEq(deployScript.TOKE_BASE_USD_REWARDER(), TOKE_BASE_USD_REWARDER, "unexpected rewarder");
        assertEq(deployScript.TOKE_REWARDS_TOKEN(), BASE_TOKE, "unexpected rewards token");
        assertEq(deployScript.AUTOPILOT_ROUTER(), BASE_AUTOPILOT_ROUTER, "unexpected autopilot router");
        assertEq(deployScript.DEFAULT_EXEC_TOLERANCE_BPS(), DEFAULT_EXEC_TOLERANCE_BPS, "unexpected exec tolerance");
        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(params.name, "TokeAutoUSD Base", "unexpected name");
        assertEq(params.protocol, "TokeAuto", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 1000e6, "unexpected cap");
        assertEq(params.globalCap, 0.3e18, "unexpected global cap");
        assertEq(params.estimatedYield, 750, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
    }

    function _mockUsableAutoVault(address vault_, address rewarder_, address asset_, address rewardToken_) internal {
        uint256 nav = 1e18;
        vm.etch(vault_, hex"01");
        vm.etch(rewarder_, hex"01");
        vm.mockCall(vault_, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(asset_));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC4626Like.oldestDebtReporting.selector), abi.encode(block.timestamp));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC4626Like.totalAssets.selector, IERC4626Like.TotalAssetPurpose.Deposit), abi.encode(nav));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC4626Like.totalAssets.selector, IERC4626Like.TotalAssetPurpose.Withdraw), abi.encode(nav));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1e18));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(0));
        vm.mockCall(vault_, abi.encodeWithSelector(IERC4626Like.convertToAssets.selector), abi.encode(1e18));
        vm.mockCall(rewarder_, abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(0));
        vm.mockCall(rewarder_, abi.encodeWithSelector(ITokeRewarderStakingToken.stakingToken.selector), abi.encode(vault_));
        vm.mockCall(rewarder_, abi.encodeWithSelector(IBaseRewarder.rewardToken.selector), abi.encode(rewardToken_));
    }

    function _config(address testMYT, address vault_) internal view returns (DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig memory config) {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);
        config = DeployTokeAutoUSDBaseStrategyScript.TokeAutoUSDBaseDeployConfig({
            myt: testMYT,
            asset: address(assetToken),
            autoVault: vault_,
            rewarder: rewarder,
            tokeRewardsToken: tokeRewardsToken,
            autopilotRouter: autopilotRouter,
            execToleranceBps: DEFAULT_EXEC_TOLERANCE_BPS,
            params: params
        });
    }
}
