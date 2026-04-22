// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/StrategySetup.sol";
import {RevertContext} from "../base/StrategyTypes.sol";
import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../../AlchemistV3PositionRenderer.sol";
import {Transmuter} from "../../Transmuter.sol";
import {AaveStrategy} from "../../strategies/AaveStrategy.sol";
import {WstETHEthereumStrategy} from "../../strategies/WstETHEthereumStrategy.sol";
import {MYTTokenSwapper, IFluidATokenSwap} from "../../MYTTokenSwapper.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IWstETHLike} from "../../interfaces/IWstETHLike.sol";
import {IAlchemistV3Errors, AlchemistInitializationParams} from "../../interfaces/IAlchemistV3.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {AlchemistNFTHelper} from "../libraries/AlchemistNFTHelper.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockSwapExecutor {
    IERC20 public immutable sellToken;
    IERC20 public immutable buyToken;
    uint256 public amountToTransfer;

    constructor(address _sellToken, address _buyToken, uint256 _amountToTransfer) {
        sellToken = IERC20(_sellToken);
        buyToken = IERC20(_buyToken);
        amountToTransfer = _amountToTransfer;
    }

    fallback() external {
        uint256 sellAllowance = sellToken.allowance(msg.sender, address(this));
        if (sellAllowance > 0) {
            sellToken.transferFrom(msg.sender, address(this), sellAllowance);
        }
        buyToken.transfer(msg.sender, amountToTransfer);
    }
}

