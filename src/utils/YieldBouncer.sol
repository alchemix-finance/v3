// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateSource} from "./rates/IRateSource.sol";

/// Minimal views of the live contracts the bouncer touches. Inline so the file
/// compiles on its own (no v3 remappings needed).
interface IBouncerAllocator {
    function vault() external view returns (address);
    function allocate(address adapter, uint256 amount) external;
    function deallocate(address adapter, uint256 amount) external;
}

interface IBouncerVault {
    function isAdapter(address account) external view returns (bool);
}

interface IBouncerStrategy {
    function realAssets() external view returns (uint256);
}

/**
 * @title YieldBouncer
 * @notice A budgeted allocator operator for pairs of lending strategies. Registered
 *         as an operator of the live AlchemistAllocator (one Safe call:
 *         `setOperator(bouncer, true)`), it lets a whitelisted bot move assets
 *         between two strategies of the same vault, in either direction, toward
 *         whichever pays the higher supply rate:
 *
 *           grantPair(bot, a, b, limits)    bot may move between a and b
 *           bounce(from, to, assets)        deallocate `from`, allocate `to`, one tx
 *
 *         Budget is a NET BAND, not a volume counter. Each pair keeps
 *         `net` = assets moved a → b minus assets moved b → a. A move toward b must
 *         leave net ≤ maxNetToB; a move toward a must leave net ≥ −maxNetToA. Each
 *         direction checks only its own limit, so a band rewritten below the current
 *         net still lets the bot move back toward it. Total volume is unlimited
 *         while net stays inside: deploy 100, withdraw 50, deploy 50 again, no more.
 *         An off-weight start is one limit at 0 (maxNetToA = 0: never pull more out
 *         of b than was put in). Yield earned inside a venue and user flows through
 *         the liquidity adapter never move the counter.
 *
 *         Direction is enforced here, AFTER both legs: rate(to) must be at least
 *         rate(from) + minSpreadBps (APR basis points). Moving money lowers the
 *         destination's rate and raises the source's, so passing after the move
 *         proves the order before it, and caps the size at the crossing point. Rates
 *         come from IRateSource views the owner registers per strategy. A strategy
 *         without one cannot be paired, and removing one stops its pairs.
 *
 *         Per pair, as on the ClipAllocator: maxClip (largest single move),
 *         minIntervalBlocks (spacing, shared by both directions), expiresAtBlock (0
 *         does not expire), and maxLossBps per leg: `from` may shrink by at most
 *         assets × (1 + bps), `to` must grow by at least assets × (1 − bps).
 *
 *         Both legs run in one transaction, so vault idle ends where it started.
 *         The allocate leg still meets the proxy's caps (VaultV2 absolute and
 *         relative, class global, class local for operators); a blocked leg
 *         reverts the whole move.
 *
 *         Authority: one owner. The deployer starts as owner, then hands it to the
 *         allocator admin (the Safe) with the two-step transfer. A bot with an
 *         active pair may pause; only the owner unpauses. `grantPair` rewrites the
 *         limits and keeps `net`; `recenter` is the only reset. The Safe keeps the
 *         kill switch: `setOperator(bouncer, false)`.
 */
