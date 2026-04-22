// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {AaveStrategy} from "../../strategies/AaveStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

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
    address public constant AAVE_V3_ETH_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant REWARD_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;
    bytes4 internal constant ALLOWED_AAVE_REVERT_SELECTOR = 0x2c5211c6;

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
