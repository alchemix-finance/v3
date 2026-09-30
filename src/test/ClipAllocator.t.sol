// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";

/// @dev Position whose `realAssets()` jumps to a scripted value when the stub
///      allocator touches it. Lets a test choose the value delta independently
///      of the assets the clip claims to move.
contract LossyStrategy {
    bytes32 public adapterId = keccak256("lossy");
    uint256 public realAssets;
    uint256 public nextRealAssets;

    function setRealAssets(uint256 current, uint256 next) external {
        realAssets = current;
        nextRealAssets = next;
    }

    function applyMove() external {
        realAssets = nextRealAssets;
    }
}

contract StubVault {
    address public asset;
    address public adapter;
    address public liquidityAdapter;

    constructor(address _asset, address _adapter) {
        asset = _asset;
        adapter = _adapter;
    }

    function isAdapter(address account) external view returns (bool) {
        return account == adapter;
    }

    function allocation(bytes32) external pure returns (uint256) {
        return 0;
    }
}

/// @dev `balanceOf` reports the vault as fully idle so an allocate clip never
///      tries to raise from the liquidity adapter.
contract StubAsset {
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract StubAllocator {
    address public vault;
    LossyStrategy public strategy;

    constructor(address _vault, LossyStrategy _strategy) {
        vault = _vault;
        strategy = _strategy;
    }

    function deallocate(address, uint256) external {
        strategy.applyMove();
    }

    function allocate(address, uint256) external {
        strategy.applyMove();
    }
}

/// @notice maxLossBps bounds how far realAssets may diverge from the clip size.
///         100 bps: a deallocate of 100 ether may shrink the position by at most
///         101 ether, and an allocate must grow it by at least 99 ether.
contract ClipAllocatorLossBoundTest is Test {
    uint256 internal constant CLIP = 100 ether;
    uint16 internal constant MAX_LOSS_BPS = 100;
    uint256 internal constant MAX_DROP = 101 ether; // CLIP * 10100 / 10000
    uint256 internal constant MIN_GAIN = 99 ether; // CLIP * 9900 / 10000

    ClipAllocator internal clip;
    LossyStrategy internal strategy;
    address internal bot = makeAddr("bot");

    function setUp() public {
        strategy = new LossyStrategy();
        StubAsset asset = new StubAsset();
        StubVault vault = new StubVault(address(asset), address(strategy));
        StubAllocator allocator = new StubAllocator(address(vault), strategy);
        clip = new ClipAllocator(address(allocator));
    }

    /// @dev Dropping the position by 900 ether to return 100 is past a 1% grant.
    function test_deallocate_revertsWhenRealAssetsLossExceedsGrant() public {
        strategy.setRealAssets(1_000 ether, 100 ether);
        clip.grantDeallocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, 900 ether, MAX_DROP, false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_deallocate_acceptsRealAssetsLossAtLimit() public {
        strategy.setRealAssets(1_000 ether, 1_000 ether - MAX_DROP);
        clip.grantDeallocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        assertEq(strategy.realAssets(), 1_000 ether - MAX_DROP);
    }

    function test_deallocate_revertsOneWeiPastLossLimit() public {
        strategy.setRealAssets(1_000 ether, 1_000 ether - MAX_DROP - 1);
        clip.grantDeallocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, MAX_DROP + 1, MAX_DROP, false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    /// @dev A position that does not shrink fails the sign check before the loss bound.
    function test_deallocate_revertsWhenRealAssetsDoesNotShrink() public {
        strategy.setRealAssets(1_000 ether, 1_000 ether);
        clip.grantDeallocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RealAssetsDidNotMove.selector, CLIP, int256(0)));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_allocate_revertsWhenRealAssetsShortfallExceedsGrant() public {
        strategy.setRealAssets(0, 1);
        clip.grantAllocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, 1, MIN_GAIN, true));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_allocate_acceptsRealAssetsShortfallAtLimit() public {
        strategy.setRealAssets(0, MIN_GAIN);
        clip.grantAllocate(bot, address(strategy), 1_000 ether, CLIP, 0, address(0), 0, MAX_LOSS_BPS);

        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);

        assertEq(strategy.realAssets(), MIN_GAIN);
    }

    /// @dev The bound is assets × (10_000 ± maxLossBps) / 10_000. A clip at that
    ///      product passes; one wei past it reverts. Division can round the
    ///      allocate minimum down to 0 or 1, and a flat position then fails the
    ///      sign check before the loss bound.
    function testFuzz_lossBound(uint256 assets, uint256 lossBps) public {
        assets = bound(assets, 1, 1_000 ether);
        lossBps = bound(lossBps, 0, 10_000);
        uint256 maxDrop = assets * (10_000 + lossBps) / 10_000;
        uint256 minGain = assets * (10_000 - lossBps) / 10_000;

        clip.grantDeallocate(bot, address(strategy), assets, assets, 0, address(0), 0, uint16(lossBps));
        strategy.setRealAssets(maxDrop + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, maxDrop + 1, maxDrop, false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), assets);

        strategy.setRealAssets(maxDrop, 0);
        vm.prank(bot);
        clip.deallocateClip(address(strategy), assets);
        assertEq(strategy.realAssets(), 0);

        clip.grantAllocate(bot, address(strategy), assets, assets, 0, address(0), 0, uint16(lossBps));
        // A gain of 0 fails the sign check before the loss bound, so the one-wei
        // shortfall is only a loss revert once the minimum itself is at least 2.
        if (minGain < 2) {
            strategy.setRealAssets(0, 0);
            vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RealAssetsDidNotMove.selector, assets, int256(0)));
        } else {
            strategy.setRealAssets(0, minGain - 1);
            vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, minGain - 1, minGain, true));
        }
        vm.prank(bot);
        clip.allocateClip(address(strategy), assets);

        uint256 acceptedGain = minGain == 0 ? 1 : minGain;
        strategy.setRealAssets(0, acceptedGain);
        vm.prank(bot);
        clip.allocateClip(address(strategy), assets);
        assertEq(strategy.realAssets(), acceptedGain);
    }
}