contract YieldBouncer {
    IBouncerAllocator public immutable allocator;
    IBouncerVault public immutable vault;

    struct Limits {
        uint256 maxNetToB;         // net may rise to +maxNetToB (moves a → b)
        uint256 maxNetToA;         // net may fall to −maxNetToA (moves b → a)
        uint256 maxClip;           // largest single move
        uint32 minIntervalBlocks;  // spacing between moves on this pair, either direction
        uint16 maxLossBps;         // per leg, realAssets vs assets (max 10_000)
        uint16 minSpreadBps;       // after the move, rate(to) ≥ rate(from) + this many APR bps
        uint64 expiresAtBlock;     // last block a move may run; 0 does not expire
    }

    struct Pair {
        address a;                 // orientation fixed by the first grant
        address b;
        int256 net;                // assets moved a → b minus b → a, raw units of the vault asset
        uint64 lastMoveBlock;
        bool active;
        Limits limits;
    }

    struct RateFeed {
        address source;            // IRateSource
        address venue;             // what the source reads (aToken, fToken, VaultV2, Yearn vault)
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant APR_BP = 1e14;   // one APR basis point in WAD

    address public owner;                      // the deployer, then the Safe
    address public pendingOwner;
    bool public paused;
    bool private locked;
    mapping(bytes32 => Pair) internal _pairs;               // pairKey(bot, x, y) → pair
    mapping(address => uint256) public activePairs;         // per bot; one is enough to pause
    mapping(address => RateFeed) public rateFeeds;          // strategy → rate source + venue

    event RateSourceSet(address indexed strategy, address source, address venue);
    event PairUpdated(address indexed bot, bytes32 indexed key, address a, address b, Limits limits, bool active, int256 net);
    event Recentered(address indexed bot, bytes32 indexed key, int256 netBefore);
    event Bounced(address indexed bot, bytes32 indexed key, address indexed from, address to, uint256 assets,
                  int256 netAfter, uint256 rateFromAfter, uint256 rateToAfter, int256 realFromDelta, int256 realToDelta);
    event Paused(address indexed by, bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnerUpdated(address indexed owner);

    error NotOwner();
    error NotBotOrOwner();
    error MoverPaused();
    error Reentrant();
    error ZeroAmount();
    error NotAdapter(address strategy);
    error SameStrategy(address strategy);
    error NoRateSource(address strategy);
    error NoPair(address bot, address from, address to);
    error OrientationMismatch(address a, address b);
    error PairExpired(uint64 expiresAtBlock);
    error ClipTooLarge(uint256 maxClip, uint256 requested);
    error TooSoon(uint64 readyAtBlock);
    error NetLimitExceeded(int256 netAfter, int256 limit);
    error RealAssetsDidNotMove(uint256 assets, int256 realAssetsDelta);
    error LossExceedsLimit(uint256 valueMoved, uint256 limit, bool isAllocate);
    error SpreadTooThin(uint256 rateTo, uint256 rateFrom, uint16 minSpreadBps);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenActive() {
        if (paused) revert MoverPaused();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrant();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _allocator) {
        require(_allocator != address(0), "zero");
        allocator = IBouncerAllocator(_allocator);
        vault = IBouncerVault(allocator.vault());
        owner = msg.sender;                                     // the deployer, until the Safe accepts
    }

    // ---- the owner (the Safe once accepted) ---------------------------------------

    /// @notice Register how to read `strategy`'s supply rate. `source` = 0 removes it,
    ///         which stops every pair over that strategy. A source that cannot read
    ///         `venue` now is refused.
    function setRateSource(address strategy, address source, address venue) external onlyOwner {
        if (source != address(0)) {
            if (!vault.isAdapter(strategy)) revert NotAdapter(strategy);
            IRateSource(source).supplyRate(venue);
        } else {
            venue = address(0);
        }
        rateFeeds[strategy] = RateFeed(source, venue);
        emit RateSourceSet(strategy, source, venue);
    }

    /// @notice Set the bot's pair over `a` and `b`. The first grant fixes the
    ///         orientation (net counts a → b); a rewrite must name the strategies in
    ///         the same order, states every limit again, and keeps `net`.
    function grantPair(address bot, address a, address b, Limits calldata limits) external onlyOwner {
        require(bot != address(0) && limits.maxClip > 0, "grant");
        require(limits.maxLossBps <= BPS, "loss");
        require(limits.maxClip <= uint256(type(int256).max) && limits.maxNetToB <= uint256(type(int256).max)
                && limits.maxNetToA <= uint256(type(int256).max), "range");
        if (a == b) revert SameStrategy(a);
        if (!vault.isAdapter(a)) revert NotAdapter(a);
        if (!vault.isAdapter(b)) revert NotAdapter(b);
        if (rateFeeds[a].source == address(0)) revert NoRateSource(a);
        if (rateFeeds[b].source == address(0)) revert NoRateSource(b);
        bytes32 key = pairKey(bot, a, b);
        Pair storage p = _pairs[key];
        if (p.a == address(0)) {
            p.a = a;
            p.b = b;
        } else if (p.a != a) {
            revert OrientationMismatch(p.a, p.b);
        }
        if (!p.active) {
            p.active = true;
            activePairs[bot] += 1;
        }
        p.limits = limits;
        emit PairUpdated(bot, key, a, b, limits, true, p.net);
    }

    /// @notice Reset the pair's net to 0. Limits stay.
    function recenter(address bot, address a, address b) external onlyOwner {
        bytes32 key = pairKey(bot, a, b);
        Pair storage p = _pairs[key];
        if (p.a == address(0)) revert NoPair(bot, a, b);
        emit Recentered(bot, key, p.net);
        p.net = 0;
    }

    /// @notice Turn the pair off. Net and limits stay; a later grant turns it back on.
    function revokePair(address bot, address a, address b) external onlyOwner {
        bytes32 key = pairKey(bot, a, b);
        Pair storage p = _pairs[key];
        if (p.a == address(0)) revert NoPair(bot, a, b);
        if (p.active) {
            p.active = false;
            activePairs[bot] -= 1;
        }
        emit PairUpdated(bot, key, p.a, p.b, p.limits, false, p.net);
    }

    /// @notice Emergency stop: a bot with an active pair may pause, only the owner may unpause.
    function setPaused(bool p) external {
        if (msg.sender != owner && !(p && activePairs[msg.sender] > 0)) revert NotBotOrOwner();
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

    // ---- the bot ------------------------------------------------------------------

    /// @notice Move `assets` out of `from` and into `to` in one transaction. Reverts
    ///         unless, after both legs, `to` pays at least `from` + minSpreadBps.
    ///         An eth_call previews the post-move rates and net.
    function bounce(address from, address to, uint256 assets)
        external
        whenActive
        nonReentrant
        returns (uint256 rateFromAfter, uint256 rateToAfter, int256 netAfter)
    {
        bytes32 key = pairKey(msg.sender, from, to);
        Limits memory l = _admit(_pairs[key], from, to, assets);
        Move memory m = _move(from, to, assets, l);
        m.netAfter = _pairs[key].net;
        emit Bounced(msg.sender, key, from, to, assets, m.netAfter, m.rateFromAfter, m.rateToAfter, m.realFromDelta, m.realToDelta);
        return (m.rateFromAfter, m.rateToAfter, m.netAfter);
    }

    // ---- views --------------------------------------------------------------------

    /// @notice One key per bot and unordered pair of strategies.
    function pairKey(address bot, address x, address y) public pure returns (bytes32) {
        (address lo, address hi) = x < y ? (x, y) : (y, x);
        return keccak256(abi.encode(bot, lo, hi));
    }

    function pairOf(address bot, address x, address y) external view returns (Pair memory) {
        return _pairs[pairKey(bot, x, y)];
    }

    /// @notice Supply APR (WAD) of `strategy` from its registered source.
    function rateOf(address strategy) external view returns (uint256) {
        RateFeed memory f = rateFeeds[strategy];
        if (f.source == address(0)) revert NoRateSource(strategy);
        return IRateSource(f.source).supplyRate(f.venue);
    }

    /// @notice Assets the band still allows from `from` to `to` for this bot (0 if none or off).
    function room(address bot, address from, address to) external view returns (uint256) {
        Pair storage p = _pairs[pairKey(bot, from, to)];
        if (!p.active || from == to) return 0;
        int256 r = from == p.a ? int256(p.limits.maxNetToB) - p.net : p.net + int256(p.limits.maxNetToA);
        return r > 0 ? uint256(r) : 0;
    }

    // ---- internals ----------------------------------------------------------------

    struct Move {
        int256 netAfter;
        uint256 rateFromAfter;
        uint256 rateToAfter;
        int256 realFromDelta;
        int256 realToDelta;
    }

    /// @dev Every check that needs no external call, then the state change (net,
    ///      lastMoveBlock) before the legs run.
    function _admit(Pair storage p, address from, address to, uint256 assets) internal returns (Limits memory l) {
        if (assets == 0) revert ZeroAmount();
        if (!p.active || from == to) revert NoPair(msg.sender, from, to);
        l = p.limits;
        if (l.expiresAtBlock != 0 && block.number > l.expiresAtBlock) revert PairExpired(l.expiresAtBlock);
        if (assets > l.maxClip) revert ClipTooLarge(l.maxClip, assets);
        uint64 readyAt = p.lastMoveBlock + l.minIntervalBlocks;
        if (p.lastMoveBlock != 0 && block.number < readyAt) revert TooSoon(readyAt);
        if (rateFeeds[from].source == address(0)) revert NoRateSource(from);
        if (rateFeeds[to].source == address(0)) revert NoRateSource(to);
        p.net = _netAfter(p, from == p.a, assets, l);
        p.lastMoveBlock = uint64(block.number);
    }

    /// @dev Both legs, the per-leg loss bound, then the rate check on post-move state.
    function _move(address from, address to, uint256 assets, Limits memory l) internal returns (Move memory m) {
        uint256 fromBefore = IBouncerStrategy(from).realAssets();
        uint256 toBefore = IBouncerStrategy(to).realAssets();
        allocator.deallocate(from, assets);
        allocator.allocate(to, assets);
        m.realFromDelta = int256(IBouncerStrategy(from).realAssets()) - int256(fromBefore);
        m.realToDelta = int256(IBouncerStrategy(to).realAssets()) - int256(toBefore);
        _checkLegs(l.maxLossBps, assets, m.realFromDelta, m.realToDelta);

        RateFeed memory feedFrom = rateFeeds[from];
        RateFeed memory feedTo = rateFeeds[to];
        m.rateFromAfter = IRateSource(feedFrom.source).supplyRate(feedFrom.venue);
        m.rateToAfter = IRateSource(feedTo.source).supplyRate(feedTo.venue);
        if (m.rateToAfter < m.rateFromAfter + uint256(l.minSpreadBps) * APR_BP) {
            revert SpreadTooThin(m.rateToAfter, m.rateFromAfter, l.minSpreadBps);
        }
    }

    function _netAfter(Pair storage p, bool towardB, uint256 assets, Limits memory l) internal view returns (int256 n) {
        if (towardB) {
            n = p.net + int256(assets);
            if (n > int256(l.maxNetToB)) revert NetLimitExceeded(n, int256(l.maxNetToB));
        } else {
            n = p.net - int256(assets);
            if (n < -int256(l.maxNetToA)) revert NetLimitExceeded(n, -int256(l.maxNetToA));
        }
    }

    /// @dev `from` may shrink by at most assets × (1 + bps); `to` must grow by at
    ///      least assets × (1 − bps).
    function _checkLegs(uint16 maxLossBps, uint256 assets, int256 dFrom, int256 dTo) internal pure {
        if (dFrom >= 0) revert RealAssetsDidNotMove(assets, dFrom);
        if (dTo <= 0) revert RealAssetsDidNotMove(assets, dTo);
        uint256 maxDrop = assets * (BPS + maxLossBps) / BPS;
        if (uint256(-dFrom) > maxDrop) revert LossExceedsLimit(uint256(-dFrom), maxDrop, false);
        uint256 minGain = assets * (BPS - maxLossBps) / BPS;
        if (uint256(dTo) < minGain) revert LossExceedsLimit(uint256(dTo), minGain, true);
    }
}