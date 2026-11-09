// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {ErrorsLib} from "lib/vault-v2/src/libraries/ErrorsLib.sol";

import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MorphoBlueMarketStrategy} from "../../strategies/MorphoBlueMarketStrategy.sol";
import {IMorphoBlue, IMorphoIrm, Market, MarketParams} from "../../strategies/interfaces/IMorphoBlue.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";

/// @notice Shared constants for the Base Morpho Blue savUSD/USDC (91.5% LLTV) market.
library MorphoSavUSDUSDCMarket {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant SAVUSD = 0xa6EF20FE18CD529cA15A8a53A29D1832B1F848ff;
    address internal constant ORACLE = 0xFfa96076474A6e5A8dC481D40109cF1626cfe4A4;
    address internal constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 internal constant LLTV = 0.915e18;
    bytes32 internal constant MARKET_ID = 0x4217fed63c853537fb818f4ba4416bc708c3d7534913532feb34c3511ce2aba6;
    uint256 internal constant FORK_BLOCK = 53_930_000;
    string internal constant RPC_FALLBACK = "https://base.gateway.tenderly.co";

    function marketParams() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: USDC, collateralToken: SAVUSD, oracle: ORACLE, irm: IRM, lltv: LLTV});
    }

    function strategyParams(address owner_) internal pure returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: owner_,
            name: "Morpho savUSD/USDC Market",
            protocol: "Morpho Blue",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 645,
            additionalIncentives: true,
            slippageBPS: 50
        });
    }
}

