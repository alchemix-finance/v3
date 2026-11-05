// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployYieldBouncerScript} from "../../../script/DeployYieldBouncer.s.sol";
import {YieldBouncer} from "../../utils/YieldBouncer.sol";
import {IRateSource} from "../../utils/rates/IRateSource.sol";

interface IAllocatorOps {
    function vault() external view returns (address);
    function setOperator(address operator, bool value) external;
    function operators(address operator) external view returns (bool);
}

/// @notice The script on a Base fork: deploy, handover, then the admin's batch
///         (operator, accept, rate sources, first grant) and one move.
contract DeployYieldBouncerScriptTest is Test {
    address internal constant BASE_ALLOCATOR = 0x347371c17D14Ee7943943995E2A0A9Df4FD83d50;
    address internal constant BASE_MYT = 0xb8BeFE5a6941ca4022a52042075ff269C3C67467;
    address internal constant STEAKHOUSE_STRATEGY = 0xaeEA02683f652dd1fb4846bE71FB8Cf26f3393d4;
    address internal constant FLUID_STRATEGY = 0x4e7Fb7BAD62D105eE2c4856d45f8FbfaDEEFa896;
    address internal constant STEAKHOUSE_VAULT = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address internal constant FUSDC = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;

    function test_run_baseFork_deployHandoverAndFirstGrant() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")));
        address deployer = makeAddr("deployer");
        vm.deal(deployer, 1 ether);
        vm.setEnv("YB_ALLOCATOR", vm.toString(BASE_ALLOCATOR));
        vm.setEnv("YB_SOURCES", "morpho,fluid");
        vm.setEnv("YB_DEPLOYER", vm.toString(deployer));

        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        address admin = script.allocatorAdmin(BASE_ALLOCATOR);
        DeployYieldBouncerScript.Deployed memory d = script.runUSD();
        YieldBouncer bouncer = YieldBouncer(d.bouncer);

        assertEq(address(bouncer.allocator()), BASE_ALLOCATOR);
        assertEq(address(bouncer.vault()), BASE_MYT);
        assertEq(bouncer.owner(), deployer, "deployer stays owner until accepted");
        assertEq(bouncer.pendingOwner(), admin, "handover to the allocator admin");
        assertTrue(d.morpho != address(0) && d.fluid != address(0));
        assertEq(d.aave, address(0));
        assertEq(bouncer.LIQ_ADAPTER_MAX(), 200_000e6, "USDC ceiling");

        // the admin's batch
        vm.startPrank(admin);
        IAllocatorOps(BASE_ALLOCATOR).setOperator(d.bouncer, true);
        bouncer.acceptOwnership();
        bouncer.setRateSource(STEAKHOUSE_STRATEGY, d.morpho, STEAKHOUSE_VAULT);
        bouncer.setRateSource(FLUID_STRATEGY, d.fluid, FUSDC);
        address bot = makeAddr("bot");
        bouncer.grantPair(bot, STEAKHOUSE_STRATEGY, FLUID_STRATEGY, YieldBouncer.Limits({
            maxNetToB: 100_000e6,
            maxNetToA: 0,
            maxClip: 25_000e6,
            minIntervalBlocks: 150,
            maxLossBps: 2,
            minSpreadBps: 5,
            expiresAtBlock: 0
        }));
        vm.stopPrank();

        assertEq(bouncer.owner(), admin);
        assertTrue(IAllocatorOps(BASE_ALLOCATOR).operators(d.bouncer));
        vm.prank(deployer);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.recenter(bot, STEAKHOUSE_STRATEGY, FLUID_STRATEGY);
        assertEq(bouncer.room(bot, STEAKHOUSE_STRATEGY, FLUID_STRATEGY), 100_000e6);
        assertGt(bouncer.rateOf(STEAKHOUSE_STRATEGY), 0);
        assertGt(bouncer.rateOf(FLUID_STRATEGY), 0);
    }

    function test_unknownSourceReverts() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        string[] memory sources = new string[](1);
        sources[0] = "compound";
        address allocator = address(new FakeAllocator());
        vm.expectRevert(bytes("unknown rate source: compound"));
        script.deployUSD(allocator, address(1), sources);
    }

    function test_entryPointPicksTheContract() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        address allocator = address(new FakeAllocator());
        YieldBouncer usd = YieldBouncer(script.deployUSD(allocator, address(1), new string[](0)).bouncer);
        YieldBouncer eth = YieldBouncer(script.deployETH(allocator, address(1), new string[](0)).bouncer);
        assertEq(usd.LIQ_ADAPTER_MAX(), 200_000e6);
        assertEq(eth.LIQ_ADAPTER_MAX(), 50e6);              // the fake asset has 6 decimals
    }
}

/// @dev Stands in for the allocator, its vault and the vault's asset.
contract FakeAllocator {
    function vault() external view returns (address) {
        return address(this);
    }

    function asset() external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}
