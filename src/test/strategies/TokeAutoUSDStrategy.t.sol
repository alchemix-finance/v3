// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
// Adjust these imports to your layout

import {TokeAutoStrategy} from "../../strategies/TokeAutoStrategy.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

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

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function redeem(
        IERC4626 vault,
        address to,
        uint256 shares,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);
        asset.transfer(to, minAmountOut);
        return minAmountOut;
    }
}

contract MockTokeAutoUSDStrategy is TokeAutoStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _usdc,
        address _autoUSD,
        address _rewarder,
        address _tokeRewardsToken,
        address _autopilotRouter
    ) TokeAutoStrategy(_myt, _params, _usdc, _autoUSD, _rewarder, _tokeRewardsToken, _autopilotRouter) {}
}

contract TokeAutoUSDStrategyTest is BaseStrategyTest {
    address public constant TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    address public constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address public constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "TokeAutoUSD",
            protocol: "TokeAutoUSD",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 1000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        MockAutopilotRouter router = new MockAutopilotRouter(USDC);
        deal(USDC, address(router), type(uint128).max);
        return address(new MockTokeAutoUSDStrategy(vault, params, USDC, TOKE_AUTO_USD_VAULT, REWARDER, TOKE, address(router)));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    // Test that full deallocation completes without reverting
    function test_strategy_full_deallocate(uint256 amountToAllocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        IMYTStrategy(strategy).deallocate(params, amountToAllocate, "", address(vault));
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 idleUsdc = IERC20(USDC).balanceOf(strategy);
        assertGt(idleUsdc, 0, "Idle USDC should remain on strategy after direct deallocate");
        assertApproxEqRel(finalRealAssets, idleUsdc, 1e16);
        vm.stopPrank();
    }

    function test_claimRewards_emits_event_and_vault_receives_asset() public {
        // Allocate assets to create a Tokemak position
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 100e6;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        // Configure mock reward claim (stakingDisabled = true via tokeLockDuration == 0)
        uint256 tokeRewardAmount = 10e18;   // 10 TOKE tokens claimed
        uint256 mockSwapReturn = 5e6;       // Simulated USDC swap output

        // Deploy a MockTokeRewarder and etch over the real REWARDER address.
        // rewardToken = TOKE, tokeLockDuration = 0 → stakingDisabled = true
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 0);
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);

        // Setup MockSwapExecutor as allowanceHolder to simulate DEX swap.
        // dexSwap(MYT.asset(), token, ...) measures USDC balance change,
        MockSwapExecutor mockSwap = new MockSwapExecutor(USDC, mockSwapReturn);
        deal(USDC, address(mockSwap), mockSwapReturn);

        // Point the strategy's allowanceHolder to our mock
        vm.prank(address(1)); // strategy owner
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));

        // Record vault USDC balance before claiming
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);

        // Expect the RewardsClaimed event with correct token and amount
        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(TOKE, tokeRewardAmount);

        // Execute claimRewards as strategy owner
        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 4.99e6);

        // Verify rewards were received and vault got the asset
        uint256 vaultBalanceAfter = IERC20(USDC).balanceOf(vault);
        assertGt(received, 0, "No rewards received from claim");
        assertEq(received, mockSwapReturn, "Received amount does not match expected swap output");
        assertEq(vaultBalanceAfter - vaultBalanceBefore, received, "Vault did not receive expected USDC amount");
    }

    function test_claimRewards_returns_zero_when_staking_enabled() public {
        // Allocate assets to create a Tokemak position
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 100e6;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        uint256 tokeRewardAmount = 10e18;

        // Deploy a MockTokeRewarder with staking ENABLED:
        // rewardToken == TOKE AND tokeLockDuration > 0 → stakingDisabled = false
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 1);
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);

        // Record vault USDC balance before claiming
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);

        // Execute claimRewards as strategy owner — should return 0
        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 9.99e18);

        // Verify nothing was returned and vault balance is unchanged
        uint256 vaultBalanceAfter = IERC20(USDC).balanceOf(vault);
        assertEq(received, 0, "Should return 0 when staking is enabled");
        assertEq(vaultBalanceAfter, vaultBalanceBefore, "Vault balance should not change when staking is enabled");
    }

    // End-to-end test: Full lifecycle with time accumulation for TokeAutoUSD
    function test_toke_auto_usd_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Initial allocation
        uint256 alloc1 = 300e6; // 300 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e5);
        
        // Warp forward 14 days
        vm.warp(block.timestamp + 14 days);
        
        // Additional allocation
        uint256 alloc2 = 200e6; // 200 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        
        // Warp forward 30 days
        vm.warp(block.timestamp + 30 days);
        
        // Partial deallocation (withdraw 100 USDC)
        uint256 deallocAmount1 = 100e6;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");
        
        // Warp forward 60 days
        vm.warp(block.timestamp + 60 days);
        
        // Check vault USDC balance
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }
        
        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(finalVaultUSDCBalance, vaultUSDCBalance, "Vault USDC should increase after deallocation");
        
        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_toke_auto_usd_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        // Use bound for array length instead of assume
        uint256 numOps = bound(amounts.length, 1, 8);
        // Ensure we don't access beyond array bounds
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;
        
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        for (uint256 i = 0; i < maxIterations; i++) {
            // Alternate between allocation and deallocation
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 10e6, 50e6); // 10-50 USDC
            
            if (isAllocate) {
                IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                uint256 deallocAmount = 0;
                if (currentAllocation > 0) {
                    deallocAmount = bound(amount, 0, currentAllocation);
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
            vm.warp(block.timestamp + timeDelay);
        }
        
        // Final sanity checks
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        vm.stopPrank();
    }

    // Test: TokeAutoUSD with reward claiming over time
    function test_toke_auto_usd_rewards_over_time() public {
        vm.startPrank(allocator);
        
        // Allocate initial amount
        uint256 allocAmount = 250e6; // 250 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        
        // Warp 30 days
        _warpWithHook(30 days);
        
        // Setup reward claiming mock (staking disabled)
        uint256 tokeRewardAmount = 10e18;
        uint256 mockSwapReturn = 5e6;
        MockTokeRewarder mockRew = new MockTokeRewarder(TOKE, tokeRewardAmount, TOKE, 0);
        bytes memory rewarderCodeBeforeMock = REWARDER.code;
        vm.etch(REWARDER, address(mockRew).code);
        deal(TOKE, REWARDER, tokeRewardAmount);
        MockSwapExecutor mockSwap = new MockSwapExecutor(USDC, mockSwapReturn);
        deal(USDC, address(mockSwap), mockSwapReturn);
        
        vm.stopPrank();
        vm.startPrank(address(1));
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));
        
        // Claim rewards
        bytes memory quote = hex"01";
        vm.stopPrank();
        vm.startPrank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(TOKE, quote, 4.99e6);
        
        assertGt(received, 0, "Should receive rewards");
        vm.etch(REWARDER, rewarderCodeBeforeMock);
        
        // Continue with allocations/deallocations
        vm.stopPrank();
        vm.startPrank(allocator);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        
        _warpWithHook(30 days);
        
        // Small deallocation
        uint256 smallDealloc = 30e6;
        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
        
        _warpWithHook(30 days);
        
        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }
        
        // Allow small residual dust from share/asset rounding on Tokemak redeem path.
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, 1e5, "All real assets should be deallocated");
        
        vm.stopPrank();
    }
}
