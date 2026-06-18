/*
 * Proof #3 — protocol fee bounds are an invariant
 *
 * Targets:
 *   setProtocolFee   (src/AlchemistV3.sol:261)  _checkArgument(fee <= BPS)
 *   setLiquidatorFee (src/AlchemistV3.sol:269)  _checkArgument(fee <= BPS)
 *   setRepaymentFee  (src/AlchemistV3.sol:277)  _checkArgument(fee <= BPS)
 *   initialize       (src/AlchemistV3.sol:167)  _checkArgument(* <= BPS)
 *
 * Each fee is written in exactly two places: initialize() (locked on the
 * implementation by the `constructor() initializer {}`) and the matching
 * setter, both guarded by `_checkArgument(fee <= BPS)` where BPS == 10_000.
 * The fees default to 0. Therefore, in every reachable state:
 *
 *   protocolFee <= BPS   &&   liquidatorFee <= BPS   &&   repaymentFee <= BPS
 *
 * We assert this as global invariants (checked after every external call,
 * including the harness setters, which never touch the fees) and additionally
 * prove the per-setter guard: a successful setter call cannot set the field
 * above BPS.
 */


methods {
    // fee setters: stateful, require env (onlyAdmin checks msg.sender)
    function setProtocolFee(uint256)   external;
    function setLiquidatorFee(uint256) external;
    function setRepaymentFee(uint256)  external;

    // pure-view getters: do not depend on env, usable in env-free invariants
    function protocolFee()   external returns (uint256) envfree;
    function liquidatorFee() external returns (uint256) envfree;
    function repaymentFee()  external returns (uint256) envfree;
    function admin()         external returns (address) envfree;
    function BPS()           external returns (uint256) envfree;
}

// ---------------------------------------------------------------------------
// Global state invariants: each fee is written only by initialize() (locked by
// `constructor() initializer {}`) and its guarded setter, and defaults to 0, so
// it can never exceed BPS in any reachable state.
// ---------------------------------------------------------------------------

invariant protocolFee_le_bps()   protocolFee()   <= BPS();
invariant liquidatorFee_le_bps() liquidatorFee() <= BPS();
invariant repaymentFee_le_bps()  repaymentFee()  <= BPS();

// ---------------------------------------------------------------------------
// Per-setter guard rules: a successful setter call cannot leave the field
// above BPS (a call with fee > BPS reverts and leaves the field unchanged).
// ---------------------------------------------------------------------------

rule setProtocolFee_enforces_bound(env e, uint256 fee) {
    require e.msg.sender == admin();
    setProtocolFee(e, fee);
    assert protocolFee() <= BPS(), "setProtocolFee must keep protocolFee <= BPS";
}

rule setLiquidatorFee_enforces_bound(env e, uint256 fee) {
    require e.msg.sender == admin();
    setLiquidatorFee(e, fee);
    assert liquidatorFee() <= BPS(), "setLiquidatorFee must keep liquidatorFee <= BPS";
}

rule setRepaymentFee_enforces_bound(env e, uint256 fee) {
    require e.msg.sender == admin();
    setRepaymentFee(e, fee);
    assert repaymentFee() <= BPS(), "setRepaymentFee must keep repaymentFee <= BPS";
}
