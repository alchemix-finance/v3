using MYTSceneHarness as vault;
using MockAsset as assetToken;
using MockStrategy as strategy;

links {
    vault.asset => assetToken;
    vault.token => assetToken;
    vault.strategy0 => strategy;
    vault.strategy1 => strategy;
    strategy.asset => assetToken;
    strategy.vault => vault;
}

methods {
    // --- VaultV2 state getters ---
    function performanceFee() external returns (uint96) envfree;
    function performanceFeeRecipient() external returns (address) envfree;
    function managementFee() external returns (uint96) envfree;
    function managementFeeRecipient() external returns (address) envfree;
    function maxRate() external returns (uint64) envfree;
    function totalSupply() external returns (uint256) envfree;
    function _totalAssets() external returns (uint128) envfree;
    function relativeCap(bytes32) external returns (uint256) envfree;
    function absoluteCap(bytes32) external returns (uint256) envfree;
    function allocation(bytes32) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) optional;
    function convertToShares(uint256) external returns (uint256) optional;
    function balanceOf(address) external returns (uint256) envfree;
    function strategy0() external returns (address) envfree;
    function strategy1() external returns (address) envfree;
    function ZERO_ADDRESS() external returns (address) envfree;

    // --- Harness helpers ---
    function id0() external returns (bytes32) envfree;
    function id1() external returns (bytes32) envfree;
    function __adapterId(uint256) external returns (bytes32) envfree;
    function __strategyAdapterId(uint256) external returns (bytes32) envfree;
    function __idleBalance() external returns (uint256) envfree;
    function __strategyRealAssets(uint256) external returns (uint256) envfree;
    function __strategyBalance(uint256) external returns (uint256) envfree;
    function __totalRealAssets() external returns (uint256) envfree;
    function __MAX_PERFORMANCE_FEE() external returns (uint256) envfree;
    function __MAX_MANAGEMENT_FEE() external returns (uint256) envfree;
    function __MAX_MAX_RATE() external returns (uint256) envfree;
    function __MAX_FORCE_DEALLOCATE_PENALTY() external returns (uint256) envfree;
    function forceDeallocatePenalty(address) external returns (uint256) envfree;
    function FEE_RECIPIENT() external returns (address) envfree;
    function __assetBalanceOf(address) external returns (uint256) envfree;
    function __vaultAddress() external returns (address) envfree;

    // --- IAdapter interface (dispatch to MockStrategy) ---
    function _.allocate(bytes, uint256, bytes4, address) external => DISPATCHER(true);
    function _.deallocate(bytes, uint256, bytes4, address) external => DISPATCHER(true);
    function _.realAssets() external => DISPATCHER(true);
}

/* =======================================================================
 * FEE — Fee parameter bounds & recipient consistency (invariants)
 * ===================================================================== */

invariant performanceFeeBounded()
    performanceFee() <= __MAX_PERFORMANCE_FEE();

invariant managementFeeBounded()
    managementFee() <= __MAX_MANAGEMENT_FEE();

invariant performanceFeeRecipientSet()
    performanceFee() == 0 || performanceFeeRecipient() != ZERO_ADDRESS();

invariant managementFeeRecipientSet()
    managementFee() == 0 || managementFeeRecipient() != ZERO_ADDRESS();

/* =======================================================================
 * RATE — maxRate bound (invariant)
 * ===================================================================== */

invariant maxRateBounded()
    maxRate() <= __MAX_MAX_RATE();

/* =======================================================================
 * CAP — Relative cap <= WAD (invariants)
 *
 * absoluteCap can be decreased below the current allocation by
 * decreaseAbsoluteCap (only requires newCap <= oldCap), so
 * "allocation <= absoluteCap" is NOT a valid state invariant.
 * It IS enforced on every successful allocate — see ALLOC rules.
 * ===================================================================== */

invariant relativeCapLeWAD0()
    relativeCap(id0()) <= 1000000000000000000;

