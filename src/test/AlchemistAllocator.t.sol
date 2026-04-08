// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";

contract MockAlchemistAllocator is AlchemistAllocator {
    constructor(address _myt, address _admin, address _operator, address _classifier) AlchemistAllocator(_myt, _admin, _operator, _classifier) {}
}

contract AlchemistAllocatorTest is Test {
    using MYTTestHelper for *;

    MockAlchemistAllocator public allocator;
    AlchemistStrategyClassifier public classifier;
    VaultV2 public vault;
    address public admin = address(0x2222222222222222222222222222222222222222);
    address public operator = address(0x3333333333333333333333333333333333333333);
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public user1 = address(0x5555555555555555555555555555555555555555);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 0.8e18; // 80%
    MockMYTStrategy public mytStrategy;

    function setUp() public {
        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW);
        classifier = new AlchemistStrategyClassifier(admin);
        // Set up risk classes with reasonable caps
        classifier.setRiskClass(0, 10_000_000 ether, 5_000_000 ether); // LOW risk
        classifier.setRiskClass(1, 7_500_000 ether, 3_750_000 ether); // MEDIUM risk
        classifier.setRiskClass(2, 5_000_000 ether, 2_500_000 ether); // HIGH risk
        // Assign risk level to the mock strategy
        bytes32 strategyId = mytStrategy.adapterId();
        classifier.assignStrategyRiskLevel(uint256(strategyId), uint8(IMYTStrategy.RiskClass.LOW));
        allocator = new MockAlchemistAllocator(address(vault), admin, operator, address(classifier));
        vm.stopPrank();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        // bytes memory idData = abi.encode("MockTokenProtocol", address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testProxyBlockedSelectors() public {
        _magicDepositToVault(address(vault), user1, 150 ether);
        
        // Get selectors for blocked functions
        bytes4 allocateSelector = bytes4(keccak256("allocate(address,bytes,uint256)"));
        bytes4 deallocateSelector = bytes4(keccak256("deallocate(address,bytes,uint256)"));
        bytes4 multicallSelector = bytes4(keccak256("multicall(bytes[])"));

        vm.startPrank(operator);
        
        bytes memory idData = mytStrategy.getIdData();

        // Test that allocate selector is blocked
        bytes memory allocateData = abi.encodeCall(IVaultV2.allocate, (address(mytStrategy), idData, 100 ether));
        vm.expectRevert(abi.encode("PD"));
        allocator.proxy(address(vault), allocateData);
        
        // Test that deallocate selector is blocked
        bytes memory deallocateData = abi.encodeCall(IVaultV2.deallocate, (address(mytStrategy), idData, 50 ether));
        vm.expectRevert(abi.encode("PD"));
        allocator.proxy(address(vault), deallocateData);
        
        // Test that multicall selector is blocked (prevents tunneling blocked calls)
        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeCall(IVaultV2.allocate, (address(mytStrategy), idData, 100 ether));
        bytes memory multicallData = abi.encodeCall(IVaultV2.multicall, (innerCalls));
        vm.expectRevert(abi.encode("PD"));
        allocator.proxy(address(vault), multicallData);
        
        vm.stopPrank();
    }

    function testAllocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.allocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testDeallocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.deallocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testSetLiquidityAdapterUnauthorizedAccessRevert() public {
        bytes memory directData = _directLiquidityData();
        vm.expectRevert(abi.encode("PD"));
        allocator.setLiquidityAdapter(address(mytStrategy), directData);
    }

    function testSetLiquidityAdapter() public {
        bytes memory data = _directLiquidityData();

        vm.startPrank(operator);
        allocator.setLiquidityAdapter(address(mytStrategy), data);
        vm.stopPrank();

        assertEq(vault.liquidityAdapter(), address(mytStrategy));
        assertEq(keccak256(vault.liquidityData()), keccak256(data));
    }

    function _directLiquidityData() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function testAllocateRevertIfAboveAbsoluteCap() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);
        
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 absoluteCap = vault.absoluteCap(strategyId);
        
        vm.startPrank(admin);

        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, absoluteCap + 1, absoluteCap));
        allocator.allocate(address(mytStrategy), absoluteCap + 1);
        vm.stopPrank();
    }

    function testAllocateRevertIfAboveRelativeCap() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);
        
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 absoluteCap = vault.absoluteCap(strategyId);
        uint256 relativeCap = vault.relativeCap(strategyId);
        
        // Max allocation = totalAssets * relativeCap / 1e18
        uint256 totalAssets = vault.totalAssets();
        uint256 maxAllocation = (totalAssets * relativeCap) / 1e18;

        // The effective limit is the minimum of absolute and relative cap (absolute is lower: 200 ether)
        uint256 effectiveLimit = absoluteCap < maxAllocation ? absoluteCap : maxAllocation;
        
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, maxAllocation + 1, effectiveLimit));
        allocator.allocate(address(mytStrategy), maxAllocation + 1);
        vm.stopPrank();
    }

    function testAllocateRelativeCapOne_RevertWhenTotalAssetsAboveAbsoluteCap() public {
        bytes memory idData = mytStrategy.getIdData();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        _magicDepositToVault(address(vault), user1, 300 ether);
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 totalAssets = vault.totalAssets();
        uint256 absoluteCap = vault.absoluteCap(strategyId);

        assertGt(totalAssets, absoluteCap);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, totalAssets, absoluteCap));
        allocator.allocate(address(mytStrategy), totalAssets);
        vm.stopPrank();
    }

    function testAllocateRelativeCapOne_SucceedsWhenTotalAssetsBelowAbsoluteCap() public {
        bytes memory idData = mytStrategy.getIdData();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        _magicDepositToVault(address(vault), user1, 150 ether);
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 totalAssets = vault.totalAssets();
        uint256 absoluteCap = vault.absoluteCap(strategyId);

        assertLt(totalAssets, absoluteCap);

        vm.startPrank(admin);
        allocator.allocate(address(mytStrategy), totalAssets);
        vm.stopPrank();

        assertEq(vault.allocation(strategyId), totalAssets);
    }

    function testAllocateRevertIfAboveRiskGlobalCap() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);

        bytes32 strategyId = mytStrategy.adapterId();
        uint256 globalCap = 100 ether;

        vm.startPrank(admin);
        classifier.setRiskClass(0, globalCap, 5_000_000 ether);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, globalCap + 1, globalCap));
        allocator.allocate(address(mytStrategy), globalCap + 1);
        vm.stopPrank();
    }

    function testAllocateRevertIfAboveRiskIndividualCap() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);
        
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 individualCap = 50 ether;
        
        vm.startPrank(admin);
        // Set individual risk cap for LOW risk class to 50 ether
        classifier.setRiskClass(0, 10_000_000 ether, individualCap);
        
        vm.stopPrank();
        vm.startPrank(operator);

        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, individualCap + 1, individualCap));
        allocator.allocate(address(mytStrategy), individualCap + 1);
        vm.stopPrank();
    }

    /// @notice Verifies that cumulative allocations are properly checked against risk caps
    /// @dev After fix, _validateCaps should check currentAllocation + amount <= limit
    function testAllocateRevertIfCumulativeAllocationExceedsRiskCap() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);
        
        bytes32 strategyId = mytStrategy.adapterId();
        uint256 individualCap = 100 ether;
        
        vm.startPrank(curator);
        // Increase vault caps to ensure only risk caps are the limiting factor
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 10000 ether)));
        vault.increaseAbsoluteCap(idData, 10000 ether);
        vm.stopPrank();

        vm.startPrank(admin);
        // Set individual risk cap for LOW risk class
        classifier.setRiskClass(0, 100 ether, individualCap);
        vm.stopPrank();
        
        vm.startPrank(operator);
        
        // First allocation: 60 ether (should succeed, 60 <= 100)
        allocator.allocate(address(mytStrategy), 60 ether);
        assertEq(vault.allocation(strategyId), 60 ether, "First allocation should succeed");
        
        // Second allocation: 50 ether should FAIL because remaining global capacity is 40 ether
        // This verifies the fix: cumulative allocation is properly checked against remaining global capacity
        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, 50 ether, 40 ether));
        allocator.allocate(address(mytStrategy), 50 ether);
        vm.stopPrank();
        
        // Verify total allocation remains at 60 ether (second allocation was rejected)
        assertEq(vault.allocation(strategyId), 60 ether, "Allocation should remain at 60 ether");
    }

    /// @notice Verifies that global risk caps are enforced across multiple strategies in the same risk class
    /// @dev Audit fix: Ensure aggregate allocation of a risk class does not exceed globalCap
    function testAllocateRevertIfGlobalRiskCapExceededByMultipleStrategies() public {
        _magicDepositToVault(address(vault), user1, 1000 ether);

        // Setup Strategy 2 (same risk class LOW)
        address mockStrategyYieldToken2 = address(new MockYieldToken(mockVaultCollateral));
        MockMYTStrategy mytStrategy2 = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken2, admin, "MockToken2", "MockTokenProtocol2", IMYTStrategy.RiskClass.LOW);
        
        vm.startPrank(admin);
        bytes32 strategyId2 = mytStrategy2.adapterId();
        classifier.assignStrategyRiskLevel(uint256(strategyId2), uint8(IMYTStrategy.RiskClass.LOW));
        vm.stopPrank();

        vm.startPrank(curator);
        bytes memory idData2 = mytStrategy2.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy2)));
        vault.addAdapter(address(mytStrategy2));
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData2, 10000 ether)));
        vault.increaseAbsoluteCap(idData2, 10000 ether);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData2, 1e18)));
        vault.increaseRelativeCap(idData2, 1e18);
        vm.stopPrank();

        // Set Global Cap for LOW risk to 100 ether
        vm.startPrank(admin);
        classifier.setRiskClass(0, 100 ether, 100 ether); // global=100, local=100
        vm.stopPrank();

        vm.startPrank(operator);
        
        // Allocate 60 ether to Strategy 1 (should succeed)
        allocator.allocate(address(mytStrategy), 60 ether);
        assertEq(vault.allocation(mytStrategy.adapterId()), 60 ether);

        // Allocate 50 ether to Strategy 2 (should FAIL: 60 + 50 = 110 > 100 globalCap)
        // Remaining capacity = 100 - 60 = 40. Requesting 50.
        vm.expectRevert(abi.encodeWithSelector(IAllocator.EffectiveCap.selector, 50 ether, 40 ether));
        allocator.allocate(address(mytStrategy2), 50 ether);

        // Verify Strategy 2 allocation is 0
        assertEq(vault.allocation(strategyId2), 0 ether, "Strategy 2 allocation should be 0");

        // Allocate 40 ether to Strategy 2 (should succeed: 60 + 40 = 100 <= 100)
        allocator.allocate(address(mytStrategy2), 40 ether);
        assertEq(vault.allocation(strategyId2), 40 ether);

        vm.stopPrank();
    }

    function testAllocate() public {
        require(vault.adaptersLength() == 1, "adaptersLength is must be 1");
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        bytes32 allocationId = mytStrategy.adapterId();
        allocator.allocate(address(mytStrategy), 100 ether);
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();

        // verify all state state changes that happen after an allocation
        assertEq(mytStrategyYieldTokenBalance, 100 ether);
        assertEq(mytStrategyYieldTokenRealAssets, 100 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(vault.allocation(allocationId), 100 ether);
        vm.stopPrank();
    }

    function testDeallocate() public {
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        allocator.allocate(address(mytStrategy), 100 ether);
        bytes32 allocationId = mytStrategy.adapterId();
        uint256 allocation = vault.allocation(allocationId);
        assertEq(allocation, 100 ether);
        allocator.deallocate(address(mytStrategy), 50 ether);
        allocation = vault.allocation(allocationId);
        console.log("allocation is reset to", allocation);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();

        // verify all state state changes that happen after a deallocation
        assertEq(mytStrategyYieldTokenBalance, 50 ether);
        assertEq(mytStrategyYieldTokenRealAssets, 50 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(allocation, 50 ether);
        vm.stopPrank();
    }


    function testDeallocateWithYield() public {

        _seedYieldToken(1_000_000 ether);
        uint256 initialYieldTokenSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();

        require(initialYieldTokenSupply == 1_000_000 ether, "initial yield token supply is not 1_000_000 ether"); 
        _magicDepositToVault(address(vault), user1, 400 ether);
        vm.startPrank(admin);

        // allocate 200 vault tokens to the strategy
        allocator.allocate(address(mytStrategy), 200 ether);
        bytes32 allocationId = mytStrategy.adapterId();
        uint256 allocation = vault.allocation(allocationId);
        require(allocation == 200 ether, "allocation is not 200 ether");

        // Baseline price before simulating yield
        uint256 initialYieldTokenPrice = IMockYieldToken(mockStrategyYieldToken).price();

        // now mock update supply of yield token to increase price (via reducing supply)
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        // Small price increase (50%): reduce mocked supply, keeping underlying constant
        uint256 modifiedVaultSupply = initialVaultSupply - (initialVaultSupply * 5000 / 10_000);
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // get current real assets of the strategy
        uint256 currentRealAssets = mytStrategy.realAssets();
        require(IMockYieldToken(mockStrategyYieldToken).price() > initialYieldTokenPrice, "price is not greater than initial yield token price");
        require(currentRealAssets > allocation, "current real assets is not greater than allocation");
        // ensure requested amount > previous allocation. e.g. amount is the allocation + 20% of the allocation
        uint256 deallocateAmount = allocation + (allocation * 2000 / 10_000);
        require(deallocateAmount > allocation, "deallocate amount is not greater than allocation");

        // deallocate the amount from the strategy
        allocator.deallocate(address(mytStrategy), deallocateAmount);
        allocation = vault.allocation(allocationId);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();

        // verify all state state changes that happen after a deallocation
        // Expected remaining real assets are determined by remaining shares * post-deallocation price.
        uint256 priceAfter = IMockYieldToken(mockStrategyYieldToken).price();
        uint256 expectedRemainingRealAssets = (mytStrategyYieldTokenBalance * priceAfter) / 1e18; // precision loss!

        assertApproxEqRel(mytStrategyYieldTokenRealAssets, expectedRemainingRealAssets, 1e14); // 0.01% rounding headroom
        assertEq(newTotalAssets, 400 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 400 ether);
        assertEq(vault.firstTotalAssets(), 400 ether);
        assertApproxEqRel(allocation, expectedRemainingRealAssets, 1e14); // 0.01% rounding headroom
        vm.stopPrank();
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), address(vault), amount);
        IVaultV2(address(vault)).deposit(amount, address(vault));
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function _seedYieldToken(uint256 seedUnderlying) internal {
        address yieldWhale = address(0x7777);

        // Give whale underlying and have it mint yield shares to itself
        deal(mockVaultCollateral, yieldWhale, seedUnderlying);
        vm.startPrank(yieldWhale);
        TokenUtils.safeApprove(mockVaultCollateral, mockStrategyYieldToken, seedUnderlying);
        IMockYieldToken(mockStrategyYieldToken).mint(seedUnderlying, yieldWhale);
        vm.stopPrank();
    }
}
