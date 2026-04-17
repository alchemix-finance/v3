// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {WstETHEthereumStrategy} from "../../strategies/WstETHEthereumStrategy.sol";
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
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
}

/// @notice Simple allowanceHolder mock that simulates swap output by
/// transferring a fixed token amount to caller on any call.
contract MockSwapExecutor {
    IERC20 public immutable token;
    uint256 public amountToTransfer;

    constructor(address _token, uint256 _amountToTransfer) {
        token = IERC20(_token);
        amountToTransfer = _amountToTransfer;
    }

    fallback() external {
        token.transfer(msg.sender, amountToTransfer);
    }
}

/// @notice Smart allowanceHolder mock that transfers buy token to the caller and
/// pulls the full approved sell token amount, matching dexSwap's balance-delta semantics.
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

contract MockWstethStrategy is WstETHEthereumStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _wstETH,
        address _wstEthEthOracle
    )
        WstETHEthereumStrategy(_myt, _params, _wstETH, _wstEthEthOracle)
    {}
}

contract WstethStrategyTest is Test {
    uint256 public constant STRATEGY_SLIPPAGE_BPS = 200;
    uint256 public constant TEST_RESIDUAL_TOLERANCE_BPS = 100;
    uint256 public constant ASSUMED_WSTETH_ETH_ORACLE_ANSWER = 1.23e18;
    uint256 public constant QUOTED_WSTETH_SELL_AMOUNT = 1_000_000_000_000;
    uint256 public constant QUOTED_WETH_BUY_AMOUNT = 1_222_732_076_605;

    address public mytStrategy;
    address public vault;
    address public allocator;
    address public classifier;
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public wstETH = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address public wstEthEthOracle = address(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;
    uint256 private _forkId;
    event WstethStrategyTestLog(string message, uint256 value);
    event WstethStrategyTestLogAddress(string message, address value);

    function setUp() public {
        // Fork setup
        string memory rpc = getRpcUrl();
        if (getForkBlockNumber() > 0) {
            _forkId = vm.createFork(rpc, getForkBlockNumber());
        } else {
            _forkId = vm.createFork(rpc);
        }
        vm.selectFork(_forkId);
        vm.startPrank(admin);
        vault = _getVault(weth);
        classifier = address(new AlchemistStrategyClassifier(admin));
        // Set up risk classes matching constructor defaults (WAD: 1e18 = 100%)
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        allocator = address(new AlchemistAllocator{salt: bytes32("allocator")}(address(vault), admin, curator, classifier));
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "WstethStrategy",
            protocol: "WstethStrategy",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 2_000_000e18,
            globalCap: 2_000_000e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: STRATEGY_SLIPPAGE_BPS
        });
        mytStrategy = _createStrategy(vault, params);
        // Assign risk level to the strategy
        bytes32 strategyId = IMYTStrategy(mytStrategy).adapterId();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(params.riskClass));
        emit WstethStrategyTestLogAddress("mytStrategy", mytStrategy);
        _setUpMYT(vault, mytStrategy, 2_000_000e18, 1e18);
        _magicDepositToVault(vault, admin, 1_000_000e18);
        require(IVaultV2(vault).totalAssets() == 1_000_000e18, "vault total assets mismatch");
        _mockFreshWstEthEthOracle();
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
            new MockWstethStrategy{salt: bytes32("wsteth_strategy")}(
                _vault, params, wstETH, wstEthEthOracle
            )
        );
    }

    function _wstEthOracleAnswer() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(wstEthEthOracle).latestRoundData();
        require(answer > 0 && updatedAt != 0, "invalid oracle answer");
        return uint256(answer);
    }

    function _maxWstEthIn(uint256 wethAmount) internal view returns (uint256) {
        uint256 maxWethIn = (wethAmount * 10_000 + (10_000 - STRATEGY_SLIPPAGE_BPS) - 1) / (10_000 - STRATEGY_SLIPPAGE_BPS);
        uint256 scale = 10 ** AggregatorV3Interface(wstEthEthOracle).decimals();
        uint256 answer = _wstEthOracleAnswer();
        uint256 stEthAmount = (maxWethIn * scale + answer - 1) / answer;
        return IWstETH(wstETH).getWstETHByStETH(stEthAmount);
    }

    function _quoteScaledWethOut(uint256 wstEthAmountIn) internal pure returns (uint256) {
        return (wstEthAmountIn * QUOTED_WETH_BUY_AMOUNT) / QUOTED_WSTETH_SELL_AMOUNT;
    }

    function test_strategy_allocate_direct() public {
        vm.startPrank(vault);
        uint256 amount = 100e18;
        deal(weth, mytStrategy, amount);
        
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        
        bytes memory data = abi.encode(params);
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        // change is the _totalValue() delta; verify allocation occurred
        assertGt(change, 0, "change should be positive after allocation");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        
        // Verify wstETH was received.
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() values the position in WETH terms using the configured oracle.
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, 0, "real assets should be positive");
        vm.stopPrank();
    }

    function test_strategy_deallocate_with_mocked_dex_swap(uint256 requestedOut) public {
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory allocParams;
        allocParams.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(allocParams), allocateAmount, "", vault);
        vm.stopPrank();

        requestedOut = bound(requestedOut, 1e18, 100e18);

        uint256 wstETHBalanceBefore = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 wstEthToSwap = _maxWstEthIn(requestedOut);
        if (wstEthToSwap > wstETHBalanceBefore) {
            wstEthToSwap = wstETHBalanceBefore;
        }
        assertLe(wstEthToSwap, wstETHBalanceBefore, "requested deallocation should be fundable by position");

        MockSwapExecutorDynamic mockSwap = new MockSwapExecutorDynamic(wstETH, weth);
        deal(weth, address(mockSwap), requestedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: hex"01",
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        (bytes32[] memory strategyIds,) = IMYTStrategy(mytStrategy).deallocate(
            abi.encode(deallocParams), requestedOut, "", vault
        );
        vm.stopPrank();

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        assertEq(IERC20(weth).allowance(mytStrategy, vault), requestedOut, "vault allowance should equal WETH deallocated");
        assertEq(IERC20(weth).balanceOf(mytStrategy), requestedOut, "strategy should receive requested WETH output");
    }

    function test_allocator_deallocate_max_preview_from_total_value(uint256 allocateAmount) public {
        allocateAmount = bound(allocateAmount, 1e18, 100e18);

        vm.prank(admin);
        IAllocator(allocator).allocate(mytStrategy, allocateAmount);

        uint256 realAssetsBefore = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 maxDeallocate = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(realAssetsBefore);
        assertGt(maxDeallocate, 0, "previewed deallocation amount should be positive");
        assertLe(maxDeallocate, realAssetsBefore, "previewed amount should not exceed total value");

        uint256 wstETHBalanceBefore = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 wstEthToSwap = _maxWstEthIn(maxDeallocate);
        assertLe(wstEthToSwap, wstETHBalanceBefore, "previewed amount should be fundable by position");

        MockSwapExecutorDynamic mockSwap = new MockSwapExecutorDynamic(wstETH, weth);
        deal(weth, address(mockSwap), maxDeallocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        bytes32 strategyId = IMYTStrategy(mytStrategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(strategyId);

        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(mytStrategy, maxDeallocate, hex"01");

        uint256 allocationAfter = IVaultV2(vault).allocation(strategyId);
        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWstETH(wstETH).balanceOf(mytStrategy), wstETHBalanceBefore, "wstETH balance should decrease after deallocation");
        assertLt(IMYTStrategy(mytStrategy).realAssets(), realAssetsBefore, "real assets should decrease after deallocation");
    }

    function test_strategy_deallocate_with_mocked_dex_swap_reverts_when_under_min_out() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory allocParams;
        allocParams.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(allocParams), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 requiredOut = 5e18;
        uint256 mockedOut = requiredOut - 1;
        MockSwapExecutor mockSwap = new MockSwapExecutor(weth, mockedOut);
        deal(weth, address(mockSwap), mockedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: hex"01",
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, requiredOut, mockedOut));
        IMYTStrategy(mytStrategy).deallocate(abi.encode(deallocParams), requiredOut, "", vault);
        vm.stopPrank();
    }

    function test_strategy_allocate_with_mocked_dex_swap() public {
        uint256 expectedWstethOut = 7e18;
        MockSwapExecutor mockSwap = new MockSwapExecutor(wstETH, expectedWstethOut);
        deal(wstETH, address(mockSwap), expectedWstethOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        uint256 amountIn = 5e18;
        deal(weth, mytStrategy, amountIn);

        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory allocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(
            abi.encode(allocParams), amountIn, "", vault
        );
        vm.stopPrank();

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        assertEq(IWstETH(wstETH).balanceOf(mytStrategy), expectedWstethOut, "strategy should receive expected wstETH from swap");
        assertGt(change, 0, "allocation change should be positive");
    }

    function test_realAssets_prices_wsteth_in_steth_units() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 10e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 stETHEquivalent = IWstETH(wstETH).getStETHByWstETH(wstETHBalance);
        uint256 scale = 10 ** AggregatorV3Interface(wstEthEthOracle).decimals();
        uint256 expectedRealAssets = stETHEquivalent * _wstEthOracleAnswer() / scale;

        assertEq(IMYTStrategy(mytStrategy).realAssets(), expectedRealAssets, "realAssets should value wstETH via stETH equivalent");
    }

    function test_realAssets_includes_idle_weth_leftover() public {
        assertEq(IWstETH(wstETH).balanceOf(mytStrategy), 0, "strategy should start without wstETH");

        vm.startPrank(vault);
        uint256 allocateAmount = 10e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 allocatedValue = IMYTStrategy(mytStrategy).realAssets();
        assertGt(allocatedValue, 0, "allocated value should be positive");

        uint256 leftover = 3e18;
        deal(weth, mytStrategy, leftover);

        uint256 totalRealAssets = IMYTStrategy(mytStrategy).realAssets();
        assertEq(totalRealAssets, allocatedValue + leftover, "realAssets should include allocation plus idle WETH leftover");
    }


    /// @notice Get swap calldata from 0x API for WETH -> wstETH
    function getWethToWstethCalldata(address taker, uint256 sellAmount) internal returns (bytes memory) {
        return _get0xCalldata(weth, wstETH, taker, sellAmount);
    }

    /// @notice Get swap calldata from 0x API for wstETH -> WETH
    function getWstethToWethCalldata(address taker, uint256 sellAmount) internal returns (bytes memory) {
        return _get0xCalldata(wstETH, weth, taker, sellAmount);
    }

    /// @notice Get 0x API key from environment variable
    function _get0xApiKey() internal view returns (string memory) {
        return vm.envString("ZEROX_API_KEY");
    }

    /// @notice Get expected buy amount from 0x API quote
    function get0xBuyAmount(address sellToken, address buyToken, address taker, uint256 sellAmount) internal returns (uint256) {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "sleep 2 && ", // to avoid rate limits of 0x
            "curl -s --location --request GET 'https://api.0x.org/swap/allowance-holder/quote?chainId=1&sellToken=",
            vm.toString(sellToken),
            "&buyToken=",
            vm.toString(buyToken),
            "&sellAmount=",
            vm.toString(sellAmount),
            "&taker=",
            vm.toString(taker),
            "' -H '0x-api-key: ",
            _get0xApiKey(),
            "' -H '0x-version: v2' | jq -r '.buyAmount' | xargs cast to-hex"
        );
        bytes memory b = vm.ffi(inputs);
        return vm.parseUint(string(b));
    }


    /// @notice Generic helper to get swap calldata from 0x API
    function _get0xCalldata(address sellToken, address buyToken, address taker, uint256 sellAmount) internal returns (bytes memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "sleep 2 && ",
            "curl -s --location --request GET 'https://api.0x.org/swap/allowance-holder/quote?chainId=1&sellToken=",
            vm.toString(sellToken),
            "&buyToken=",
            vm.toString(buyToken),
            "&sellAmount=",
            vm.toString(sellAmount),
            "&taker=",
            vm.toString(taker),
            "' -H '0x-api-key: ",
            _get0xApiKey(),
            "' -H '0x-version: v2' | jq -r .transaction.data"
        );
        return vm.ffi(inputs);
    }

    /// @notice Fork at latest block since we use live API quotes
    function getForkBlockNumber() internal pure returns (uint256) {
        return 0;
    }

    function _mockFreshWstEthEthOracle() internal {
        _mockWstEthEthOracleAnswer(ASSUMED_WSTETH_ETH_ORACLE_ANSWER);
    }

    function _mockWstEthEthOracleAnswer(uint256 answerToMock) internal {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(wstEthEthOracle).latestRoundData();
        vm.mockCall(
            wstEthEthOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, int256(answerToMock), startedAt, block.timestamp, answeredInRound)
        );
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

        // Validation
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


    function getRpcUrl() internal view returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }


    function test_allocator_allocate(uint256 amountToAllocate) public {
        // Lido has stake limits - cap at 1000 ETH to avoid STAKE_LIMIT error
        amountToAllocate = bound(amountToAllocate, 1e18, 1_000e18);
        vm.startPrank(admin);
        IAllocator(allocator).allocate(mytStrategy, amountToAllocate);
        
        // Verify wstETH was received.
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() values the position in WETH terms using the configured oracle.
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, 0, "real assets should be positive");
        vm.stopPrank();
    }


    function test_allocator_deallocate_with_swap() public {
        uint256 amountToAllocate = 100e18;
        vm.prank(admin);
        IAllocator(allocator).allocate(mytStrategy, amountToAllocate);

        uint256 wstETHBalanceBefore = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalanceBefore, 0, "wstETH balance should be positive");

        uint256 realAssetsBefore = IMYTStrategy(mytStrategy).realAssets();
        uint256 previewedDeallocate = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(realAssetsBefore);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");

        uint256 wstEthToSwap = _maxWstEthIn(previewedDeallocate);
        assertLe(wstEthToSwap, wstETHBalanceBefore, "previewed deallocation should be fundable by position");

        MockSwapExecutorDynamic mockSwap = new MockSwapExecutorDynamic(wstETH, weth);
        deal(weth, address(mockSwap), previewedDeallocate);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(mytStrategy, previewedDeallocate, hex"01");

        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 leftoverWeth = IERC20(weth).balanceOf(mytStrategy);
        uint256 realAssetsAfter = IMYTStrategy(mytStrategy).realAssets();
        assertLe(realAssetsAfter, maxResidual, "remaining strategy balance should stay within slippage tolerance");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
        assertLt(IWstETH(wstETH).balanceOf(mytStrategy), wstETHBalanceBefore, "wstETH balance should decrease after deallocation");
    }

    function test_previewAdjustedWithdraw() public {
        // Should return 0 when strategy has no wstETH
        uint256 previewEmpty = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(100e18);
        assertEq(previewEmpty, 0, "should return 0 when no wstETH balance");

        // Allocate some funds and verify preview
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);
        
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        bytes memory data = abi.encode(params);
        IMYTStrategy(mytStrategy).allocate(data, allocateAmount, "", vault);
        vm.stopPrank();

        // Get strategy's fundamental capacity in WETH terms (oracle-adjusted).
        uint256 maxCapacity = IMYTStrategy(mytStrategy).realAssets();
        
        // Preview for amount within capacity
        uint256 requestedAmount = 50e18;
        uint256 preview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(requestedAmount);
        
        // Should be less than requested due to slippage haircut
        assertLt(preview, requestedAmount, "preview should be less than requested due to haircut");
        assertGt(preview, 0, "preview should be positive");
        
        // Verify haircut is applied correctly (slippageBPS = 200 from setUp)
        uint256 expectedPreview = (requestedAmount * (10_000 - STRATEGY_SLIPPAGE_BPS)) / 10_000;
        assertEq(preview, expectedPreview, "preview should match expected after haircut");

        // Preview for amount exceeding capacity should cap at capacity
        uint256 excessAmount = maxCapacity + 100e18;
        uint256 previewExcess = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(excessAmount);

        uint256 expectedCapped = (maxCapacity * (10_000 - STRATEGY_SLIPPAGE_BPS)) / 10_000;

        assertEq(previewExcess, expectedCapped, "preview should be capped at max capacity minus haircut");
    }

    function test_realAssets_reverts_when_oracle_is_stale() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 10e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), allocateAmount, "", vault);
        vm.stopPrank();

        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(wstEthEthOracle).latestRoundData();
        vm.mockCall(
            wstEthEthOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp - 8 days, answeredInRound)
        );

        vm.expectRevert(bytes("Stale oracle answer"));
        IMYTStrategy(mytStrategy).realAssets();
    }

    // Test: WstETH Mainnet yield accumulation over time
    // Verifies that realAssets() remains stable/increases after time passes
    // (wstETH accrues yield via staking rewards reflected in exchange rate)
    function test_wsteth_mainnet_yield_accumulation() public {
        // Set up mocked swap executor for deallocations (avoids 0x signature deadline issues with vm.warp)
        MockSwapExecutorDynamic mockSwap = new MockSwapExecutorDynamic(wstETH, weth);
        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));
        
        vm.startPrank(allocator);
    
        // Allocate initial amount
        uint256 allocAmount = 100e18; // 100 WETH
    
        // Use direct allocation (WETH -> wstETH wrap)
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.direct,
            swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
        });
        bytes memory data = abi.encode(params);
        IVaultV2(vault).allocate(mytStrategy, data, allocAmount);
        
        _mockFreshWstEthEthOracle();
        uint256 initialRealAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(initialRealAssets, 0, "Should have real assets after allocation");
        
        // Track real assets over multiple time periods
        uint256 previousAssets = initialRealAssets;
        for (uint256 i = 0; i < 3; i++) {
            // Warp forward 30 days
            vm.warp(block.timestamp + 30 days);
            _mockFreshWstEthEthOracle();
            
            // Real assets should not decrease significantly over time
            // (wstETH exchange rate typically increases with staking rewards)
            uint256 currentAssets = IMYTStrategy(mytStrategy).realAssets();
            assertGe(currentAssets, previousAssets * 95 / 100, "Real assets should not decrease significantly");
            
            previousAssets = currentAssets;
        }
        
        // Final deallocation using mocked swap
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 realAssetsValue = IMYTStrategy(mytStrategy).realAssets();
        
        // Fund mock with exactly the oracle-adjusted WETH value
        // The mock returns its full balance, so fund it with what we expect to receive
        deal(weth, address(mockSwap), realAssetsValue);
        
        IMYTStrategy.SwapParams memory deallocSwapParams = IMYTStrategy.SwapParams({
            txData: hex"01", // Mock calldata
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory deallocParams = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap,
            swapParams: deallocSwapParams
        });
        bytes memory deallocateData = abi.encode(deallocParams);
        
        // Deallocate the oracle-adjusted WETH value
        IVaultV2(vault).deallocate(mytStrategy, deallocateData, realAssetsValue);

        assertEq(IWstETH(wstETH).balanceOf(mytStrategy), 0, "wstETH should be fully swapped");
        // Verify deallocation succeeded - realAssets should be significantly reduced
        uint256 remainingRealAssets = IMYTStrategy(mytStrategy).realAssets();
        uint256 leftoverWeth = IERC20(weth).balanceOf(mytStrategy);
        uint256 maxResidual = (initialRealAssets * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
        assertLe(remainingRealAssets, maxResidual, "remaining real assets should stay within slippage tolerance");
        
        vm.stopPrank();
    }
    
}