contract MorphoSavUSDUSDCStrategyTest is BaseStrategyTest {
    function getStrategyConfig() internal view override returns (IMYTStrategy.StrategyParams memory) {
        return MorphoSavUSDUSDCMarket.strategyParams(admin);
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({
            vaultAsset: MorphoSavUSDUSDCMarket.USDC,
            vaultInitialDeposit: 10_000e6,
            absoluteCap: 10_000e6,
            relativeCap: 0.1e18,
            decimals: 6
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MorphoBlueMarketStrategy(vault_, params, MorphoSavUSDUSDCMarket.MORPHO_BLUE, MorphoSavUSDUSDCMarket.marketParams()));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return MorphoSavUSDUSDCMarket.FORK_BLOCK;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", MorphoSavUSDUSDCMarket.RPC_FALLBACK);
    }

    /// @dev Fuzz headroom is computed from the stale `allocation`; after long warps accrued interest can push the
    ///      position over a cap before the next allocate, so both cap errors are legitimate MYT-side rejections.
    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isAllocationFuzz = context == RevertContext.HandlerAllocate || context == RevertContext.FuzzAllocate;
        return isAllocationFuzz && (selector == ErrorsLib.RelativeCapExceeded.selector || selector == ErrorsLib.AbsoluteCapExceeded.selector);
    }

    /// @dev Morpho can only return what borrowers have not drawn; clamp requests to idle + min(position, liquidity).
    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);
        uint256 position = s.expectedSupplyAssets();
        uint256 liquidity = s.availableLiquidity();
        uint256 withdrawable = IERC20(testConfig.vaultAsset).balanceOf(strategy) + (position < liquidity ? position : liquidity);
        return requestedAssets < withdrawable ? requestedAssets : withdrawable;
    }

    function test_morphoMarket_wiring() public view {
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);
        assertEq(address(s.mytAsset()), MorphoSavUSDUSDCMarket.USDC, "unexpected MYT asset");
        assertEq(address(s.morpho()), MorphoSavUSDUSDCMarket.MORPHO_BLUE, "unexpected morpho");
        assertEq(s.marketId(), MorphoSavUSDUSDCMarket.MARKET_ID, "unexpected market id");
        assertEq(s.collateralToken(), MorphoSavUSDUSDCMarket.SAVUSD, "unexpected collateral");
        assertEq(s.oracle(), MorphoSavUSDUSDCMarket.ORACLE, "unexpected oracle");
        assertEq(s.irm(), MorphoSavUSDUSDCMarket.IRM, "unexpected irm");
        assertEq(s.lltv(), MorphoSavUSDUSDCMarket.LLTV, "unexpected lltv");

        MarketParams memory onchain = IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE).idToMarketParams(MorphoSavUSDUSDCMarket.MARKET_ID);
        assertEq(onchain.loanToken, MorphoSavUSDUSDCMarket.USDC, "onchain loan token mismatch");
        assertEq(onchain.collateralToken, MorphoSavUSDUSDCMarket.SAVUSD, "onchain collateral mismatch");
        assertEq(s.realAssets(), 0, "fresh strategy should be empty");
        assertFalse(s.canForceDeallocate(), "force deallocate should default disabled");
    }

    function test_morphoMarket_constructorRejectsWrongLoanToken() public {
        MarketParams memory bad = MorphoSavUSDUSDCMarket.marketParams();
        bad.loanToken = MorphoSavUSDUSDCMarket.SAVUSD;
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueMarketStrategy.LoanTokenMismatch.selector, bad.loanToken, MorphoSavUSDUSDCMarket.USDC));
        new MorphoBlueMarketStrategy(vault, getStrategyConfig(), MorphoSavUSDUSDCMarket.MORPHO_BLUE, bad);
    }

    function test_morphoMarket_constructorRejectsUncreatedMarket() public {
        MarketParams memory bad = MorphoSavUSDUSDCMarket.marketParams();
        bad.lltv = 0.5e18;
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueMarketStrategy.MarketNotCreated.selector, keccak256(abi.encode(bad))));
        new MorphoBlueMarketStrategy(vault, getStrategyConfig(), MorphoSavUSDUSDCMarket.MORPHO_BLUE, bad);
    }

    function test_morphoMarket_swapRoutesUnsupported() public {
        IMYTStrategy.VaultAdapterParams memory p;
        p.action = IMYTStrategy.ActionType.swap;
        p.swapParams = IMYTStrategy.SwapParams({txData: hex"1234", minIntermediateOut: 0});
        bytes memory data = abi.encode(p);

        deal(testConfig.vaultAsset, strategy, 100e6);
        vm.startPrank(vault);
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(strategy).allocate(data, 100e6, "", vault);
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(strategy).deallocate(data, 1, "", vault);
        vm.stopPrank();
    }

    function test_morphoMarket_allocateSuppliesAndAccrues() public {
        uint256 amount = 1_000e6;
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amount);

        uint256 supplied = s.expectedSupplyAssets();
        assertApproxEqAbs(supplied, amount, 2, "supplied should match allocation");
        assertEq(IERC20(testConfig.vaultAsset).balanceOf(strategy), 0, "no idle USDC after allocate");
        assertGt(IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE).position(MorphoSavUSDUSDCMarket.MARKET_ID, strategy).supplyShares, 0, "no shares");
        assertEq(IVaultV2(vault).allocation(s.adapterId()), s.realAssets(), "allocation tracks realAssets");

        // Projected accrual must agree with Morpho's own accrual once it is written on-chain.
        vm.warp(block.timestamp + 30 days);
        uint256 projected = s.expectedSupplyAssets();
        assertGt(projected, supplied, "interest should accrue");
        IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE).accrueInterest(MorphoSavUSDUSDCMarket.marketParams());
        assertApproxEqAbs(s.expectedSupplyAssets(), projected, 1, "projection must match on-chain accrual");
    }

    function test_morphoMarket_partialAndFullDeallocate() public {
        uint256 amount = 1_000e6;
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amount);

        uint256 preview = s.previewAdjustedWithdraw(400e6);
        assertLt(preview, 400e6, "preview applies slippage buffer");
        uint256 vaultBefore = IERC20(testConfig.vaultAsset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), preview);
        assertEq(IERC20(testConfig.vaultAsset).balanceOf(vault) - vaultBefore, preview, "vault receives exact amount");
        assertApproxEqAbs(s.realAssets(), amount - preview, 2, "remaining value");

        uint256 remaining = s.realAssets();
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), remaining);
        assertLe(s.realAssets(), 1, "position should be fully exited up to rounding dust");
    }

    function test_morphoMarket_deallocateBeyondLiquidityReverts() public {
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);
        uint256 amount = 1_000e6;
        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amount);

        // Drain market liquidity so our position exceeds what Morpho can release.
        Market memory m = IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE).market(MorphoSavUSDUSDCMarket.MARKET_ID);
        uint256 liquidity = m.totalSupplyAssets - m.totalBorrowAssets;
        _borrowAgainstFreshCollateral(liquidity - 100e6);

        uint256 position = s.expectedSupplyAssets();
        assertLt(s.availableLiquidity(), position, "liquidity should be below position");
        uint256 preview = s.previewAdjustedWithdraw(position);
        assertLt(preview, position * (10_000 - 50) / 10_000, "preview must be capped by liquidity");

        vm.prank(allocator);
        vm.expectRevert(bytes("insufficient liquidity"));
        IVaultV2(vault).deallocate(strategy, getVaultParams(), position);

        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), preview);
    }

    function test_morphoMarket_claimRewardsForwardsIdleAsset() public {
        uint256 reward = 25e6;
        deal(testConfig.vaultAsset, strategy, reward);
        uint256 vaultBefore = IERC20(testConfig.vaultAsset).balanceOf(vault);

        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(testConfig.vaultAsset, reward);
        vm.prank(admin);
        uint256 received = IMYTStrategy(strategy).claimRewards(testConfig.vaultAsset, "", 0);

        assertEq(received, reward, "returned amount");
        assertEq(IERC20(testConfig.vaultAsset).balanceOf(vault) - vaultBefore, reward, "vault receives rewards");
    }

    function test_morphoMarket_forceDeallocateDisabledByDefaultAndOwnerCanEnable() public {
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy);

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);

        vm.prank(admin);
        s.setCanForceDeallocate(true);
        deal(testConfig.vaultAsset, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);
    }

    /// @dev Borrow `amount` USDC from the market using a fresh account funded with savUSD collateral.
    function _borrowAgainstFreshCollateral(uint256 amount) internal {
        address borrower = makeAddr("liquidityDrainer");
        IMorphoBlue morpho = IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE);
        uint256 collateral = amount * 1e12 * 2; // 18 decimals, ~2x overcollateralized at ~$1.21/savUSD
        deal(MorphoSavUSDUSDCMarket.SAVUSD, borrower, collateral);

        vm.startPrank(borrower);
        IERC20(MorphoSavUSDUSDCMarket.SAVUSD).approve(address(morpho), collateral);
        (bool ok,) = address(morpho).call(
            abi.encodeWithSignature(
                "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)",
                MorphoSavUSDUSDCMarket.marketParams(),
                collateral,
                borrower,
                ""
            )
        );
        require(ok, "supplyCollateral failed");
        (ok,) = address(morpho).call(
            abi.encodeWithSignature(
                "borrow((address,address,address,address,uint256),uint256,uint256,address,address)",
                MorphoSavUSDUSDCMarket.marketParams(),
                amount,
                0,
                borrower,
                borrower
            )
        );
        require(ok, "borrow failed");
        vm.stopPrank();
    }
}

