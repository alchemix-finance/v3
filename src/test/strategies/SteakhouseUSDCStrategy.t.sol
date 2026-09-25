// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";
import {ERC4626Candidates} from "./base/ERC4626Candidates.sol";

contract SteakhouseUSDCStrategyTest is ERC4626StrategyUnitTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.steakhouseUSDC();
    }
}

contract SteakhouseUSDCInvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.steakhouseUSDC();
    }
}
