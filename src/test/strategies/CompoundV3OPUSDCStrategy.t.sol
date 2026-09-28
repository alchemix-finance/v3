// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {CompoundV3Strategy, IComet} from "../../strategies/CompoundV3Strategy.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";

interface ICometRewardsConfig {
    function rewardConfig(address comet) external view returns (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier);
}

contract CompoundV3OPUSDCStrategyTest is BaseStrategyTest {
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant COMET = 0x2e44e174f7D53F0212823acC11C01A11d58c5bCB;
    address internal constant COMET_REWARDS = 0x443EA0340cb75a160F31A440722dec7b5bc3C2E9;
    address internal constant COMP = 0x7e7d4467112689329f7E06571eD0E8CbAd4910eE;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "CompoundV3OPUSDC",
            protocol: "CompoundV3",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: true,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 1000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new CompoundV3Strategy(vault, params, COMET, COMET_REWARDS, COMP));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 157_189_422;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function test_compound_market_assets_match_strategy() public view {
        CompoundV3Strategy compoundStrategy = CompoundV3Strategy(strategy);
        (address configuredRewardToken,,,) = ICometRewardsConfig(COMET_REWARDS).rewardConfig(COMET);

        assertEq(IVaultV2(vault).asset(), USDC, "MYT asset mismatch");
        assertEq(address(compoundStrategy.mytAsset()), USDC, "strategy asset mismatch");
        assertEq(address(compoundStrategy.comet()), COMET, "Comet market mismatch");
        assertEq(IComet(COMET).baseToken(), USDC, "Comet base asset mismatch");
        assertEq(address(compoundStrategy.rewards()), COMET_REWARDS, "Comet rewards mismatch");
        assertEq(address(compoundStrategy.rewardToken()), COMP, "strategy reward asset mismatch");
        assertEq(configuredRewardToken, COMP, "Comet reward asset mismatch");
    }

    function test_preview_caps_requested_assets_to_real_assets() public {
        uint256 amount = 1e6;
        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(type(uint256).max);
        assertLt(preview, realAssets, "preview must preserve the rounding reserve");

        IAllocator(allocator).deallocate(strategy, preview);
        vm.stopPrank();

        assertEq(IComet(COMET).borrowBalanceOf(strategy), 0, "strategy must not borrow");
    }

    function test_deallocate_reverts_instead_of_borrowing() public {
        uint256 amount = 1e6;
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 supplied = IComet(COMET).balanceOf(strategy);
        vm.expectRevert(abi.encodeWithSelector(CompoundV3Strategy.CompoundV3BorrowNotAllowed.selector, supplied + 1, supplied));
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), supplied + 1, bytes4(0), admin);
    }

    function test_real_assets_reverts_if_compound_debt_exists() public {
        vm.mockCall(COMET, abi.encodeCall(IComet.borrowBalanceOf, (strategy)), abi.encode(1));
        vm.expectRevert(abi.encodeWithSelector(CompoundV3Strategy.CompoundV3DebtDetected.selector, 1));
        IMYTStrategy(strategy).realAssets();
    }

    function test_constructor_reverts_for_mismatched_reward_token() public {
        vm.expectRevert(abi.encodeWithSelector(CompoundV3Strategy.CompoundV3RewardTokenMismatch.selector, USDC, COMP));
        new CompoundV3Strategy(vault, getStrategyConfig(), COMET, COMET_REWARDS, USDC);
    }
}
