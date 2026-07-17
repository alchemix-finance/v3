// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";

contract Re7WETHStrategyTest is BaseStrategyTest {
    address public constant RE7_WETH_VAULT = 0x3d63934715b6D4c4DFbBC1a00Fe2A2145079DD76;
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "Re7 WETH Morpho V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 20e18,
            globalCap: 0.25e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 20e18, absoluteCap: 20e18, relativeCap: 0.25e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, RE7_WETH_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 154_316_176;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function test_re7VaultUsesMytAsset() public view {
        assertEq(address(ERC4626Strategy(strategy).mytAsset()), WETH, "unexpected MYT asset");
        assertEq(address(ERC4626Strategy(strategy).vault()), RE7_WETH_VAULT, "unexpected Re7 vault");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        ERC4626Strategy re7Strategy = ERC4626Strategy(strategy);
        assertFalse(re7Strategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        re7Strategy.setCanForceDeallocate(true);
        assertTrue(re7Strategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(WETH, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }
}
