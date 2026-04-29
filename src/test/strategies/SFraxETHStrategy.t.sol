// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../FrxEthEthDualOracleAggregatorAdapter.sol";
import {SFraxETHStrategy} from "../../strategies/SFraxETHStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";

interface ISfrxETHView {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

contract MockSwapperForSFraxETH {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract SFraxETHStrategyTest is Test {
    uint256 internal constant ABSOLUTE_CAP = 1_000_000e18;
    uint256 internal constant RELATIVE_CAP = 1e18;
    uint256 internal constant MIN_FRXETH_OUT_BPS = 9000;
    uint256 internal constant MAX_ORACLE_STALENESS = 24 hours;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address public constant FRAX_MINTER_V2 = 0x7Bc6bad540453360F744666D625fec0ee1320cA3;
    address public constant FRXETH_ETH_DUAL_ORACLE = 0x350a9841956D8B0212EAdF5E14a449CA85FAE1C0;

    MockMYTVault internal vault;
    AlchemistAllocator internal allocator;
    AlchemistStrategyClassifier internal classifier;
    SFraxETHStrategy internal strategy;
    FrxEthEthDualOracleAggregatorAdapter internal oracleAdapter;

    address internal admin = address(0xA11CE);
    address internal operator = address(0xB0B);
    uint256 private _forkId;

    function setUp() public {
        _forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"), getForkBlockNumber());
        vm.selectFork(_forkId);

        vault = new MockMYTVault(admin, WETH);
        classifier = new AlchemistStrategyClassifier(admin);
        oracleAdapter = new FrxEthEthDualOracleAggregatorAdapter(FRXETH_ETH_DUAL_ORACLE);

        vm.startPrank(admin);
        vault.setCurator(operator);
        classifier.setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        classifier.setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        classifier.setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        allocator = new AlchemistAllocator(address(vault), admin, operator, address(classifier));

        vm.stopPrank();
        vm.startPrank(operator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (admin)));
        vault.setPerformanceFeeRecipient(admin);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (15e16)));
        vault.setPerformanceFee(15e16);
        vm.stopPrank();
        vm.startPrank(admin);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "sfrxETH",
            protocol: "Frax",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 100
        });

        strategy = new SFraxETHStrategy(
            address(vault),
            params,
            FRAX_MINTER_V2,
            FRXETH,
            SFRXETH,
            address(oracleAdapter),
            0,
            MAX_ORACLE_STALENESS
        );

        classifier.assignStrategyRiskLevel(uint256(IMYTStrategy(address(strategy)).adapterId()), uint8(params.riskClass));
        vm.stopPrank();

        _setUpMYT();
        _mockFreshFrxEthEthOracle();
        _depositToVault(ABSOLUTE_CAP);
    }

    function test_allocator_allocate_direct_mintsSfrxEth(uint256 amount) public {
        _mockFreshFrxEthEthOracle();
        amount = bound(amount, 1e18, ABSOLUTE_CAP);

        vm.prank(admin);
        IAllocator(address(allocator)).allocate(address(strategy), amount);

        assertGt(ISfrxETHView(SFRXETH).balanceOf(address(strategy)), 0, "strategy should receive sfrxETH shares");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "strategy should not keep idle WETH after direct allocate");
        assertApproxEqRel(
            IMYTStrategy(address(strategy)).realAssets(),
            ISfrxETHView(SFRXETH).convertToAssets(ISfrxETHView(SFRXETH).balanceOf(address(strategy))),
            1e15
        );
    }

    function test_allocator_allocateWithSwap_wrapsReceivedFrxEthIntoSfrxEth() public {
        _mockFreshFrxEthEthOracle();

        MockSwapperForSFraxETH swapper = new MockSwapperForSFraxETH();
        deal(FRXETH, address(swapper), 10e18);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForSFraxETH.swap, (WETH, FRXETH, 10e18, 10e18));

        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), 10e18, txData);

        uint256 sharesBalance = ISfrxETHView(SFRXETH).balanceOf(address(strategy));
        assertGt(sharesBalance, 0, "strategy should receive sfrxETH shares after swap allocation");
        assertEq(IERC20(FRXETH).balanceOf(address(strategy)), 0, "strategy should not retain frxETH after deposit");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "strategy should not retain idle WETH after swap allocation");
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), ISfrxETHView(SFRXETH).convertToAssets(sharesBalance), 1e15);
    }

    function test_realAssets_includesRawFrxEthBalance() public {
        _mockFreshFrxEthEthOracle();

        deal(FRXETH, address(strategy), 3e18);

        assertEq(IMYTStrategy(address(strategy)).realAssets(), 3e18, "raw frxETH should be counted in real assets");
    }

    function test_allocator_allocateWithSwap_reverts_below_minFrxEthOut_floor_when_oracle_min_is_weakened() public {
        uint256 amountIn = 10e18;
        uint256 minFrxEthOut = (amountIn * MIN_FRXETH_OUT_BPS) / 10_000;
        uint256 mockedOut = minFrxEthOut - 1;

        vm.mockCall(
            FRXETH_ETH_DUAL_ORACLE,
            abi.encodeWithSignature("getPrices()"),
            abi.encode(false, uint256(100e18), uint256(100e18))
        );

        MockSwapperForSFraxETH swapper = new MockSwapperForSFraxETH();
        deal(FRXETH, address(swapper), mockedOut);

        vm.prank(admin);
        strategy.setMinFrxEthOutBps(MIN_FRXETH_OUT_BPS);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForSFraxETH.swap, (WETH, FRXETH, amountIn, mockedOut));

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minFrxEthOut, mockedOut));
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);
    }

    function test_setMinFrxEthOutBps_onlyOwner_updatesValue() public {
        assertEq(strategy.minFrxEthOutBps(), 0, "unexpected initial minFrxEthOutBps");

        vm.prank(admin);
        strategy.setMinFrxEthOutBps(MIN_FRXETH_OUT_BPS);

        assertEq(strategy.minFrxEthOutBps(), MIN_FRXETH_OUT_BPS, "minFrxEthOutBps should update");
    }

    function test_setMinFrxEthOutBps_reverts_for_non_owner() public {
        vm.expectRevert();
        vm.prank(operator);
        strategy.setMinFrxEthOutBps(MIN_FRXETH_OUT_BPS);
    }

    function test_setMinFrxEthOutBps_reverts_above_bps_limit() public {
        vm.expectRevert(bytes("Invalid min frxETH out bps"));
        vm.prank(admin);
        strategy.setMinFrxEthOutBps(10_001);
    }

    function test_constructor_sets_max_oracle_staleness() public view {
        assertEq(strategy.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS, "unexpected initial max oracle staleness");
    }

    function test_allocator_deallocate_with_unwrapAndSwap_usesFrxEthIntermediate() public {
        _mockFreshFrxEthEthOracle();

        vm.prank(admin);
        IAllocator(address(allocator)).allocate(address(strategy), 10e18);

        MockSwapperForSFraxETH swapper = new MockSwapperForSFraxETH();
        deal(WETH, address(swapper), 4e18);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 strategySharesBefore = ISfrxETHView(SFRXETH).balanceOf(address(strategy));
        uint256 allocationBefore = IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId());
        bytes memory txData = abi.encodeCall(MockSwapperForSFraxETH.swap, (FRXETH, WETH, 4e18, 4e18));

        _mockFreshFrxEthEthOracle();

        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 4e18);

        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultBalanceBefore + 4e18, "vault should receive deallocated WETH");
        assertEq(IERC20(FRXETH).balanceOf(address(strategy)), 0, "strategy should not retain frxETH after swap");
        assertLt(ISfrxETHView(SFRXETH).balanceOf(address(strategy)), strategySharesBefore, "strategy should burn sfrxETH");
        assertLt(
            IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId()),
            allocationBefore,
            "allocation should decrease after deallocation"
        );
    }

    function test_allocator_deallocateWithSwap_reverts_useUnwrapPath() public {
        _mockFreshFrxEthEthOracle();

        vm.prank(admin);
        IAllocator(address(allocator)).allocate(address(strategy), 10e18);

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithSwap(address(strategy), 1e18, hex"01");
    }

    function _mockFreshFrxEthEthOracle() internal {
        vm.mockCall(
            FRXETH_ETH_DUAL_ORACLE,
            abi.encodeWithSignature("getPrices()"),
            abi.encode(false, uint256(1e18), uint256(1e18))
        );
    }

    function _setUpMYT() internal {
        vm.startPrank(operator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        IVaultV2(address(vault)).setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(strategy)));
        IVaultV2(address(vault)).addAdapter(address(strategy));

        bytes memory idData = IMYTStrategy(address(strategy)).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, ABSOLUTE_CAP)));
        IVaultV2(address(vault)).increaseAbsoluteCap(idData, ABSOLUTE_CAP);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        IVaultV2(address(vault)).increaseRelativeCap(idData, RELATIVE_CAP);
        vm.stopPrank();
    }

    function _depositToVault(uint256 amount) internal {
        deal(WETH, admin, amount);
        vm.startPrank(admin);
        TokenUtils.safeApprove(WETH, address(vault), amount);
        IVaultV2(address(vault)).deposit(amount, admin);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(address(vault)).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(address(vault)).timelock(selector));
    }

    function getForkBlockNumber() internal pure returns (uint256) {
        return 24595012;
    }
}
