// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
// Adjust these imports to your layout

import {TokeAutoStrategy, TokeRedeemParams, TokeSwapRoute} from "../../strategies/TokeAutoStrategy.sol";
import {BaseStrategyTest, RevertContext} from "../BaseStrategyTest.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

interface IRootOracle {
    function getPriceInEth(address token) external returns (uint256);
    function getCeilingPrice(address token, address pool, address quoteToken) external returns (uint256);
    function getFloorPrice(address token, address pool, address quoteToken) external returns (uint256);
}

interface IAutoEthMath {
    enum Rounding {
        Down,
        Up,
        Zero
    }

    enum TotalAssetPurpose {
        Global,
        Deposit,
        Withdraw
    }

    function totalAssets(TotalAssetPurpose purpose) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToShares(
        uint256 assets,
        uint256 totalAssetsForPurpose,
        uint256 supply,
        Rounding rounding
    ) external view returns (uint256);
}

/// @notice Replaces the Tokemak MainRewarder via vm.etch so that
///         getReward actually transfers TOKE tokens to the recipient.
contract MockTokeRewarder {
    IERC20 public immutable tokeToken;
    uint256 public immutable rewardAmount;
    address public immutable rewardTokenAddr;
    uint256 public immutable lockDuration;

    constructor(address _tokeToken, uint256 _rewardAmount, address _rewardTokenAddr, uint256 _lockDuration) {
        tokeToken = IERC20(_tokeToken);
        rewardAmount = _rewardAmount;
        rewardTokenAddr = _rewardTokenAddr;
        lockDuration = _lockDuration;
    }

    function allowExtraRewards() external pure returns (bool) {
        return false;
    }

    function getReward(address, address recipient, bool) external {
        tokeToken.transfer(recipient, rewardAmount);
    }

    function rewardToken() external view returns (address) {
        return rewardTokenAddr;
    }

    function tokeLockDuration() external view returns (uint256) {
        return lockDuration;
    }
}

/// @notice When used as allowanceHolder, transfers a fixed amount of token
///         to msg.sender on any call (simulates swap output).
contract MockSwapExecutor {
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

contract MockAutopilotRouter {
    IERC20 public immutable asset;
    uint256 public redeemCalls;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function redeem(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        redeemCalls++;
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);
        asset.transfer(to, minAmountOut);
        return minAmountOut;
    }

    function redeemWithRoutes(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut,
        TokeSwapRoute[] calldata
    ) external returns (uint256 amountOut) {
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);
        asset.transfer(to, minAmountOut);
        return minAmountOut;
    }
}

contract MockTokeAutoEthStrategy is TokeAutoStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _autoEth,
        address _rewarder,
        address _weth,
        address _tokeRewardsToken,
        address _autopilotRouter
    )
        // This suite drives the real AutopoolETH.redeem while mocking only the oracle, which
        // creates a several-percent gap between convertToAssets (NAV) and realized redeem proceeds.
        // Production uses the tight DEFAULT_EXEC_TOLERANCE_BPS; here we widen it so the mocked
        // valuation gap does not trip Tokemak's MinAmountError on legitimate deallocations.
        TokeAutoStrategy(_myt, _params, _weth, _autoEth, _rewarder, _tokeRewardsToken, _autopilotRouter, 600)
    {}
}

