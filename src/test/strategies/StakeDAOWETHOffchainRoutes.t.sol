// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeDAOWETHStrategy} from "../../strategies/StakeDAOWETHStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IStakeDAORewardVault} from "../../strategies/interfaces/IStakeDAO.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fork tests that replay pinned Enso route calldata from static JSON fixtures.
abstract contract StakeDAOWETHOffchainRoutesBaseTest is Test {
    address internal constant DEPLOYER = address(uint160(0xC0FFEE));
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant REWARD_VAULT = 0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C;
    address internal constant ETH_PLUS_WETH_POOL = 0x2c683fAd51da2cd17793219CC86439C1875c353e;
    address internal constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    address internal admin = address(1);
    address internal curator = address(2);
    address internal operator = address(3);
    address internal vaultDepositor = address(4);

    MockMYTVault internal vault;
    StakeDAOWETHStrategy internal strategy;
    string internal fixture;
    address internal allocator;
    address internal classifier;

    function setUp() public {
        fixture = vm.readFile(_fixturePath());
        _requireGeneratedFixture();
        uint256 blockNumber = _readUint(".blockNumber");
        vm.createSelectFork(_readString(".rpcUrl"), blockNumber);

        _deployStrategyAtFixtureAddress();
        _setUpAllocator();
    }

    function test_allocateWithSwap_usesStaticEnsoRoute() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 sharesReceived = IERC20(REWARD_VAULT).balanceOf(address(strategy)) - sharesBefore;
        assertGt(sharesReceived, 0, "no RewardVault shares received");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), wethBefore, "WETH should be fully routed");
        assertGe(IMYTStrategy(address(strategy)).realAssets(), allocateAmount * 99 / 100, "realAssets underallocated");
        _assertEnsoAllowancesCleared();
    }

    function test_allocateWithSwap_succeedsAtLpPerWethFloorBoundary() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesOut = _readUint(".allocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        uint256 quotedLpOut = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(quotedSharesOut);
        uint256 boundaryFloor = Math.mulDiv(quotedLpOut, 1e18, allocateAmount);

        vm.prank(admin);
        strategy.setMinCurveLpPerWeth(boundaryFloor);

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        assertEq(IERC20(REWARD_VAULT).balanceOf(address(strategy)), quotedSharesOut, "unexpected shares at floor boundary");
        _assertEnsoAllowancesCleared();
    }

    function test_allocateWithSwap_revertsBelowLpPerWethFloor() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesOut = _readUint(".allocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        uint256 quotedLpOut = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(quotedSharesOut);
        uint256 floorAboveRoute = Math.mulDiv(quotedLpOut, 1e18, allocateAmount, Math.Rounding.Ceil) + 1;

        vm.prank(admin);
        strategy.setMinCurveLpPerWeth(floorAboveRoute);

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        vm.expectPartialRevert(StakeDAOWETHStrategy.CurveLpOutputBelowFloor.selector);
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        assertEq(IERC20(WETH).balanceOf(address(strategy)), allocateAmount, "WETH changed after reverted allocation");
        assertEq(IERC20(REWARD_VAULT).balanceOf(address(strategy)), 0, "shares changed after reverted allocation");
        _assertEnsoAllowancesCleared();
    }

    function test_deallocateWithSwap_usesStaticEnsoRoute() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 withdrawAmount = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 sharesAfterAllocate = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(withdrawAmount);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        assertGe(IERC20(WETH).balanceOf(address(strategy)) - wethBefore, preview, "insufficient WETH out");
        assertLt(IERC20(REWARD_VAULT).balanceOf(address(strategy)), sharesAfterAllocate, "shares should decrease");
        _assertEnsoAllowancesCleared();
    }

    function test_deallocateWithSwap_succeedsAtWethPerLpFloorBoundary() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesIn = _readUint(".deallocate.amountIn");
        uint256 quotedWethOut = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 lpValueBefore = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 quotedLpSpent = Math.mulDiv(quotedSharesIn, lpValueBefore, shares, Math.Rounding.Ceil);
        uint256 boundaryFloor = Math.mulDiv(quotedWethOut, 1e18, quotedLpSpent);
        vm.prank(admin);
        strategy.setMinWethPerCurveLp(boundaryFloor);

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(quotedWethOut);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        assertEq(shares - IERC20(REWARD_VAULT).balanceOf(address(strategy)), quotedSharesIn, "unexpected shares spent at floor boundary");
        assertGe(IERC20(WETH).balanceOf(address(strategy)), preview, "insufficient WETH at floor boundary");
        _assertEnsoAllowancesCleared();
    }

    function test_deallocateWithSwap_revertsBelowWethPerLpFloor() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesIn = _readUint(".deallocate.amountIn");
        uint256 quotedWethOut = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));
        uint256 lpValueBefore = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(sharesBefore);
        uint256 quotedLpSpent = Math.mulDiv(quotedSharesIn, lpValueBefore, sharesBefore, Math.Rounding.Ceil);
        uint256 floorAboveRoute = Math.mulDiv(quotedWethOut, 1e18, quotedLpSpent) + 1e15;
        vm.prank(admin);
        strategy.setMinWethPerCurveLp(floorAboveRoute);

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(quotedWethOut);
        vm.prank(address(vault));
        vm.expectRevert("Enso route failed");
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        assertEq(IERC20(REWARD_VAULT).balanceOf(address(strategy)), sharesBefore, "shares changed after reverted deallocation");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), wethBefore, "WETH changed after reverted deallocation");
        _assertEnsoAllowancesCleared();
    }

    function test_partialDeallocateWithSwap_preservesRemainingShares() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesIn = _readUint(".deallocate.amountIn");
        uint256 quotedWethOut = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(quotedWethOut);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        uint256 sharesAfter = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        assertEq(sharesBefore - sharesAfter, quotedSharesIn, "route consumed unexpected shares");
        assertGt(sharesAfter, 0, "partial deallocation consumed full position");
        assertGe(IERC20(WETH).balanceOf(address(strategy)) - wethBefore, preview, "insufficient WETH out");
        _assertEnsoAllowancesCleared();
    }

    function test_fullDeallocateWithSwap_redeemsAllShares() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesIn = _readUint(".deallocateFull.amountIn");
        uint256 quotedWethOut = _readUint(".deallocateFull.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocateFull.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        assertEq(sharesBefore, quotedSharesIn, "full route input should match position");
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(quotedWethOut);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        assertEq(IERC20(REWARD_VAULT).balanceOf(address(strategy)), 0, "full deallocation should redeem all shares");
        assertGe(IERC20(WETH).balanceOf(address(strategy)) - wethBefore, preview, "insufficient WETH out");
        _assertEnsoAllowancesCleared();
    }

    function test_mixedIdleAndEnsoDeallocate_usesIdleBeforeRoutingShortfall() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 quotedSharesIn = _readUint(".deallocate.amountIn");
        uint256 quotedWethOut = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, address(strategy), allocateAmount);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(_swapParams(allocateCalldata), allocateAmount, "", address(vault));

        uint256 idleAmount = allocateAmount / 10;
        deal(WETH, address(strategy), idleAmount);
        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(idleAmount + quotedWethOut);
        assertGt(preview, idleAmount, "position should cover a shortfall");

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(_swapParams(deallocateCalldata), preview, "", address(vault));

        uint256 sharesAfter = IERC20(REWARD_VAULT).balanceOf(address(strategy));
        assertEq(sharesBefore - sharesAfter, quotedSharesIn, "route consumed unexpected shares");
        assertGt(sharesAfter, 0, "mixed deallocation consumed full position");
        assertGe(IERC20(WETH).balanceOf(address(strategy)), preview, "idle plus routed WETH should cover withdrawal");
        _assertEnsoAllowancesCleared();
    }

    function test_allocator_allocateAndDeallocateWithSwap_usesStaticEnsoRoutes() public {
        uint256 allocateAmount = _readUint(".allocate.amountIn");
        uint256 withdrawAmount = _readUint(".deallocate.amountOut");
        bytes memory allocateCalldata = vm.parseJsonBytes(fixture, ".allocate.tx.data");
        bytes memory deallocateCalldata = vm.parseJsonBytes(fixture, ".deallocate.tx.data");

        deal(WETH, vaultDepositor, allocateAmount * 2);
        vm.startPrank(vaultDepositor);
        IERC20(WETH).approve(address(vault), allocateAmount * 2);
        vault.deposit(allocateAmount * 2, vaultDepositor);
        vm.stopPrank();

        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(address(strategy), allocateAmount, allocateCalldata);
        assertGe(IMYTStrategy(address(strategy)).realAssets(), allocateAmount * 99 / 100, "strategy underallocated");

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(withdrawAmount);
        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(address(vault));
        IAllocator(allocator).deallocateWithSwap(address(strategy), preview, deallocateCalldata);
        vm.stopPrank();

        assertGe(IERC20(WETH).balanceOf(address(vault)) - vaultBalanceBefore, preview, "vault should receive WETH");
        _assertEnsoAllowancesCleared();
    }

    function test_fixtureAssumptions() public view {
        assertEq(vm.parseJsonAddress(fixture, ".strategyAddress"), address(strategy), "strategy address mismatch");
        assertEq(vm.parseJsonAddress(fixture, ".ensoRouter"), ENSO_ROUTER, "enso router mismatch");
        assertEq(vm.parseJsonAddress(fixture, ".allocate.tx.to"), ENSO_ROUTER, "allocate tx.to mismatch");
        assertEq(vm.parseJsonAddress(fixture, ".deallocate.tx.to"), ENSO_ROUTER, "deallocate tx.to mismatch");
        assertEq(vm.parseJsonAddress(fixture, ".deallocateFull.tx.to"), ENSO_ROUTER, "full deallocate tx.to mismatch");
        assertEq(IStakeDAORewardVault(REWARD_VAULT).asset(), ETH_PLUS_WETH_POOL, "reward vault asset mismatch");
    }

    function _deployStrategyAtFixtureAddress() internal {
        address expectedStrategy = vm.parseJsonAddress(fixture, ".strategyAddress");

        vm.startPrank(DEPLOYER);
        require(vm.getNonce(DEPLOYER) == 0, "unexpected deployer nonce");

        vault = new MockMYTVault(admin, WETH);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "StakeDAOWETH Offchain Routes",
            protocol: "StakeDAO",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: true,
            slippageBPS: 125
        });

        strategy = new StakeDAOWETHStrategy(address(vault), params, REWARD_VAULT, ETH_PLUS_WETH_POOL, ENSO_ROUTER, 125, 1e18, 0.95e18);
        vm.stopPrank();

        assertEq(address(vault), vm.computeCreateAddress(DEPLOYER, 0), "vault address mismatch");
        assertEq(address(strategy), vm.computeCreateAddress(DEPLOYER, 1), "strategy nonce mismatch");
        assertEq(address(strategy), expectedStrategy, "regenerate fixture after bytecode changes");
    }

    function _setUpAllocator() internal {
        vm.prank(admin);
        vault.setCurator(curator);

        vm.startPrank(admin);
        classifier = address(new AlchemistStrategyClassifier(admin));
        AlchemistStrategyClassifier(classifier).setRiskClass(uint8(IMYTStrategy.RiskClass.MEDIUM), 1e18, 1e18);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategy.adapterId()), uint8(IMYTStrategy.RiskClass.MEDIUM));
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);
        _submitAndExecute(abi.encodeCall(IVaultV2.addAdapter, (address(strategy))));
        vault.addAdapter(address(strategy));
        bytes memory idData = strategy.getIdData();
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 10_000e18)));
        vault.increaseAbsoluteCap(idData, 10_000e18);
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();
    }

    function _swapParams(bytes memory txData) internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap, swapParams: IMYTStrategy.SwapParams({txData: txData, minIntermediateOut: 0})
        });
        return abi.encode(params);
    }

    function _requireGeneratedFixture() internal {
        if (!vm.parseJsonBool(fixture, ".generated")) {
            vm.skip(true);
        }
    }

    function _readUint(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(fixture, key));
    }

    function _readString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(fixture, key);
    }

    function _fixturePath() internal pure virtual returns (string memory);

    function _assertEnsoAllowancesCleared() internal view {
        assertEq(IERC20(WETH).allowance(address(strategy), ENSO_ROUTER), 0, "WETH allowance should be cleared");
        assertEq(IERC20(REWARD_VAULT).allowance(address(strategy), ENSO_ROUTER), 0, "RewardVault allowance should be cleared");
    }

    function _submitAndExecute(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }
}

contract StakeDAOWETHOffchainRoutesTest is StakeDAOWETHOffchainRoutesBaseTest {
    function _fixturePath() internal pure override returns (string memory) {
        return "src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle1Eth.json";
    }
}

contract StakeDAOWETH300WETHOffchainRoutesTest is StakeDAOWETHOffchainRoutesBaseTest {
    function _fixturePath() internal pure override returns (string memory) {
        return "src/test/strategies/utils/offchain/quotes/stakeDaoWethLifecycle300Weth.json";
    }
}