contract MYTTokenSwapperTest is StrategySetup {
    address public constant AAVE_V3_ETH_WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address public constant AAVE_V3_ETH_WSTETH_ATOKEN = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address public constant AAVE_V3_ETH_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WSTETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address public constant FLUID_A_TOKEN_SWAP = 0x4f8f03caD7512E4F6d1050FB9b2F8b91aE4bC901;
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

    function createStrategy(address _vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new AaveStrategy(
                _vault, params, WETH, AAVE_V3_ETH_WETH_ATOKEN, AAVE_V3_ETH_POOL_ADDRESS_PROVIDER, REWARDS_CONTROLLER, WSTETH
            )
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

    function _allocateToPrimaryStrategy(uint256 amount) internal {
        // Allocate real WETH from the MYT vault into the source Aave strategy through the normal
        // vault -> adapter -> Aave supply flow used in production.
        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
    }

    function _deployLocalAlchemistStack() internal returns (LocalAlchemistStack memory stack) {
        // Deploy a minimal alAsset + transmuter pair for the isolated liquidation scenario.
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

        // Initialize an Alchemist proxy that treats the existing MYT vault shares as collateral.
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

        // Wire the transmuter, debt token, and position NFT into the new Alchemist.
        stack.transmuter.setDepositCap(uint256(type(int256).max));
        stack.transmuter.setAlchemist(address(stack.alchemist));
        stack.debtToken.setWhitelist(address(stack.alchemist), true);

        stack.positionNft = new AlchemistV3Position(address(stack.alchemist), address(this));
        stack.positionNft.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        stack.alchemist.setAlchemistPositionNFT(address(stack.positionNft));
    }

    function _deployAndRegisterWstethStrategy() internal returns (address targetStrategy) {
        IMYTStrategy.StrategyParams memory params = getStrategyConfig();
        params.name = "WstethTarget";
        params.protocol = "WstethTarget";

        // Deploy a mainnet WstETH strategy that only needs to accept transferred raw wstETH and report its
        // value in WETH terms.
        vm.startPrank(admin);
        targetStrategy = address(new WstETHEthereumStrategy(vault, params, WSTETH, WSTETH_ETH_ORACLE));
        vm.stopPrank();

        // Register the target adapter on the same MYT vault with the same caps as the source.
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

    function _deployAndRegisterWstethEthereumStrategy(uint256 absoluteCap, uint256 relativeCap)
        internal
        returns (address targetStrategy)
    {
        IMYTStrategy.StrategyParams memory params = getStrategyConfig();
        params.name = "WstETHEthereumTarget";
        params.protocol = "WstETHEthereumTarget";

        vm.startPrank(admin);
        targetStrategy = address(new WstETHEthereumStrategy(vault, params, WSTETH, WSTETH_ETH_ORACLE));
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, targetStrategy));
        IVaultV2(vault).addAdapter(targetStrategy);

        bytes memory idData = IMYTStrategy(targetStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, absoluteCap)));
        IVaultV2(vault).increaseAbsoluteCap(idData, absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, relativeCap)));
        IVaultV2(vault).increaseRelativeCap(idData, relativeCap);
        vm.stopPrank();
    }

    function _quoteFluidMigration(uint256 requestedAmount)
        internal
        view
        returns (uint256 amountToMove, uint256 quotedAethwstEthOut, uint256 minAethwstEthOut)
    {
        // Stay below Fluid's live max-swap ceiling so the mainnet fork test remains deterministic.
        uint256 fluidMaxSwap = IFluidATokenSwap(FLUID_A_TOKEN_SWAP).maxSwapToWstETH();
        require(fluidMaxSwap > 1e18, "no fluid capacity");

        amountToMove = requestedAmount;
        uint256 safeFluidLimit = fluidMaxSwap - 1;
        if (amountToMove > safeFluidLimit) amountToMove = safeFluidLimit;

        quotedAethwstEthOut = IFluidATokenSwap(FLUID_A_TOKEN_SWAP).getWstETHAmountOut(amountToMove);
        minAethwstEthOut = quotedAethwstEthOut > 1 ? quotedAethwstEthOut - 1 : quotedAethwstEthOut;
    }

    function _installSwapperAndMigrate(uint256 amountToMove, uint256 minAethwstEthOut, address targetStrategy)
        internal
        returns (uint256 reportedReceived, address helper)
    {
        // Install the migration helper as the source strategy's temporary allowance holder.
        MYTTokenSwapper swapper = new MYTTokenSwapper(
            admin,
            AAVE_V3_ETH_WETH_ATOKEN,
            AAVE_V3_ETH_WSTETH_ATOKEN,
            WSTETH,
            FLUID_A_TOKEN_SWAP,
            AAVE_V3_ETH_POOL_ADDRESS_PROVIDER
        );
        helper = address(swapper);
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(helper);

        // Keep dexSwap's "to" token on harmless WETH while the helper forwards raw wstETH to the
        // destination strategy.
        bytes memory callData = abi.encodeCall(
            MYTTokenSwapper.swapAaveWethToWstethViaFluid,
            (amountToMove, minAethwstEthOut, targetStrategy)
        );

        vm.prank(admin);
        reportedReceived = AaveStrategy(strategy).adminDexSwap(WETH, AAVE_V3_ETH_WETH_ATOKEN, amountToMove, 0, callData);
    }

    function _wstEthOracleAnswer() internal view returns (uint256 answer, uint256 scale) {
        (, int256 raw,, uint256 updatedAt,) = AggregatorV3Interface(WSTETH_ETH_ORACLE).latestRoundData();
        require(raw > 0 && updatedAt != 0, "invalid oracle answer");
        answer = uint256(raw);
        scale = 10 ** AggregatorV3Interface(WSTETH_ETH_ORACLE).decimals();
    }

    function _wstethToWethValue(uint256 wstethAmount) internal view returns (uint256) {
        (uint256 answer, uint256 scale) = _wstEthOracleAnswer();
        uint256 stEthAmount = IWstETHLike(WSTETH).getStETHByWstETH(wstethAmount);
        return stEthAmount * answer / scale;
    }

    function test_swapper_can_route_aWETH_to_target_wsteth_strategy_via_fluid() public {
        uint256 amountToAllocate = 500e18;

        // Allocate WETH into the source Aave strategy so it holds live aEthWETH.
        _allocateToPrimaryStrategy(amountToAllocate);

        // Register a real WstethStrategy on the same vault to receive the withdrawn raw wstETH.
        address targetStrategy = _deployAndRegisterWstethStrategy();
        bytes32 sourceId = IMYTStrategy(strategy).adapterId();
        bytes32 targetId = IMYTStrategy(targetStrategy).adapterId();

        (uint256 amountToMove,, uint256 minAethwstEthOut) = _quoteFluidMigration(amountToAllocate * 98 / 100);

        // Snapshot live balances and vault accounting before executing the helper-driven migration.
        uint256 totalAssetsBefore = IVaultV2(vault).totalAssets();
        uint256 vaultIdleBefore = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 sourceATokenBefore = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 manualTotalBefore = vaultIdleBefore + sourceRealAssetsBefore;
        assertEq(IMYTStrategy(targetStrategy).realAssets(), 0, "target strategy should start empty");
        assertEq(IERC20(WSTETH).balanceOf(targetStrategy), 0, "target strategy should start without wstETH");

        (uint256 reportedReceived,) = _installSwapperAndMigrate(amountToMove, minAethwstEthOut, targetStrategy);

        // Re-read live strategy balances and vault accounting after the Fluid + Aave migration leg.
        uint256 totalAssetsAfter = IVaultV2(vault).totalAssets();
        uint256 vaultIdleAfter = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 targetRealAssetsAfter = IMYTStrategy(targetStrategy).realAssets();
        uint256 sourceATokenAfter = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);
        uint256 targetWstethAfter = IERC20(WSTETH).balanceOf(targetStrategy);
        uint256 expectedTargetValueFromBalance = _wstethToWethValue(targetWstethAfter);
        uint256 realizedLoss = (sourceRealAssetsBefore - sourceRealAssetsAfter) - targetRealAssetsAfter;
        uint256 manualTotalAfter = vaultIdleAfter + sourceRealAssetsAfter + targetRealAssetsAfter;

        // The source loses aEthWETH, the target receives raw wstETH, and the migration realizes
        // Fluid's premium haircut instead of preserving total value exactly.
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

        // Seed a small allocator-managed allocation on the target strategy so the vault records a
        // non-zero target allocation before attempting an allocator-driven deallocation.
        uint256 managedAllocateAmount = 5e18;
        uint256 managedAllocateWstethOut = 10e18;
        MockSwapExecutor allocSwap = new MockSwapExecutor(WETH, WSTETH, managedAllocateWstethOut);
        deal(WSTETH, address(allocSwap), managedAllocateWstethOut);

        vm.prank(admin);
        MYTStrategy(targetStrategy).setAllowanceHolder(address(allocSwap));

        vm.prank(admin);
        IAllocator(allocator).allocateWithSwap(targetStrategy, managedAllocateAmount, hex"01");

        uint256 targetAllocationAfterManagedAllocate = IVaultV2(vault).allocation(targetId);
        uint256 targetWstethBeforeAllocatorDeallocate = IERC20(WSTETH).balanceOf(targetStrategy);
        uint256 targetRealAssetsBeforeAllocatorDeallocate = IMYTStrategy(targetStrategy).realAssets();
        uint256 vaultIdleBeforeAllocatorDeallocate = IERC20(WETH).balanceOf(vault);
        assertGt(targetAllocationAfterManagedAllocate, 0, "target strategy should have managed allocation before deallocate");

        // Prove the allocator can still unwind the target WstethStrategy after it has received the
        // migrated wstETH, as long as the vault has some recorded allocation for that adapter.
        uint256 previewedTargetDeallocate = IMYTStrategy(targetStrategy).previewAdjustedWithdraw(managedAllocateAmount);
        MockSwapExecutor deallocSwap = new MockSwapExecutor(WSTETH, WETH, previewedTargetDeallocate);
        deal(WETH, address(deallocSwap), previewedTargetDeallocate);

        vm.prank(admin);
        MYTStrategy(targetStrategy).setAllowanceHolder(address(deallocSwap));

        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(targetStrategy, previewedTargetDeallocate, hex"01");

        uint256 targetAllocationAfterAllocatorDeallocate = IVaultV2(vault).allocation(targetId);
        uint256 targetWstethAfterAllocatorDeallocate = IERC20(WSTETH).balanceOf(targetStrategy);
        uint256 targetRealAssetsAfterAllocatorDeallocate = IMYTStrategy(targetStrategy).realAssets();
        uint256 vaultIdleAfterAllocatorDeallocate = IERC20(WETH).balanceOf(vault);

        assertLt(
            targetAllocationAfterAllocatorDeallocate,
            targetAllocationAfterManagedAllocate,
            "allocator deallocation should reduce target allocation"
        );
        assertLt(
            targetWstethAfterAllocatorDeallocate,
            targetWstethBeforeAllocatorDeallocate,
            "allocator deallocation should reduce target wstETH"
        );
        assertLt(
            targetRealAssetsAfterAllocatorDeallocate,
            targetRealAssetsBeforeAllocatorDeallocate,
            "allocator deallocation should reduce target real assets"
        );
        assertGe(
            vaultIdleAfterAllocatorDeallocate - vaultIdleBeforeAllocatorDeallocate,
            previewedTargetDeallocate,
            "allocator deallocation should return WETH to the vault"
        );
    }

    function test_swapper_max_ltv_user_is_not_liquidatable_while_vault_total_assets_stay_stale() public {
        uint256 amountToAllocate = 500e18;
        uint256 userDepositShares = 100e18;
        address user = vaultDepositor;
        address liquidator = address(0xBEEF);

        // Allocate half of the vault into the source strategy, leaving the other half idle.
        _allocateToPrimaryStrategy(amountToAllocate);

        // Add the target WstethStrategy that will receive the migrated wstETH position.
        address targetStrategy = _deployAndRegisterWstethStrategy();
        bytes32 sourceId = IMYTStrategy(strategy).adapterId();
        bytes32 targetId = IMYTStrategy(targetStrategy).adapterId();

        // The source strategy should represent about half of total MYT value before the migration.
        uint256 totalAssetsBeforeMove = IVaultV2(vault).totalAssets();
        uint256 sourceAllocationBeforeMove = IVaultV2(vault).allocation(sourceId);
        assertApproxEqAbs(sourceAllocationBeforeMove * 2, totalAssetsBeforeMove, 4, "source strategy should be ~50% of MYT");
        assertEq(IVaultV2(vault).allocation(targetId), 0, "target strategy should start with zero allocation");

        // Deploy a minimal Alchemist stack that uses MYT shares as collateral.
        LocalAlchemistStack memory stack = _deployLocalAlchemistStack();

        // Have a single user deposit vault shares and mint to the maximum borrowable amount.
        vm.startPrank(user);
        IERC20(address(vault)).approve(address(stack.alchemist), type(uint256).max);
        stack.alchemist.deposit(userDepositShares, user, 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(stack.positionNft));
        uint256 maxBorrowable = stack.alchemist.getMaxBorrowable(tokenId);
        stack.alchemist.mint(tokenId, maxBorrowable, user);
        vm.stopPrank();

        // Snapshot the user's collateral view and the vault's manual economic value before moving.
        uint256 totalValueBefore = stack.alchemist.totalValue(tokenId);
        (, uint256 debtBefore,) = stack.alchemist.getCDP(tokenId);
        uint256 vaultIdleBefore = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 manualTotalBefore = vaultIdleBefore + sourceRealAssetsBefore;
        assertGt(totalValueBefore, 0, "user should have collateral value");
        assertGt(debtBefore, 0, "user should have debt");

        (uint256 amountToMove,, uint256 minAethwstEthOut) = _quoteFluidMigration(sourceAllocationBeforeMove * 99 / 100);

        _installSwapperAndMigrate(amountToMove, minAethwstEthOut, targetStrategy);

        // The helper migration realizes a manual economic loss, but the mock vault bookkeeping
        // stays stale, so the collateral view exposed to the Alchemist remains unchanged.
        uint256 totalAssetsAfterMove = IVaultV2(vault).totalAssets();
        uint256 totalValueAfter = stack.alchemist.totalValue(tokenId);
        (, uint256 debtAfter,) = stack.alchemist.getCDP(tokenId);
        uint256 vaultIdleAfter = IERC20(WETH).balanceOf(vault);
        uint256 sourceRealAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 targetRealAssetsAfter = IMYTStrategy(targetStrategy).realAssets();
        uint256 manualTotalAfter = vaultIdleAfter + sourceRealAssetsAfter + targetRealAssetsAfter;

        assertLt(manualTotalAfter, manualTotalBefore, "manual economic value should fall after the Fluid haircut");
        assertApproxEqAbs(totalAssetsAfterMove, totalAssetsBeforeMove, 2, "vault total assets should stay stale in this harness");
        assertApproxEqAbs(totalValueAfter, totalValueBefore, 2, "user collateral value should stay unchanged in this harness");
        assertEq(debtAfter, debtBefore, "user debt should not change before liquidation");
        assertApproxEqAbs(
            IVaultV2(vault).allocation(sourceId),
            sourceAllocationBeforeMove,
            1,
            "source strategy allocation should remain stale"
        );
        assertEq(IVaultV2(vault).allocation(targetId), 0, "target strategy allocation should remain zero");

        // Because the vault's share-price bookkeeping does not move with the manual migration in
        // this test harness, the position still appears healthy and regular liquidation reverts.
        vm.prank(liquidator);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        stack.alchemist.liquidate(tokenId);
    }

    function test_guardrailed_migration_keeps_both_adapters_live_and_syncs_target_allocation() public {
        uint256 amountToAllocate = 500e18;
        uint256 syncAllocateAmount = 1e9;

        _allocateToPrimaryStrategy(amountToAllocate);

        address targetStrategy = _deployAndRegisterWstethEthereumStrategy(testConfig.absoluteCap, testConfig.relativeCap);
        bytes32 sourceId = IMYTStrategy(strategy).adapterId();
        bytes32 targetId = IMYTStrategy(targetStrategy).adapterId();
        address originalAllowanceHolder = MYTStrategy(strategy).allowanceHolder();

        assertEq(IVaultV2(vault).adaptersLength(), 2, "migration should keep both adapters registered");
        assertTrue(IVaultV2(vault).isAdapter(strategy), "source adapter should remain active");
        assertTrue(IVaultV2(vault).isAdapter(targetStrategy), "target adapter should be active before migration");
        assertEq(IVaultV2(vault).allocation(targetId), 0, "target allocation should start at zero");

        bytes memory sourceIdData = IMYTStrategy(strategy).getIdData();
        vm.prank(curator);
        IVaultV2(vault).decreaseAbsoluteCap(sourceIdData, 0);
        assertEq(IVaultV2(vault).absoluteCap(sourceId), 0, "source strategy cap should be frozen before migration");

        vm.prank(admin);
        vm.expectRevert();
        IAllocator(allocator).allocate(strategy, 1e18);

        (uint256 amountToMove,, uint256 minAethwstEthOut) = _quoteFluidMigration(amountToAllocate * 98 / 100);
        uint256 sourceAllocationBeforeMigration = IVaultV2(vault).allocation(sourceId);
        uint256 sourceATokenBeforeMigration = IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy);

        (uint256 reportedReceived, address helper) =
            _installSwapperAndMigrate(amountToMove, minAethwstEthOut, targetStrategy);

        uint256 targetRealAssetsBeforeSync = IMYTStrategy(targetStrategy).realAssets();
        assertEq(reportedReceived, 0, "migration helper should not report WETH received on the source strategy");
        assertEq(MYTStrategy(strategy).allowanceHolder(), helper, "source strategy should point at the helper during migration");
        assertGe(
            sourceATokenBeforeMigration - IERC20(AAVE_V3_ETH_WETH_ATOKEN).balanceOf(strategy),
            amountToMove,
            "source strategy should lose the migrated aWETH"
        );
        assertGt(targetRealAssetsBeforeSync, 0, "target strategy should receive migrated wstETH");
        assertEq(IVaultV2(vault).allocation(targetId), 0, "target allocation stays stale until a post-migration sync");
        assertGe(
            IVaultV2(vault).absoluteCap(targetId),
            targetRealAssetsBeforeSync,
            "target cap should already cover the migrated position before syncing"
        );
        assertTrue(IVaultV2(vault).isAdapter(strategy), "source adapter should stay registered throughout migration");
        assertTrue(IVaultV2(vault).isAdapter(targetStrategy), "target adapter should stay registered throughout migration");

        vm.prank(admin);
        IAllocator(allocator).allocate(targetStrategy, syncAllocateAmount);

        uint256 targetAllocationAfterSync = IVaultV2(vault).allocation(targetId);
        uint256 targetRealAssetsAfterSync = IMYTStrategy(targetStrategy).realAssets();
        assertGt(
            targetAllocationAfterSync,
            syncAllocateAmount,
            "post-migration sync should book the full migrated position, not just the dust allocation"
        );
        assertApproxEqAbs(
            targetAllocationAfterSync,
            targetRealAssetsAfterSync,
            3,
            "target allocation should track live real assets after the sync allocate"
        );
        assertApproxEqAbs(
            IVaultV2(vault).allocation(sourceId),
            sourceAllocationBeforeMigration,
            1,
            "source allocation should remain stale until it is explicitly unwound"
        );

        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(originalAllowanceHolder);
        assertEq(
            MYTStrategy(strategy).allowanceHolder(),
            originalAllowanceHolder,
            "migration should restore the source strategy allowance holder"
        );
    }

    function test_guardrailed_migration_sync_allocate_reverts_when_target_cap_is_too_low() public {
        uint256 amountToAllocate = 500e18;
        uint256 syncAllocateAmount = 1e9;

        _allocateToPrimaryStrategy(amountToAllocate);

        address targetStrategy = _deployAndRegisterWstethEthereumStrategy(1e18, testConfig.relativeCap);
        bytes32 sourceId = IMYTStrategy(strategy).adapterId();
        bytes32 targetId = IMYTStrategy(targetStrategy).adapterId();

        bytes memory sourceIdData = IMYTStrategy(strategy).getIdData();
        vm.prank(curator);
        IVaultV2(vault).decreaseAbsoluteCap(sourceIdData, 0);
        assertEq(IVaultV2(vault).absoluteCap(sourceId), 0, "source strategy cap should be frozen before migration");

        (uint256 amountToMove,, uint256 minAethwstEthOut) = _quoteFluidMigration(amountToAllocate * 98 / 100);
        _installSwapperAndMigrate(amountToMove, minAethwstEthOut, targetStrategy);

        assertGt(
            IMYTStrategy(targetStrategy).realAssets(),
            IVaultV2(vault).absoluteCap(targetId),
            "test setup should preload more value than the target cap allows"
        );

        vm.prank(admin);
        vm.expectRevert();
        IAllocator(allocator).allocate(targetStrategy, syncAllocateAmount);
    }
}