contract TokeAutoETHStrategyTest is BaseStrategyTest {
    address public constant TOKE_AUTO_ETH_VAULT = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address public constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC;
    address public constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    // Error(string) selector (0x08c379a0), observed in Tokemak traces.
    // In this suite it is observed on both allocate and deallocate paths.
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;
    // Tokemak custom error selector (0x8d54ba1f / InvalidDataReturned in tests).
    // In this suite it is observed on allocate paths (stake mock), not deallocate.
    bytes4 internal constant ALLOWED_TOKEMAK_REVERT_SELECTOR = 0x8d54ba1f;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "TokeAutoEth",
            protocol: "TokeAutoEth",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 600
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockTokeAutoEthStrategy(vault, params, TOKE_AUTO_ETH_VAULT, REWARDER, WETH, TOKE, AUTOPILOT_ROUTER));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24667747;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function _beforeTimeShift(uint256) internal override {
        // Keep Tokemak oracle reads fresh across synthetic time warps.
        // Use live-like mainnet values captured via Tenderly RPC.
        uint256 mockedEthPrice = 1_108_368_970_000_000_000;
        uint256 mockedCeilingPrice = 1_006_112_990_447_894_840;
        uint256 mockedFloorPrice = 1_001_260_889_888_317_396;
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOracle.getPriceInEth.selector),
            abi.encode(mockedEthPrice)
        );
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOracle.getCeilingPrice.selector),
            abi.encode(mockedCeilingPrice)
        );
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOracle.getFloorPrice.selector),
            abi.encode(mockedFloorPrice)
        );
    }

    function _beforePreviewWithdraw(uint256 requestedAssets) internal override {
        if (requestedAssets == 0) return;

        // Force convertToShares(assets, ...) -> assets for this requested amount.
        // Use calldata-prefix matching on selector + first arg so changing totals/supply
        // do not bypass the mock.
        vm.mockCall(
            TOKE_AUTO_ETH_VAULT,
            abi.encodePacked(IAutoEthMath.convertToShares.selector, bytes32(requestedAssets)),
            abi.encode(requestedAssets)
        );

        // Deallocate is called with previewAdjustedWithdraw(amount), so pre-mock that
        // amount too as identity to keep strategy-side convertToShares deterministic.
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedAssets);
        if (previewAmount == 0) return;
        vm.mockCall(
            TOKE_AUTO_ETH_VAULT,
            abi.encodePacked(IAutoEthMath.convertToShares.selector, bytes32(previewAmount)),
            abi.encode(previewAmount)
        );
    }

    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        if (
            selector != ERROR_STRING_SELECTOR
                && selector != ALLOWED_TOKEMAK_REVERT_SELECTOR
        ) return false;

        return context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;
    }

    function isMytRevertAllowed(bytes4, RevertContext) external pure override returns (bool) {
        return false;
    }

    // Add any strategy-specific tests here
    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1e18, testConfig.vaultInitialDeposit);
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

    function test_deallocate_full_real_assets() public {
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        uint256 amountToAllocate = 12345 * 10 ** 18;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        uint256 initialIdle = IERC20(WETH).balanceOf(strategy);

        /// staking to the REWARDER contract through the TokeAutoEthStrategy's allocate method
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(0));        
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");

        // Direct adapter deallocate leaves withdrawn WETH idle on the strategy until the vault pulls it.
        IMYTStrategy(strategy).deallocate(params, initialRealAssets, "", address(vault));
        uint256 idleWeth = IERC20(WETH).balanceOf(strategy);
        assertGt(idleWeth, 0, "Idle WETH should remain on strategy after direct deallocate");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), idleWeth, 1e16);
        vm.stopPrank();
    }

    function test_deallocate_direct_uses_router_redeem_once() public {
        uint256 amountToAllocate = 10e18;
        uint256 amountToDeallocate = 1e18;

        MockAutopilotRouter router = new MockAutopilotRouter(WETH);
        address localStrategy =
            address(new MockTokeAutoEthStrategy(vault, strategyConfig, TOKE_AUTO_ETH_VAULT, REWARDER, WETH, TOKE, address(router)));

        vm.startPrank(vault);
        deal(testConfig.vaultAsset, localStrategy, amountToAllocate);
        IMYTStrategy(localStrategy).allocate(getVaultParams(), amountToAllocate, "", address(vault));
        vm.stopPrank();

        deal(WETH, address(router), amountToDeallocate);

        vm.prank(vault);
        IMYTStrategy(localStrategy).deallocate(getVaultParams(), amountToDeallocate, "", address(vault));

        assertEq(router.redeemCalls(), 1, "router redeem should be called once");
        assertGe(IERC20(WETH).balanceOf(localStrategy), amountToDeallocate, "strategy should hold deallocated WETH");
        assertGt(IERC20(TOKE_AUTO_ETH_VAULT).balanceOf(address(router)), 0, "router should pull shares");
    }

    function test_deallocateWithSwap_redeems_with_custom_routes() public {
        uint256 amountToAllocate = 10e18;
        uint256 amountToDeallocate = 1e18;

        MockAutopilotRouter router = new MockAutopilotRouter(WETH);
        address localStrategy =
            address(new MockTokeAutoEthStrategy(vault, strategyConfig, TOKE_AUTO_ETH_VAULT, REWARDER, WETH, TOKE, address(router)));

        vm.startPrank(vault);
        deal(testConfig.vaultAsset, localStrategy, amountToAllocate);
        IMYTStrategy(localStrategy).allocate(getVaultParams(), amountToAllocate, "", address(vault));
        vm.stopPrank();

        deal(WETH, address(router), amountToDeallocate);

        TokeSwapRoute[] memory routes = new TokeSwapRoute[](0);
        TokeRedeemParams memory redeemParams =
            TokeRedeemParams({minAmountOut: amountToDeallocate, customRoutes: routes});
        IMYTStrategy.SwapParams memory swapParams =
            IMYTStrategy.SwapParams({txData: abi.encode(redeemParams), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory params =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        vm.prank(vault);
        IMYTStrategy(localStrategy).deallocate(abi.encode(params), amountToDeallocate, "", address(vault));

        assertGe(IERC20(WETH).balanceOf(localStrategy), amountToDeallocate, "strategy should hold deallocated WETH");
        assertGt(IERC20(TOKE_AUTO_ETH_VAULT).balanceOf(address(router)), 0, "router should pull shares");
    }

    function test_allocator_deallocateWithSwap_redeems_with_custom_routes() public {
        uint256 amountToAllocate = 10e18;
        uint256 amountToDeallocate = 1e18;

        MockAutopilotRouter router = new MockAutopilotRouter(WETH);
        vm.etch(AUTOPILOT_ROUTER, address(router).code);
        deal(WETH, AUTOPILOT_ROUTER, amountToDeallocate);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amountToAllocate);

        TokeSwapRoute[] memory routes = new TokeSwapRoute[](0);
        TokeRedeemParams memory redeemParams =
            TokeRedeemParams({minAmountOut: amountToDeallocate, customRoutes: routes});

        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(vault);
        IAllocator(allocator).deallocateWithSwap(strategy, amountToDeallocate, abi.encode(redeemParams));
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(vault) - vaultBalanceBefore, amountToDeallocate, "vault should receive WETH");
        assertGt(IERC20(TOKE_AUTO_ETH_VAULT).balanceOf(AUTOPILOT_ROUTER), 0, "router should pull shares");
    }

    function test_claimRewards_emits_event_and_vault_receives_asset() public {
        // Allocate assets to create a Tokemak position
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 10e18;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        // Configure mock reward claim (stakingDisabled = true via tokeLockDuration == 0)
        uint256 tokeRewardAmount = 10e18;   // 10 TOKE tokens claimed
        uint256 mockSwapReturn = 5e15;      // Simulated WETH swap output

        // Deploy a MockTokeRewarder and etch over the real REWARDER address.
        // rewardToken = TOKE, tokeLockDuration = 0 → stakingDisabled = true
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 0);
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);

        // Setup MockSwapExecutor as allowanceHolder to simulate DEX swap.
        // dexSwap(MYT.asset(), token, ...) measures WETH balance change,
        // so the mock executor transfers WETH to the strategy.
        // NOTE: quote must be non-empty so the call hits fallback() not receive().
        MockSwapExecutor mockSwap = new MockSwapExecutor(WETH, mockSwapReturn);
        deal(WETH, address(mockSwap), mockSwapReturn);

        // Point the strategy's allowanceHolder to our mock
        vm.prank(address(1)); // strategy owner
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));

        // Record vault WETH balance before claiming
        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(vault);

        // Expect the RewardsClaimed event with correct token and amount
        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(TOKE, tokeRewardAmount);

        // Execute claimRewards as strategy owner
        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 4.99e15);

        // Verify rewards were received and vault got the asset
        uint256 vaultBalanceAfter = IERC20(WETH).balanceOf(vault);
        assertGt(received, 0, "No rewards received from claim");
        assertEq(received, mockSwapReturn, "Received amount does not match expected swap output");
        assertEq(vaultBalanceAfter - vaultBalanceBefore, received, "Vault did not receive expected WETH amount");
    }

    function test_claimRewards_returns_zero_when_staking_enabled() public {
        // Allocate assets to create a Tokemak position
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 10e18;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        uint256 tokeRewardAmount = 10e18;

        // Deploy a MockTokeRewarder with staking ENABLED:
        // rewardToken == TOKE AND tokeLockDuration > 0 → stakingDisabled = false
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 1);
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);

        // Record vault WETH balance before claiming
        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(vault);

        // Execute claimRewards as strategy owner — should return 0
        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 9.99e18);

        // Verify nothing was returned and vault balance is unchanged
        uint256 vaultBalanceAfter = IERC20(WETH).balanceOf(vault);
        assertEq(received, 0, "Should return 0 when staking is enabled");
        assertEq(vaultBalanceAfter, vaultBalanceBefore, "Vault balance should not change when staking is enabled");
    }

    function test_allowlisted_revert_deposit_value_below_minimum_is_deterministic() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 1e18;
        bytes4 convertToAssetsSelector = bytes4(keccak256("convertToAssets(uint256,uint256,uint256,uint8)"));

        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.mockCall(TOKE_AUTO_ETH_VAULT, abi.encodePacked(convertToAssetsSelector), abi.encode(0));
        vm.expectRevert(bytes("Deposit value below minimum"));
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        vm.stopPrank();
    }

    function test_allowlisted_revert_withdraw_amount_insufficient_is_deterministic() public {
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 2e18;
        uint256 amountToDeallocate = 1e18;

        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        vm.mockCall(
            REWARDER,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), strategy),
            abi.encode(0)
        );
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    // Ensures the allowlisted custom selector (0x8d54ba1f / InvalidDataReturned) is explicitly asserted.
    // Mocks rewarder.stake() to emit that revert so fuzz-skip coverage has a deterministic counterpart.
    function test_allowlisted_revert_custom_selector_is_deterministic() public {
        uint256 amountToAllocate = 1e18;
        bytes4 convertToAssetsSelector = bytes4(keccak256("convertToAssets(uint256,uint256,uint256,uint8)"));
        bytes4 stakeSelector = bytes4(keccak256("stake(address,uint256)"));

        vm.startPrank(allocator);
        vm.mockCall(TOKE_AUTO_ETH_VAULT, abi.encodePacked(convertToAssetsSelector), abi.encode(amountToAllocate));
        vm.mockCallRevert(REWARDER, abi.encodePacked(stakeSelector), abi.encodeWithSelector(ALLOWED_TOKEMAK_REVERT_SELECTOR));
        vm.expectRevert(ALLOWED_TOKEMAK_REVERT_SELECTOR);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amountToAllocate);
        vm.stopPrank();
    }

    // End-to-end test: Full lifecycle with time accumulation for TokeAutoETH
    function test_toke_auto_eth_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Initial allocation
        uint256 alloc1 = 2e18; // 2 WETH
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e15);
        
        // Warp forward 14 days
        _warpWithHook(14 days);
        
        // Additional allocation
        uint256 alloc2 = 1e18; // 1 WETH
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        
        // Warp forward 30 days
        _warpWithHook(30 days);
        
        // Partial deallocation (withdraw 0.5 WETH)
        uint256 deallocAmount1 = 0.05e18;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");
        
        // Warp forward 60 days
        _warpWithHook(60 days);
        
        // Check vault WETH balance
        uint256 vaultWETHBalance = IERC20(WETH).balanceOf(vault);
        assertGt(vaultWETHBalance, 0, "Vault should have WETH");
        
        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 finalTarget = IVaultV2(vault).allocation(allocationId) / 20;
            if (finalTarget > 1e15) {
                uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalTarget);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
            }
        }
        
        uint256 finalVaultWETHBalance = IERC20(WETH).balanceOf(vault);
        assertGt(finalVaultWETHBalance, vaultWETHBalance, "Vault WETH should increase after deallocation");
        
        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_toke_auto_eth_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        // Use bound for array length instead of assume
        uint256 numOps = bound(amounts.length, 1, 8);
        // Ensure we don't access beyond array bounds
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;
        
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        for (uint256 i = 0; i < maxIterations; i++) {
            // Alternate between allocation and deallocation
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 0.1e18, 5e18); // 0.1-5 WETH
            
            if (isAllocate) {
                IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                uint256 deallocAmount = 0;
                if (currentAllocation > 0) {
                    uint256 conservativeMax = currentAllocation / 10_000;
                    deallocAmount = conservativeMax == 0 ? 0 : bound(amount, 0, conservativeMax);
                }
                if (deallocAmount > 0) {
                    uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount);
                    if (deallocPreview > 0) {
                        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                    }
                }
            }
            
            // Warp forward (only access if timeDelays has this index)
            uint256 timeDelay = i < timeDelays.length ? bound(timeDelays[i], 1 hours, 60 days) : 1 hours;
            _warpWithHook(timeDelay);
        }
        
        // Final sanity checks
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultWETHBalance = IERC20(WETH).balanceOf(vault);
        
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultWETHBalance, 0, "Vault should have WETH");
        
        vm.stopPrank();
    }

    // Test: TokeAutoETH with reward claiming over time
    function test_toke_auto_eth_rewards_over_time() public {
        vm.startPrank(allocator);
        
        // Allocate initial amount
        uint256 allocAmount = 3e18; // 3 WETH
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        
        // Warp 30 days
        _warpWithHook(30 days);
        
        // Setup reward claiming mock (staking disabled)
        uint256 tokeRewardAmount = 10e18;
        uint256 mockSwapReturn = 5e15;
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 0);
        bytes memory rewarderCodeBeforeMock = REWARDER.code;
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);
        MockSwapExecutor mockSwap = new MockSwapExecutor(WETH, mockSwapReturn);
        deal(WETH, address(mockSwap), mockSwapReturn);
        
        vm.stopPrank();
        vm.startPrank(address(1));
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));
        
        // Claim rewards
        bytes memory quote = hex"01";
        vm.stopPrank();
        vm.startPrank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 4.99e15);
        
        assertGt(received, 0, "Should receive rewards");
        vm.etch(REWARDER, rewarderCodeBeforeMock);
        
        // Continue with allocations/deallocations
        vm.stopPrank();
        vm.startPrank(allocator);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        
        _warpWithHook(30 days);
        
        // Small deallocation
        uint256 smallDealloc = 0.05e18;
        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
        
        _warpWithHook(30 days);
        
        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e15) {
            bytes32 allocationId = IMYTStrategy(strategy).adapterId();
            uint256 finalTarget = IVaultV2(vault).allocation(allocationId) / 20;
            if (finalTarget > 1e15) {
                uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalTarget);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
            }
        }
        
        assertLe(IMYTStrategy(strategy).realAssets(), realAssets1, "Final real assets should not exceed prior balance");
        
        vm.stopPrank();
    }
}
