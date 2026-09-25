// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {AaveStrategy} from "../../strategies/AaveStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
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

contract AaveV3ETHWETHInvariantTest is E2EInvariantStrategyTest {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_V3_ETH_WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant AAVE_V3_ETH_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant AAVE_REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_REWARD_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getAsset() internal pure override returns (address) {
        return WETH;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
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

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new AaveStrategy(vault_, params, WETH, AAVE_V3_ETH_WETH_ATOKEN, AAVE_V3_ETH_POOL_ADDRESS_PROVIDER, AAVE_REWARDS_CONTROLLER, AAVE_REWARD_TOKEN)
        );
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 bal = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 loss = amount > bal ? bal : amount;
        if (loss == 0) return;
        vm.prank(strategy);
        IERC20(AAVE_V3_ETH_WETH_ATOKEN).transfer(address(0xdead), loss);
    }
}
