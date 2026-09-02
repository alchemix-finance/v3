// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";
import {ERC4626Candidates} from "./base/ERC4626Candidates.sol";

contract YearnOGUSDCV2StrategyTest is ERC4626StrategyUnitTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnOGUSDCV2();
    }

    function test_morphoVaultV2_zeroMaxMethodsAreNonBindingSentinels() public view {
        IERC4626 morphoVault = IERC4626(_candidate().targetVault);

        assertEq(morphoVault.maxDeposit(strategy), 0, "unexpected maxDeposit");
        assertEq(morphoVault.maxMint(strategy), 0, "unexpected maxMint");
        assertEq(morphoVault.maxWithdraw(strategy), 0, "unexpected maxWithdraw");
        assertEq(morphoVault.maxRedeem(strategy), 0, "unexpected maxRedeem");
    }
}

contract YearnOGUSDCV2InvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.yearnOGUSDCV2();
    }
}
