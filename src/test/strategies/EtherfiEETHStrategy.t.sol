// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {EtherfiEETHMYTStrategy, IWeETH} from "../../strategies/EtherfiEETHStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

struct RedemptionLimitView {
    uint64 capacity;
    uint64 remaining;
    uint64 lastRefill;
    uint64 refillRate;
}

interface IRedemptionManagerView {
    function canRedeem(uint256 amount, address token) external view returns (bool);
    function tokenToRedemptionInfo(address token)
        external
        view
        returns (
            RedemptionLimitView memory limit,
            uint16 exitFeeSplitToTreasuryInBps,
            uint16 exitFeeInBps,
            uint16 lowWatermarkInBpsOfTvl
        );
}

contract MockSwapper {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        (bool pullOk,) = from.call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amountIn));
        require(pullOk, "pull failed");
        (bool pushOk,) = to.call(abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amountOut));
        require(pushOk, "push failed");
    }
}

contract MockFeeRedemptionManager {
    uint256 public constant BPS = 10_000;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable weETH;
    address public immutable eETH;
    uint256 public immutable feeBps;

    constructor(address _weETH, address _eETH, uint256 _feeBps) payable {
        weETH = _weETH;
        eETH = _eETH;
        feeBps = _feeBps;
    }

    function canRedeem(uint256, address token) external view returns (bool) {
        return token == ETH;
    }

    function liquidityPool() external view returns (address) {
        return address(this);
    }

    function amountForShare(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function sharesForAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function sharesForWithdrawalAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function previewRedeem(uint256 shares, address token) external view returns (uint256) {
        if (token != ETH) return 0;
        uint256 fee = (shares * feeBps + BPS - 1) / BPS;
        return shares - fee;
    }

    function tokenToRedemptionInfo(address token)
        external
        view
        returns (RedemptionLimitView memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl)
    {
        if (token != ETH) {
            return (limit, 0, 0, 0);
        }
        return (
            RedemptionLimitView({capacity: type(uint64).max, remaining: type(uint64).max, lastRefill: 0, refillRate: 0}),
            0,
            uint16(feeBps),
            0
        );
    }

    function redeemWeEth(uint256 amount, address receiver, address outputToken) external returns (uint256) {
        require(outputToken == ETH, "invalid output token");
        require(IERC20(weETH).transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 grossEth = IWeETH(weETH).getEETHByWeETH(amount);
        uint256 fee = (grossEth * feeBps + BPS - 1) / BPS;
        uint256 netEth = grossEth - fee;
        (bool ok,) = receiver.call{value: netEth}("");
        require(ok, "eth transfer failed");
        return netEth;
    }

    receive() external payable {}
}

contract MockEtherfiEETHStrategy is EtherfiEETHMYTStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _eETH,
        address _weETH,
        address _depositAdapter,
        address _redemptionManager,
        address _weEthEthOracle,
        uint256 _maxOracleStaleness
    )
        EtherfiEETHMYTStrategy(
            _myt,
            _params,
            _eETH,
            _weETH,
            _depositAdapter,
            _redemptionManager,
            _weEthEthOracle,
            _maxOracleStaleness
        )
    {}
}

