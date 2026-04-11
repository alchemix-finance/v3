// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {WstethStrategy} from "../../strategies/WStethStrategy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IWstETH {
    function balanceOf(address account) external view returns (uint256);
}

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

contract MockSwapExecutorDynamic {
    IERC20 public immutable buyToken;
    IERC20 public immutable sellToken;

    constructor(address _sellToken, address _buyToken) {
        sellToken = IERC20(_sellToken);
        buyToken = IERC20(_buyToken);
    }

    fallback() external {
        uint256 sellAllowance = sellToken.allowance(msg.sender, address(this));
        if (sellAllowance > 0) {
            sellToken.transferFrom(msg.sender, address(this), sellAllowance);
        }

        uint256 buyBalance = buyToken.balanceOf(address(this));
        if (buyBalance > 0) {
            buyToken.transfer(msg.sender, buyBalance);
        }
    }
}

contract MockWstethOptimismStrategy is WstethStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _wstETH,
        address _wstEthEthOracle
    )
        WstethStrategy(_myt, _params, _wstETH, _wstEthEthOracle, false)
    {}
}

contract WstethOptimismStrategyTest is Test {
    uint256 public constant STRATEGY_SLIPPAGE_BPS = 200;
    uint256 public constant TEST_RESIDUAL_TOLERANCE_BPS = 100;

    address public mytStrategy;
    address public vault;
    address public allocator;
    address public classifier;

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address public constant WSTETH_ETH_ORACLE = 0x524299Ab0987a7c4B3c8022a35669DdcdC715a10;

    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);
    uint256 private _forkId;

    function setUp() public {
        string memory rpc = getRpcUrl();
        if (getForkBlockNumber() > 0) {
            _forkId = vm.createFork(rpc, getForkBlockNumber());
        } else {
            _forkId = vm.createFork(rpc);
        }
        vm.selectFork(_forkId);

        vm.startPrank(admin);
        vault = _getVault(WETH);
        classifier = address(new AlchemistStrategyClassifier(admin));
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        allocator = address(new AlchemistAllocator{salt: bytes32("allocator")}(address(vault), admin, curator, classifier));

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "WstethOptimismStrategy",
            protocol: "WstethOptimismStrategy",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 2_000_000e18,
            globalCap: 2_000_000e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: STRATEGY_SLIPPAGE_BPS
        });

        mytStrategy = _createStrategy(vault, params);
        bytes32 strategyId = IMYTStrategy(mytStrategy).adapterId();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(params.riskClass));
        _setUpMYT(vault, mytStrategy, 2_000_000e18, 1e18);
        _magicDepositToVault(vault, admin, 1_000_000e18);
        require(IVaultV2(vault).totalAssets() == 1_000_000e18, "vault total assets mismatch");
        vm.stopPrank();
    }

    function _getVault(address asset) internal returns (address) {
        MockMYTVault v = new MockMYTVault{salt: bytes32("vault")}(admin, asset);
        v.setCurator(curator);
        vm.stopPrank();
        vm.startPrank(curator);
        v.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (admin)));
        v.setPerformanceFeeRecipient(admin);
        v.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (15e16)));
        v.setPerformanceFee(15e16);
        vm.stopPrank();
        vm.startPrank(admin);
        return address(v);
    }

    function _createStrategy(address _vault, IMYTStrategy.StrategyParams memory params) internal returns (address) {
        return address(
            new MockWstethOptimismStrategy{salt: bytes32("wsteth_strategy")}(
                _vault, params, WSTETH, WSTETH_ETH_ORACLE
            )
        );
    }

    function _wstEthOracleAnswer() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(WSTETH_ETH_ORACLE).latestRoundData();
        require(answer > 0 && updatedAt != 0, "invalid oracle answer");
        return uint256(answer);
    }

    function _maxWstEthIn(uint256 wethAmount) internal view returns (uint256) {
        uint256 maxWethIn = (wethAmount * 10_000 + (10_000 - STRATEGY_SLIPPAGE_BPS) - 1) / (10_000 - STRATEGY_SLIPPAGE_BPS);
        uint256 scale = 10 ** AggregatorV3Interface(WSTETH_ETH_ORACLE).decimals();
        uint256 answer = _wstEthOracleAnswer();
        uint256 wstEthAmount = (maxWethIn * scale + answer - 1) / answer;
        return wstEthAmount == 0 ? 1 : wstEthAmount;
    }

    function _allocateWithMockedSwap(uint256 amountIn, uint256 expectedWstethOut) internal {
        MockSwapExecutor mockSwap = new MockSwapExecutor(WETH, WSTETH, expectedWstethOut);
        deal(WSTETH, address(mockSwap), expectedWstethOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        deal(WETH, mytStrategy, amountIn);

        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory allocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        IMYTStrategy(mytStrategy).allocate(abi.encode(allocParams), amountIn, "", vault);
        vm.stopPrank();
    }

    function test_strategy_allocate_direct_reverts() public {
        vm.startPrank(vault);
        deal(WETH, mytStrategy, 1e18);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), 1e18, "", vault);
        vm.stopPrank();
    }

    function test_strategy_allocate_with_mocked_dex_swap() public {
        uint256 amountIn = 5e18;
        uint256 expectedWstethOut = 7e18;
        _allocateWithMockedSwap(amountIn, expectedWstethOut);

        assertEq(IWstETH(WSTETH).balanceOf(mytStrategy), expectedWstethOut, "strategy should receive expected wstETH from swap");
        assertGt(IMYTStrategy(mytStrategy).realAssets(), 0, "allocation should create real assets");
    }

    function test_strategy_deallocate_with_mocked_dex_swap() public {
        _allocateWithMockedSwap(100e18, 100e18);

        uint256 expectedOut = 5e18;
        MockSwapExecutor mockSwap = new MockSwapExecutor(WSTETH, WETH, expectedOut);
        deal(WETH, address(mockSwap), expectedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        (bytes32[] memory strategyIds,) = IMYTStrategy(mytStrategy).deallocate(
            abi.encode(deallocParams), expectedOut, "", vault
        );
        vm.stopPrank();

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        assertEq(IERC20(WETH).allowance(mytStrategy, vault), expectedOut, "vault allowance should equal WETH deallocated");
        assertEq(IERC20(WETH).balanceOf(mytStrategy), expectedOut, "strategy should receive mocked WETH output");
    }

    function test_strategy_deallocate_with_mocked_dex_swap_reverts_when_under_min_out() public {
        _allocateWithMockedSwap(100e18, 100e18);

        uint256 requiredOut = 5e18;
        uint256 mockedOut = requiredOut - 1;
        MockSwapExecutor mockSwap = new MockSwapExecutor(WSTETH, WETH, mockedOut);
        deal(WETH, address(mockSwap), mockedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, requiredOut, mockedOut));
        IMYTStrategy(mytStrategy).deallocate(abi.encode(deallocParams), requiredOut, "", vault);
        vm.stopPrank();
    }

    function test_realAssets_includes_idle_weth_leftover() public {
        assertEq(IWstETH(WSTETH).balanceOf(mytStrategy), 0, "strategy should start without wstETH");

        _allocateWithMockedSwap(10e18, 10e18);

        uint256 allocatedValue = IMYTStrategy(mytStrategy).realAssets();
        assertGt(allocatedValue, 0, "allocated value should be positive");

        uint256 leftover = 3e18;
        deal(WETH, mytStrategy, leftover);

        uint256 totalRealAssets = IMYTStrategy(mytStrategy).realAssets();
        assertEq(totalRealAssets, allocatedValue + leftover, "realAssets should include allocation plus idle WETH leftover");
    }

    function test_previewAdjustedWithdraw() public {
        uint256 previewEmpty = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(100e18);
        assertEq(previewEmpty, 0, "should return 0 when no wstETH balance");

        _allocateWithMockedSwap(100e18, 100e18);

        uint256 maxCapacity = IMYTStrategy(mytStrategy).realAssets();
        uint256 requestedAmount = 50e18;
        uint256 preview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(requestedAmount);

        assertLt(preview, requestedAmount, "preview should be less than requested due to haircut");
        assertGt(preview, 0, "preview should be positive");

        uint256 expectedPreview = (requestedAmount * (10_000 - STRATEGY_SLIPPAGE_BPS)) / 10_000;
        assertEq(preview, expectedPreview, "preview should match expected after haircut");

        uint256 excessAmount = maxCapacity + 100e18;
        uint256 previewExcess = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(excessAmount);
        uint256 expectedCapped = (maxCapacity * (10_000 - STRATEGY_SLIPPAGE_BPS)) / 10_000;
        assertEq(previewExcess, expectedCapped, "preview should be capped at max capacity minus haircut");

        uint256 idleLeftover = 10e18;
        deal(WETH, mytStrategy, idleLeftover);

        uint256 previewIdleOnly = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(8e18);
        assertEq(previewIdleOnly, 8e18, "idle assets should be previewed at par");

        uint256 mixedRequest = idleLeftover + 20e18;
        uint256 mixedPreview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(mixedRequest);
        uint256 expectedMixedPreview = idleLeftover + (20e18 * (10_000 - STRATEGY_SLIPPAGE_BPS)) / 10_000;
        assertEq(mixedPreview, expectedMixedPreview, "preview should use idle assets before haircutting invested assets");
    }

    function test_realAssets_reverts_when_oracle_is_stale() public {
        _allocateWithMockedSwap(10e18, 10e18);

        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(WSTETH_ETH_ORACLE).latestRoundData();
        vm.mockCall(
            WSTETH_ETH_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp - 8 days, answeredInRound)
        );

        vm.expectRevert(bytes("Stale oracle answer"));
        IMYTStrategy(mytStrategy).realAssets();
    }

    function test_allocator_allocate_with_mocked_swap() public {
        uint256 amountToAllocate = 100e18;
        MockSwapExecutor mockSwap = new MockSwapExecutor(WETH, WSTETH, amountToAllocate);
        deal(WSTETH, address(mockSwap), amountToAllocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(
            mytStrategy,
            amountToAllocate,
            hex"01"
        );

        uint256 wstETHBalance = IWstETH(WSTETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, 0, "real assets should be positive");
        vm.stopPrank();
    }

    function test_allocator_deallocate_with_mocked_swap() public {
        uint256 amountToAllocate = 100e18;
        MockSwapExecutor allocSwap = new MockSwapExecutor(WETH, WSTETH, amountToAllocate);
        deal(WSTETH, address(allocSwap), amountToAllocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(allocSwap));

        vm.prank(admin);
        IAllocator(allocator).allocateWithSwap(mytStrategy, amountToAllocate, hex"01");

        uint256 wstETHBalanceBefore = IWstETH(WSTETH).balanceOf(mytStrategy);
        assertGt(wstETHBalanceBefore, 0, "wstETH balance should be positive");

        uint256 realAssetsBefore = IMYTStrategy(mytStrategy).realAssets();
        uint256 previewedDeallocate = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(realAssetsBefore);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");

        uint256 wstEthToSwap = _maxWstEthIn(previewedDeallocate);
        assertLe(wstEthToSwap, wstETHBalanceBefore, "previewed deallocation should be fundable by position");

        MockSwapExecutorDynamic deallocSwap = new MockSwapExecutorDynamic(WSTETH, WETH);
        deal(WETH, address(deallocSwap), previewedDeallocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(deallocSwap));

        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(mytStrategy, previewedDeallocate, hex"01");

        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 leftoverWeth = IERC20(WETH).balanceOf(mytStrategy);
        uint256 realAssetsAfter = IMYTStrategy(mytStrategy).realAssets();
        assertLe(realAssetsAfter, maxResidual, "remaining strategy balance should stay within slippage tolerance");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
        assertLt(IWstETH(WSTETH).balanceOf(mytStrategy), wstETHBalanceBefore, "wstETH balance should decrease after deallocation");
    }

    function test_allocator_deallocate_max_preview_from_total_value(uint256 allocateAmount) public {
        allocateAmount = bound(allocateAmount, 1e18, 100e18);

        MockSwapExecutor allocSwap = new MockSwapExecutor(WETH, WSTETH, allocateAmount);
        deal(WSTETH, address(allocSwap), allocateAmount);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(allocSwap));

        vm.prank(admin);
        IAllocator(allocator).allocateWithSwap(mytStrategy, allocateAmount, hex"01");

        uint256 realAssetsBefore = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 maxDeallocate = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(realAssetsBefore);
        assertGt(maxDeallocate, 0, "previewed deallocation amount should be positive");
        assertLe(maxDeallocate, realAssetsBefore, "previewed amount should not exceed total value");

        uint256 wstETHBalanceBefore = IWstETH(WSTETH).balanceOf(mytStrategy);
        uint256 wstEthToSwap = _maxWstEthIn(maxDeallocate);
        assertLe(wstEthToSwap, wstETHBalanceBefore, "previewed amount should be fundable by position");

        MockSwapExecutorDynamic deallocSwap = new MockSwapExecutorDynamic(WSTETH, WETH);
        deal(WETH, address(deallocSwap), maxDeallocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(deallocSwap));

        bytes32 strategyId = IMYTStrategy(mytStrategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(strategyId);

        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(mytStrategy, maxDeallocate, hex"01");

        uint256 allocationAfter = IVaultV2(vault).allocation(strategyId);
        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWstETH(WSTETH).balanceOf(mytStrategy), wstETHBalanceBefore, "wstETH balance should decrease after deallocation");
        assertLt(IMYTStrategy(mytStrategy).realAssets(), realAssetsBefore, "real assets should decrease after deallocation");
    }

    function getForkBlockNumber() internal pure returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function _setUpMYT(address _vault, address _mytStrategy, uint256 absoluteCap, uint256 relativeCap) internal {
        vm.startPrank(admin);
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        IVaultV2(_vault).setIsAllocator(allocator, true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, _mytStrategy));
        IVaultV2(_vault).addAdapter(_mytStrategy);

        bytes memory idData = IMYTStrategy(_mytStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, absoluteCap)));
        IVaultV2(_vault).increaseAbsoluteCap(idData, absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, relativeCap)));
        IVaultV2(_vault).increaseRelativeCap(idData, relativeCap);

        require(IVaultV2(_vault).adaptersLength() == 1, "adaptersLength must be 1");
        require(IVaultV2(_vault).isAllocator(allocator), "allocator is not set");
        require(IVaultV2(_vault).isAdapter(_mytStrategy), "strategy is not set");
        bytes32 strategyId = IMYTStrategy(_mytStrategy).adapterId();
        require(IVaultV2(_vault).absoluteCap(strategyId) == absoluteCap, "absoluteCap is not set");
        require(IVaultV2(_vault).relativeCap(strategyId) == relativeCap, "relativeCap is not set");
        vm.stopPrank();
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(IVaultV2(_vault).asset()), depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(IVaultV2(_vault).asset()), _vault, amount);
        uint256 shares = IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(vault).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(vault).timelock(selector));
    }
}
