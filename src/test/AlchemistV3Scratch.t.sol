// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeERC20} from "../libraries/SafeERC20.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {AlchemistV3Test} from "./AlchemistV3.t.sol";

contract AlchemistV3ScratchTest is AlchemistV3Test {
    function testScratch_ZeroRedemptionThenLaterEarmarkDoesNotEraseUnearmarkedDebt() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), type(uint256).max);
        alchemist.deposit(100e18, address(0xbeef), 0);
        uint256 beefId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(beefId, 50e18, address(0xbeef));
        vm.stopPrank();

        vm.mockCall(address(transmuterLogic), abi.encodeWithSelector(ITransmuter.queryGraph.selector), abi.encode(10e18));
        vm.roll(block.number + 1);
        alchemist.poke(beefId);

        (, uint256 debtAfterFirstSync, uint256 earmarkedAfterFirstSync) = alchemist.getCDP(beefId);
        assertEq(debtAfterFirstSync, 50e18, "initial debt");
        assertApproxEqAbs(earmarkedAfterFirstSync, 10e18, 1, "initial earmark");

        vm.prank(address(transmuterLogic));
        alchemist.redeem(10e18);

        vm.mockCall(address(transmuterLogic), abi.encodeWithSelector(ITransmuter.queryGraph.selector), abi.encode(type(uint256).max));
        vm.roll(block.number + 1);
        vm.prank(address(transmuterLogic));
        alchemist.redeem(0);

        alchemist.poke(beefId);

        (, uint256 finalDebt, uint256 finalEarmarked) = alchemist.getCDP(beefId);
        assertApproxEqAbs(finalDebt, 40e18, 1, "only the old earmarked debt should be redeemed");
        assertApproxEqAbs(finalEarmarked, 40e18, 1, "remaining debt should be newly earmarked");
    }
}