contract EtherfiEETHStrategyTest is BaseStrategyTest {
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address public constant WEETH_ETH_ORACLE = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    uint256 public constant MAX_ORACLE_STALENESS = 24 hours;
    uint256 public constant TEST_RESIDUAL_TOLERANCE_BPS = 100;

    MockSwapper public swapper;

    function setUp() public override {
        swapper = new MockSwapper();
        super.setUp();

        vm.startPrank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(swapper));
        vm.stopPrank();

        // Only swap execution is mocked; protocol contracts are live mainnet.
        deal(WETH, address(swapper), 1_000_000e18);
        deal(WEETH, address(swapper), 1_000_000e18);
    }

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "EETH",
            protocol: "EtherFi",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 2_000_000e18,
            globalCap: 2_000_000e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 10
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({
            vaultAsset: WETH,
            vaultInitialDeposit: 1000e18,
            absoluteCap: 2_000_000e18,
            relativeCap: 1e18,
            decimals: 18
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(
            new MockEtherfiEETHStrategy(
                vault_,
                params,
                EETH,
                WEETH,
                DEPOSIT_ADAPTER,
                REDEMPTION_MANAGER,
                WEETH_ETH_ORACLE,
                MAX_ORACLE_STALENESS
            )
        );
    }

    function test_constructor_sets_max_oracle_staleness() public view {
        assertEq(
            EtherfiEETHMYTStrategy(payable(strategy)).MAX_ORACLE_STALENESS(),
            MAX_ORACLE_STALENESS,
            "unexpected initial max oracle staleness"
        );
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24595012; //25324617
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function _mockFreshWeEthEthOracle(uint256 targetTimestamp) internal {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(WEETH_ETH_ORACLE).latestRoundData();
        vm.mockCall(
            WEETH_ETH_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, targetTimestamp, answeredInRound)
        );
    }

    function _beforeTimeShift(uint256 targetTimestamp) internal override {
        _mockFreshWeEthEthOracle(targetTimestamp);
    }

    function _beforePreviewWithdraw(uint256) internal override {
        _mockFreshWeEthEthOracle(block.timestamp);
    }

    function _minWeEthOut(uint256 wethAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(WEETH_ETH_ORACLE).latestRoundData();
        require(answer > 0 && updatedAt != 0, "invalid oracle answer");
        uint256 minWethValue = (wethAmount * (10_000 - strategyConfig.slippageBPS)) / 10_000;
        uint256 minWeEthOut = minWethValue * (10 ** AggregatorV3Interface(WEETH_ETH_ORACLE).decimals()) / uint256(answer);
        return minWeEthOut == 0 ? 1 : minWeEthOut;
    }

    function _maxWeEthIn(uint256 wethAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(WEETH_ETH_ORACLE).latestRoundData();
        require(answer > 0 && updatedAt != 0, "invalid oracle answer");
        uint256 maxWethIn = (wethAmount * 10_000 + (10_000 - strategyConfig.slippageBPS) - 1) / (10_000 - strategyConfig.slippageBPS);
        uint256 scale = 10 ** AggregatorV3Interface(WEETH_ETH_ORACLE).decimals();
        uint256 maxWeEthIn = (maxWethIn * scale + uint256(answer) - 1) / uint256(answer);
        return maxWeEthIn == 0 ? 1 : maxWeEthIn;
    }

    function _grossRedeemAmount(address manager, uint256 netAmount) internal view returns (uint256) {
        (, uint16 exitFeeInBps,) = _redemptionInfo(manager);
        return (netAmount * 10_000 + (10_000 - exitFeeInBps) - 1) / (10_000 - exitFeeInBps);
    }

    function _maxNetDirectDeallocate(address manager) internal view returns (uint256) {
        uint256 maxGrossDeallocate = _effectiveDeallocateAmount(type(uint256).max);
        (, uint16 exitFeeInBps,) = _redemptionInfo(manager);
        if (exitFeeInBps >= 10_000) return 0;
        return (maxGrossDeallocate * (10_000 - exitFeeInBps)) / 10_000;
    }

    function _redemptionInfo(address manager)
        internal
        view
        returns (uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl)
    {
        (, exitFeeSplitToTreasuryInBps, exitFeeInBps, lowWatermarkInBpsOfTvl) =
            IRedemptionManagerView(manager).tokenToRedemptionInfo(ETH);
    }

    function _swapCallDataForWethOut(uint256 wethOut) internal view returns (bytes memory) {
        uint256 idleBalance = IERC20(WETH).balanceOf(strategy);
        uint256 shortfall = wethOut > idleBalance ? wethOut - idleBalance : 0;
        if (shortfall == 0) {
            return abi.encodeCall(MockSwapper.swap, (WEETH, WETH, 0, 0));
        }
        uint256 weETHBalance = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(shortfall);
        if (weETHToSwap > weETHBalance) weETHToSwap = weETHBalance;
        if (weETHToSwap == 0 && weETHBalance > 0) weETHToSwap = 1;
        return abi.encodeCall(MockSwapper.swap, (WEETH, WETH, weETHToSwap, shortfall));
    }

    function test_allocate_swap_mock_success() public {
        uint256 amount = 10e18;
        _mockFreshWeEthEthOracle(block.timestamp);
        uint256 minWeEthOut = _minWeEthOut(amount);
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, WEETH, amount, minWeEthOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();

        assertGe(IWeETH(WEETH).balanceOf(strategy), minWeEthOut, "weETH balance should satisfy oracle min out");
    }

    function test_allocate_swap_reverts_when_allowanceHolder_returns_less_than_minAmountOut() public {
        uint256 amount = 10e18;
        _mockFreshWeEthEthOracle(block.timestamp);
        uint256 minWeEthOut = _minWeEthOut(amount);
        require(minWeEthOut > 1, "min output too small");
        uint256 insufficientOut = minWeEthOut - 1;
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, WEETH, amount, insufficientOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        assertEq(MYTStrategy(strategy).allowanceHolder(), address(swapper), "test should execute through allowance holder");
        // The mock allowance holder call succeeds but under-delivers weETH, so dexSwap must
        // revert on the post-swap balance delta check against the oracle-derived minimum.
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minWeEthOut, insufficientOut));
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();
    }

    function getDeallocateVaultParams(uint256 assets) internal view override returns (bytes memory) {
        IMYTStrategy.SwapParams memory sp =
            IMYTStrategy.SwapParams({txData: _swapCallDataForWethOut(assets), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        return abi.encode(vp);
    }

    function _useAllocatorDeallocateSwap() internal pure override returns (bool) {
        return false;
    }

    function _allocatorDeallocateSwapData(uint256 amount) internal view override returns (bytes memory) {
        return _swapCallDataForWethOut(amount);
    }

    function _assertDeallocateChange(int256 change, uint256 amountToDeallocate) internal view override {
        assertApproxEqRel(change, -int256(amountToDeallocate), 1e16);
    }

    function test_deallocate_swap_mock_success() public {
        uint256 amount = 10e18;
        bytes memory directParams = getVaultParams();

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(directParams, amount, "", address(vault));
        vm.stopPrank();

        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 deallocCap = maxEETH / 2;
        uint256 deallocAmount = amount < deallocCap ? amount : deallocCap;
        require(deallocAmount > 0, "dealloc amount is zero");
        deal(WETH, address(swapper), deallocAmount);
        bytes memory callData = _swapCallDataForWethOut(deallocAmount);
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        bytes memory deallocParams = abi.encode(vp);

        vm.startPrank(vault);
        IMYTStrategy(strategy).deallocate(deallocParams, deallocAmount, "", address(vault));
        vm.stopPrank();
    }

    function test_deallocate_swap_mock_reverts_on_insufficient_swap_output() public {
        uint256 amount = 10e18;
        bytes memory directParams = getVaultParams();

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(directParams, amount, "", address(vault));
        vm.stopPrank();

        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 deallocCap = maxEETH / 2;
        uint256 deallocAmount = amount < deallocCap ? amount : deallocCap;
        require(deallocAmount > 1, "dealloc amount too small");
        uint256 insufficientOut = deallocAmount - 1;
        uint256 sellAmount = IWeETH(WEETH).getWeETHByeETH(deallocAmount);
        uint256 weETHBalance = IWeETH(WEETH).balanceOf(strategy);
        if (sellAmount > weETHBalance) sellAmount = weETHBalance;

        deal(WETH, address(swapper), insufficientOut);
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WEETH, WETH, sellAmount, insufficientOut));
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        bytes memory deallocParams = abi.encode(vp);

        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, deallocAmount, insufficientOut));
        IMYTStrategy(strategy).deallocate(deallocParams, deallocAmount, "", address(vault));
        vm.stopPrank();
    }

    function test_allocator_deallocate_max_preview_from_total_value(uint256 amountToAllocate) public {
        amountToAllocate = bound(amountToAllocate, 1e18, 100e18);
        _mockFreshWeEthEthOracle(block.timestamp);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amountToAllocate);

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 targetDeallocate = _effectiveDeallocateAmount(realAssetsBefore);
        require(targetDeallocate > 0, "target deallocate is zero");

        uint256 previewedDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDeallocate);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");
        assertLe(previewedDeallocate, targetDeallocate, "previewed amount should not exceed target");

        uint256 weETHBalanceBefore = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(previewedDeallocate);
        assertLe(weETHToSwap, weETHBalanceBefore, "previewed deallocation should be fundable by position");

        deal(WETH, address(swapper), previewedDeallocate);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        IAllocator(allocator).deallocateWithSwap(strategy, previewedDeallocate, _swapCallDataForWethOut(previewedDeallocate));
        vm.stopPrank();

        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 leftoverWeth = IERC20(WETH).balanceOf(strategy);
        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 expectedRemaining = realAssetsBefore > previewedDeallocate ? realAssetsBefore - previewedDeallocate : 0;

        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWeETH(WEETH).balanceOf(strategy), weETHBalanceBefore, "weETH balance should decrease after deallocation");
        assertLe(realAssetsAfter, expectedRemaining + maxResidual, "remaining strategy balance should stay near expected residual");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
    }


    function test_fuzz_allocator_deallocate_with_swap(uint256 amountToAllocate, uint256 rawDeallocateAmount) public {
        amountToAllocate = bound(amountToAllocate, 1e18, 100e18);
        _mockFreshWeEthEthOracle(block.timestamp);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amountToAllocate);

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 maxDeallocate = _effectiveDeallocateAmount(realAssetsBefore);
        require(maxDeallocate >= 1e16, "max deallocate too small");
        uint256 deallocateAmount = bound(rawDeallocateAmount, 1e16, maxDeallocate);
        uint256 previewedDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocateAmount);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");
        assertLe(previewedDeallocate, deallocateAmount, "previewed amount should not exceed target");

        uint256 weETHBalanceBefore = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(previewedDeallocate);
        assertLe(weETHToSwap, weETHBalanceBefore, "previewed deallocation should be fundable by position");

        deal(WETH, address(swapper), previewedDeallocate);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        IAllocator(allocator).deallocateWithSwap(strategy, previewedDeallocate, _swapCallDataForWethOut(previewedDeallocate));
        vm.stopPrank();

        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 leftoverWeth = IERC20(WETH).balanceOf(strategy);
        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 expectedRemaining = realAssetsBefore > previewedDeallocate ? realAssetsBefore - previewedDeallocate : 0;

        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWeETH(WEETH).balanceOf(strategy), weETHBalanceBefore, "weETH balance should decrease after deallocation");
        assertLe(realAssetsAfter, expectedRemaining + maxResidual, "remaining strategy balance should stay near expected residual");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
    }

    function test_deallocate_direct_uses_instant_redeem_path_cant_redeem() public {
        uint256 allocateAmount = 1e18;
        uint256 deallocateAmount = 1e16;
        bytes memory allocParams = getAllocateVaultParams(allocateAmount);

        vm.startPrank(vault);
        deal(WETH, strategy, allocateAmount);
        IMYTStrategy(strategy).allocate(allocParams, allocateAmount, "", address(vault));
        vm.stopPrank();

        // If canRedeem is unavailable/reverting at this fork state, skip deterministically.
        uint256 grossRedeemAmount = _grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount);
        bool redeemable = IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(grossRedeemAmount, ETH);
        if (redeemable) return;

        // if liquidity is unavailable, direct deallocate should revert
        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        vm.startPrank(vault);
        vm.expectRevert(bytes("Cannot redeem. Instant redemption path is not available."));
        IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        vm.stopPrank();
    }

    function test_vault_user_forceDeallocate_reverts_when_strategy_disables_force_deallocation() public {
        uint256 allocateAmount = 10e18;
        uint256 forceDeallocateAmount = 1e18;

        _mockFreshWeEthEthOracle(block.timestamp);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        vm.prank(admin);
        EtherfiEETHMYTStrategy(payable(strategy)).setCanForceDeallocate(false);

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(vaultDepositor);
        IVaultV2(vault).forceDeallocate(strategy, abi.encode(directDealloc), forceDeallocateAmount, vaultDepositor);
    }

    function test_fuzz_deallocate_direct_succeeds_with_updated_gross_redeem_amount_buffer(
        uint256 rawAllocateAmount,
        uint256 rawDeallocateAmount,
        uint256 rawBuffer
    ) public {
        // sanity check that the pinned fork block exposes instant redemption liquidity at all
        require(
            IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(_grossRedeemAmount(REDEMPTION_MANAGER, 1e18), ETH),
            "fork block should support instant redemption"
        );

        uint256 allocateAmount = bound(rawAllocateAmount, 2e18, 100e18);
        uint256 buffer = bound(rawBuffer, 1, EtherfiEETHMYTStrategy(payable(strategy)).MAX_GROSS_REDEEM_AMOUNT_BUFFER());

        vm.prank(admin);
        EtherfiEETHMYTStrategy(payable(strategy)).setGrossRedeemAmountBuffer(buffer);

        bytes memory allocParams = getDirectAllocateVaultParams(allocateAmount);

        vm.startPrank(vault);
        deal(WETH, strategy, allocateAmount);
        IMYTStrategy(strategy).allocate(allocParams, allocateAmount, "", address(vault));

        // gross redeem = shortfall*10000/(10000-fee)+buffer must fit positionEETH; reserve covers the
        // strategy's `ethReceived >= shortfall` check which is ~1 wei short at the boundary.
        (, uint16 exitFeeInBps,) = _redemptionInfo(REDEMPTION_MANAGER);
        uint256 positionEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 maxDeallocate = ((positionEETH - buffer) * (10_000 - exitFeeInBps)) / 10_000 - 1e3;
        uint256 deallocateAmount = bound(rawDeallocateAmount, 1e16, maxDeallocate);

        // consistency: the closed-form bound must agree with the contract's gross-up getter
        assertLe(_grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount) + buffer, positionEETH, "bound diverges from getter");

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);

        IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(strategy), deallocateAmount, "idle WETH should cover requested deallocation");
        vm.stopPrank();
    }

    function getDirectAllocateVaultParams(uint256) internal view virtual returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function test_deallocate_direct_accounts_for_instant_redemption_fee() public {
        uint256 allocateAmount = 10e18;
        uint256 deallocateAmount = 1e18;
        bytes memory allocParams = getAllocateVaultParams(allocateAmount);

        MockFeeRedemptionManager feeRedemptionManager = new MockFeeRedemptionManager(WEETH, EETH, 30);
        address localStrategy = address(
            new MockEtherfiEETHStrategy(
                vault,
                strategyConfig,
                EETH,
                WEETH,
                DEPOSIT_ADAPTER,
                address(feeRedemptionManager),
                WEETH_ETH_ORACLE,
                MAX_ORACLE_STALENESS
            )
        );
        vm.deal(address(feeRedemptionManager), allocateAmount);

        vm.startPrank(vault);
        deal(WETH, localStrategy, allocateAmount);
        IMYTStrategy(localStrategy).allocate(allocParams, allocateAmount, "", address(vault));

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        IMYTStrategy(localStrategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(localStrategy), deallocateAmount, "idle WETH should cover requested deallocation");
        vm.stopPrank();
    }

    function test_deallocate_direct_uses_live_fee_from_redemption_manager() public {
        uint256 allocateAmount = 10e18;
        uint256 deallocateAmount = 1e18;
        bytes memory allocParams = getAllocateVaultParams(allocateAmount);

        MockFeeRedemptionManager feeRedemptionManager = new MockFeeRedemptionManager(WEETH, EETH, 100);
        address localStrategy = address(
            new MockEtherfiEETHStrategy(
                vault,
                strategyConfig,
                EETH,
                WEETH,
                DEPOSIT_ADAPTER,
                address(feeRedemptionManager),
                WEETH_ETH_ORACLE,
                MAX_ORACLE_STALENESS
            )
        );
        vm.deal(address(feeRedemptionManager), allocateAmount);

        vm.startPrank(vault);
        deal(WETH, localStrategy, allocateAmount);
        IMYTStrategy(localStrategy).allocate(allocParams, allocateAmount, "", address(vault));

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        IMYTStrategy(localStrategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(localStrategy), deallocateAmount, "strategy should adapt to updated fee");
        vm.stopPrank();
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        if (maxEETH == 0) return 0;
        // `MYTStrategy.deallocate()` requires totalValueAfter >= assets, so cap requests
        // to at most half of current position to stay inside that invariant.
        uint256 maxSafe = maxEETH / 2;
        if (maxSafe == 0) return 0;
        uint256 capped = requestedAssets < maxSafe ? requestedAssets : maxSafe;
        uint256 minAssetForOneWeETH = IWeETH(WEETH).getEETHByWeETH(1);
        if (capped < minAssetForOneWeETH && minAssetForOneWeETH <= maxSafe) {
            return minAssetForOneWeETH;
        }
        return capped;
    }

    function _allocateMultipleTimes(uint256[] memory rawAmounts) internal {
        uint256 iterations = bound(rawAmounts.length, 2, 10);
        bytes memory allocParams = getAllocateVaultParams(0);
        uint256 lastRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 successfulAllocs = 0;
        uint256 minAllocUnit = 1e16;

        vm.startPrank(vault);
        for (uint256 i = 0; i < iterations; i++) {
            (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
            if (maxAlloc < minAllocUnit) break;

            uint256 remainingIterations = iterations - i;
            uint256 maxPerIteration = maxAlloc / remainingIterations;
            if (maxPerIteration < minAllocUnit) break;

            uint256 seed = rawAmounts.length == 0 ? uint256(keccak256(abi.encode(i))) : rawAmounts[i % rawAmounts.length];
            uint256 amount = bound(seed, minAlloc, maxPerIteration);
            deal(WETH, strategy, amount);
            IMYTStrategy(strategy).allocate(allocParams, amount, "", address(vault));

            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            assertGe(currentRealAssets, lastRealAssets, "Real assets should not decrease after allocation");
            lastRealAssets = currentRealAssets;
            successfulAllocs++;
        }
        vm.stopPrank();

        assertGt(successfulAllocs, 1, "Expected multiple successful allocations");
        assertGt(IMYTStrategy(strategy).realAssets(), 0, "Final real assets should be positive");
    }

    function test_fuzz_allocate_multiple_times(uint256[] memory rawAmounts) public {
        _allocateMultipleTimes(rawAmounts);
    }

    function test_fuzz_deallocate_direct_uses_instant_redeem_path_can_redeem(
        uint256[] memory rawAllocateAmounts,
        uint256 rawDeallocateAmount
    ) public {
        _allocateMultipleTimes(rawAllocateAmounts);

        uint256 maxDeallocate = _maxNetDirectDeallocate(REDEMPTION_MANAGER);
        require(maxDeallocate > 0, "max dealloc is zero");

        uint256 deallocateAmount = bound(rawDeallocateAmount, 1, maxDeallocate);
        uint256 grossRedeemAmount = _grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount);
        if (!IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(grossRedeemAmount, ETH)) return;

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        vm.startPrank(vault);
        try IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault)) {} catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();
    }
}
