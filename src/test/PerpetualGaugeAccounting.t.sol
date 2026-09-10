// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { PerpetualGauge } from "../PerpetualGauge.sol";

contract SimpleBalanceToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PerpetualGaugeAccountingTest is Test {
    uint256 private constant YT_ID = 1;
    uint256 private constant STRATEGY_A = 11;
    uint256 private constant STRATEGY_B = 22;
    uint256 private constant STRATEGY_LIST_SLOT = 9;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    SimpleBalanceToken internal token;
    PerpetualGauge internal gauge;

    function setUp() public {
        token = new SimpleBalanceToken();
        gauge = new PerpetualGauge(address(0x100), address(0x200), address(token));

        token.mint(ALICE, 100e18);
        _setStrategyList(YT_ID, _pair(STRATEGY_A, STRATEGY_B));
    }

    function testClearVoteLeavesGhostWeightWhenBalanceDrops() public {
        vm.prank(ALICE);
        gauge.vote(YT_ID, _single(STRATEGY_A), _single(1));

        vm.prank(ALICE);
        token.transfer(BOB, 100e18);

        vm.prank(ALICE);
        gauge.clearVote(YT_ID);

        vm.prank(BOB);
        gauge.vote(YT_ID, _single(STRATEGY_B), _single(1));

        (, uint256[] memory weights) = gauge.getCurrentAllocations(YT_ID);
        assertEq(weights[0], 0.5e18);
        assertEq(weights[1], 0.5e18);
    }

    function testClearVoteRevertsWhenBalanceIncreases() public {
        vm.prank(ALICE);
        gauge.vote(YT_ID, _single(STRATEGY_A), _single(1));

        token.mint(ALICE, 1);

        vm.prank(ALICE);
        vm.expectRevert(stdError.arithmeticError);
        gauge.clearVote(YT_ID);
    }

    function testExpiredVoteStillCountsAfterRevote() public {
        vm.prank(ALICE);
        gauge.vote(YT_ID, _single(STRATEGY_A), _single(1));

        vm.warp(block.timestamp + 366 days);

        vm.prank(ALICE);
        gauge.vote(YT_ID, _single(STRATEGY_B), _single(1));

        (, uint256[] memory weights) = gauge.getCurrentAllocations(YT_ID);
        assertEq(weights[0], 0.5e18);
        assertEq(weights[1], 0.5e18);
    }

    function _setStrategyList(uint256 ytId, uint256[] memory strategyIds) internal {
        bytes32 slot = keccak256(abi.encode(ytId, STRATEGY_LIST_SLOT));
        vm.store(address(gauge), slot, bytes32(strategyIds.length));

        bytes32 base = keccak256(abi.encode(slot));
        uint256 start = uint256(base);
        for (uint256 i = 0; i < strategyIds.length; i++) {
            vm.store(address(gauge), bytes32(start + i), bytes32(strategyIds[i]));
        }
    }

    function _single(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