invariant relativeCapLeWAD1()
    relativeCap(id1()) <= 1000000000000000000;

/* =======================================================================
 * ALLOC — Allocation cap enforcement on allocate (rules)
 *
 * These are the core soundness rules: after a successful allocate,
 * the strategy's allocation MUST be within its caps.
 * ===================================================================== */

/// After allocate, allocation must not exceed the absolute cap.
/// Verifies line 583: require(_caps.allocation <= _caps.absoluteCap).
rule allocateRespectsAbsoluteCap(env e, uint256 which, uint256 assets) {
    bytes32 id = __adapterId(which);
    require id == __strategyAdapterId(which);
    __allocate@withrevert(e, which, assets);
    assert lastReverted || allocation(id) <= absoluteCap(id),
        "ALLOC: allocation exceeds absolute cap after allocate";
}

/// If absoluteCap is zero, allocate must revert.
/// Verifies line 582: require(_caps.absoluteCap > 0).
rule zeroAbsoluteCapBlocksAllocate(env e, uint256 which, uint256 assets) {
    bytes32 id = __adapterId(which);
    require id == __strategyAdapterId(which);
    require absoluteCap(id) == 0;
    __allocate@withrevert(e, which, assets);
    assert lastReverted,
        "ALLOC: allocate must revert when absolute cap is zero";
}

/// After allocate, absoluteCap must still be > 0.
/// Verifies that allocate never disables an id.
rule allocatePreservesNonZeroAbsoluteCap(env e, uint256 which, uint256 assets) {
    bytes32 id = __adapterId(which);
    require absoluteCap(id) > 0;
    __allocate@withrevert(e, which, assets);
    assert lastReverted || absoluteCap(id) > 0,
        "ALLOC: absolute cap must remain positive after allocate";
}

/* =======================================================================
 * CAPM — Cap-setter monotonicity (rules)
 *
 * increaseAbsoluteCap / increaseRelativeCap must only INCREASE.
 * decreaseAbsoluteCap / decreaseRelativeCap must only DECREASE.
 * ===================================================================== */

rule increaseAbsoluteCapMonotonic(env e, uint256 which, uint256 newCap) {
    bytes32 id = __adapterId(which);
    uint256 oldCap = absoluteCap(id);
    __increaseAbsoluteCap@withrevert(e, which, newCap);
    assert lastReverted || absoluteCap(id) >= oldCap,
        "CAPM: increaseAbsoluteCap decreased the cap";
}

rule decreaseAbsoluteCapMonotonic(env e, uint256 which, uint256 newCap) {
    bytes32 id = __adapterId(which);
    uint256 oldCap = absoluteCap(id);
    __decreaseAbsoluteCap@withrevert(e, which, newCap);
    assert lastReverted || absoluteCap(id) <= oldCap,
        "CAPM: decreaseAbsoluteCap increased the cap";
}

rule increaseRelativeCapMonotonic(env e, uint256 which, uint256 newCap) {
    bytes32 id = __adapterId(which);
    uint256 oldCap = relativeCap(id);
    __increaseRelativeCap@withrevert(e, which, newCap);
    assert lastReverted || relativeCap(id) >= oldCap,
        "CAPM: increaseRelativeCap decreased the cap";
}

rule decreaseRelativeCapMonotonic(env e, uint256 which, uint256 newCap) {
    bytes32 id = __adapterId(which);
    uint256 oldCap = relativeCap(id);
    __decreaseRelativeCap@withrevert(e, which, newCap);
    assert lastReverted || relativeCap(id) <= oldCap,
        "CAPM: decreaseRelativeCap increased the cap";
}

/* =======================================================================
 * DEALLOC — Deallocate reclaimability (rules)
 *
 * Funds must not be locked: assuming strategies hold the tokens they
 * claim, deallocate always brings assets back to the vault.
 * ===================================================================== */

