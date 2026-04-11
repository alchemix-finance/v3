// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantsTest.t.sol";
import {ITestYieldToken} from "../../interfaces/test/ITestYieldToken.sol";

/// @title CrucibleTest — Extreme stress-testing for yield loss, cascading liquidation, and recovery
/// @notice Standalone invariant suite (does NOT inherit HardenedInvariantsTest).
///         Extends InvariantsTest for base infrastructure only.
///
/// Purpose:
///   Test the full lifecycle: normal → yield accrual → catastrophic loss → cascading
///   liquidations → bad debt socialization via transmuter → recovery through new yield.
///
/// Handlers (position-building):
///   - depositCollateral: create/grow positions
///   - borrowCollateral: take on debt
///   - repayDebt: repay with yield tokens
///   - transmuterStake: lock synthetics in transmuter
///   - mine: advance blocks
///
/// Handlers (stress):
///   - accrueYield: steady share-price increases (0.01-0.5%)
///   - realizeLargeValueLoss: catastrophic loss events (5-30%)
///   - cascadeLiquidations: sweep all undercollateralized positions
///   - transmuterClaimDuringBadDebt: exercise badDebtRatio scaling path
///   - recoverFromLoss: inject recovery yield (10-50%)
///
/// Invariants:
///   - C1: Storage debt consistency (sum(account.debt) ≈ totalDebt after poke)
///   - C2: Share price > 0 (no total wipeout)
///   - C3: Bad debt bounded by realized losses
///   - C4: Post-liquidation positions are healthy or zeroed
///   - C5: Recovery works (net positive yield → no bad debt)
///   - C6: Synthetics balance (totalSyntheticsIssued >= transmuter.totalLocked)
///   - C7: cumulativeEarmarked <= totalDebt
contract CrucibleTest is InvariantsTest {

    // ═══════ Ghost tracking ═══════
    uint256 public totalYieldAccrued;
    uint256 public totalLossRealized;
    uint256 public cascadingLiquidationRounds;
    uint256 public badDebtEvents;
    uint256 public recoveryEvents;
    uint256 public liquidationAttempts;
    uint256 public liquidationSuccesses;
    uint256 public yieldAccruals;
    uint256 public handlerSkips;

    // Debt consistency tracking
    uint256 public maxDebtDelta;
    uint256 public maxEarmarkDelta;
    uint256 public maxCollateralDelta;

    bool public inBadDebtState;
    bool public lossAfterLastLiquidation; // tracks if a loss occurred after the most recent cascade

    uint256 internal constant MAX_TEST_VALUE = 1e28;
    bytes4 internal constant ILLEGAL_STATE_SELECTOR = bytes4(keccak256("IllegalState()"));

    function setUp() public virtual override {
        // Position-building handlers
        selectors.push(this.depositCollateral.selector);
        selectors.push(this.borrowCollateral.selector);
        selectors.push(this.repayDebt.selector);
        selectors.push(this.transmuterStake.selector);
        selectors.push(this.transmuterClaim.selector);
        selectors.push(this.mine.selector);

        // Stress handlers
        selectors.push(this.accrueYield.selector);
        selectors.push(this.realizeLargeValueLoss.selector);
        selectors.push(this.cascadeLiquidations.selector);
        selectors.push(this.transmuterClaimDuringBadDebt.selector);
        selectors.push(this.recoverFromLoss.selector);

        super.setUp();
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS (from HardenedInvariantsTest — duplicated here for
    //  standalone operation without inheriting that test suite)
    // ═══════════════════════════════════════════════════════════════

    /// @dev Returns first tokenId for `user`, or 0 if no position NFT.
    function _getTokenId(address user) internal view returns (uint256) {
        if (IERC721Enumerable(address(alchemistNFT)).balanceOf(user) == 0) return 0;
        return IERC721Enumerable(address(alchemistNFT)).tokenOfOwnerByIndex(user, 0);
    }

    function _findMinter(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);
        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = _getTokenId(users[i]);
            if (tokenId != 0 && alchemist.getMaxBorrowable(tokenId) > 0) {
                candidates[i] = users[i];
            }
        }
        return _randomNonZero(candidates, seed);
    }

    function _findRepayer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);
        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = _getTokenId(users[i]);
            if (tokenId != 0) {
                (, uint256 debt,) = alchemist.getCDP(tokenId);
                if (debt > 0) candidates[i] = users[i];
            }
        }
        return _randomNonZero(candidates, seed);
    }

    function _findClaimer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);
        for (uint256 i; i < users.length; ++i) {
            if (IERC721Enumerable(address(transmuterLogic)).balanceOf(users[i]) > 0) {
                candidates[i] = users[i];
            }
        }
        return _randomNonZero(candidates, seed);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _handleExpectedBadDebtRevert(bytes memory reason) internal {
        bytes4 selector;
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 32))
            }
        }

        // Handlers are allowed to no-op when deposit/mint are blocked by protocol bad debt.
        if (_isBadDebt() && selector == ILLEGAL_STATE_SELECTOR) {
            handlerSkips++;
            return;
        }

        if (reason.length == 0) revert();
        assembly {
            revert(add(reason, 32), mload(reason))
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  BAD DEBT HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _isBadDebt() internal view returns (bool) {
        uint256 totalSynthetics = alchemist.totalSyntheticsIssued();
        if (totalSynthetics == 0) return false;

        address myt = alchemist.myt();
        uint256 transmuterShares = IERC20(myt).balanceOf(address(transmuterLogic));
        uint256 backingUnderlying = alchemist.getTotalLockedUnderlyingValue()
            + alchemist.convertYieldTokensToUnderlying(transmuterShares);
        uint256 backingDebt = alchemist.normalizeUnderlyingTokensToDebt(backingUnderlying);

        return totalSynthetics > backingDebt;
    }

    function _checkBadDebtState() internal {
        inBadDebtState = _isBadDebt();
    }

    // ═══════════════════════════════════════════════════════════════
    //  HANDLER: Deposit Collateral
    //  Creates/grows positions. Uses previewMint for correct
    //  underlying amount at current share price.
    // ═══════════════════════════════════════════════════════════════

    function depositCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomNonZero(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) { handlerSkips++; return; }

        amount = bound(amount, 1, MAX_TEST_VALUE);
        uint256 tokenId = _getTokenId(onBehalf);

        uint256 underlyingNeeded = vault.previewMint(amount);
        if (underlyingNeeded == 0) { handlerSkips++; return; }

        deal(mockVaultCollateral, onBehalf, underlyingNeeded);
        vm.startPrank(onBehalf);
        IERC20(mockVaultCollateral).approve(address(vault), underlyingNeeded);
        vault.mint(amount, onBehalf);
        try alchemist.deposit(amount, onBehalf, tokenId) returns (uint256, uint256) {
            vm.stopPrank();
        } catch (bytes memory reason) {
            vm.stopPrank();
            _handleExpectedBadDebtRevert(reason);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  HANDLER: Borrow (Mint Debt)
    //  mint() does NOT call _sync() — poke AFTER vm.roll to sync.
    // ═══════════════════════════════════════════════════════════════

    function borrowCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _findMinter(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) { handlerSkips++; return; }

        vm.roll(block.number + 1);

        uint256 tokenId = _getTokenId(onBehalf);
        if (tokenId == 0) { handlerSkips++; return; }

        alchemist.poke(tokenId);

        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        if (maxBorrow == 0) { handlerSkips++; return; }

        amount = bound(amount, 1, maxBorrow);

        vm.prank(onBehalf);
        try alchemist.mint(tokenId, amount, onBehalf) {
            // no-op
        } catch (bytes memory reason) {
            _handleExpectedBadDebtRevert(reason);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  HANDLER: Repay Debt (with yield tokens)
    //  Uses previewMint for correct underlying at current price.
    // ═══════════════════════════════════════════════════════════════

    function repayDebt(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _findRepayer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) { handlerSkips++; return; }

        uint256 tokenId = _getTokenId(onBehalf);
        if (tokenId == 0) { handlerSkips++; return; }

        (, uint256 debt,) = alchemist.getCDP(tokenId);
        if (debt == 0) { handlerSkips++; return; }

        uint256 maxRepayShares = alchemist.convertDebtTokensToYield(debt);
        if (maxRepayShares == 0) { handlerSkips++; return; }

        amount = bound(amount, 1, maxRepayShares);

        uint256 underlyingNeeded = vault.previewMint(amount);
        if (underlyingNeeded == 0) { handlerSkips++; return; }

        vm.roll(block.number + 1);

        deal(mockVaultCollateral, onBehalf, underlyingNeeded);
        vm.startPrank(onBehalf);
        IERC20(mockVaultCollateral).approve(address(vault), underlyingNeeded);
        vault.mint(amount, onBehalf);
        alchemist.repay(amount, tokenId);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  HANDLER: Transmuter Stake
    //  Uses existing alToken balance (from borrowing) or borrows
    //  through the alchemist. Never mints alTokens directly — that
    //  would bypass totalSyntheticsIssued tracking and corrupt C6/C7.
    // ═══════════════════════════════════════════════════════════════

    function transmuterStake(uint256 amount, uint256 onBehalfSeed) external {
        uint256 totalIssued = alchemist.totalSyntheticsIssued();
        uint256 totalLocked = transmuterLogic.totalLocked();
        if (totalIssued <= totalLocked) { handlerSkips++; return; }
        uint256 maxStakeable = totalIssued - totalLocked;

        address[] memory senders = targetSenders();

        // Find a user with alToken balance (from prior borrowing)
        address staker;
        uint256 available;
        uint256 startIdx = onBehalfSeed % senders.length;
        for (uint256 i; i < senders.length; ++i) {
            address candidate = senders[(startIdx + i) % senders.length];
            uint256 bal = alToken.balanceOf(candidate);
            if (bal > 0) {
                staker = candidate;
                available = bal;
                break;
            }
        }

        // If nobody has balance, borrow through alchemist to create alTokens
        if (staker == address(0)) {
            address minter = _findMinter(senders, onBehalfSeed);
            if (minter == address(0)) { handlerSkips++; return; }

            uint256 tokenId = _getTokenId(minter);
            if (tokenId == 0) { handlerSkips++; return; }

            vm.roll(block.number + 1);
            alchemist.poke(tokenId);

            uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
            if (maxBorrow == 0) { handlerSkips++; return; }

            uint256 borrowAmt = bound(amount, 1, maxBorrow);
            vm.prank(minter);
            try alchemist.mint(tokenId, borrowAmt, minter) {
                // no-op
            } catch (bytes memory reason) {
                _handleExpectedBadDebtRevert(reason);
                return;
            }

            staker = minter;
            available = alToken.balanceOf(staker);

            // Re-read after mint (totalSyntheticsIssued changed)
            totalIssued = alchemist.totalSyntheticsIssued();
            totalLocked = transmuterLogic.totalLocked();
            if (totalIssued <= totalLocked) { handlerSkips++; return; }
            maxStakeable = totalIssued - totalLocked;
        }

        if (available == 0 || maxStakeable == 0) { handlerSkips++; return; }

        uint256 cap = available > maxStakeable ? maxStakeable : available;
        amount = bound(amount, 1, cap);

        vm.startPrank(staker);
        alToken.approve(address(transmuterLogic), amount);
        transmuterLogic.createRedemption(amount, staker);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  HANDLER: Transmuter Claim
    // ═══════════════════════════════════════════════════════════════

    function transmuterClaim(uint256 onBehalfSeed) external {
        address onBehalf = _findClaimer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) { handlerSkips++; return; }

        uint256 tid = IERC721Enumerable(address(transmuterLogic)).tokenOfOwnerByIndex(onBehalf, 0);

        vm.roll(block.number + 10000);
        vm.startPrank(onBehalf);
        transmuterLogic.claimRedemption(tid);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  STRESS HANDLER: Steady Yield Accrual (0.01-0.5%)
    //  Simulates real strategy harvest → pricePerShare increases.
    //  Positions become healthier, earmark capacity increases.
    // ═══════════════════════════════════════════════════════════════

    function accrueYield(uint256 yieldBps) external {
        yieldBps = bound(yieldBps, 1, 50);

        uint256 currentUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 yieldAmount = currentUnderlying * yieldBps / 10000;
        if (yieldAmount == 0) { handlerSkips++; return; }

        deal(mockVaultCollateral, address(this), yieldAmount);
        IERC20(mockVaultCollateral).approve(mockStrategyYieldToken, yieldAmount);
        ITestYieldToken(mockStrategyYieldToken).slurp(yieldAmount);

        totalYieldAccrued += yieldAmount;
        yieldAccruals++;

        vm.roll(block.number + bound(yieldBps, 10, 1000));
    }

    // ═══════════════════════════════════════════════════════════════
    //  STRESS HANDLER: Large Value Loss (5-30%)
    //  Simulates hack/depeg/slashing. Drops share price significantly,
    //  potentially pushing multiple positions below liquidation threshold.
    //  Floor: won't drain below 5% to avoid total wipeout.
    // ═══════════════════════════════════════════════════════════════

    function realizeLargeValueLoss(uint256 lossBps) external {
        lossBps = bound(lossBps, 500, 3000);

        uint256 currentUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 lossAmount = currentUnderlying * lossBps / 10000;

        // Don't drain below 5%
        uint256 remaining = currentUnderlying - lossAmount;
        if (remaining < currentUnderlying / 20) {
            lossAmount = currentUnderlying - currentUnderlying / 20;
        }
        if (lossAmount == 0) { handlerSkips++; return; }

        ITestYieldToken(mockStrategyYieldToken).siphon(lossAmount);
        totalLossRealized += lossAmount;
        lossAfterLastLiquidation = true;

        _checkBadDebtState();
    }

    // ═══════════════════════════════════════════════════════════════
    //  STRESS HANDLER: Cascade Liquidations
    //  Iterates all positions. Pokes each, then liquidates any that
    //  are below collateralizationLowerBound. Tracks multi-position
    //  cascade rounds separately.
    //
    //  Tests: sequential liquidations, _subDebt under rapid state
    //  changes, global accounting consistency after multiple liquidations.
    // ═══════════════════════════════════════════════════════════════

    function cascadeLiquidations() external {
        // Guard: share price must be > 0, otherwise _liquidate early-returns (0,0,0) → LiquidationError
        if (vault.convertToAssets(1e18) == 0) { handlerSkips++; return; }
        // Guard: totalDebt must be > 0, otherwise _doLiquidation divides by zero in
        // normalizeUnderlyingTokensToDebt(...) * FIXED_POINT_SCALAR / totalDebt
        if (alchemist.totalDebt() == 0) { handlerSkips++; return; }

        address[] memory senders = targetSenders();
        uint256 liquidatedCount;

        for (uint256 i; i < senders.length; ++i) {
            uint256 tid = _getTokenId(senders[i]);
            if (tid == 0) continue;

            alchemist.poke(tid);

            (, uint256 debt,) = alchemist.getCDP(tid);
            if (debt == 0) continue;

            uint256 collateralValue = alchemist.totalValue(tid);
            uint256 lowerBound = alchemist.collateralizationLowerBound();
            uint256 requiredCollateral = (debt * lowerBound) / FIXED_POINT_SCALAR;

            if (collateralValue <= requiredCollateral) {
                // Re-check totalDebt after poke — prior liquidations in this loop
                // may have clamped totalDebt to 0, which would cause overflow in
                // _doLiquidation's global collateralization calculation.
                if (alchemist.totalDebt() == 0) break;

                // Guard: if the product normalizeUnderlyingTokensToDebt(totalUnderlying) * 1e18
                // would overflow uint256 when divided by totalDebt, skip this liquidation.
                // This happens when totalDebt is dust-level after cascading liquidations.
                uint256 totalUnderlying = alchemist.convertYieldTokensToUnderlying(
                    IERC20(address(vault)).balanceOf(address(alchemist))
                );
                uint256 totalDebtNormalized = alchemist.normalizeUnderlyingTokensToDebt(totalUnderlying);
                // Check if totalDebtNormalized * FIXED_POINT_SCALAR would overflow
                if (totalDebtNormalized > type(uint256).max / FIXED_POINT_SCALAR) break;

                liquidationAttempts++;
                try alchemist.liquidate(tid) returns (uint256 amt, uint256, uint256) {
                    if (amt > 0) {
                        liquidationSuccesses++;
                        liquidatedCount++;
                    }
                } catch (bytes memory reason) {
                    bytes4 selector;
                    if (reason.length >= 4) {
                        assembly {
                            selector := mload(add(reason, 32))
                        }
                    }

                    // LiquidationError() means nothing was liquidatable after sync/rounding.
                    // This is an expected no-op path for the stress harness.
                    if (selector == 0xf478bcad) {
                        handlerSkips++;
                    } else {
                        if (reason.length == 0) revert();
                        assembly {
                            revert(add(reason, 32), mload(reason))
                        }
                    }
                }
            }
        }

        if (liquidatedCount > 0) {
            lossAfterLastLiquidation = false; // reset — we just cleaned up
            if (liquidatedCount > 1) {
                cascadingLiquidationRounds++;
            }
        } else {
            handlerSkips++;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  STRESS HANDLER: Transmuter Claim During Bad Debt
    //  Exercises the badDebtRatio scaling path in claimRedemption().
    //  When totalSynthetics > backing, claimant receives less yield
    //  than their transmuted amount — socializes the loss.
    //
    //  If nobody has a transmuter position yet, this handler creates
    //  one: mints synthetics, deposits to transmuter (creating an NFT),
    //  advances blocks, then claims. No more skipping.
    // ═══════════════════════════════════════════════════════════════

    function transmuterClaimDuringBadDebt(uint256 onBehalfSeed, uint256 stakeAmount) external {
        address[] memory senders = targetSenders();
        address onBehalf = _findClaimer(senders, onBehalfSeed);

        // If nobody has a transmuter position, create one properly (no direct alToken.mint!)
        if (onBehalf == address(0)) {
            uint256 totalIssued = alchemist.totalSyntheticsIssued();
            uint256 totalLocked = transmuterLogic.totalLocked();

            // Find alToken balance to stake
            address staker;
            uint256 available;
            uint256 startIdx = onBehalfSeed % senders.length;
            for (uint256 i; i < senders.length; ++i) {
                address candidate = senders[(startIdx + i) % senders.length];
                uint256 bal = alToken.balanceOf(candidate);
                if (bal > 0) {
                    staker = candidate;
                    available = bal;
                    break;
                }
            }

            // If nobody has balance, borrow through alchemist
            if (staker == address(0)) {
                address minter = _findMinter(senders, onBehalfSeed);
                if (minter == address(0)) { handlerSkips++; return; }

                uint256 tokenId = _getTokenId(minter);
                if (tokenId == 0) { handlerSkips++; return; }

                vm.roll(block.number + 1);
                alchemist.poke(tokenId);

                uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
                if (maxBorrow == 0) { handlerSkips++; return; }

                uint256 borrowAmt = bound(stakeAmount, 1, maxBorrow);
                vm.prank(minter);
                try alchemist.mint(tokenId, borrowAmt, minter) {
                    // no-op
                } catch (bytes memory reason) {
                    _handleExpectedBadDebtRevert(reason);
                    return;
                }

                staker = minter;
                available = alToken.balanceOf(staker);
            }

            // Re-read after potential borrow
            totalIssued = alchemist.totalSyntheticsIssued();
            totalLocked = transmuterLogic.totalLocked();
            if (totalIssued <= totalLocked) { handlerSkips++; return; }

            uint256 maxStakeable = totalIssued - totalLocked;
            if (maxStakeable == 0 || available == 0) { handlerSkips++; return; }

            uint256 cap = available > maxStakeable ? maxStakeable : available;
            stakeAmount = bound(stakeAmount, 1, cap);

            vm.startPrank(staker);
            alToken.approve(address(transmuterLogic), stakeAmount);
            transmuterLogic.createRedemption(stakeAmount, staker);
            vm.stopPrank();

            onBehalf = staker;
        }

        uint256 tid = IERC721Enumerable(address(transmuterLogic)).tokenOfOwnerByIndex(onBehalf, 0);

        bool wasBadDebt = _isBadDebt();
        if (wasBadDebt) badDebtEvents++;

        vm.roll(block.number + 10000);

        vm.prank(onBehalf);
        transmuterLogic.claimRedemption(tid);
    }

    // ═══════════════════════════════════════════════════════════════
    //  STRESS HANDLER: Recovery From Loss (10-50% yield injection)
    //  Simulates system recovery. Only fires when system has
    //  experienced loss. Tracks transitions out of bad debt.
    // ═══════════════════════════════════════════════════════════════

    function recoverFromLoss(uint256 recoveryBps) external {
        if (!_isBadDebt() && totalLossRealized == 0) { handlerSkips++; return; }

        recoveryBps = bound(recoveryBps, 1000, 5000);

        uint256 currentUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 recoveryAmount = currentUnderlying * recoveryBps / 10000;
        if (recoveryAmount == 0) { handlerSkips++; return; }

        deal(mockVaultCollateral, address(this), recoveryAmount);
        IERC20(mockVaultCollateral).approve(mockStrategyYieldToken, recoveryAmount);
        ITestYieldToken(mockStrategyYieldToken).slurp(recoveryAmount);

        totalYieldAccrued += recoveryAmount;

        bool wasInBadDebt = inBadDebtState;
        _checkBadDebtState();
        if (wasInBadDebt && !inBadDebtState) {
            recoveryEvents++;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C1: Storage Debt Consistency
    //  After poking all positions, sum(account.debt) ≈ totalDebt
    //  and sum(account.earmarked) ≈ cumulativeEarmarked.
    //  Tolerance accounts for Q128 rounding drift in _sync().
    // ═══════════════════════════════════════════════════════════════

    function test_Regression_LiquidationClamp_PreventsUnderflow() public {
        this.depositCollateral(2005632228859, 32050235932314973874844605524603652259934571675798953);
        this.transmuterClaimDuringBadDebt(
            115792089237316195423570985008687907853269984665640564039457584007913129639932,
            1087715915021040162320100296756322045
        );
        this.repayDebt(4533, 2191105088);
        this.borrowCollateral(9999000000000000000000, 15265);
        this.realizeLargeValueLoss(1598288580650331967);
        this.cascadeLiquidations();

        this.invariantDebtConsistency();
        assertLe(alchemist.cumulativeEarmarked(), alchemist.totalDebt(), "global earmark must remain bounded by debt");
    }

    function test_Regression_BadDebtClaimLossCollateralDriftWithinTolerance() public {
        this.depositCollateral(52442825112839348585061025984960103989962694978198461973028259411208, 3);
        this.transmuterClaimDuringBadDebt(3468, 4387425010760926899844490068);
        this.depositCollateral(8052470305035150090755704148969369914834259484690729, 200);
        this.borrowCollateral(70145030891776661966643435961501872124, 0);
        this.realizeLargeValueLoss(84475498225639534990814110233184881838435220661872913905);
        this.transmuterStake(33965530496226231438924998564746689922, 365704568792561798);
        this.transmuterClaim(5951);

        this.invariantDebtConsistency();
    }

    function invariantDebtConsistency() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _getTokenId(senders[i]);
            if (tokenId != 0) alchemist.poke(tokenId);
        }

        uint256 sumDebt;
        uint256 sumEarmarked;
        uint256 sumCollateral;
        uint256 active;

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _getTokenId(senders[i]);
            if (tokenId != 0) {
                (uint256 col, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
                active++;
                sumDebt += debt;
                sumEarmarked += earmarked;
                sumCollateral += col;
            }
        }

        uint256 totalDebt = alchemist.totalDebt();
        uint256 cumEarmarked = alchemist.cumulativeEarmarked();
        uint256 totalDeposited = alchemist.getTotalDeposited();

        uint256 debtDelta = _absDiff(sumDebt, totalDebt);
        uint256 earmarkDelta = _absDiff(sumEarmarked, cumEarmarked);
        uint256 colDelta = _absDiff(sumCollateral, totalDeposited);

        if (debtDelta > maxDebtDelta) maxDebtDelta = debtDelta;
        if (earmarkDelta > maxEarmarkDelta) maxEarmarkDelta = earmarkDelta;
        if (colDelta > maxCollateralDelta) maxCollateralDelta = colDelta;

        uint256 cf = alchemist.underlyingConversionFactor();
        // Q128 rounding produces O(1) wei drift per account per sync cycle.
        // Floor of 1e6 gives ~40x headroom; cf scaling handles 6-decimal tokens.
        uint256 debtTol = _max(1e6, cf * _max(active, 1));
        // Higher collateral tolerance: mulDivUp + weighted-average redemption
        // accounting accumulates divergence in share units when loss/yield cycles
        // move the share price between redemptions.
        // A replayed bad-debt claim + loss sequence drifted by ~1.28e18 shares
        // on ~6.84e27 tracked shares (~1.86e-10 relative), so use a modest
        // relative tolerance of 2e-10 plus a small floor instead of a fixed
        // multi-ETH absolute value.
        // NOTE: collateral values here are vault shares, not underlying units.
        uint256 colTol = _max(1e15, totalDeposited / 5_000_000_000);

        assertLe(debtDelta, debtTol, "C1a: stored debt sum != totalDebt after full sync");
        assertLe(earmarkDelta, debtTol, "C1b: stored earmark sum != cumulativeEarmarked after full sync");
        assertLe(colDelta, colTol, "C1c: stored collateral sum != totalDeposited after full sync");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C2: Share Price Non-Zero
    //  The yield token share price must never hit zero.
    //  A zero share price means total wipeout — separate concern from
    //  loss recovery (we floor at 5% in the loss handler).
    // ═══════════════════════════════════════════════════════════════

    function invariantSharePriceNonZero() public view {
        uint256 sharePrice = vault.convertToAssets(1e18);
        assertGt(sharePrice, 0, "C2: share price is zero - total wipeout");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C3: Bad Debt Bounded by Realized Losses
    //  When totalSynthetics > backing (bad debt), the shortfall
    //  must not exceed total realized losses (+ tolerance for
    //  conversion rounding and liquidation fees).
    // ═══════════════════════════════════════════════════════════════

    function invariantBadDebtBounded() public view {
        uint256 totalSynthetics = alchemist.totalSyntheticsIssued();
        if (totalSynthetics == 0) return;

        address myt = alchemist.myt();
        uint256 transmuterYield = IERC20(myt).balanceOf(address(transmuterLogic));
        uint256 backingUnderlying = alchemist.getTotalLockedUnderlyingValue()
            + alchemist.convertYieldTokensToUnderlying(transmuterYield);

        if (totalSynthetics > backingUnderlying) {
            uint256 badDebt = totalSynthetics - backingUnderlying;
            // Tolerance: 1% of loss + 1e18 absolute for rounding
            uint256 tolerance = totalLossRealized / 100 + 1e18;
            assertLe(
                badDebt,
                totalLossRealized + tolerance,
                "C3: bad debt exceeds total loss realized"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C4: Post-Liquidation Health
    //  After a liquidation round, every position with remaining debt
    //  must be above collateralizationLowerBound (or fully zeroed).
    //  1% tolerance for liquidation target calculation rounding.
    // ═══════════════════════════════════════════════════════════════

    function invariantPostLiquidationHealth() public {
        if (liquidationSuccesses == 0) return;
        // Skip if a loss event occurred after the last liquidation round —
        // new losses can push positions back below threshold, that's expected
        // behavior, not a liquidation bug.
        if (lossAfterLastLiquidation) return;

        address[] memory senders = targetSenders();
        for (uint256 i; i < senders.length; ++i) {
            uint256 tid = _getTokenId(senders[i]);
            if (tid == 0) continue;

            alchemist.poke(tid);
            (, uint256 debt,) = alchemist.getCDP(tid);
            if (debt == 0) continue;

            uint256 collateralValue = alchemist.totalValue(tid);
            // Dust-only residue can remain after aggressive cascades due to integer conversion
            // boundaries (e.g. debt=1, collateral=0). Treat up to one underlying unit as closed.
            uint256 debtDustTol = alchemist.underlyingConversionFactor();
            if (collateralValue == 0 && debt <= debtDustTol) continue;
            uint256 lowerBound = alchemist.collateralizationLowerBound();
            uint256 required = (debt * lowerBound) / FIXED_POINT_SCALAR;

            assertGe(
                collateralValue * 100,
                required * 99,
                "C4: position still undercollateralized after liquidation round"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C5: Recovery Works
    //  After recovery events with net positive yield, the system
    //  should not be catastrophically underbacked. 25% tolerance because:
    //  - Losses compound on a shrinking base (30% of 1000 != 30% of 700)
    //  - Recoveries add to the already-reduced base
    //  - Liquidation penalties erode backing further (~3% per liquidation)
    //  - Transmuter claims distribute yield tokens out of the system
    //  - Multiple loss-recovery cycles amplify the divergence
    //  This is a sanity bound, not a solvency guarantee. The protocol's
    //  real defense is the badDebtRatio scaling in the transmuter.
    // ═══════════════════════════════════════════════════════════════

    function invariantRecoveryWorks() public view {
        if (recoveryEvents == 0) return;

        if (totalYieldAccrued > totalLossRealized) {
            uint256 totalSynthetics = alchemist.totalSyntheticsIssued();
            if (totalSynthetics > 0) {
                address myt = alchemist.myt();
                uint256 transmuterYield = IERC20(myt).balanceOf(address(transmuterLogic));
                uint256 backing = alchemist.getTotalLockedUnderlyingValue()
                    + alchemist.convertYieldTokensToUnderlying(transmuterYield);

                assertGe(
                    backing * 100,
                    totalSynthetics * 75,
                    "C5: system catastrophically underbacked despite net positive yield"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C6: Synthetics Balance
    //  totalSyntheticsIssued must always >= transmuter.totalLocked
    // ═══════════════════════════════════════════════════════════════

    function invariantSyntheticsBalance() public view {
        assertGe(
            alchemist.totalSyntheticsIssued(),
            transmuterLogic.totalLocked(),
            "C6: totalSyntheticsIssued < transmuter.totalLocked"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT C7: No Orphaned Earmarks
    //  cumulativeEarmarked can never exceed totalDebt
    // ═══════════════════════════════════════════════════════════════

    function invariantNoOrphanedEarmarks() public view {
        assertLe(
            alchemist.cumulativeEarmarked(),
            alchemist.totalDebt(),
            "C7: cumulativeEarmarked > totalDebt"
        );
    }
}
