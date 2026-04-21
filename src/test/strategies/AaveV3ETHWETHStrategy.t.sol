// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../../AlchemistV3PositionRenderer.sol";
import {Transmuter} from "../../Transmuter.sol";
import {AaveStrategy} from "../../strategies/AaveStrategy.sol";
import {WstethStrategy} from "../../strategies/WStethStrategy.sol";
import {MYTTokenSwapper, IFluidATokenSwap} from "../../MYTTokenSwapper.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAlchemistV3Errors, AlchemistInitializationParams} from "../../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {AlchemistNFTHelper} from "../libraries/AlchemistNFTHelper.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockRewardsControllerETH {
    IERC20 public immutable rewardToken;
    uint256 public immutable rewardAmount;

    constructor(address _rewardToken, uint256 _rewardAmount) {
        rewardToken = IERC20(_rewardToken);
        rewardAmount = _rewardAmount;
    }

    function claimAllRewardsToSelf(address[] calldata)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        rewardToken.transfer(msg.sender, rewardAmount);
        rewardsList = new address[](1);
        rewardsList[0] = address(rewardToken);
        claimedAmounts = new uint256[](1);
        claimedAmounts[0] = rewardAmount;
    }
}

contract MockSwapExecutorETH {
    IERC20 public immutable token;
    uint256 public amountToTransfer;

    constructor(address _token, uint256 _amountToTransfer) {
        token = IERC20(_token);
        amountToTransfer = _amountToTransfer;
    }

    receive() external payable {}

    fallback() external {
        token.transfer(msg.sender, amountToTransfer);
    }
}

contract MockATokenDrainHelper {
    function drain(address token, address from, address to, uint256 amount) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}