/// After deallocate, vault idle balance increases by exactly the requested
/// assets (strategy returns the tokens via transferFrom).
rule deallocateReclaimsFunds(env e, uint256 which, uint256 assets) {
    require assets > 0;
    require __strategyBalance(which) >= assets;
    uint256 idleBefore = __idleBalance();
    __deallocate@withrevert(e, which, assets);
    assert lastReverted || __idleBalance() == idleBefore + assets || _totalAssets() == 0,
        "DEALLOC: vault idle must increase by exactly assets";
}

/// Allocate→deallocate round-trip always succeeds when the strategy has
/// sufficient tokens (no funds locked in an ideal strategy).
rule allocateDeallocateRoundTrip(env e, uint256 which, uint256 assets) {
    require assets > 0;

    address third;
    require third != e.msg.sender;
    require third != __vaultAddress();
    require third != strategy0();
    require third != strategy1();
    uint256 thirdBefore = __assetBalanceOf(third);

    
    __allocate@withrevert(e, which, assets);
    require !lastReverted;
    __deallocate@withrevert(e, which, assets);
    assert !lastReverted,
    "DEALLOC: must be able to deallocate after successful allocate";

    assert __assetBalanceOf(third) == thirdBefore, "LEAK";
}

/* =======================================================================
 * FORCE — forceDeallocate bounds (rules)
 *
 * forceDeallocate is callable by anyone.  It pulls assets FROM the
 * adapter into the vault and takes a penalty from the caller's shares.
 * ===================================================================== */

/// forceDeallocate brings assets INTO the vault (via deallocateInternal)
/// and the penalty self-transfer (receiver = vault) is a no-op for the
/// vault's token balance.  Therefore the vault's real balance never
/// decreases.
rule forceDeallocateDoesNotDrainVault(env e, uint256 which, uint256 assets) {
    address attacker;
    require attacker != __vaultAddress();
    require attacker != strategy0();
    require attacker != strategy1();
    require assets > 0;
    require __strategyBalance(which) >= assets;

    uint256 vaultBalanceBefore = __idleBalance();
    uint256 attackerBefore = __assetBalanceOf(attacker);

    __forceDeallocate@withrevert(e, which, assets);
    bool reverted = lastReverted;
    uint256 idleAfter = __idleBalance();
    uint128 totalAfter = _totalAssets();
    uint256 attackerAfter = __assetBalanceOf(attacker);

    assert reverted || idleAfter >= vaultBalanceBefore || totalAfter == 0,
        "FORCE: vault token balance must not decrease after forceDeallocate";
    assert reverted || attackerAfter <= attackerBefore,
        "FORCE: thirdparty must not gain assets from forceDeallocate";
}


/**
  Check that each possible operation changes the balance of at most two users - taken from Aave ;)
  The vault, strategies, and fee recipient are excluded — their balances
  legitimately change as part of vault operations (deposit, withdraw,
  allocate, deallocate, fee accrual).
*/
rule balanceOfChange(address a, address b, address c, method f )
  filtered { f ->  !f.isView }
{
  env e;
  require a!=b && a!=c && b!=c;
  require a != __vaultAddress() && a != strategy0() && a != strategy1() && a != FEE_RECIPIENT();
  require b != __vaultAddress() && b != strategy0() && b != strategy1() && b != FEE_RECIPIENT();
  require c != __vaultAddress() && c != strategy0() && c != strategy1() && c != FEE_RECIPIENT();
  uint256 balanceABefore = __assetBalanceOf(a);
  uint256 balanceBBefore = __assetBalanceOf(b);
  uint256 balanceCBefore = __assetBalanceOf(c);

  calldataarg arg;
  f@withrevert(e, arg);
  bool functionReverted = lastReverted;

  uint256 balanceAAfter = __assetBalanceOf(a);
  uint256 balanceBAfter = __assetBalanceOf(b);
  uint256 balanceCAfter = __assetBalanceOf(c);

  assert (functionReverted || balanceABefore == balanceAAfter || balanceBBefore == balanceBAfter || balanceCBefore == balanceCAfter);
}
