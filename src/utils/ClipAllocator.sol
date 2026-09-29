// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal views of the live contracts the mover touches. Inline so the file
/// compiles on its own (no v3 remappings needed).
interface IAlchemistAllocatorFull {
    function vault() external view returns (address);
    function allocate(address adapter, uint256 amount) external;
    function deallocate(address adapter, uint256 amount) external;
    function allocateWithSwap(address adapter, uint256 amount, bytes memory txData) external;
    function deallocateWithSwap(address adapter, uint256 amount, bytes memory txData) external;
    function deallocateWithUnwrapAndSwap(address adapter, uint256 amount, bytes memory txData, uint256 minIntermediateOut) external;
    function operators(address) external view returns (bool);
}

interface IVaultV2Lite {
    function asset() external view returns (address);
    function isAdapter(address account) external view returns (bool);
    function allocation(bytes32 id) external view returns (uint256);
    function liquidityAdapter() external view returns (address);
}

interface IMYTStrategyLite {
    function adapterId() external view returns (bytes32);
    function realAssets() external view returns (uint256);
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title ClipAllocator
 * @notice A budgeted allocator operator. Registered as an operator of the
 *         live AlchemistAllocator (one Safe call: `setOperator(mover, true)`),
 *         it lets whitelisted bots move capital between strategies in clips,
 *         each clip drawn from a grant the owner (the allocator admin Safe)
 *         handed out:
 *
 *           grantDeallocate(bot, strategyA, X)   bot may pull up to X units out of A
 *           grantAllocate(bot, strategyB, Y)     bot may push up to Y units into B
 *
 *         Counters are independent: X may equal Y for a one-to-one move, or one
 *         deallocate grant may feed several allocate grants. Every clip consumes
 *         its `assets` from the matching counter; at zero the bot stops and the
 *         owner extends with another grant (amounts add). Nothing on-chain links
 *         the two sides, so a deallocate bot and an allocate bot run at their own
 *         pace, and user withdrawals in between never touch a counter.
 *
 *         Per grant, small and worth it:
 *         - maxClip: the largest single move, so one bad quote cannot spend the grant;
 *         - minIntervalBlocks: spacing between clips from the same grant;
 *         - a PRICE FLOOR, not a slippage bound: `priceToken` is the ERC20 whose
 *           balance at the adapter measures the position (the LST a swap
 *           strategy holds, an aToken, a 4626 share), and `limitRate` is
 *           underlying per token, WAD-scaled on raw units
 *           (rate = assets × 1e18 / Δtokens). A deallocate clip must RECEIVE at
 *           least limitRate per token given up; an allocate clip must PAY at
 *           most limitRate per token gained. priceToken = 0 leaves the grant
 *           unguarded here (the adapter's own slippageBPS still applies).
 *
 *         Idle cash: an allocate clip needs the vault to hold `assets`. When it is
 *         short, the clip raises the shortfall from the liquidity adapter, and that
 *         raise consumes the bot's DEALLOCATE grant on the liquidity adapter. No
 *         grant there means IdleUnavailable: nothing moves outside a grant.
 *
 *         Caps: the allocator proxy applies the risk-class global cap and, for
 *         operators, the class local cap to every allocate clip; this contract
 *         cannot lift them. The proxy's deallocate has no cap check, which is why
 *         grants and maxClip are the only ceiling on the way out.
 *
 *         Authority: one owner. The deployer starts as owner, grants the first
 *         budgets, then hands ownership to the allocator admin (the Safe) with the
 *         two-step transfer. Any bot holding a grant may pause (emergency stop);
 *         only the owner unpauses. The Safe keeps the kill switch:
 *         `setOperator(mover, false)`.
 */
contract ClipAllocator {
    IAlchemistAllocatorFull public immutable allocator;
    IVaultV2Lite public immutable vault;
    IERC20Lite public immutable asset;

    struct Grant {
        uint256 remaining;         // units still allowed to move
        uint256 maxClip;           // largest single move
        uint32 minIntervalBlocks;  // spacing between clips from this grant
        uint64 lastClipBlock;
        address priceToken;        // ERC20 whose balance at the adapter measures the position (0 = unguarded)
        uint256 limitRate;         // underlying per token, WAD on raw units: floor (deallocate) / ceiling (allocate)
    }

    address public owner;                                         // the deployer, then the Safe
    address public pendingOwner;
    bool public paused;
    mapping(address => bool) public bots;                          // any address that ever held a grant
    mapping(address => mapping(address => Grant)) public deallocateGrants;  // bot → adapter → grant
    mapping(address => mapping(address => Grant)) public allocateGrants;    // bot → adapter → grant

    event GrantUpdated(address indexed bot, address indexed adapter, bool isAllocate,
                       uint256 remaining, uint256 maxClip, uint32 minIntervalBlocks,
                       address priceToken, uint256 limitRate);
    event ClipExecuted(address indexed bot, address indexed adapter, bool isAllocate,
                       uint256 assets, int256 realAssetsDelta, int256 bookedAllocationDelta,
                       int256 priceTokenDelta, uint256 rate, uint256 remaining);
    event IdleRaised(address indexed bot, address indexed liquidityAdapter, uint256 assets, uint256 remaining);
    event Paused(address indexed by, bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnerUpdated(address indexed owner);

    error NotOwner();
    error NotBotOrOwner();
    error MoverPaused();
    error NotAdapter(address adapter);
    error NoGrant(address bot, address adapter, bool isAllocate);
    error GrantExhausted(uint256 remaining, uint256 requested);
    error ClipTooLarge(uint256 maxClip, uint256 requested);
    error TooSoon(uint64 readyAtBlock);
    error IdleUnavailable(uint256 needed, uint256 vaultIdle, address liquidityAdapter);
    error RateOutsideLimit(uint256 rate, uint256 limitRate, bool isAllocate);
    error PositionDidNotMove(address priceToken, int256 priceTokenDelta);
    error RealAssetsDidNotMove(uint256 assets, int256 realAssetsDelta);
    error ZeroAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenActive() {
        if (paused) revert MoverPaused();
        _;
    }

    constructor(address _allocator) {
        require(_allocator != address(0), "zero");
        allocator = IAlchemistAllocatorFull(_allocator);
        vault = IVaultV2Lite(allocator.vault());
        asset = IERC20Lite(vault.asset());
        owner = msg.sender;                                     // the deployer, until the Safe accepts
    }

    // ---- the owner (the Safe once accepted): grants, unpause, succession ------

    /// @notice Add `amount` to the bot's deallocate budget on `adapter` and set
    ///         its limits. Amounts add, so a top-up is the same call again.
    function grantDeallocate(address bot, address adapter, uint256 amount, uint256 maxClip,
                             uint32 minIntervalBlocks, address priceToken, uint256 limitRate) external onlyOwner {
        _grant(deallocateGrants[bot][adapter], bot, adapter, false, amount, maxClip, minIntervalBlocks, priceToken, limitRate);
    }

    function grantAllocate(address bot, address adapter, uint256 amount, uint256 maxClip,
                           uint32 minIntervalBlocks, address priceToken, uint256 limitRate) external onlyOwner {
        _grant(allocateGrants[bot][adapter], bot, adapter, true, amount, maxClip, minIntervalBlocks, priceToken, limitRate);
    }

    /// @notice Zero a budget. The limits stay for the next grant.
    function revokeDeallocate(address bot, address adapter) external onlyOwner {
        Grant storage g = deallocateGrants[bot][adapter];
        g.remaining = 0;
        emit GrantUpdated(bot, adapter, false, 0, g.maxClip, g.minIntervalBlocks, g.priceToken, g.limitRate);
    }

    function revokeAllocate(address bot, address adapter) external onlyOwner {
        Grant storage g = allocateGrants[bot][adapter];
        g.remaining = 0;
        emit GrantUpdated(bot, adapter, true, 0, g.maxClip, g.minIntervalBlocks, g.priceToken, g.limitRate);
    }

    function _grant(Grant storage g, address bot, address adapter, bool isAllocate, uint256 amount,
                    uint256 maxClip, uint32 minIntervalBlocks, address priceToken, uint256 limitRate) internal {
        require(bot != address(0) && maxClip > 0, "grant");
        require(priceToken == address(0) || limitRate > 0, "rate");   // a guarded grant needs a real limit
        if (!vault.isAdapter(adapter)) revert NotAdapter(adapter);
        g.remaining += amount;
        g.maxClip = maxClip;
        g.minIntervalBlocks = minIntervalBlocks;
        g.priceToken = priceToken;
        g.limitRate = limitRate;
        bots[bot] = true;
        emit GrantUpdated(bot, adapter, isAllocate, g.remaining, maxClip, minIntervalBlocks, priceToken, limitRate);
    }

    /// @notice Emergency stop: any bot may pause, only the owner may unpause.
    function setPaused(bool p) external {
        if (msg.sender != owner && !(p && bots[msg.sender])) revert NotBotOrOwner();
        paused = p;
        emit Paused(msg.sender, p);
    }

    /// @notice Classic two-step transfer: the deployer names the Safe, the Safe accepts.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerUpdated(owner);
    }

    // ---- clips ------------------------------------------------------------------

    /// @notice Pull `assets` out of `adapter` on the direct path.
    function deallocateClip(address adapter, uint256 assets) external whenActive {
        _consume(deallocateGrants[msg.sender][adapter], adapter, false, assets);
        _deallocate(adapter, assets, 0, "", 0);
    }

    /// @notice Pull `assets` out of a swap-path adapter with 0x calldata.
    function deallocateClipWithSwap(address adapter, uint256 assets, bytes calldata txData) external whenActive {
        _consume(deallocateGrants[msg.sender][adapter], adapter, false, assets);
        _deallocate(adapter, assets, 1, txData, 0);
    }

    /// @notice Pull `assets` out of an unwrap-then-swap adapter (sfrxETH and the like).
    function deallocateClipWithUnwrapAndSwap(address adapter, uint256 assets, bytes calldata txData,
                                             uint256 minIntermediateOut) external whenActive {
        _consume(deallocateGrants[msg.sender][adapter], adapter, false, assets);
        _deallocate(adapter, assets, 2, txData, minIntermediateOut);
    }

    /// @notice Push `assets` into `adapter` on the direct path, raising idle from
    ///         the liquidity adapter (against the caller's deallocate grant there)
    ///         when the vault is short.
    function allocateClip(address adapter, uint256 assets) external whenActive {
        _consume(allocateGrants[msg.sender][adapter], adapter, true, assets);
        _raiseIdle(assets, adapter);
        _allocate(adapter, assets, false, "");
    }

    function allocateClipWithSwap(address adapter, uint256 assets, bytes calldata txData) external whenActive {
        _consume(allocateGrants[msg.sender][adapter], adapter, true, assets);
        _raiseIdle(assets, adapter);
        _allocate(adapter, assets, true, txData);
    }

    // ---- internals ------------------------------------------------------------

    function _consume(Grant storage g, address adapter, bool isAllocate, uint256 assets) internal {
        if (assets == 0) revert ZeroAmount();
        if (g.maxClip == 0) revert NoGrant(msg.sender, adapter, isAllocate);
        if (assets > g.remaining) revert GrantExhausted(g.remaining, assets);
        if (assets > g.maxClip) revert ClipTooLarge(g.maxClip, assets);
        uint64 readyAt = g.lastClipBlock + g.minIntervalBlocks;
        if (g.lastClipBlock != 0 && block.number < readyAt) revert TooSoon(readyAt);
        g.remaining -= assets;
        g.lastClipBlock = uint64(block.number);
    }

    struct Snap { bytes32 id; uint256 booked; uint256 real; uint256 tokens; }

    function _deallocate(address adapter, uint256 assets, uint8 mode, bytes memory txData,
                         uint256 minIntermediateOut) internal {
        Grant storage g = deallocateGrants[msg.sender][adapter];
        Snap memory b = _snapshot(adapter, g.priceToken);
        if (mode == 0) allocator.deallocate(adapter, assets);
        else if (mode == 1) allocator.deallocateWithSwap(adapter, assets, txData);
        else allocator.deallocateWithUnwrapAndSwap(adapter, assets, txData, minIntermediateOut);
        (int256 dReal, int256 dBooked, int256 dTokens) = _deltas(adapter, g.priceToken, b);
        if (dReal >= 0) revert RealAssetsDidNotMove(assets, dReal);
        // price floor: the vault received `assets` for |dTokens| of the position
        uint256 rate = _rate(g, assets, dTokens, false);
        emit ClipExecuted(msg.sender, adapter, false, assets, dReal, dBooked, dTokens, rate, g.remaining);
    }

    function _allocate(address adapter, uint256 assets, bool withSwap, bytes memory txData) internal {
        Grant storage g = allocateGrants[msg.sender][adapter];
        Snap memory b = _snapshot(adapter, g.priceToken);
        if (withSwap) allocator.allocateWithSwap(adapter, assets, txData);
        else allocator.allocate(adapter, assets);
        (int256 dReal, int256 dBooked, int256 dTokens) = _deltas(adapter, g.priceToken, b);
        if (dReal <= 0) revert RealAssetsDidNotMove(assets, dReal);
        // price ceiling: the vault paid `assets` for dTokens of the position
        uint256 rate = _rate(g, assets, dTokens, true);
        emit ClipExecuted(msg.sender, adapter, true, assets, dReal, dBooked, dTokens, rate, g.remaining);
    }

    /// @dev rate = underlying per position token, WAD on raw units. Deallocate:
    ///      tokens leave the adapter (dTokens < 0) and must fetch >= limitRate
    ///      each. Allocate: tokens arrive (dTokens > 0) and must cost <= limitRate
    ///      each. Unguarded grants (priceToken = 0) report rate 0.
    function _rate(Grant storage g, uint256 assets, int256 dTokens, bool isAllocate) internal view returns (uint256 rate) {
        if (g.priceToken == address(0)) return 0;
        if (isAllocate ? dTokens <= 0 : dTokens >= 0) revert PositionDidNotMove(g.priceToken, dTokens);
        uint256 moved = isAllocate ? uint256(dTokens) : uint256(-dTokens);
        rate = assets * 1e18 / moved;
        if (isAllocate ? rate > g.limitRate : rate < g.limitRate) revert RateOutsideLimit(rate, g.limitRate, isAllocate);
    }

    function _snapshot(address adapter, address priceToken) internal view returns (Snap memory s) {
        s.id = IMYTStrategyLite(adapter).adapterId();
        s.booked = vault.allocation(s.id);
        s.real = IMYTStrategyLite(adapter).realAssets();
        s.tokens = priceToken == address(0) ? 0 : IERC20Lite(priceToken).balanceOf(adapter);
    }

    function _deltas(address adapter, address priceToken, Snap memory b)
        internal view returns (int256 dReal, int256 dBooked, int256 dTokens)
    {
        dReal = int256(IMYTStrategyLite(adapter).realAssets()) - int256(b.real);
        dBooked = int256(vault.allocation(b.id)) - int256(b.booked);
        dTokens = priceToken == address(0) ? int256(0)
            : int256(IERC20Lite(priceToken).balanceOf(adapter)) - int256(b.tokens);
    }

    /// @dev An allocate clip needs the vault to hold `needed`. The shortfall comes
    ///      out of the liquidity adapter, drawn from the caller's deallocate grant
    ///      there. Raising is a vault-internal move (never a borrow).
    function _raiseIdle(uint256 needed, address target) internal {
        uint256 idle = asset.balanceOf(address(vault));
        if (idle >= needed) return;
        address liq = vault.liquidityAdapter();
        uint256 shortfall = needed - idle;
        if (liq == address(0) || liq == target) revert IdleUnavailable(needed, idle, liq);
        Grant storage g = deallocateGrants[msg.sender][liq];
        if (g.maxClip == 0 || shortfall > g.remaining) revert IdleUnavailable(needed, idle, liq);
        // the raise is spacing-exempt (it is part of this clip) but budget-bound
        g.remaining -= shortfall;
        allocator.deallocate(liq, shortfall);
        emit IdleRaised(msg.sender, liq, shortfall, g.remaining);
    }
}