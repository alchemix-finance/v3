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
    function test_runBase_deployHandoverAndFirstGrant() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")));

        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        address deployer = script.deployerAddr();
        vm.deal(deployer, 1 ether);
        address admin = script.allocatorAdmin(script.BASE_ALLOCATOR());
        DeployYieldBouncerScript.Deployed memory deployed = script.runBase();
        YieldBouncer bouncer = YieldBouncer(deployed.usdBouncer);

        assertEq(address(bouncer.allocator()), script.BASE_ALLOCATOR());
        assertEq(address(bouncer.vault()), script.BASE_MYT());
        assertEq(bouncer.owner(), deployer, "deployer stays owner until accepted");
        assertEq(bouncer.pendingOwner(), admin, "handover to the allocator admin");
        assertEq(deployed.ethBouncer, address(0), "Base has no ETH MYT");
        assertTrue(deployed.sources.morpho != address(0) && deployed.sources.fluid != address(0));
        assertEq(deployed.sources.aave, address(0));
        assertEq(bouncer.LIQ_ADAPTER_MAX(), 200_000e6, "USDC ceiling");
        (bool liquidityMovable,) = bouncer.sourceGuard();
        assertTrue(liquidityMovable, "Base draws from the liquidity adapter");

        // the deploy registered every feed, set both references and granted the bot
        address steak = script.STEAKHOUSE_STRATEGY();
        address fluid = script.FLUID_STRATEGY();
        address bot = script.BASE_BOT_USD();
        assertEq(bouncer.fedStrategies().length, 2);
        (address steakSource, address steakVenue) = bouncer.rateFeeds(steak);
        assertEq(steakSource, deployed.sources.morpho);
        assertEq(steakVenue, script.STEAKHOUSE_VAULT());
        assertGt(bouncer.rateOf(steak), 0);
        assertGt(bouncer.rateOf(fluid), 0);
        assertEq(bouncer.activePairs(bot), 1);
        assertEq(bouncer.room(bot, steak, fluid), 100_000e6);
        assertEq(bouncer.room(bot, fluid, steak), 0, "nothing moves back toward Steakhouse");

        // the admin only makes it an operator and accepts
        vm.startPrank(admin);
        IAllocatorOps(script.BASE_ALLOCATOR()).setOperator(deployed.usdBouncer, true);
        bouncer.acceptOwnership();
        vm.stopPrank();

        assertEq(bouncer.owner(), admin);
        assertTrue(IAllocatorOps(script.BASE_ALLOCATOR()).operators(deployed.usdBouncer));
        vm.prank(deployer);
        vm.expectRevert(YieldBouncer.NotOwner.selector);
        bouncer.recenter(bot, steak, fluid);
    }

    /// The hardcoded mainnet allocators and admin match the live chain, each bouncer lands on
    /// the MYT of its denomination, and the Yearn source both MYTs use deploys once.
    function test_runMainnet_bothBouncersShareSources() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        vm.deal(script.deployerAddr(), 1 ether);
        assertEq(script.allocatorAdmin(script.MAINNET_USD_ALLOCATOR()), script.MAINNET_ADMIN(), "alUSD admin");
        assertEq(script.allocatorAdmin(script.MAINNET_ETH_ALLOCATOR()), script.MAINNET_ADMIN(), "alETH admin");

        uint64 nonceBefore = vm.getNonce(script.deployerAddr());
        DeployYieldBouncerScript.Deployed memory deployed = script.runMainnet();
        YieldBouncer usd = YieldBouncer(deployed.usdBouncer);
        YieldBouncer eth = YieldBouncer(deployed.ethBouncer);
        assertEq(address(usd.allocator()), script.MAINNET_USD_ALLOCATOR());
        assertEq(address(eth.allocator()), script.MAINNET_ETH_ALLOCATOR());
        assertEq(usd.pendingOwner(), script.MAINNET_ADMIN());
        assertEq(eth.pendingOwner(), script.MAINNET_ADMIN());
        assertEq(usd.LIQ_ADAPTER_MAX(), 200_000e6, "USDC ceiling");
        assertEq(eth.LIQ_ADAPTER_MAX(), 50e18, "WETH ceiling");

        DeployYieldBouncerScript.RateSources memory sources = deployed.sources;
        assertTrue(sources.yearn != address(0) && sources.fluidlite != address(0) && sources.aave != address(0));
        assertEq(sources.morpho, address(0));
        assertEq(usd.fedStrategies().length, 2);
        assertEq(eth.fedStrategies().length, 2);
        (address aaveSource,) = eth.rateFeeds(script.AAVE_STRATEGY());
        assertEq(aaveSource, sources.aave);
        (bool liquidityMovable,) = usd.sourceGuard();
        assertFalse(liquidityMovable, "mainnet draws from the liquidity adapter stay off");
        assertEq(usd.activePairs(script.MAINNET_BOT_USD()), 1);
        assertEq(eth.activePairs(script.MAINNET_BOT_ETH()), 1);
        assertEq(usd.room(script.MAINNET_BOT_USD(), script.YVUSD_STRATEGY(), script.FLUID_LITE_STRATEGY()), 100_000e6);
        assertEq(eth.room(script.MAINNET_BOT_ETH(), script.AAVE_STRATEGY(), script.YEARN_STRATEGY()), 25 ether);
        (uint256 refRate, uint16 band,,) = usd.rateRefs(script.YVUSD_STRATEGY());
        assertEq(refRate, usd.rateOf(script.YVUSD_STRATEGY()));
        assertEq(band, script.RATE_BAND_BPS());
        // two bouncers, two handovers, three sources, four feed registrations,
        // four rate references, two grants
        assertEq(vm.getNonce(script.deployerAddr()) - nonceBefore, 17);
    }

    function test_deployRateSources_unknownReverts() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        string[] memory names = new string[](1);
        names[0] = "compound";
        vm.expectRevert(bytes("unknown rate source: compound"));
        script.deployRateSources(names);
    }

    function test_deployRateSources_deploysEachOnce() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        string[] memory names = new string[](3);
        (names[0], names[1], names[2]) = ("yearn", "aave", "yearn");
        uint64 nonceBefore = vm.getNonce(address(script));
        DeployYieldBouncerScript.RateSources memory sources = script.deployRateSources(names);
        assertTrue(sources.yearn != address(0) && sources.aave != address(0));
        assertEq(vm.getNonce(address(script)) - nonceBefore, 2);
    }

    function test_feedsPerChain() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        DeployYieldBouncerScript.Feed[] memory feeds = script.getBaseFeeds("usd");
        assertEq(feeds.length, 2);
        assertEq(feeds[0].strategy, script.STEAKHOUSE_STRATEGY());
        assertEq(feeds[0].source, "morpho");
        assertEq(feeds[0].venue, script.STEAKHOUSE_VAULT());
        assertEq(feeds[1].source, "fluid");
        assertEq(script.getBaseFeeds("eth").length, 0, "Base has no ETH MYT");
        feeds = script.getMainnetFeeds("usd");
        assertEq(feeds[0].strategy, script.YVUSD_STRATEGY());
        assertEq(feeds[0].source, "yearn");
        assertEq(feeds[1].source, "fluidlite");
        feeds = script.getMainnetFeeds("eth");
        assertEq(feeds[0].strategy, script.AAVE_STRATEGY());
        assertEq(feeds[0].source, "aave");
        assertEq(feeds[1].source, "yearn");
    }

    function test_runOnTheWrongChainReverts() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain 1"));
        script.runBase();
        vm.chainId(8453);
        vm.expectRevert(bytes("wrong chain 8453"));
        script.runMainnet();
    }

    function test_deployPicksTheContract() public {
        DeployYieldBouncerScript script = new DeployYieldBouncerScript();
        address allocator = address(new FakeAllocator());
        YieldBouncer usd = script.deployUSD(allocator, true);
        YieldBouncer eth = script.deployETH(allocator);
        assertEq(usd.LIQ_ADAPTER_MAX(), 200_000e6);
        assertEq(eth.LIQ_ADAPTER_MAX(), 50e6);              // the fake asset has 6 decimals
        assertEq(usd.owner(), address(script), "the deployer keeps it until the run transfers");
        (bool liquidityMovable,) = usd.sourceGuard();
        assertTrue(liquidityMovable);
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