contract MorphoSavUSDUSDCInvariantTest is E2EInvariantStrategyTest {
    function getRpcUrl() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", MorphoSavUSDUSDCMarket.RPC_FALLBACK);
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return MorphoSavUSDUSDCMarket.FORK_BLOCK;
    }

    function getAsset() internal pure override returns (address) {
        return MorphoSavUSDUSDCMarket.USDC;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return MorphoSavUSDUSDCMarket.strategyParams(address(0));
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MorphoBlueMarketStrategy(vault_, params, MorphoSavUSDUSDCMarket.MORPHO_BLUE, MorphoSavUSDUSDCMarket.marketParams()));
    }

    function _enableForceDeallocate(address strategy_) internal override {
        MorphoBlueMarketStrategy(strategy_).setCanForceDeallocate(true);
    }

    /// @dev The handler bounds forced exits by `realAssets()` only. Multi-year fuzz warps compound the position past the
    ///      market's free liquidity, so Morpho correctly reverts; forced exits are covered by the unit suite instead.
    function _realStrategySupportsForceDeallocate() internal pure override returns (bool) {
        return false;
    }

    /// @dev Repeated year-long warps while the vault is the marginal supplier push utilization to 100% and let the
    ///      AdaptiveCurve IRM ramp toward its 2000% APR ceiling. Fee share growth is then driven by the IRM, not the
    ///      strategy, so the vault-level bound is only enforced while the market rate is below 100% APR.
    function invariant_feeRecipientSharesBounded() public view override {
        IMorphoBlue morpho = IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE);
        uint256 ratePerSecond = IMorphoIrm(MorphoSavUSDUSDCMarket.IRM).borrowRateView(
            MorphoSavUSDUSDCMarket.marketParams(), morpho.market(MorphoSavUSDUSDCMarket.MARKET_ID)
        );
        if (ratePerSecond * 365 days > 1e18) return;
        super.invariant_feeRecipientSharesBounded();
    }

    /// @dev Simulate loss by withdrawing supplied USDC from the strategy's position to a burn address.
    function onSimulateValueLoss(address strategy_, uint256 amount) external override {
        MorphoBlueMarketStrategy s = MorphoBlueMarketStrategy(strategy_);
        uint256 position = s.expectedSupplyAssets();
        uint256 liquidity = s.availableLiquidity();
        uint256 max = position < liquidity ? position : liquidity;
        if (amount > max) amount = max;
        if (amount == 0) return;

        vm.prank(strategy_);
        IMorphoBlue(MorphoSavUSDUSDCMarket.MORPHO_BLUE).withdraw(MorphoSavUSDUSDCMarket.marketParams(), amount, 0, strategy_, address(0xdead));
    }
}