/// @dev Balance the test can set per holder. Used both as the vault asset (idle)
///      and as a strategy's price token.
contract ScriptedToken {
    mapping(address => uint256) public balanceOf;

    function set(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}

contract GuardStrategy {
    bytes32 public adapterId;
    uint256 public realAssets;
    uint256 public nextRealAssets;
    ScriptedToken public priceToken;
    uint256 public nextPriceBalance;

    constructor(bytes32 id) {
        adapterId = id;
    }

    function setPriceToken(ScriptedToken token) external {
        priceToken = token;
    }

    /// @dev The next allocator touch jumps realAssets and, when a price token is
    ///      attached, that token's balance at this strategy.
    function setMove(uint256 currentReal, uint256 nextReal, uint256 currentPrice, uint256 nextPrice) external {
        realAssets = currentReal;
        nextRealAssets = nextReal;
        nextPriceBalance = nextPrice;
        if (address(priceToken) != address(0)) priceToken.set(address(this), currentPrice);
    }

    function applyMove() external {
        realAssets = nextRealAssets;
        if (address(priceToken) != address(0)) priceToken.set(address(this), nextPriceBalance);
    }
}

contract GuardVault {
    address public asset;
    mapping(address => bool) public isAdapter;
    address public liquidityAdapter;

    constructor(address _asset, address _adapter) {
        asset = _asset;
        isAdapter[_adapter] = true;
    }

    function addAdapter(address account) external {
        isAdapter[account] = true;
    }

    function setLiquidityAdapter(address account) external {
        liquidityAdapter = account;
    }

    function allocation(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract GuardAllocator {
    address public vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function deallocate(address adapter, uint256) external {
        GuardStrategy(adapter).applyMove();
    }

    function allocate(address adapter, uint256) external {
        GuardStrategy(adapter).applyMove();
    }
}

/// @notice Budget, authority, price, and idle guard rails. The loss-bound tests
///         above cover the missing magnitude check; these cover the checks that do revert.
contract ClipAllocatorGuardsTest is Test {
    uint256 internal constant CLIP = 100 ether;

    ClipAllocator internal clip;
    GuardStrategy internal strategy;
    GuardStrategy internal liquidity;
    GuardVault internal vault;
    ScriptedToken internal asset;
    ScriptedToken internal priceToken;
    address internal bot = makeAddr("bot");

    function setUp() public {
        strategy = new GuardStrategy(keccak256("target"));
        liquidity = new GuardStrategy(keccak256("liquidity"));
        asset = new ScriptedToken();
        priceToken = new ScriptedToken();
        strategy.setPriceToken(priceToken);
        vault = new GuardVault(address(asset), address(strategy));
        vault.addAdapter(address(liquidity));
        asset.set(address(vault), type(uint256).max);
        clip = new ClipAllocator(address(new GuardAllocator(address(vault))));
    }

    function test_deallocate_revertsOnZeroAmount() public {
        vm.expectRevert(ClipAllocator.ZeroAmount.selector);
        vm.prank(bot);
        clip.deallocateClip(address(strategy), 0);
    }

    function test_deallocate_revertsWithoutGrant() public {
        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.NoGrant.selector, bot, address(strategy), false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_deallocate_revertsWhenGrantExhaustedAndDoesNotConsume() public {
        clip.grantDeallocate(bot, address(strategy), 50 ether, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.GrantExhausted.selector, 50 ether, CLIP));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        (uint256 remaining,,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remaining, 50 ether);
    }

    function test_deallocate_revertsWhenClipExceedsMax() public {
        clip.grantDeallocate(bot, address(strategy), 1_000 ether, 10 ether, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.ClipTooLarge.selector, 10 ether, CLIP));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_deallocate_enforcesMinInterval() public {
        clip.grantDeallocate(bot, address(strategy), 2 * CLIP, CLIP, 5, address(0), 0, 0);
        strategy.setMove(1_000 ether, 900 ether, 0, 0);

        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        strategy.setMove(900 ether, 800 ether, 0, 0);
        uint64 readyAt = uint64(block.number) + 5;
        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.TooSoon.selector, readyAt));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        (uint256 remainingAfterRevert,,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remainingAfterRevert, CLIP);

        vm.roll(readyAt);
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        (uint256 remaining,,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remaining, 0);
    }

    /// @dev Revoke zeroes the budget and leaves maxClip, so the next clip is exhausted
    ///      rather than missing a grant.
    function test_revoke_zeroesRemainingButKeepsMaxClip() public {
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.revokeDeallocate(bot, address(strategy));

        (uint256 remaining, uint256 maxClip,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remaining, 0);
        assertEq(maxClip, CLIP);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.GrantExhausted.selector, 0, CLIP));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_allocateGrant_doesNotAuthorizeDeallocate() public {
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.NoGrant.selector, bot, address(strategy), false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_grant_revertsForNonOwner() public {
        vm.expectRevert(ClipAllocator.NotOwner.selector);
        vm.prank(bot);
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
    }

    function test_grant_revertsForUnknownAdapter() public {
        address unknown = makeAddr("not-adapter");

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.NotAdapter.selector, unknown));
        clip.grantDeallocate(bot, unknown, CLIP, CLIP, 0, address(0), 0, 0);
    }

    function test_pause_blocksClipsUntilOwnerUnpauses() public {
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        strategy.setMove(1_000 ether, 900 ether, 0, 0);

        vm.prank(bot);
        clip.setPaused(true);

        vm.expectRevert(ClipAllocator.MoverPaused.selector);
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);

        (uint256 remaining,,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remaining, CLIP);

        address stranger = makeAddr("stranger");
        vm.expectRevert(ClipAllocator.NotBotOrOwner.selector);
        vm.prank(stranger);
        clip.setPaused(true);

        vm.expectRevert(ClipAllocator.NotBotOrOwner.selector);
        vm.prank(bot);
        clip.setPaused(false);

        clip.setPaused(false);
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
        assertEq(strategy.realAssets(), 900 ether);
    }

    /// @dev 100 ether comes back for 200 ether of the position token. rate = 0.5e18,
    ///      under a 1e18 floor.
    function test_deallocate_revertsWhenRateBelowFloor() public {
        strategy.setMove(1_000 ether, 900 ether, 200 ether, 0);
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 1e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RateOutsideLimit.selector, 0.5e18, 1e18, false));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_deallocate_acceptsRateAtFloor() public {
        strategy.setMove(1_000 ether, 900 ether, 100 ether, 0);
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 1e18, 0);

        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
        assertEq(strategy.realAssets(), 900 ether);
    }

    /// @dev Paying 100 ether gains 50 ether of the position token. rate = 2e18,
    ///      over a 1e18 ceiling.
    function test_allocate_revertsWhenRateAboveCeiling() public {
        strategy.setMove(0, CLIP, 0, 50 ether);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 1e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RateOutsideLimit.selector, 2e18, 1e18, true));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_allocate_acceptsRateAtCeiling() public {
        strategy.setMove(0, CLIP, 0, CLIP);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 1e18, 0);

        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
        assertEq(strategy.realAssets(), CLIP);
    }

    function test_guardedDeallocate_revertsWhenPriceTokenDoesNotMove() public {
        strategy.setMove(1_000 ether, 900 ether, 100 ether, 100 ether);
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 1e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.PositionDidNotMove.selector, address(priceToken), int256(0)));
        vm.prank(bot);
        clip.deallocateClip(address(strategy), CLIP);
    }

    function test_allocate_revertsWhenIdleShortAndNoLiquidityAdapter() public {
        asset.set(address(vault), 40 ether);
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.IdleUnavailable.selector, CLIP, 40 ether, address(0)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_allocate_revertsWhenLiquidityAdapterIsTheTarget() public {
        asset.set(address(vault), 40 ether);
        vault.setLiquidityAdapter(address(strategy));
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.IdleUnavailable.selector, CLIP, 40 ether, address(strategy)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_allocate_revertsWhenLiquidityGrantIsMissing() public {
        asset.set(address(vault), 40 ether);
        vault.setLiquidityAdapter(address(liquidity));
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.IdleUnavailable.selector, CLIP, 40 ether, address(liquidity)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    /// @dev The raise pulls exactly the shortfall and charges the liquidity grant for it.
    function test_allocate_raisesShortfallAndConsumesLiquidityGrant() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setMove(shortfall, 0, 0, 0);
        strategy.setMove(0, CLIP, 0, 0);

        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(0), 0, 0);

        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);

        assertEq(strategy.realAssets(), CLIP);
        assertEq(liquidity.realAssets(), 0);
        (uint256 liquidityLeft,,,,,,) = clip.deallocateGrants(bot, address(liquidity));
        assertEq(liquidityLeft, 0);
        (uint256 allocateLeft,,,,,,) = clip.allocateGrants(bot, address(strategy));
        assertEq(allocateLeft, 0);
    }

    /// @dev For any clip the vault cannot fully fund: a shortfall above maxClip reverts, and a
    ///      liquidity-position drop past maxLossBps reverts without spending the grant.
    function testFuzz_raise_enforcesLiquidityMaxClipAndMaxLoss(
        uint256 clipAmount,
        uint256 idle,
        uint256 maxClip,
        uint256 lossBps,
        uint256 extraDrop
    ) public {
        clipAmount = bound(clipAmount, 2, 1_000 ether);
        idle = bound(idle, 0, clipAmount - 2);
        uint256 shortfall = clipAmount - idle;
        maxClip = bound(maxClip, 1, shortfall - 1);
        lossBps = bound(lossBps, 0, 10_000);
        uint256 maxDrop = shortfall * (10_000 + lossBps) / 10_000;
        extraDrop = bound(extraDrop, 1, 1_000 ether);
        uint256 drop = maxDrop + extraDrop;

        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setMove(drop, 0, 0, 0);
        strategy.setMove(0, clipAmount, 0, 0);
        clip.grantAllocate(bot, address(strategy), clipAmount, clipAmount, 0, address(0), 0, 0);

        clip.grantDeallocate(bot, address(liquidity), shortfall, maxClip, 0, address(0), 0, uint16(lossBps));
        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.ClipTooLarge.selector, maxClip, shortfall));
        vm.prank(bot);
        clip.allocateClip(address(strategy), clipAmount);

        clip.revokeDeallocate(bot, address(liquidity));
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(0), 0, uint16(lossBps));
        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.LossExceedsLimit.selector, drop, maxDrop, false));
        vm.prank(bot);
        clip.allocateClip(address(strategy), clipAmount);

        assertEq(liquidity.realAssets(), drop);
        (uint256 liquidityLeft,,,,,,) = clip.deallocateGrants(bot, address(liquidity));
        assertEq(liquidityLeft, shortfall);
    }

    /// @dev A raise is part of the allocate clip, so the liquidity grant's spacing
    ///      does not apply and the raise does not move lastClipBlock.
    function test_raise_ignoresMinIntervalAndDoesNotStampLastClip() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        clip.grantDeallocate(bot, address(liquidity), 2 * CLIP + shortfall, CLIP, 5, address(0), 0, 0);
        liquidity.setMove(1_000 ether, 1_000 ether - CLIP, 0, 0);

        vm.prank(bot);
        clip.deallocateClip(address(liquidity), CLIP);
        uint64 stamped = uint64(block.number);

        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setMove(1_000 ether - CLIP, 1_000 ether - CLIP - shortfall, 0, 0);
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.roll(block.number + 1);
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);

        assertEq(strategy.realAssets(), CLIP);
        (,,, uint64 lastClipBlock,,,) = clip.deallocateGrants(bot, address(liquidity));
        assertEq(lastClipBlock, stamped);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.TooSoon.selector, stamped + 5));
        vm.prank(bot);
        clip.deallocateClip(address(liquidity), CLIP);
    }

    /// @dev 60 ether of idle is raised for 120 ether of the position token.
    ///      rate = 0.5e18, under a 1e18 floor.
    function test_raise_revertsWhenRateBelowFloor() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setPriceToken(priceToken);
        liquidity.setMove(1_000 ether, 1_000 ether - shortfall, 120 ether, 0);
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(priceToken), 1e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RateOutsideLimit.selector, 0.5e18, 1e18, false));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_raise_revertsWhenPriceTokenDoesNotMove() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setPriceToken(priceToken);
        liquidity.setMove(1_000 ether, 1_000 ether - shortfall, 100 ether, 100 ether);
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(priceToken), 1e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.PositionDidNotMove.selector, address(priceToken), int256(0)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_raise_revertsWhenRealAssetsDoNotShrink() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        liquidity.setMove(1_000 ether, 1_000 ether, 0, 0);
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.RealAssetsDidNotMove.selector, shortfall, int256(0)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_raise_revertsWhenShortfallExceedsRemaining() public {
        uint256 idle = 40 ether;
        uint256 shortfall = CLIP - idle;
        asset.set(address(vault), idle);
        vault.setLiquidityAdapter(address(liquidity));
        strategy.setMove(0, CLIP, 0, 0);
        clip.grantAllocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
        clip.grantDeallocate(bot, address(liquidity), shortfall - 1, shortfall, 0, address(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClipAllocator.IdleUnavailable.selector, CLIP, idle, address(liquidity)));
        vm.prank(bot);
        clip.allocateClip(address(strategy), CLIP);
    }

    function test_grant_revertsOnBadParameters() public {
        vm.expectRevert(bytes("grant"));
        clip.grantDeallocate(address(0), address(strategy), CLIP, CLIP, 0, address(0), 0, 0);

        vm.expectRevert(bytes("grant"));
        clip.grantDeallocate(bot, address(strategy), CLIP, 0, 0, address(0), 0, 0);

        vm.expectRevert(bytes("rate"));
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(priceToken), 0, 0);

        vm.expectRevert(bytes("loss"));
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 10_001);
    }

    /// @dev A second grant adds budget and overwrites the limits, including a tighter cap.
    function test_grant_topUpAddsRemainingAndReplacesLimits() public {
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 5, address(0), 0, 100);
        clip.grantDeallocate(bot, address(strategy), CLIP, 1 ether, 0, address(priceToken), 1e18, 0);

        (
            uint256 remaining,
            uint256 maxClip,
            uint32 interval,
            ,
            address price,
            uint256 limitRate,
            uint16 maxLossBps
        ) = clip.deallocateGrants(bot, address(strategy));
        assertEq(remaining, 2 * CLIP);
        assertEq(maxClip, 1 ether);
        assertEq(interval, 0);
        assertEq(price, address(priceToken));
        assertEq(limitRate, 1e18);
        assertEq(maxLossBps, 0);
    }

    function test_ownership_twoStepAndRejectsWrongAcceptor() public {
        address safe = makeAddr("safe");

        vm.expectRevert(ClipAllocator.NotOwner.selector);
        vm.prank(bot);
        clip.transferOwnership(safe);

        clip.transferOwnership(safe);
        assertEq(clip.pendingOwner(), safe);
        assertEq(clip.owner(), address(this));

        vm.expectRevert(ClipAllocator.NotOwner.selector);
        vm.prank(bot);
        clip.acceptOwnership();

        vm.prank(safe);
        clip.acceptOwnership();
        assertEq(clip.owner(), safe);
        assertEq(clip.pendingOwner(), address(0));

        vm.expectRevert(ClipAllocator.NotOwner.selector);
        clip.grantDeallocate(bot, address(strategy), CLIP, CLIP, 0, address(0), 0, 0);
    }
}
