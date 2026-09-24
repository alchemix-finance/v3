// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV3BaseAlUSDbScript} from "../../script/DeployV3BaseAlUSDb.s.sol";
import {DeployV3BaseScript} from "../../script/DeployV3Base.s.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "../AlTokenV3.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DeployV3BaseScriptTest is Test {
    address internal deployer = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal multisig = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    DeployV3BaseAlUSDbScript internal script1;
    DeployV3BaseScript internal script2;

    function setUp() public {
        script1 = new DeployV3BaseAlUSDbScript();
        script2 = new DeployV3BaseScript();

        ERC20Mock usdcMock = new ERC20Mock("USD Coin", "USDC");
        vm.etch(USDC_BASE, address(usdcMock).code);

        vm.deal(deployer, 100 ether);
    }

    function test_grantBackFlow() public {
        script1.run();

        CrossChainCanonicalAlchemicTokenV3 token = CrossChainCanonicalAlchemicTokenV3(script1.alUSDb());
        assertFalse(token.hasRole(token.ADMIN_ROLE(), deployer), "deployer should have renounced ADMIN_ROLE");
        assertFalse(token.hasRole(token.SENTINEL_ROLE(), deployer), "deployer should have renounced SENTINEL_ROLE");
        assertTrue(token.hasRole(token.ADMIN_ROLE(), multisig), "multisig should hold ADMIN_ROLE");
        assertTrue(token.hasRole(token.SENTINEL_ROLE(), multisig), "multisig should hold SENTINEL_ROLE");

        vm.startPrank(multisig);
        token.grantRole(token.ADMIN_ROLE(), deployer);
        vm.stopPrank();
        assertTrue(token.hasRole(token.ADMIN_ROLE(), deployer), "multisig should have granted ADMIN_ROLE back");

        vm.setEnv("ALUSDB_ADDRESS", vm.toString(script1.alUSDb()));
        script2.run();

        assertTrue(script2.usdcAlchemist().pendingAdmin() == multisig, "unexpected pending admin");
        assertTrue(script2.usdcTransmuter().pendingAdmin() == multisig, "unexpected transmuter pending admin");
        assertTrue(
            token.whitelisted(address(script2.usdcAlchemist())), "alchemist should be whitelisted for minting"
        );
        assertFalse(token.hasRole(token.ADMIN_ROLE(), deployer), "deployer should have renounced ADMIN_ROLE again");
    }

    function test_revertsWithoutGrantBack() public {
        script1.run();

        vm.setEnv("ALUSDB_ADDRESS", vm.toString(script1.alUSDb()));
        vm.expectRevert();
        script2.run();
    }
}
