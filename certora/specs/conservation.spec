/*
 * Conservation Spec — end-to-end value conservation for AlchemistV3.
 *
 * Target: AlchemistV3SceneHarness (inheritance scene with typed anchors).
 *
 * Invariant blocks are verified by Certora after every external call,
 * equivalent to parametric rules but with internal optimizations.
 */

methods {
    function __mytSharesDeposited() external returns (uint256) envfree;
    function __vaultBalanceOf(address) external returns (uint256) envfree;
    function __transmuterTotalLocked() external returns (uint256) envfree;
    function __vaultPerformanceFee() external returns (uint96) envfree;
    function totalSyntheticsIssued() external returns (uint256) envfree;
    function FEE_COLLECTOR() external returns (address) envfree;
    function ADMIN_ACTOR() external returns (address) envfree;

    /* HAVOC_ALL for functions with array params that crash points-to analysis */
    function batchLiquidate(uint256[]) external => HAVOC_ALL;
}

invariant mytSharesDepositedLeBalance()
    __mytSharesDeposited() <= __vaultBalanceOf(currentContract);

invariant syntheticsGeqLocked()
    totalSyntheticsIssued() >= __transmuterTotalLocked();

invariant performanceFeeCapped()
    __vaultPerformanceFee() <= 500;

invariant feeCollectorNotAlchemist()
    FEE_COLLECTOR() != currentContract;

invariant feeCollectorNotAdmin()
    FEE_COLLECTOR() != ADMIN_ACTOR();