contract AaveV3ETHWETHStrategyTest is BaseStrategyTest {
    address public constant AAVE_V3_ETH_WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address public constant AAVE_V3_ETH_WSTETH_ATOKEN = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address public constant AAVE_V3_ETH_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address public constant FLUID_A_TOKEN_SWAP = 0x4f8f03caD7512E4F6d1050FB9b2F8b91aE4bC901;
    address public constant REWARD_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;
    bytes4 internal constant ALLOWED_AAVE_REVERT_SELECTOR = 0x2c5211c6;

    struct LocalAlchemistStack {
        AlchemistV3 alchemist;
        AlchemicTokenV3 debtToken;
        Transmuter transmuter;
        AlchemistV3Position positionNft;
    }

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "AaveV3ETHWETH",
            protocol: "AaveV3ETHWETH",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new AaveStrategy(vault, params, WETH, AAVE_V3_ETH_WETH_ATOKEN, AAVE_V3_ETH_POOL_ADDRESS_PROVIDER, REWARDS_CONTROLLER, REWARD_TOKEN)
        );
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;

        if (!isFuzzOrHandler) return false;
        return selector == ALLOWED_AAVE_REVERT_SELECTOR || selector == ERROR_STRING_SELECTOR;
    }

    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        amountToDeallocate = amountToAllocate;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    function test_allowlisted_revert_custom_selector_is_deterministic() public {
        uint256 amountToAllocate = 1e18;
        uint256 amountToDeallocate = 5e17;
        address mockPool = address(0xBEEF);
        bytes4 getPoolSelector = bytes4(keccak256("getPool()"));
        bytes4 withdrawSelector = bytes4(keccak256("withdraw(address,uint256,address)"));

        vm.startPrank(allocator);
        _prepareVaultAssets(amountToAllocate);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amountToAllocate);

        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToDeallocate);
        require(deallocPreview > 0, "preview is zero");

        vm.mockCall(AAVE_V3_ETH_POOL_ADDRESS_PROVIDER, abi.encodeWithSelector(getPoolSelector), abi.encode(mockPool));
        vm.mockCallRevert(
            mockPool, abi.encodePacked(withdrawSelector), abi.encodeWithSelector(ALLOWED_AAVE_REVERT_SELECTOR)
        );
        vm.expectRevert(ALLOWED_AAVE_REVERT_SELECTOR);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
        vm.stopPrank();
    }

    function test_allowlisted_revert_error_string_is_deterministic() public {
        uint256 amountToAllocate = 1e18;
        uint256 amountToDeallocate = 5e17;
        address mockPool = address(0xBEEF);
        bytes4 getPoolSelector = bytes4(keccak256("getPool()"));
        bytes4 withdrawSelector = bytes4(keccak256("withdraw(address,uint256,address)"));

        vm.startPrank(allocator);
        _prepareVaultAssets(amountToAllocate);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amountToAllocate);

        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToDeallocate);
        require(deallocPreview > 0, "preview is zero");

        vm.mockCall(AAVE_V3_ETH_POOL_ADDRESS_PROVIDER, abi.encodeWithSelector(getPoolSelector), abi.encode(mockPool));
        vm.mockCallRevert(
            mockPool, abi.encodePacked(withdrawSelector), abi.encodeWithSelector(ERROR_STRING_SELECTOR, "PD")
        );
        vm.expectRevert(bytes("PD"));
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
        vm.stopPrank();
    }

    function test_claimRewards_succeeds() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 1000e18;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        vm.prank(address(1));
        IMYTStrategy(strategy).claimRewards(AAVE_V3_ETH_WETH_ATOKEN, "", 0);
        vm.stopPrank();
    }

    function test_claimRewards_emits_event_and_vault_receives_asset() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 10e18;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        uint256 rewardAmount = 10e18;
        uint256 mockSwapReturn = 5e15;

        MockRewardsControllerETH mockRC = new MockRewardsControllerETH(REWARD_TOKEN, rewardAmount);
        vm.etch(REWARDS_CONTROLLER, address(mockRC).code);
        deal(REWARD_TOKEN, REWARDS_CONTROLLER, rewardAmount);

        MockSwapExecutorETH mockSwap = new MockSwapExecutorETH(WETH, mockSwapReturn);
        deal(WETH, address(mockSwap), mockSwapReturn);

        vm.prank(address(1));
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));

        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(vault);

        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(REWARD_TOKEN, rewardAmount);

        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(AAVE_V3_ETH_WETH_ATOKEN, quote, 4.99e15);

        uint256 vaultBalanceAfter = IERC20(WETH).balanceOf(vault);
        uint256 vaultAssetReceived = vaultBalanceAfter - vaultBalanceBefore;
        assertGt(received, 0, "No rewards received from claim");
        assertEq(vaultAssetReceived, mockSwapReturn, "Vault did not receive expected WETH amount");
        assertEq(received, vaultAssetReceived, "Returned amount is not in vault asset terms");
    }

    function _allocateToPrimaryStrategy(uint256 amount) internal {
        // Allocate real WETH from the MYT vault into the primary strategy using the standard
        // vault -> adapter -> Aave supply flow.
        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
    }

    function _deployLocalAlchemistStack() internal returns (LocalAlchemistStack memory stack) {
        // Deploy a minimal alAsset + transmuter pair for this isolated liquidation test.
        stack.debtToken = new AlchemicTokenV3("Alchemix Test ETH", "alETH-test", 0);
        stack.transmuter = new Transmuter(
            ITransmuter.TransmuterInitializationParams({
                syntheticToken: address(stack.debtToken),
                feeReceiver: address(this),
                timeToTransmute: 5_256_000,
                transmutationFee: 100,
                exitFee: 200,
                graphSize: 52_560_000
            })
        );

        // Initialize an Alchemist proxy against the existing MYT vault using WETH as the underlying unit.
        AlchemistV3 alchemistLogic = new AlchemistV3();
        bytes memory alchemParams = abi.encodeWithSelector(
            AlchemistV3.initialize.selector,
            AlchemistInitializationParams({
                admin: address(this),
                debtToken: address(stack.debtToken),
                underlyingToken: WETH,
                depositCap: type(uint256).max,
                minimumCollateralization: uint256(1e36) / 9e17,
                globalMinimumCollateralization: uint256(1e36) / 9e17,
                collateralizationLowerBound: 1_052_631_578_950_000_000,
                liquidationTargetCollateralization: uint256(1e36) / 88e16,
                transmuter: address(stack.transmuter),
                protocolFee: 100,
                protocolFeeReceiver: address(this),
                liquidatorFee: 300,
                repaymentFee: 100,
                myt: address(vault)
            })
        );
        TransparentUpgradeableProxy proxyAlchemist =
            new TransparentUpgradeableProxy(address(alchemistLogic), address(this), alchemParams);
        stack.alchemist = AlchemistV3(address(proxyAlchemist));

        // Wire the transmuter, debt token, and position NFT into the newly initialized Alchemist.
        stack.transmuter.setDepositCap(uint256(type(int256).max));
        stack.transmuter.setAlchemist(address(stack.alchemist));
        stack.debtToken.setWhitelist(address(stack.alchemist), true);

        stack.positionNft = new AlchemistV3Position(address(stack.alchemist), address(this));
        stack.positionNft.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        stack.alchemist.setAlchemistPositionNFT(address(stack.positionNft));
    }

    function _deployAndRegisterSecondStrategy() internal returns (address secondStrategy) {
        // Deploy a second Aave WETH strategy pointed at the same aWETH market.
        vm.startPrank(admin);
        secondStrategy = createStrategy(vault, getStrategyConfig());
        vm.stopPrank();

        // Register the new adapter on the existing MYT vault and give it the same caps as the
        // first strategy, but do not allocate anything into it.
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, secondStrategy));
        IVaultV2(vault).addAdapter(secondStrategy);

        bytes memory idData = IMYTStrategy(secondStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, testConfig.absoluteCap)));
        IVaultV2(vault).increaseAbsoluteCap(idData, testConfig.absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, testConfig.relativeCap)));
        IVaultV2(vault).increaseRelativeCap(idData, testConfig.relativeCap);
        vm.stopPrank();
    }

    function _deployAndRegisterWstethStrategy() internal returns (address targetStrategy) {
        IMYTStrategy.StrategyParams memory params = getStrategyConfig();
        params.name = "WstethTarget";
        params.protocol = "WstethTarget";

        // Deploy a target WstethStrategy with direct deposits disabled. It only needs to accept
        // transferred wstETH and report/deallocate in WETH terms.
        vm.startPrank(admin);
        targetStrategy = address(new WstethStrategy(vault, params, REWARD_TOKEN, WSTETH_ETH_ORACLE, false));
        vm.stopPrank();

        // Register the adapter on the existing MYT vault with the same caps as the primary strategy.
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, targetStrategy));
        IVaultV2(vault).addAdapter(targetStrategy);

        bytes memory idData = IMYTStrategy(targetStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, testConfig.absoluteCap)));
        IVaultV2(vault).increaseAbsoluteCap(idData, testConfig.absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, testConfig.relativeCap)));
        IVaultV2(vault).increaseRelativeCap(idData, testConfig.relativeCap);
        vm.stopPrank();
    }

    function _wstEthOracleAnswer() internal view returns (uint256 answer, uint256 scale) {
        (, int256 raw,, uint256 updatedAt,) = AggregatorV3Interface(WSTETH_ETH_ORACLE).latestRoundData();
        require(raw > 0 && updatedAt != 0, "invalid oracle answer");
        answer = uint256(raw);
        scale = 10 ** AggregatorV3Interface(WSTETH_ETH_ORACLE).decimals();
    }

    function _wstethToWethValue(uint256 wstethAmount) internal view returns (uint256) {
        (uint256 answer, uint256 scale) = _wstEthOracleAnswer();
        return wstethAmount * answer / scale;
    }

    function test_adminDexSwap_can_move_aWETH_out_via_custom_allowance_holder() public {
        uint256 amountToAllocate = 500e18;
        uint256 amountToDrain = amountToAllocate * 98 / 100;
        address recipient = address(0xBEEF);

        // Allocate WETH from the vault into Aave so the strategy receives live aWETH via the
        // normal production path.
        _allocateToPrimaryStrategy(amountToAllocate);

        // Snapshot balances and live strategy value before the helper-driven drain.
        uint256 aTokenBalanceBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(strategy);
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        assertGe(aTokenBalanceBefore, amountToDrain, "strategy did not receive enough aWETH");

        // Replace 0x's allowance holder with a custom helper that simply transferFroms aWETH away.
        MockATokenDrainHelper helper = new MockATokenDrainHelper();
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(helper));

        // Encode the helper call that will pull aWETH from the strategy to the chosen recipient.
        bytes memory callData = abi.encodeCall(
            MockATokenDrainHelper.drain,
            (AAVE_V3_ETH_WETH_ATOKEN, strategy, recipient, amountToDrain)
        );

        uint256 recipientBalanceBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(recipient);

        // Use WETH as the "to" token so dexSwap's post-call balance delta is zero instead of
        // underflowing when the helper drains aWETH out of the strategy.
        vm.prank(admin);
        uint256 reportedReceived =
            AaveStrategy(strategy).adminDexSwap(WETH, AAVE_V3_ETH_WETH_ATOKEN, amountToDrain, 0, callData);

        // Re-read strategy and recipient balances after the helper transfer completes.
        uint256 aTokenBalanceAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 recipientBalanceAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(recipient);
        uint256 wethBalanceAfter = IERC20(WETH).balanceOf(strategy);
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 allowanceAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).allowance(strategy, address(helper));

        // The helper moved the aWETH claim token out, but returned no WETH to the strategy.
        assertEq(reportedReceived, 0, "adminDexSwap should report zero received");
        assertGe(aTokenBalanceBefore - aTokenBalanceAfter, amountToDrain, "strategy aWETH did not decrease enough");
        assertEq(recipientBalanceAfter - recipientBalanceBefore, amountToDrain, "recipient did not receive aWETH");
        assertEq(wethBalanceAfter, wethBalanceBefore, "strategy WETH balance changed unexpectedly");
        assertEq(allowanceAfter, 0, "allowance was not reset");
        assertGe(realAssetsBefore - realAssetsAfter, amountToDrain, "realAssets did not drop by drained amount");
    }

    function test_adminDexSwap_reverts_when_to_token_is_aWETH_and_helper_drains_aWETH() public {
        uint256 amountToAllocate = 500e18;
        uint256 amountToDrain = amountToAllocate * 98 / 100;
        address recipient = address(0xBEEF);

        // Allocate WETH from the vault into Aave so the strategy receives live aWETH.
        _allocateToPrimaryStrategy(amountToAllocate);

        // Point the strategy at the drain helper.
        MockATokenDrainHelper helper = new MockATokenDrainHelper();
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(helper));

        // Ask the helper to transfer aWETH away from the strategy.
        bytes memory callData = abi.encodeCall(
            MockATokenDrainHelper.drain,
            (AAVE_V3_ETH_WETH_ATOKEN, strategy, recipient, amountToDrain)
        );

        // Using aWETH itself as the "to" token makes dexSwap snapshot aWETH before the call and
        // then observe a lower balance after the helper drain, which causes the internal balance
        // delta math to revert.
        vm.prank(admin);
        vm.expectRevert();
        AaveStrategy(strategy).adminDexSwap(
            AAVE_V3_ETH_WETH_ATOKEN, AAVE_V3_ETH_WETH_ATOKEN, amountToDrain, 0, callData
        );
    }

    function test_adminDexSwap_can_move_aWETH_to_second_aave_strategy_without_changing_myt_total_value() public {
        uint256 amountToSeed = 500e18;
        uint256 amountToMove = amountToSeed * 98 / 100;

        // Add a second Aave WETH adapter to the same MYT vault, but leave its stored allocation at zero.
        address secondStrategy = _deployAndRegisterSecondStrategy();

        // Allocate only into the first strategy so it holds the aWETH position and the second
        // strategy still starts with zero stored allocation.
        _allocateToPrimaryStrategy(amountToSeed);

        // Capture adapter ids and live vault/strategy accounting before the transfer.
        bytes32 firstId = IMYTStrategy(strategy).adapterId();
        bytes32 secondId = IMYTStrategy(secondStrategy).adapterId();

        uint256 totalAssetsBefore = IVaultV2(vault).totalAssets();
        uint256 firstRealAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 secondRealAssetsBefore = IMYTStrategy(secondStrategy).realAssets();
        uint256 firstATokenBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 secondATokenBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(secondStrategy);

        assertApproxEqAbs(
            IVaultV2(vault).allocation(firstId), amountToSeed, 1, "first strategy should reflect the vault allocation"
        );
        assertEq(IVaultV2(vault).allocation(secondId), 0, "second strategy should start with zero allocation");
        assertEq(secondRealAssetsBefore, 0, "second strategy should start with zero real assets");

        // Reuse the same helper trick, but direct the aWETH into the second strategy instead of an EOA.
        MockATokenDrainHelper helper = new MockATokenDrainHelper();
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(helper));

        // Encode a transferFrom that moves aWETH from strategy A to strategy B.
        bytes memory callData = abi.encodeCall(
            MockATokenDrainHelper.drain,
            (AAVE_V3_ETH_WETH_ATOKEN, strategy, secondStrategy, amountToMove)
        );

        // Execute the helper-driven move while keeping dexSwap's "to" token on harmless WETH.
        vm.prank(admin);
        uint256 reportedReceived =
            AaveStrategy(strategy).adminDexSwap(WETH, AAVE_V3_ETH_WETH_ATOKEN, amountToMove, 0, callData);

        // Read live vault and strategy value after the move.
        uint256 totalAssetsAfter = IVaultV2(vault).totalAssets();
        uint256 firstRealAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 secondRealAssetsAfter = IMYTStrategy(secondStrategy).realAssets();
        uint256 firstATokenAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 secondATokenAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(secondStrategy);

        // Live realAssets move from the first strategy to the second, but the stored vault
        // allocations do not follow because this bypassed the vault-managed allocate/deallocate flow.
        assertEq(reportedReceived, 0, "adminDexSwap should report zero received");
        assertGe(firstATokenBefore - firstATokenAfter, amountToMove, "first strategy did not lose enough aWETH");
        assertEq(secondATokenAfter - secondATokenBefore, amountToMove, "second strategy did not receive aWETH");
        assertGe(firstRealAssetsBefore - firstRealAssetsAfter, amountToMove, "first strategy real assets did not decrease");
        assertGe(secondRealAssetsAfter - secondRealAssetsBefore, amountToMove, "second strategy real assets did not increase");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 2, "vault total assets should remain unchanged");
        assertApproxEqAbs(
            IVaultV2(vault).allocation(firstId), amountToSeed, 1, "first strategy allocation should remain stale"
        );
        assertEq(IVaultV2(vault).allocation(secondId), 0, "second strategy allocation should remain zero");
    }

    function test_adminDexSwap_max_ltv_user_is_not_liquidatable_after_99pct_move_to_second_strategy() public {
        uint256 amountToAllocate = 500e18;
        uint256 userDepositShares = 100e18;
        address user = vaultDepositor;
        address liquidator = address(0xBEEF);

        // Allocate half of the vault into the first strategy, leaving the other half idle.
        _allocateToPrimaryStrategy(amountToAllocate);
        address secondStrategy = _deployAndRegisterSecondStrategy();

        // The first strategy should represent ~50% of total vault value before the manual aWETH move.
        bytes32 firstId = IMYTStrategy(strategy).adapterId();
        bytes32 secondId = IMYTStrategy(secondStrategy).adapterId();
        uint256 totalAssetsBeforeMove = IVaultV2(vault).totalAssets();
        uint256 firstAllocationBeforeMove = IVaultV2(vault).allocation(firstId);
        assertApproxEqAbs(firstAllocationBeforeMove * 2, totalAssetsBeforeMove, 4, "first strategy should be ~50% of MYT");
        assertEq(IVaultV2(vault).allocation(secondId), 0, "second strategy should start with zero allocation");

        // Deploy a minimal Alchemist stack that uses the existing MYT vault shares as collateral.
        LocalAlchemistStack memory stack = _deployLocalAlchemistStack();

        // Have a single user deposit MYT shares and mint to the maximum borrowable amount.
        vm.startPrank(user);
        IERC20(address(vault)).approve(address(stack.alchemist), type(uint256).max);
        stack.alchemist.deposit(userDepositShares, user, 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(stack.positionNft));
        uint256 maxBorrowable = stack.alchemist.getMaxBorrowable(tokenId);
        stack.alchemist.mint(tokenId, maxBorrowable, user);
        vm.stopPrank();

        // Snapshot the user's collateral value and debt before moving the aWETH position.
        uint256 totalValueBefore = stack.alchemist.totalValue(tokenId);
        (, uint256 debtBefore,) = stack.alchemist.getCDP(tokenId);
        assertGt(totalValueBefore, 0, "user should have collateral value");
        assertGt(debtBefore, 0, "user should have debt");

        // Move 99% of the first strategy's stored allocation into the second strategy.
        uint256 amountToMove = firstAllocationBeforeMove * 99 / 100;
        MockATokenDrainHelper helper = new MockATokenDrainHelper();
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(helper));

        bytes memory callData = abi.encodeCall(
            MockATokenDrainHelper.drain,
            (AAVE_V3_ETH_WETH_ATOKEN, strategy, secondStrategy, amountToMove)
        );

        vm.prank(admin);
        AaveStrategy(strategy).adminDexSwap(WETH, AAVE_V3_ETH_WETH_ATOKEN, amountToMove, 0, callData);

        // The vault and the user's collateral value should remain unchanged because the live value
        // merely moved from one registered adapter to another.
        uint256 totalAssetsAfterMove = IVaultV2(vault).totalAssets();
        uint256 totalValueAfter = stack.alchemist.totalValue(tokenId);
        (, uint256 debtAfter,) = stack.alchemist.getCDP(tokenId);
        assertApproxEqAbs(totalAssetsAfterMove, totalAssetsBeforeMove, 2, "vault total assets should stay constant");
        assertApproxEqAbs(totalValueAfter, totalValueBefore, 2, "user collateral value should stay constant");
        assertEq(debtAfter, debtBefore, "user debt should not change before liquidation");
        assertApproxEqAbs(
            IVaultV2(vault).allocation(firstId), firstAllocationBeforeMove, 1, "first strategy allocation should remain stale"
        );
        assertEq(IVaultV2(vault).allocation(secondId), 0, "second strategy allocation should remain zero");

        // Since the move preserved the vault's total value, the user's max-LTV position should still
        // be healthy and regular liquidation must revert.
        vm.prank(liquidator);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        stack.alchemist.liquidate(tokenId);
    }

    function test_adminDexSwap_helper_can_route_aWETH_to_target_wsteth_strategy_via_fluid() public {
        uint256 amountToAllocate = 500e18;

        // Allocate WETH into the source Aave strategy so it holds live aEthWETH.
        _allocateToPrimaryStrategy(amountToAllocate);

        // Register a real WstethStrategy on the same vault to receive the withdrawn raw wstETH.
        address targetStrategy = _deployAndRegisterWstethStrategy();
        bytes32 sourceId = IMYTStrategy(strategy).adapterId();
        bytes32 targetId = IMYTStrategy(targetStrategy).adapterId();

        uint256 fluidMaxSwap = IFluidATokenSwap(FLUID_A_TOKEN_SWAP).maxSwapToWstETH();
        require(fluidMaxSwap > 1e18, "no fluid capacity");

        // Use a near-full migration amount, but stay within the live Fluid debt-ceiling limit.
        uint256 amountToMove = amountToAllocate * 98 / 100;
        uint256 safeFluidLimit = fluidMaxSwap - 1;
        if (amountToMove > safeFluidLimit) amountToMove = safeFluidLimit;

        uint256 quotedAethwstEthOut = IFluidATokenSwap(FLUID_A_TOKEN_SWAP).getWstETHAmountOut(amountToMove);
        uint256 minAethwstEthOut = quotedAethwstEthOut > 1 ? quotedAethwstEthOut - 1 : quotedAethwstEthOut;

        // Snapshot live balances and vault accounting before executing the helper-driven migration.
        uint256 totalAssetsBefore = IVaultV2(vault).totalAssets();
        uint256 vaultIdleBefore = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 sourceATokenBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 manualTotalBefore = vaultIdleBefore + sourceRealAssetsBefore;
        assertEq(IMYTStrategy(targetStrategy).realAssets(), 0, "target strategy should start empty");
        assertEq(IERC20(REWARD_TOKEN).balanceOf(targetStrategy), 0, "target strategy should start without wstETH");

        // Install the migration helper as the source strategy's temporary allowance holder.
        MYTTokenSwapper helper = new MYTTokenSwapper(
            admin,
            AAVE_V3_ETH_WETH_ATOKEN,
            AAVE_V3_ETH_WSTETH_ATOKEN,
            REWARD_TOKEN,
            FLUID_A_TOKEN_SWAP,
            AAVE_V3_ETH_POOL_ADDRESS_PROVIDER
        );
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(helper));

        // Use WETH as the "to" token so adminDexSwap reports zero received on the source strategy
        // while the helper forwards raw wstETH to the destination strategy.
        bytes memory callData = abi.encodeCall(
            MYTTokenSwapper.swapAaveWethToWstethViaFluid,
            (amountToMove, minAethwstEthOut, targetStrategy)
        );

        vm.prank(admin);
        uint256 reportedReceived =
            AaveStrategy(strategy).adminDexSwap(WETH, AAVE_V3_ETH_WETH_ATOKEN, amountToMove, 0, callData);

        // Re-read live strategy balances and vault accounting after the Fluid + Aave migration leg.
        uint256 totalAssetsAfter = IVaultV2(vault).totalAssets();
        uint256 vaultIdleAfter = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 targetRealAssetsAfter = IMYTStrategy(targetStrategy).realAssets();
        uint256 sourceATokenAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 targetWstethAfter = IERC20(REWARD_TOKEN).balanceOf(targetStrategy);
        uint256 expectedTargetValueFromBalance = _wstethToWethValue(targetWstethAfter);
        uint256 realizedLoss = (sourceRealAssetsBefore - sourceRealAssetsAfter) - targetRealAssetsAfter;
        uint256 manualTotalAfter = vaultIdleAfter + sourceRealAssetsAfter + targetRealAssetsAfter;

        // The source loses aEthWETH, the target receives raw wstETH, and the vault realizes the
        // Fluid premium haircut instead of preserving total assets exactly.
        assertEq(reportedReceived, 0, "adminDexSwap should report zero received on the source strategy");
        assertGe(sourceATokenBefore - sourceATokenAfter, amountToMove, "source strategy did not lose enough aEthWETH");
        assertGe(sourceRealAssetsBefore - sourceRealAssetsAfter, amountToMove, "source strategy value did not decrease");
        assertGe(targetWstethAfter, minAethwstEthOut, "target did not receive enough wstETH");
        assertEq(vaultIdleAfter, vaultIdleBefore, "helper migration should not change idle vault WETH");
        assertApproxEqAbs(
            targetRealAssetsAfter,
            expectedTargetValueFromBalance,
            3,
            "target strategy value should reflect its wstETH balance"
        );
        assertGt(realizedLoss, 0, "Fluid swap should realize a premium haircut");
        assertApproxEqAbs(manualTotalAfter, manualTotalBefore - realizedLoss, 5, "manual total should match realized haircut");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 2, "vault totalAssets bookkeeping should remain unchanged");
        assertApproxEqAbs(
            IVaultV2(vault).allocation(sourceId),
            amountToAllocate,
            1,
            "source allocation should remain stale after helper migration"
        );
        assertEq(IVaultV2(vault).allocation(targetId), 0, "target allocation should remain zero");
    }

    function test_aave_v3_ethweth_yield_accumulation() public {
        vm.startPrank(allocator);

        uint256 allocAmount = 300e18;
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();

        uint256[] memory realAssetsSnapshots = new uint256[](4);
        uint256 minExpected = initialRealAssets * 95 / 100;
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 30 days);

            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);

            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();

            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            minExpected = realAssetsSnapshots[i];

            if (i == 1) {
                uint256 smallDealloc = 30e18;
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }

        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, initialRealAssets / 100, "All real assets should be deallocated");

        vm.stopPrank();
    }
}
