// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {AlchemistV3} from "../AlchemistV3.sol";
import {AlEth} from "../external/AlEth.sol";
import {Transmuter} from "../Transmuter.sol";
import {StakingGraph} from "../libraries/StakingGraph.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/ITransmuter.sol";

import "../base/Errors.sol";
import "../base/TransmuterErrors.sol";

contract MockAlchemist {
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public underlyingValue;
    uint256 public syntheticsIssued;
    address public myt;

    constructor(address _myt) {
        myt = _myt;
    }

    function setUnderlyingValue(uint256 amount) public {
        underlyingValue = amount;
    }

    function setSyntheticsIssued(uint256 amount) public {
        syntheticsIssued = amount;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) {
        return (amount * 2 * FIXED_POINT_SCALAR) / FIXED_POINT_SCALAR;
    }

    function convertUnderlyingTokensToYield(uint256 amount) public pure returns (uint256) {
        return amount * FIXED_POINT_SCALAR / (2 * FIXED_POINT_SCALAR);
    }

    function normalizeUnderlyingTokensToDebt(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertYieldTokensToDebt(uint256 amount) public pure returns (uint256) {
        return (amount * 2 * FIXED_POINT_SCALAR) / FIXED_POINT_SCALAR;
    }

    function convertDebtTokensToYield(uint256 amount) public pure returns (uint256) {
        return amount * FIXED_POINT_SCALAR / (2 * FIXED_POINT_SCALAR);
    }

    function redeem(uint256 underlying) external returns (uint256 sharesSent) {
        sharesSent = convertUnderlyingTokensToYield(underlying);
        IERC20(myt).transfer(msg.sender, sharesSent);
    }
    
    function totalDebt() external pure returns (uint256) {
        return type(uint256).max;
    }

    function totalSyntheticsIssued() external returns (uint256) {
        if (syntheticsIssued > 0) {
            return syntheticsIssued;
        } else {
            return type(uint256).max / 1e20;
        }
    }

    function reduceSyntheticsIssued(uint256 amount) external {}

    function setTransmuterTokenBalance(uint256 amount) external {}

    function yieldToken() external view returns (address) {
        return address(myt);
    }

    function underlyingToken() external view returns (address) {
        return address(myt);
    }

    function getTotalLockedUnderlyingValue() external view returns (uint256) {
        if (underlyingValue > 0) {
            return underlyingValue;
        } else {
            return type(uint256).max / 1e20;
        }
    }
}

contract MockMorphoV2Vault is ERC20 {
    // Simplied vault for testing
    // Shares are still treated as 18 decimal erc20 tokens
    // regardless of the underlying token decimals
    constructor() ERC20("Mock Myt Vault", "MMV") {}
}

contract TransmuterTest is Test {
    using StakingGraph for StakingGraph.Graph;

    AlEth public alETH;
    ERC20 public collateralToken; // morpho vault 2 shares
    AlEth public underlyingToken;
    Transmuter public transmuter;

    MockAlchemist public alchemist;

    StakingGraph.Graph private graph;
    MockMorphoV2Vault public vault;
    address public admin;
    address public curator;

    event TransmuterLog(string message, uint256 value);

    function setUp() public {
        alETH = new AlEth();
        underlyingToken = new AlEth();
        vault = new MockMorphoV2Vault();
        collateralToken = ERC20(address(vault));
        alchemist = new MockAlchemist(address(collateralToken));
        transmuter = new Transmuter(ITransmuter.TransmuterInitializationParams(address(alETH), address(this), 5_256_000, 0, 0, 52_560_000 / 2));

        transmuter.setAlchemist(address(alchemist));

        transmuter.setDepositCap(uint256(type(int256).max));

        deal(alchemist.myt(), address(alchemist), type(uint256).max);
        deal(address(alETH), address(0xbeef), type(uint256).max);

        vm.prank(address(alchemist));
        IERC20(alchemist.myt()).approve(address(transmuter), type(uint256).max);

        vm.prank(address(0xbeef));
        alETH.approve(address(transmuter), type(uint256).max);
    }

    function testSetAdmin() public {
        transmuter.setPendingAdmin(address(0xbeef));

        vm.prank(address(0xbeef));
        transmuter.acceptAdmin();

        assertEq(address(0xbeef), transmuter.admin());
    }

    function testSetAdminWrongAddress() public {
        transmuter.setPendingAdmin(address(0xbeef));

        vm.startPrank(address(0xbeef123));
        vm.expectRevert();
        transmuter.acceptAdmin();
        vm.stopPrank();
    }

    function testURI() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        transmuter.tokenURI(1);
    }

    function testSetTransmutaitonFeeTooHigh() public {
        vm.expectRevert();
        transmuter.setTransmutationFee(10_001);
    }

    function testSetExitFeeTooHigh() public {
        vm.expectRevert();
        transmuter.setExitFee(10_001);
    }

    function testSetTransmutationTime() public {
        transmuter.setTransmutationTime(20 days);

        assertEq(transmuter.timeToTransmute(), 20 days);
    }

    function testSetTransmutationTimeZeroReverts() public {
        vm.expectRevert();
        transmuter.setTransmutationTime(0);
    }

    function testSetTransmutationTimeTooHighReverts() public {
        vm.expectRevert();
        transmuter.setTransmutationTime(uint256(type(int256).max) + 1);
    }

    function testConstructorFeeReceiverZeroReverts() public {
        vm.expectRevert();
        new Transmuter(
            ITransmuter.TransmuterInitializationParams(address(alETH), address(0), 5_256_000, 0, 0, 52_560_000 / 2)
        );
    }

    function testConstructorTransmutationFeeTooHighReverts() public {
        vm.expectRevert();
        new Transmuter(
            ITransmuter.TransmuterInitializationParams(address(alETH), address(this), 5_256_000, 10_001, 0, 52_560_000 / 2)
        );
    }

    function testConstructorExitFeeTooHighReverts() public {
        vm.expectRevert();
        new Transmuter(
            ITransmuter.TransmuterInitializationParams(address(alETH), address(this), 5_256_000, 0, 10_001, 52_560_000 / 2)
        );
    }

    function testConstructorTransmutationTimeZeroReverts() public {
        vm.expectRevert();
        new Transmuter(ITransmuter.TransmuterInitializationParams(address(alETH), address(this), 0, 0, 0, 52_560_000 / 2));
    }

    function testConstructorTransmutationTimeTooHighReverts() public {
        vm.expectRevert();
        new Transmuter(
            ITransmuter.TransmuterInitializationParams(
                address(alETH), address(this), uint256(type(int256).max) + 1, 0, 0, 52_560_000 / 2
            )
        );
    }

    function testCreateRedemption() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));
        Transmuter.StakingPosition memory position = transmuter.getPosition(1);
        assertEq(position.amount, 100e18);
        assertEq(transmuter.totalLocked(), 100e18);
    }

    function testCreateRedemptionForRecipient() public {
        address recipient = address(0xcafe);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, recipient);

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        assertEq(position.amount, 100e18);
        assertEq(transmuter.ownerOf(1), recipient);
        assertEq(transmuter.totalLocked(), 100e18);
    }

    function testCreateRedemptionTooLarge() public {
        vm.startPrank(address(0xbeef));
        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(uint256(type(int256).max) + 1, address(0xbeef));
        vm.stopPrank();
    }

    function testFuzzCreateRedemption(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount < uint256(type(int256).max) / 1e50);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(amount, address(0xbeef));

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        assertEq(position.amount, amount);
        assertEq(transmuter.totalLocked(), amount);
    }

    function testCreateRedemptionNoTokens() public {
        vm.expectRevert(DepositZeroAmount.selector);
        transmuter.createRedemption(0, address(this));
    }

    function testCreateRedemptionZeroRecipientReverts() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(IllegalArgument.selector);
        transmuter.createRedemption(100e18, address(0));
    }

    function testCreateRedemptionDepositCapReached() public {
        transmuter.setDepositCap(90e18);

        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(100e18, address(this));
    }

    function testCreateRedemptionDepositCapReachedSynthetic() public {
        transmuter.setDepositCap(110e18);
        alchemist.setSyntheticsIssued(90e18);

        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(100e18, address(this));
    }

    function testClaimRedemptionNoPosition() public {
        vm.expectRevert(PositionNotFound.selector);
        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);
    }

    function test_target_ClaimRedemption() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);
        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionBadDebt() public {
        deal(address(collateralToken), address(transmuter), 200e18);
        alchemist.setSyntheticsIssued(1200e18);
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        alchemist.setUnderlyingValue(200e18);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) / 2);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionNotOwner() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        vm.startPrank(address(0xbeef123));
        vm.expectRevert(CallerNotOwner.selector);
        transmuter.claimRedemption(1);

        vm.stopPrank();
    }

    function testClaimRedemptionFromAlchemist() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        uint256 startingBalance = collateralToken.balanceOf(address(alchemist));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18));
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        assertEq(collateralToken.balanceOf(address(alchemist)), startingBalance - alchemist.convertUnderlyingTokensToYield(100e18));
    }

    function testFuzzClaimRedemption(uint256 amount) public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.assume(amount > 0);
        vm.assume(amount < uint256(type(int256).max) / 1e50);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(amount, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(amount));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionWithTransmuterFee() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        // 1% fee
        transmuter.setTransmutationFee(100);
        transmuter.setProtocolFeeReceiver(address(this));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) * 9900 / 10_000);
        assertEq(collateralToken.balanceOf(address(this)), alchemist.convertUnderlyingTokensToYield(100e18) * 100 / 10_000);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testFuzzClaimRedemptionWithTransmuterFee(uint256 fee) public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.assume(fee <= 10_000);

        transmuter.setTransmutationFee(fee);
        transmuter.setProtocolFeeReceiver(address(this));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) * (10_000 - fee) / 10_000);
        assertEq(collateralToken.balanceOf(address(this)), alchemist.convertUnderlyingTokensToYield(100e18) * fee / 10_000);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionPremature() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        // uint256 query = transmuter.queryGraph(block.number + 1, block.number + 5256000);
        // assertEq(query, 100e18);

        vm.roll(block.number + (5_256_000 / 2));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(50e18));
        assertEq(balanceBefore - balanceAfter, 50e18);
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        // Make sure remaining graph is cleared
        uint256 query2 = transmuter.queryGraph(block.number + 1, block.number + (5_256_000 / 2));

        assertApproxEqAbs(query2, 0, 1);
    }

    function testFuzzClaimRedemptionPremature(uint256 time) public {
        vm.assume(time > 0);
        vm.assume(time < 5_256_000);

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        uint256 query = transmuter.queryGraph(block.number + 1, block.number + 5_256_000);
        assertEq(query, 100e18);

        vm.roll(block.number + time);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertApproxEqAbs(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield((100e18 * time) / 5_256_000), 1);
        assertApproxEqAbs(balanceBefore - balanceAfter, (100e18 * time) / 5_256_000, 1);
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        // Make sure remaining graph is cleared
        // uint256 query2 = transmuter.queryGraph(block.number + 1, block.number + (5256000 - time));

        // assertApproxEqAbs(query2, 0, 1);
    }

    function testClaimRedemptionPrematureWithFee() public {
        // 1%
        transmuter.setExitFee(100);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.roll(block.number + (5_256_000 / 2));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(50e18));
        assertEq(balanceAfter - balanceBefore, 50e18 - (50e18 * 100 / 10_000));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
        assertEq(alETH.balanceOf(address(this)), 50e18 * 100 / 10_000);
    }

    function testQueryGraph() external {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + 5_256_000);

        uint256 treeQuery = transmuter.queryGraph(block.number - 5_256_000 + 1, block.number);

        assertApproxEqAbs(treeQuery, 100e18, 1);
    }

    function testQueryGraphPartial() external {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + (5_256_000 / 2));

        uint256 treeQuery = transmuter.queryGraph(block.number - (5_256_000 / 2) + 1, block.number);

        assertApproxEqAbs(treeQuery, 50e18, 1);
    }

    function testClaimRedemption_division() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));
        vm.roll(block.number + 5_256_000); // Mature the staking position
        alchemist.setUnderlyingValue(0); // Simulate all users exiting with 0 underlying left
        emit log_named_uint("total token there", alchemist.getTotalLockedUnderlyingValue());
        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);
    }

    function test_delta_overflow() public {
        int256 amount = (2 ** 111) - 1;
        uint32 start = 1000;
        uint32 duration = 10;

        graph.addStake(amount / 10, start, duration);

        int256 result = graph.queryStake(start, start + duration);

        assertApproxEqAbs(result, amount, 10);
    }

    function test_negative_stake() public {
        // Add stake of 100 wei from block 25 to block 28
        graph.addStake(100, 25, 3);
        assertEq(graph.size, 32, "Graph size should be 32 after stake");
        // The current block is now greater than the last initialized block in the fenwick tree
        // Check that the graph queries only to its max size and does not return negative number
        int256 result = graph.queryStake(63, 63);
        assertEq(result, 0);
    }

    function test_queryStake_OutOfBoundsStartBeyondDoubleSize_ReturnsZero() public {
        // Build a small tree and then query far beyond its right boundary.
        // Without clamping the left prefix index, Fenwick traversal can miss the terminal node
        // and return a non-zero historical amount for an empty range.
        graph.addStake(100, 25, 3);
        assertEq(graph.size, 32, "Graph size should be 32 after stake");

        int256 result = graph.queryStake(70, 70);
        assertEq(result, 0);
    }

    function testStakingGraph_Bounds_AcceptsDeltaMax() public {
        int256 deltaMax = (int256(1) << 111) - 1;

        this._addStakeExternal(deltaMax, 1, 1);

        int256 result = this._queryStakeExternal(1, 2);
        assertEq(result, deltaMax);
    }

    function testStakingGraph_Bounds_AcceptsDeltaMin() public {
        int256 deltaMin = -(int256(1) << 111);

        this._addStakeExternal(deltaMin, 1, 1);

        int256 result = this._queryStakeExternal(1, 2);
        assertEq(result, deltaMin);
    }

    function testStakingGraph_Bounds_RevertsAboveDeltaMax() public {
        // DELTA_BITS = 112 => max signed delta is 2^111 - 1
        // so 2^111 must revert.
        int256 aboveMax = (int256(1) << 111);

        vm.expectRevert(); // hits require(amount <= DELTA_MAX && amount >= DELTA_MIN)
        this._addStakeExternal(aboveMax, 1, 1);
    }

    function testStakingGraph_Bounds_RevertsBelowDeltaMin() public {
        // min signed delta is -2^111, so -2^111 - 1 must revert.
        int256 deltaMin = -(int256(1) << 111);
        int256 belowMin = deltaMin - 1;

        vm.expectRevert();
        this._addStakeExternal(belowMin, 1, 1);
    }

    function testStakingGraph_Bounds_MaxDelta_WithLargeStart_DoesNotRevert() public {
        int256 deltaMax = (int256(1) << 111) - 1;

        // GRAPH_MAX is intended to be 2^32 for the 112/144 split design.
        // start must satisfy start < GRAPH_MAX - 1, so pick something comfortably < 2^32 - 1.
        uint256 start = uint256(type(uint32).max) - 3; // ~ 2^32 - 4
        uint256 duration = 1;

        // Should NOT revert
        graph.addStake(deltaMax, start, duration);

        int256 result = graph.queryStake(start, start + duration);
        assertEq(result, deltaMax, "deltaMax should work at large start without corruption/revert");
    }

    // External wrappers so vm.expectRevert can catch internal/library reverts.
    function _addStakeExternal(int256 amount, uint256 start, uint256 duration) external {
        graph.addStake(amount, start, duration);
    }

    function _queryStakeExternal(uint256 start, uint256 end) external view returns (int256) {
        return graph.queryStake(start, end);
    }

    function testPokeMatured_FreesDepositCap() public {
        // cap only allows 100e18 in-flight
        transmuter.setDepositCap(100e18);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        // should fail before poke (still in-flight, not matured)
        vm.prank(address(0xbeef));
        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(1e18, address(0xbeef));

        // mature it
        vm.roll(block.number + transmuter.timeToTransmute());

        // poke by anyone
        transmuter.pokeMatured(1);

        // now cap should be freed, deposit succeeds
        vm.prank(address(0xbeef));
        transmuter.createRedemption(1e18, address(0xbeef));
    }

    function testPokeMatured_RevertsIfNotMatured() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.expectRevert(); // PositionNotMatured (custom error)
        transmuter.pokeMatured(1);
    }

    function testPokeMatured_RevertsIfAlreadyPoked() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18, address(0xbeef));

        vm.roll(block.number + transmuter.timeToTransmute());

        transmuter.pokeMatured(1);

        vm.expectRevert(); // PositionAlreadyPoked
        transmuter.pokeMatured(1);
    }
}
