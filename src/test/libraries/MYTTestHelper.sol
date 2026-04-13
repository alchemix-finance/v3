// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

library MYTTestHelper {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant PERFORMANCE_FEE = 15e16;

    function _setupVault(address collateral, address admin, address curator) internal returns (MockMYTVault) {
        MockMYTVault vault = new MockMYTVault(admin, collateral);
        vault.setCurator(curator);

        vm.stopPrank();
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (admin)));
        vault.setPerformanceFeeRecipient(admin);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (PERFORMANCE_FEE)));
        vault.setPerformanceFee(PERFORMANCE_FEE);
        vm.stopPrank();
        vm.startPrank(admin);

        return vault;
    }

    function _setupStrategy(address myt, address yieldToken, address owner, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass)
        external
        returns (MockMYTStrategy)
    {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false,
            slippageBPS: 1
        });
        return new MockMYTStrategy(myt, yieldToken, params);
    }
}
