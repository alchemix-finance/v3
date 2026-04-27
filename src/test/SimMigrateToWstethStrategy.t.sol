// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SimMigrateToWstethStrategy} from "../../script/SimMigrateToWstethStrategy.s.sol";

contract SimMigrateToWstethStrategyHarness is SimMigrateToWstethStrategy {
    function validateApprovedQuote(uint256 expectedOut) external pure {
        _validateApprovedQuote(expectedOut);
    }
}

contract SimMigrateToWstethStrategyTest is Test {
    function test_validateApprovedQuote_revertsWhenQuoteCheckFails() public {
        SimMigrateToWstethStrategyHarness script = new SimMigrateToWstethStrategyHarness();
        uint256 quoteJustBelowAllowedDeviation = 5241580400307487052037;

        vm.expectRevert(bytes("Fluid quote below manually approved value"));
        script.validateApprovedQuote(quoteJustBelowAllowedDeviation);
    }
}
