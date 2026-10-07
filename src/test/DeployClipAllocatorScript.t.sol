// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {DeployClipAllocatorScript} from "../../script/DeployClipAllocator.s.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";

contract DeployClipAllocatorScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_454_018;

    uint256 internal constant ALLOCATE_AMOUNT = 100 ether;
    uint256 internal constant DEALLOCATE_AMOUNT = 80 ether;
    uint256 internal constant TOP_UP = 20 ether;

    function test_run_fork_deploysAndOwnerManagesGrants() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        DeployClipAllocatorScript deployScript = new DeployClipAllocatorScript();
        ClipAllocator clip = ClipAllocator(deployScript.run());

        assertEq(address(clip.allocator()), ETH_ALLOCATOR, "unexpected allocator");
        assertEq(address(clip.vault()), ETH_MYT, "unexpected vault");
        assertEq(address(clip.asset()), MAINNET_WETH, "unexpected asset");
        assertEq(clip.owner(), DEPLOYER, "deployer stays owner until accepted");
        assertEq(clip.pendingOwner(), NEW_OWNER, "handover not started");

        address adapter = IVaultV2(ETH_MYT).adapters(0);
        address bot = makeAddr("bot");

        _grantTopUpAndRevoke(clip, DEPLOYER, bot, adapter);

        vm.prank(NEW_OWNER);
        clip.acceptOwnership();
        assertEq(clip.owner(), NEW_OWNER, "owner after accept");
        assertEq(clip.pendingOwner(), address(0), "pending cleared");

        vm.expectRevert(ClipAllocator.NotOwner.selector);
        vm.prank(DEPLOYER);
        clip.grantAllocate(bot, adapter, 1, 1, 0, address(0), 0, 0);

        _grantTopUpAndRevoke(clip, NEW_OWNER, bot, adapter);
    }

    /// @dev Grant, top up, and revoke both sides, then confirm the bot still cannot grant.
    function _grantTopUpAndRevoke(ClipAllocator clip, address owner, address bot, address adapter) internal {
        vm.startPrank(owner);
        clip.grantAllocate(bot, adapter, ALLOCATE_AMOUNT, 10 ether, 0, address(0), 0, 50);
        clip.grantDeallocate(bot, adapter, DEALLOCATE_AMOUNT, 8 ether, 0, address(0), 0, 50);
        clip.topUpAllocate(bot, adapter, TOP_UP);
        clip.topUpDeallocate(bot, adapter, TOP_UP);
        vm.stopPrank();

        assertEq(clip.budget(bot), ALLOCATE_AMOUNT + DEALLOCATE_AMOUNT + 2 * TOP_UP, "budget");
        (uint256 allocateLeft, uint256 allocateClip,,,,,,) = clip.allocateGrants(bot, adapter);
        assertEq(allocateLeft, ALLOCATE_AMOUNT + TOP_UP, "allocate remaining");
        assertEq(allocateClip, 10 ether, "allocate maxClip");
        (uint256 deallocateLeft, uint256 deallocateClip,,,,,,) = clip.deallocateGrants(bot, adapter);
        assertEq(deallocateLeft, DEALLOCATE_AMOUNT + TOP_UP, "deallocate remaining");
        assertEq(deallocateClip, 8 ether, "deallocate maxClip");

        vm.startPrank(owner);
        clip.revokeAllocate(bot, adapter);
        clip.revokeDeallocate(bot, adapter);
        vm.stopPrank();

        assertEq(clip.budget(bot), 0, "budget after revoke");
        (allocateLeft, allocateClip,,,,,,) = clip.allocateGrants(bot, adapter);
        assertEq(allocateLeft, 0, "allocate remaining after revoke");
        assertEq(allocateClip, 10 ether, "revoke keeps maxClip");
        (deallocateLeft,,,,,,,) = clip.deallocateGrants(bot, adapter);
        assertEq(deallocateLeft, 0, "deallocate remaining after revoke");

        vm.expectRevert(ClipAllocator.NotOwner.selector);
        vm.prank(bot);
        clip.grantAllocate(bot, adapter, 1, 1, 0, address(0), 0, 0);
    }
}
