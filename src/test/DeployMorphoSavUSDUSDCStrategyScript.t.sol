// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployMorphoSavUSDUSDCStrategyScript} from "../../script/DeployMorphoSavUSDUSDCStrategy.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MorphoBlueMarketStrategy} from "../strategies/MorphoBlueMarketStrategy.sol";
import {IMorphoBlue, MarketParams} from "../strategies/interfaces/IMorphoBlue.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

contract DeployMorphoSavUSDUSDCStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant BASE_NEW_OWNER = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDC_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 internal constant MARKET_ID = 0x4217fed63c853537fb818f4ba4416bc708c3d7534913532feb34c3511ce2aba6;
    uint256 internal constant BASE_FORK_BLOCK = 53_930_000;

    DeployMorphoSavUSDUSDCStrategyScript internal deployScript;

    function setUp() public {
        deployScript = new DeployMorphoSavUSDUSDCStrategyScript();
    }

    function test_defaultParams_usesExpectedDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        MarketParams memory mp = deployScript.defaultMarketParams();

        assertEq(params.owner, DEPLOYER, "unexpected owner");
        assertEq(deployScript.newOwner(), BASE_NEW_OWNER, "unexpected final owner");
        assertEq(params.name, "Morpho savUSD/USDC Market", "unexpected name");
        assertEq(params.protocol, "Morpho Blue", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.HIGH), "unexpected risk class");
        assertEq(params.cap, 10_000e6, "unexpected cap");
        assertEq(params.globalCap, 0.1e18, "unexpected global cap");
        assertEq(params.slippageBPS, 50, "unexpected slippage");
        assertTrue(params.additionalIncentives, "market pays Merkl incentives");

        assertEq(mp.loanToken, BASE_USDC, "unexpected loan token");
        assertEq(keccak256(abi.encode(mp)), MARKET_ID, "market params do not hash to the target market id");
    }

    function test_deploy_revertsOffBase() public {
        vm.chainId(1);
        DeployMorphoSavUSDUSDCStrategyScript.MorphoMarketDeployConfig memory config = _localConfig();
        vm.expectRevert(abi.encodeWithSelector(DeployMorphoSavUSDUSDCStrategyScript.InvalidBaseChain.selector, 1));
        deployScript.deployMorphoMarketStrategy(BASE_NEW_OWNER, config);
    }

    function test_deploy_revertsForMissingMYTCode() public {
        vm.chainId(8453);
        DeployMorphoSavUSDUSDCStrategyScript.MorphoMarketDeployConfig memory config = _localConfig();
        config.myt = makeAddr("missingMYT");
        vm.expectRevert(abi.encodeWithSelector(DeployMorphoSavUSDUSDCStrategyScript.DeploymentTargetHasNoCode.selector, config.myt));
        deployScript.deployMorphoMarketStrategy(BASE_NEW_OWNER, config);
    }

    function test_deploy_revertsForLoanTokenMismatch() public {
        vm.chainId(8453);
        DeployMorphoSavUSDUSDCStrategyScript.MorphoMarketDeployConfig memory config = _localConfig();
        TestERC20 other = new TestERC20(1e18, 18);
        config.marketParams.loanToken = address(other);
        vm.expectRevert(
            abi.encodeWithSelector(DeployMorphoSavUSDUSDCStrategyScript.DeploymentAssetMismatch.selector, address(_asset(config.myt)), address(other))
        );
        deployScript.deployMorphoMarketStrategy(BASE_NEW_OWNER, config);
    }

    function test_run_fork_deploysAgainstLiveBaseMarket() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")), BASE_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployMorphoSavUSDUSDCStrategyScript forkDeployScript = new DeployMorphoSavUSDUSDCStrategyScript();
        MorphoBlueMarketStrategy strategy = MorphoBlueMarketStrategy(forkDeployScript.run());

        assertEq(address(strategy.MYT()), BASE_USDC_MYT, "unexpected MYT");
        assertEq(address(strategy.mytAsset()), BASE_USDC, "unexpected MYT asset");
        assertEq(address(strategy.morpho()), MORPHO_BLUE, "unexpected morpho");
        assertEq(strategy.marketId(), MARKET_ID, "unexpected market id");
        assertGt(IMorphoBlue(MORPHO_BLUE).market(MARKET_ID).lastUpdate, 0, "market should exist");
        assertEq(strategy.owner(), BASE_NEW_OWNER, "unexpected owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertFalse(strategy.canForceDeallocate(), "force deallocation should default disabled");
        assertEq(strategy.realAssets(), 0, "new strategy should have no assets");
        assertGt(strategy.availableLiquidity(), 0, "market should have withdrawable liquidity");
    }

    /// @dev Local config with a mock MYT; the morpho address only needs code for validation to pass.
    function _localConfig() internal returns (DeployMorphoSavUSDUSDCStrategyScript.MorphoMarketDeployConfig memory config) {
        TestERC20 assetToken = new TestERC20(1_000_000e6, 6);
        MockMYTVault myt = new MockMYTVault(address(this), address(assetToken));
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();
        params.owner = address(deployScript);
        MarketParams memory mp = deployScript.defaultMarketParams();
        mp.loanToken = address(assetToken);
        config = DeployMorphoSavUSDUSDCStrategyScript.MorphoMarketDeployConfig({
            myt: address(myt),
            morpho: address(this),
            marketParams: mp,
            params: params
        });
    }

    function _asset(address myt) internal view returns (address) {
        return MockMYTVault(myt).asset();
    }
}
