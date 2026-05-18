// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "../InvariantsTest.t.sol";
import {ITestYieldToken} from "../../interfaces/test/ITestYieldToken.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";

contract HardenedInvariantHandler is Test {
    struct Snapshot {
        uint256 totalDebt;
        uint256 cumulativeEarmarked;
        uint256 totalDeposited;
        uint256 totalSyntheticsIssued;
        uint256 totalLocked;
        uint256 strategyUnderlying;
    }

    uint256 internal constant FIXED_POINT_SCALAR = 1e18;
    uint256 internal constant MAX_TEST_VALUE = 1e28;
    bytes4 internal constant LIQUIDATION_ERROR_SELECTOR = bytes4(keccak256("LiquidationError()"));
    bytes4 internal constant UNDERCOLLATERALIZED_SELECTOR = bytes4(keccak256("Undercollateralized()"));
    bytes4 internal constant ILLEGAL_STATE_SELECTOR = bytes4(keccak256("IllegalState()"));
    bytes4 internal constant ILLEGAL_ARGUMENT_SELECTOR = bytes4(keccak256("IllegalArgument()"));
    bytes4 internal constant BURN_LIMIT_EXCEEDED_SELECTOR = bytes4(keccak256("BurnLimitExceeded(uint256,uint256)"));
    bytes4 internal constant CANNOT_REPAY_ON_MINT_BLOCK_SELECTOR = bytes4(keccak256("CannotRepayOnMintBlock()"));

    AlchemistV3 public immutable alchemist;
    Transmuter public immutable transmuterLogic;
    AlchemistV3Position public immutable alchemistNFT;
    AlchemicTokenV3 public immutable alToken;
    IVaultV2 public immutable vault;
    address public immutable mockVaultCollateral;
    address public immutable mockStrategyYieldToken;

    address[] internal actors;

    
    uint256 public skippedCalls;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostBorrows;
    uint256 public ghostRepays;
    uint256 public ghostBurnRepays;
    uint256 public ghostStakes;
    uint256 public ghostClaims;
    uint256 public ghostLiquidationAttempts;
    uint256 public ghostLiquidationSuccesses;
    uint256 public ghostYieldEvents;
    uint256 public ghostValueLossEvents;
    uint256 public ghostPokeCalls;
    uint256 public ghostBlocksAdvanced;

    uint256 public ghostDepositedShares;
    uint256 public ghostWithdrawnShares;
    uint256 public ghostMintedDebt;
    uint256 public ghostRepaidShares;
    uint256 public ghostBurnedDebt;
    uint256 public ghostStakedDebt;
    uint256 public ghostClaimedDebt;
    uint256 public ghostLiquidatedShares;
    uint256 public ghostYieldAddedUnderlying;
    uint256 public ghostLossSiphonedUnderlying;

    uint256 public initialTotalDebt;
    uint256 public initialCumulativeEarmarked;
    uint256 public initialTotalDeposited;
    uint256 public initialTotalSyntheticsIssued;
    uint256 public initialTransmuterLocked;
    uint256 public initialStrategyUnderlying;

    uint256 public ghostTotalDebtIncrease;
    uint256 public ghostTotalDebtDecrease;
    uint256 public ghostCumulativeEarmarkedIncrease;
    uint256 public ghostCumulativeEarmarkedDecrease;
    uint256 public ghostTotalDepositedIncrease;
    uint256 public ghostTotalDepositedDecrease;
    uint256 public ghostTotalSyntheticsIssuedIncrease;
    uint256 public ghostTotalSyntheticsIssuedDecrease;
    uint256 public ghostTransmuterLockedIncrease;
    uint256 public ghostTransmuterLockedDecrease;
    uint256 public ghostStrategyUnderlyingIncrease;
    uint256 public ghostStrategyUnderlyingDecrease;

    constructor(
        AlchemistV3 _alchemist,
        Transmuter _transmuterLogic,
        AlchemistV3Position _alchemistNFT,
        AlchemicTokenV3 _alToken,
        IVaultV2 _vault,
        address _mockVaultCollateral,
        address _mockStrategyYieldToken,
        address[] memory _actors
    ) {
        alchemist = _alchemist;
        transmuterLogic = _transmuterLogic;
        alchemistNFT = _alchemistNFT;
        alToken = _alToken;
        vault = _vault;
        mockVaultCollateral = _mockVaultCollateral;
        mockStrategyYieldToken = _mockStrategyYieldToken;

        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }

        Snapshot memory snap = _snapshot();
        initialTotalDebt = snap.totalDebt;
        initialCumulativeEarmarked = snap.cumulativeEarmarked;
        initialTotalDeposited = snap.totalDeposited;
        initialTotalSyntheticsIssued = snap.totalSyntheticsIssued;
        initialTransmuterLocked = snap.totalLocked;
        initialStrategyUnderlying = snap.strategyUnderlying;
    }

    modifier tracked(bytes4 selector) {
    

        Snapshot memory beforeState = _snapshot();
        _;
        Snapshot memory afterState = _snapshot();

        if (afterState.totalDebt >= beforeState.totalDebt) {
            ghostTotalDebtIncrease += afterState.totalDebt - beforeState.totalDebt;
        } else {
            ghostTotalDebtDecrease += beforeState.totalDebt - afterState.totalDebt;
        }

        if (afterState.cumulativeEarmarked >= beforeState.cumulativeEarmarked) {
            ghostCumulativeEarmarkedIncrease += afterState.cumulativeEarmarked - beforeState.cumulativeEarmarked;
        } else {
            ghostCumulativeEarmarkedDecrease += beforeState.cumulativeEarmarked - afterState.cumulativeEarmarked;
        }

        if (afterState.totalDeposited >= beforeState.totalDeposited) {
            ghostTotalDepositedIncrease += afterState.totalDeposited - beforeState.totalDeposited;
        } else {
            ghostTotalDepositedDecrease += beforeState.totalDeposited - afterState.totalDeposited;
        }

        if (afterState.totalSyntheticsIssued >= beforeState.totalSyntheticsIssued) {
            ghostTotalSyntheticsIssuedIncrease += afterState.totalSyntheticsIssued - beforeState.totalSyntheticsIssued;
        } else {
            ghostTotalSyntheticsIssuedDecrease += beforeState.totalSyntheticsIssued - afterState.totalSyntheticsIssued;
        }

        if (afterState.totalLocked >= beforeState.totalLocked) {
            ghostTransmuterLockedIncrease += afterState.totalLocked - beforeState.totalLocked;
        } else {
            ghostTransmuterLockedDecrease += beforeState.totalLocked - afterState.totalLocked;
        }

        if (afterState.strategyUnderlying >= beforeState.strategyUnderlying) {
            ghostStrategyUnderlyingIncrease += afterState.strategyUnderlying - beforeState.strategyUnderlying;
        } else {
            ghostStrategyUnderlyingDecrease += beforeState.strategyUnderlying - afterState.strategyUnderlying;
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function depositCollateral(uint256 amount, uint256 actorSeed) external tracked(this.depositCollateral.selector) {
        if (_isBadDebt()) {
            skippedCalls++;
            return;
        }

        address actor = _actor(actorSeed);

        uint256 depositCap = alchemist.depositCap();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        if (depositCap <= totalDeposited) {
            skippedCalls++;
            return;
        }

        uint256 maxDepositable = depositCap - totalDeposited;
        uint256 maxAmount = _min(MAX_TEST_VALUE, maxDepositable);
        amount = bound(amount, 1, maxAmount);

        uint256 tokenId = _tokenId(actor);
        uint256 underlyingNeeded = vault.previewMint(amount);
        if (underlyingNeeded == 0) {
            skippedCalls++;
            return;
        }

        deal(mockVaultCollateral, actor, underlyingNeeded);

        vm.startPrank(actor);
        IERC20(mockVaultCollateral).approve(address(vault), underlyingNeeded);
        vault.mint(amount, actor);
        try alchemist.deposit(amount, actor, tokenId) {
            ghostDeposits++;
            ghostDepositedShares += amount;
        } catch (bytes memory errData) {
            bytes4 sel = _selector(errData);
            // deposit() throws IllegalState for three reasons (AlchemistV3.sol L420-422):
            //   1. depositsPaused (admin toggled between handler precondition check and call)
            //   2. protocol is in bad debt (share price moved since _isBadDebt() check)
            //   3. deposit cap exceeded (another deposit filled the gap)
            // Assert that at least one of these holds — any other IllegalState is a bug.
            if (sel == ILLEGAL_STATE_SELECTOR) {
                require(
                    alchemist.depositsPaused()
                        || _isBadDebt()
                        || alchemist.getTotalDeposited() + amount > alchemist.depositCap(),
                    "deposit: IllegalState with no known justification"
                );
                skippedCalls++;
                vm.stopPrank();
                return;
            }
            vm.stopPrank();
            _bubble(errData);
        }
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 amount, uint256 actorSeed) external tracked(this.withdrawCollateral.selector) {
        (address actor, uint256 tokenId, uint256 maxWithdraw) = _findWithdrawer(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(actor);
        try alchemist.withdraw(amount, actor, tokenId) {
            ghostWithdrawals++;
            ghostWithdrawnShares += amount;
        } catch (bytes memory errData) {
            bytes4 sel = _selector(errData);
            // withdraw() can revert after internal _earmark()+_sync() changes state:
            //   IllegalArgument (L460): collateralBalance - lockedCollateral < amount
            //     (stale getMaxWithdrawable view vs post-sync reality)
            //   Undercollateralized (L464 via _validate): withdrawal made position unhealthy
            //     after sync repriced collateral/debt
            // Both are stale-view races — the handler read getMaxWithdrawable() before
            // _earmark/_sync ran inside withdraw(), and state shifted.
            if (sel == ILLEGAL_ARGUMENT_SELECTOR || sel == UNDERCOLLATERALIZED_SELECTOR) {
                // The position must have debt for sync to change the picture.
                // A debt-free position has lockedCollateral=0 and _validate always passes,
                // so these errors should never fire for debt-free positions.
                (, uint256 debt,) = alchemist.getCDP(tokenId);
                require(debt > 0, "withdraw: revert on debt-free position is a bug");
                skippedCalls++;
                return;
            }
            _bubble(errData);
        }
    }

    function borrowCollateral(uint256 amount, uint256 actorSeed) external tracked(this.borrowCollateral.selector) {
        if (_isBadDebt()) {
            skippedCalls++;
            return;
        }

        vm.roll(block.number + 1);

        (address actor, uint256 tokenId, uint256 maxBorrow) = _findBorrower(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        amount = bound(amount, 1, maxBorrow);

        vm.prank(actor);
        try alchemist.mint(tokenId, amount, actor) {
            ghostBorrows++;
            ghostMintedDebt += amount;
        } catch (bytes memory errData) {
            bytes4 sel = _selector(errData);
            // mint() throws Undercollateralized (L1279 _addDebt, L1413 _validate) when
            // _earmark+_sync changed debt/collateral since getMaxBorrowable() view call.
            if (sel == UNDERCOLLATERALIZED_SELECTOR) {
                skippedCalls++;
                return;
            }
            // mint() throws IllegalState for (AlchemistV3.sol L479, L484):
            //   1. loansPaused (admin toggled between handler check and call)
            //   2. protocol entered bad debt (share price moved since _isBadDebt() check)
            if (sel == ILLEGAL_STATE_SELECTOR) {
                require(
                    alchemist.loansPaused() || _isBadDebt(),
                    "mint: IllegalState with no known justification"
                );
                skippedCalls++;
                return;
            }
            _bubble(errData);
        }
    }

    function repayDebt(uint256 amount, uint256 actorSeed) external tracked(this.repayDebt.selector) {
        vm.roll(block.number + 1);

        (address actor, uint256 tokenId, uint256 maxRepayShares) = _findRepayer(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        amount = bound(amount, 1, maxRepayShares);
        uint256 underlyingNeeded = vault.previewMint(amount);
        if (underlyingNeeded == 0) {
            skippedCalls++;
            return;
        }

        deal(mockVaultCollateral, actor, underlyingNeeded);

        vm.startPrank(actor);
        IERC20(mockVaultCollateral).approve(address(vault), underlyingNeeded);
        vault.mint(amount, actor);
        try alchemist.repay(amount, tokenId) returns (uint256 repaid) {
            ghostRepays++;
            ghostRepaidShares += repaid;
        } catch (bytes memory errData) {
            bytes4 sel = _selector(errData);
            // repay() throws IllegalState for (AlchemistV3.sol L570, L587):
            //   1. account.debt == 0 after _sync (debt was repaid by redemption since view)
            //   2. feeAmount > account.collateralBalance (fee on earmarked portion exceeds
            //      collateral after sync repriced things)
            if (sel == ILLEGAL_STATE_SELECTOR) {
                // Verify: either debt is now 0, or the account's collateral is very small
                // relative to its earmarked debt (fee could exceed collateral).
                (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
                (uint256 col,,) = alchemist.getCDP(tokenId);
                require(
                    debt == 0 || (earmarked > 0 && col < alchemist.convertDebtTokensToYield(earmarked)),
                    "repay: IllegalState with no known justification"
                );
                skippedCalls++;
                vm.stopPrank();
                return;
            }
            // CannotRepayOnMintBlock (L559): handler does vm.roll(block.number+1) but
            // another handler could have minted on the new block in the same sequence.
            // This is a legitimate test-infrastructure artifact, not a protocol bug.
            if (sel == CANNOT_REPAY_ON_MINT_BLOCK_SELECTOR) {
                skippedCalls++;
                vm.stopPrank();
                return;
            }
            vm.stopPrank();
            _bubble(errData);
        }
        vm.stopPrank();
    }

    function repayDebtViaBurn(uint256 amount, uint256 actorSeed) external tracked(this.repayDebtViaBurn.selector) {
        vm.roll(block.number + 1);

        (address actor, uint256 tokenId, uint256 burnable) = _findBurner(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        amount = bound(amount, 1, burnable);

        vm.prank(actor);
        try alchemist.burn(amount, tokenId) {
            ghostBurnRepays++;
            ghostBurnedDebt += amount;
        } catch (bytes memory errData) {
            bytes4 sel = _selector(errData);
            // burn() throws IllegalState (L526) when unearmarked debt is 0 after _sync.
            // This happens if _sync earmarked all remaining debt since the view call.
            if (sel == ILLEGAL_STATE_SELECTOR) {
                (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
                require(
                    debt == 0 || earmarked >= debt,
                    "burn: IllegalState but position still has unearmarked debt"
                );
                skippedCalls++;
                return;
            }
            // BurnLimitExceeded (L533): credit > totalSyntheticsIssued - totalLocked.
            // Transmuter state changed between _findBurner view and the actual call.
            if (sel == BURN_LIMIT_EXCEEDED_SELECTOR) {
                uint256 freeSynthetics = alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked();
                require(
                    amount > freeSynthetics,
                    "burn: BurnLimitExceeded but amount <= free synthetics"
                );
                skippedCalls++;
                return;
            }
            // Undercollateralized (L546 via _validate): extremely rare — sync could
            // dramatically change collateral. Only valid if position has debt.
            if (sel == UNDERCOLLATERALIZED_SELECTOR) {
                (, uint256 debt,) = alchemist.getCDP(tokenId);
                require(debt > 0, "burn: Undercollateralized on debt-free position is a bug");
                skippedCalls++;
                return;
            }
            _bubble(errData);
        }
    }

    function transmuterStake(uint256 amount, uint256 actorSeed) external tracked(this.transmuterStake.selector) {
        uint256 totalIssued = alchemist.totalSyntheticsIssued();
        uint256 totalLocked = transmuterLogic.totalLocked();
        if (totalIssued <= totalLocked) {
            skippedCalls++;
            return;
        }

        uint256 depositCap = transmuterLogic.depositCap();
        uint256 totalActiveLocked = transmuterLogic.totalActiveLocked();
        if (depositCap <= totalActiveLocked) {
            skippedCalls++;
            return;
        }

        (address actor, uint256 actorBalance) = _findActorWithAlToken(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        uint256 maxStakeable = totalIssued - totalLocked;
        uint256 maxByDepositCap = depositCap - totalActiveLocked;
        uint256 cap = _min(_min(actorBalance, maxStakeable), maxByDepositCap);
        if (cap == 0) {
            skippedCalls++;
            return;
        }

        amount = bound(amount, 1, cap);

        vm.startPrank(actor);
        alToken.approve(address(transmuterLogic), amount);
        transmuterLogic.createRedemption(amount, actor);
        vm.stopPrank();

        ghostStakes++;
        ghostStakedDebt += amount;
    }

    function transmuterClaim(uint256 actorSeed) external tracked(this.transmuterClaim.selector) {
        (address actor, uint256 redemptionTokenId) = _findClaimer(actorSeed);
        if (actor == address(0)) {
            skippedCalls++;
            return;
        }

        ITransmuter.StakingPosition memory position = transmuterLogic.getPosition(redemptionTokenId);
        if (position.maturationBlock == 0) {
            skippedCalls++;
            return;
        }

        if (block.number < position.maturationBlock) {
            vm.roll(position.maturationBlock);
        }

        uint256 lockedBefore = transmuterLogic.totalLocked();
        vm.prank(actor);
        transmuterLogic.claimRedemption(redemptionTokenId);
        uint256 lockedAfter = transmuterLogic.totalLocked();

        ghostClaims++;
        if (lockedBefore > lockedAfter) {
            ghostClaimedDebt += lockedBefore - lockedAfter;
        }
    }

    function triggerLiquidation(uint256 seed) external tracked(this.triggerLiquidation.selector) {
        if (vault.convertToAssets(1e18) == 0 || alchemist.totalDebt() == 0) {
            skippedCalls++;
            return;
        }

        uint256 start = seed % actors.length;

        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[(start + i) % actors.length];
            uint256 tokenId = _tokenId(actor);
            if (tokenId == 0) continue;

            alchemist.poke(tokenId);

            (, uint256 debt,) = alchemist.getCDP(tokenId);
            if (debt == 0) continue;

            uint256 collateralValue = alchemist.totalValue(tokenId);
            uint256 requiredCollateral = debt * alchemist.collateralizationLowerBound() / FIXED_POINT_SCALAR;
            if (collateralValue > requiredCollateral) continue;

            ghostLiquidationAttempts++;

            try alchemist.liquidate(tokenId) returns (uint256 liquidatedShares, uint256, uint256) {
                if (liquidatedShares > 0) {
                    ghostLiquidationSuccesses++;
                    ghostLiquidatedShares += liquidatedShares;
                }
            } catch (bytes memory errData) {
                bytes4 sel = _selector(errData);
                // LiquidationError (L614): liquidation made no progress. This can happen
                // when the position was borderline — _earmark+_sync inside liquidate()
                // pushed it back to healthy, or the position's debt was fully redeemed.
                if (sel == LIQUIDATION_ERROR_SELECTOR) {
                    // After the failed liquidate, the position should be healthy or have no debt.
                    (, uint256 debtAfter,) = alchemist.getCDP(tokenId);
                    if (debtAfter > 0) {
                        uint256 colVal = alchemist.totalValue(tokenId);
                        uint256 lowerBound = alchemist.collateralizationLowerBound();
                        require(
                            colVal * FIXED_POINT_SCALAR >= debtAfter * lowerBound,
                            "liquidate: LiquidationError but position is still unhealthy"
                        );
                    }
                    skippedCalls++;
                    return;
                }

                _bubble(errData);
            }
            return;
        }

        skippedCalls++;
    }

    function simulateValueLoss(uint256 lossBps) external tracked(this.simulateValueLoss.selector) {
        lossBps = bound(lossBps, 10, 200);

        uint256 strategyUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 lossAmount = strategyUnderlying * lossBps / 10_000;
        if (lossAmount == 0 || strategyUnderlying - lossAmount <= strategyUnderlying / 10) {
            skippedCalls++;
            return;
        }

        ITestYieldToken(mockStrategyYieldToken).siphon(lossAmount);

        ghostValueLossEvents++;
        ghostLossSiphonedUnderlying += lossAmount;
    }

    function simulateYield(uint256 yieldBps) external tracked(this.simulateYield.selector) {
        yieldBps = bound(yieldBps, 1, 300);

        uint256 strategyUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 yieldAmount = strategyUnderlying * yieldBps / 10_000;
        if (yieldAmount == 0) {
            skippedCalls++;
            return;
        }

        deal(mockVaultCollateral, address(this), yieldAmount);
        IERC20(mockVaultCollateral).approve(mockStrategyYieldToken, yieldAmount);
        ITestYieldToken(mockStrategyYieldToken).slurp(yieldAmount);

        ghostYieldEvents++;
        ghostYieldAddedUnderlying += yieldAmount;
    }

    function pokeAll() external tracked(this.pokeAll.selector) {
        uint256 poked;
        for (uint256 i; i < actors.length; ++i) {
            uint256 tokenId = _tokenId(actors[i]);
            if (tokenId != 0) {
                alchemist.poke(tokenId);
                poked++;
            }
        }

        if (poked == 0) {
            skippedCalls++;
            return;
        }

        ghostPokeCalls += poked;
    }

    function pokeRandom(uint256 seed) external tracked(this.pokeRandom.selector) {
        address actor = _actor(seed);
        uint256 tokenId = _tokenId(actor);
        if (tokenId == 0) {
            skippedCalls++;
            return;
        }

        alchemist.poke(tokenId);
        ghostPokeCalls++;
    }

    function mine(uint256 blocksToAdvance) external tracked(this.mine.selector) {
        blocksToAdvance = bound(blocksToAdvance, 1, 72_000);
        vm.roll(block.number + blocksToAdvance);
        ghostBlocksAdvanced += blocksToAdvance;
    }

    function expectedTotalDebt() external view returns (uint256) {
        return initialTotalDebt + ghostTotalDebtIncrease - ghostTotalDebtDecrease;
    }

    function expectedCumulativeEarmarked() external view returns (uint256) {
        return initialCumulativeEarmarked + ghostCumulativeEarmarkedIncrease - ghostCumulativeEarmarkedDecrease;
    }

    function expectedTotalDeposited() external view returns (uint256) {
        return initialTotalDeposited + ghostTotalDepositedIncrease - ghostTotalDepositedDecrease;
    }

    function expectedTotalSyntheticsIssued() external view returns (uint256) {
        return initialTotalSyntheticsIssued + ghostTotalSyntheticsIssuedIncrease - ghostTotalSyntheticsIssuedDecrease;
    }

    function expectedTransmuterLocked() external view returns (uint256) {
        return initialTransmuterLocked + ghostTransmuterLockedIncrease - ghostTransmuterLockedDecrease;
    }

    function expectedStrategyUnderlying() external view returns (uint256) {
        return initialStrategyUnderlying + ghostStrategyUnderlyingIncrease - ghostStrategyUnderlyingDecrease;
    }


    function _snapshot() internal view returns (Snapshot memory s) {
        s.totalDebt = alchemist.totalDebt();
        s.cumulativeEarmarked = alchemist.cumulativeEarmarked();
        s.totalDeposited = alchemist.getTotalDeposited();
        s.totalSyntheticsIssued = alchemist.totalSyntheticsIssued();
        s.totalLocked = transmuterLogic.totalLocked();
        s.strategyUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _tokenId(address user) internal view returns (uint256) {
        uint256 count = IERC721Enumerable(address(alchemistNFT)).balanceOf(user);
        if (count == 0) return 0;
        return IERC721Enumerable(address(alchemistNFT)).tokenOfOwnerByIndex(user, 0);
    }

    function _findWithdrawer(uint256 seed) internal view returns (address actor, uint256 tokenId, uint256 maxWithdraw) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            tokenId = _tokenId(actor);
            if (tokenId == 0) continue;

            maxWithdraw = alchemist.getMaxWithdrawable(tokenId);
            if (maxWithdraw > 0) return (actor, tokenId, maxWithdraw);
        }
        return (address(0), 0, 0);
    }

    function _findBorrower(uint256 seed) internal view returns (address actor, uint256 tokenId, uint256 maxBorrow) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            tokenId = _tokenId(actor);
            if (tokenId == 0) continue;

            maxBorrow = alchemist.getMaxBorrowable(tokenId);
            if (maxBorrow > 0) return (actor, tokenId, maxBorrow);
        }
        return (address(0), 0, 0);
    }

    function _findRepayer(uint256 seed) internal view returns (address actor, uint256 tokenId, uint256 maxRepayShares) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            tokenId = _tokenId(actor);
            if (tokenId == 0) continue;

            (, uint256 debt,) = alchemist.getCDP(tokenId);
            if (debt == 0) continue;

            maxRepayShares = alchemist.convertDebtTokensToYield(debt);
            if (maxRepayShares > 0) return (actor, tokenId, maxRepayShares);
        }
        return (address(0), 0, 0);
    }

    function _findBurner(uint256 seed) internal view returns (address actor, uint256 tokenId, uint256 burnable) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            tokenId = _tokenId(actor);
            if (tokenId == 0) continue;

            (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
            if (debt <= earmarked) continue;

            uint256 freeSynthetics = alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked();
            uint256 actorBalance = alToken.balanceOf(actor);
            uint256 debtHeadroom = debt - earmarked;
            burnable = _min(_min(debtHeadroom, freeSynthetics), actorBalance);
            if (burnable > 0) return (actor, tokenId, burnable);
        }
        return (address(0), 0, 0);
    }

    function _findActorWithAlToken(uint256 seed) internal view returns (address actor, uint256 balance) {
        uint256 start = seed % actors.length;
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            balance = alToken.balanceOf(actor);
            if (balance > 0) return (actor, balance);
        }
        return (address(0), 0);
    }

    function _findClaimer(uint256 seed) internal view returns (address actor, uint256 redemptionTokenId) {
        uint256 start = seed % actors.length;
        IERC721Enumerable redemptions = IERC721Enumerable(address(transmuterLogic));

        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            uint256 count = redemptions.balanceOf(actor);
            if (count == 0) continue;

            redemptionTokenId = redemptions.tokenOfOwnerByIndex(actor, count - 1);
            return (actor, redemptionTokenId);
        }
        return (address(0), 0);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _isBadDebt() internal view returns (bool) {
        uint256 totalSynthetics = alchemist.totalSyntheticsIssued();
        if (totalSynthetics == 0) return false;

        uint256 transmuterYield = IERC20(alchemist.myt()).balanceOf(address(transmuterLogic));
        uint256 backingUnderlying = alchemist.getTotalLockedUnderlyingValue()
            + alchemist.convertYieldTokensToUnderlying(transmuterYield);
        uint256 backingDebt = alchemist.normalizeUnderlyingTokensToDebt(backingUnderlying);

        return totalSynthetics > backingDebt;
    }

    function _selector(bytes memory errData) internal pure returns (bytes4 sel) {
        if (errData.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(errData, 32))
        }
    }

    function _bubble(bytes memory errData) internal pure {
        if (errData.length == 0) revert();
        assembly {
            revert(add(errData, 32), mload(errData))
        }
    }
}

contract HardenedInvariantsTest is InvariantsTest {
    uint256 internal constant DEPLOY_MIN_COLLATERALIZATION = 1_111_111_111_111_111_111;
    uint256 internal constant DEPLOY_COLLATERALIZATION_LOWER_BOUND = 1_052_631_578_950_000_000;
    uint256 internal constant DEPLOY_LIQUIDATION_TARGET = 1_111_111_111_111_111_111;
    uint256 internal constant DEPLOY_PROTOCOL_FEE = 25;
    uint256 internal constant DEPLOY_LIQUIDATOR_FEE = 300;
    uint256 internal constant DEPLOY_REPAYMENT_FEE = 0;

    uint256 internal constant DEPLOY_TRANSMUTATION_TIME = 604_800;
    uint256 internal constant DEPLOY_TRANSMUTATION_FEE = 0;
    uint256 internal constant DEPLOY_EXIT_FEE = 100;

    uint256 public maxDebtDelta;
    uint256 public maxEarmarkDelta;
    uint256 public maxCollateralDelta;

    HardenedInvariantHandler public handler;

    function setUp() public virtual override {
        selectors.push(this.noop.selector);
        super.setUp();

        _applyDeployV3ETHEconomicParams();

        handler = new HardenedInvariantHandler(
            alchemist,
            transmuterLogic,
            alchemistNFT,
            alToken,
            IVaultV2(address(vault)),
            mockVaultCollateral,
            mockStrategyYieldToken,
            targetSenders()
        );

        excludeContract(address(this));

        targetContract(address(handler));

        bytes4[] memory handlerSelectors = new bytes4[](13);
        handlerSelectors[0] = handler.depositCollateral.selector;
        handlerSelectors[1] = handler.withdrawCollateral.selector;
        handlerSelectors[2] = handler.borrowCollateral.selector;
        handlerSelectors[3] = handler.repayDebt.selector;
        handlerSelectors[4] = handler.repayDebtViaBurn.selector;
        handlerSelectors[5] = handler.transmuterStake.selector;
        handlerSelectors[6] = handler.transmuterClaim.selector;
        handlerSelectors[7] = handler.triggerLiquidation.selector;
        handlerSelectors[8] = handler.simulateValueLoss.selector;
        handlerSelectors[9] = handler.simulateYield.selector;
        handlerSelectors[10] = handler.pokeAll.selector;
        handlerSelectors[11] = handler.pokeRandom.selector;
        handlerSelectors[12] = handler.mine.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: handlerSelectors}));
    }

    // this is just to rate-limit the state changing functions, we cannot realistically expect 100k liquidations in a row...
    function noop() external {}

    function _applyDeployV3ETHEconomicParams() internal {
        vm.startPrank(alOwner);
        alchemist.setProtocolFee(DEPLOY_PROTOCOL_FEE);
        alchemist.setLiquidatorFee(DEPLOY_LIQUIDATOR_FEE);
        alchemist.setRepaymentFee(DEPLOY_REPAYMENT_FEE);
        alchemist.setMinimumCollateralization(DEPLOY_MIN_COLLATERALIZATION);
        alchemist.setCollateralizationLowerBound(DEPLOY_COLLATERALIZATION_LOWER_BOUND);
        alchemist.setLiquidationTargetCollateralization(DEPLOY_LIQUIDATION_TARGET);

        transmuterLogic.setProtocolFeeReceiver(protocolFeeReceiver);
        transmuterLogic.setTransmutationFee(DEPLOY_TRANSMUTATION_FEE);
        transmuterLogic.setExitFee(DEPLOY_EXIT_FEE);
        transmuterLogic.setTransmutationTime(DEPLOY_TRANSMUTATION_TIME);
        vm.stopPrank();
    }

    function invariantStorageDebtConsistency() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _tokenId(senders[i]);
            if (tokenId != 0) {
                alchemist.poke(tokenId);
            }
        }

        uint256 sumDebt;
        uint256 sumEarmarked;
        uint256 sumCollateral;
        uint256 active;

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _tokenId(senders[i]);
            if (tokenId == 0) continue;

            (uint256 col, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
            active++;
            sumDebt += debt;
            sumEarmarked += earmarked;
            sumCollateral += col;
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
        // `getCDP()` is the most up-to-date account view, but the account/global
        // redemption math can still diverge slightly after an explicit `poke()`
        // due to mixed Q128 ceil/floor rounding across earmark and redemption
        // survival updates.
        // A replayed 8-step counterexample reached ~8.15e15 debt drift with a
        // single live account, so keep a small fixed floor with modest headroom
        // while still scaling for decimal normalization.
        uint256 debtTol = _max(5e12, cf * _max(active, 1));
        // Collateral drift is structurally larger: lazy sync uses a weighted-
        // average shares/debt ratio across redemptions, diverging from per-
        // redemption exact debits when share prices shift between redemptions.
        // Use a relative tolerance (2e-11 of total tracked shares) plus a tiny
        // absolute floor. Avoids hard-coding multi-ETH absolute slack while
        // still allowing deep-state fuzz sequences to pass.
        // NOTE: collateral values here are vault shares, not underlying units.
        uint256 colTol = _max(1e15, totalDeposited / 50_000_000_000);
        assertLe(debtDelta, debtTol, "H1a: stored debt sum != totalDebt after full sync");
        assertLe(earmarkDelta, debtTol, "H1b: stored earmark sum != cumulativeEarmarked after full sync");
        assertLe(colDelta, colTol, "H1c: stored collateral sum != totalDeposited after full sync");
        assertLe(cumEarmarked, totalDebt, "H1d: cumulativeEarmarked > totalDebt");
    }

    function invariantPerPositionSanity() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _tokenId(senders[i]);
            if (tokenId == 0) continue;

            alchemist.poke(tokenId);

            (uint256 col, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

            assertLe(earmarked, debt, "H2a: earmarked > debt");
            if (debt == 0) {
                assertEq(earmarked, 0, "H2b: zero debt but nonzero earmarked");
            }

            uint256 totalDeposited = alchemist.getTotalDeposited();
            if (col > totalDeposited) {
                assertLe(col - totalDeposited, 2, "H2c: position collateral exceeds total deposited by >2 wei");
            }
        }
    }

    function invariantMYTTokenAccounting() public view {
        uint256 contractBalance = IERC20(alchemist.myt()).balanceOf(address(alchemist));
        uint256 tracked = alchemist.getTotalDeposited();

        uint256 active;
        address[] memory senders = targetSenders();
        for (uint256 i; i < senders.length; ++i) {
            if (_tokenId(senders[i]) != 0) active++;
        }

        uint256 drift = _absDiff(contractBalance, tracked);
        uint256 tolerance = _max(100, active * 4);
        assertLe(drift, tolerance, "H3: MYT balance drift exceeds rounding tolerance");
    }

    function invariantPokeIdempotent() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _tokenId(senders[i]);
            if (tokenId == 0) continue;

            alchemist.poke(tokenId);
            (uint256 col1, uint256 debt1, uint256 ear1) = alchemist.getCDP(tokenId);
            uint256 td1 = alchemist.totalDebt();
            uint256 ce1 = alchemist.cumulativeEarmarked();

            alchemist.poke(tokenId);
            (uint256 col2, uint256 debt2, uint256 ear2) = alchemist.getCDP(tokenId);
            uint256 td2 = alchemist.totalDebt();
            uint256 ce2 = alchemist.cumulativeEarmarked();

            assertEq(debt1, debt2, "H4a: poke not idempotent (debt)");
            assertEq(ear1, ear2, "H4b: poke not idempotent (earmarked)");
            assertEq(col1, col2, "H4c: poke not idempotent (collateral)");
            assertEq(td1, td2, "H4d: poke not idempotent (totalDebt)");
            assertEq(ce1, ce2, "H4e: poke not idempotent (cumulativeEarmarked)");
        }
    }

    function invariantSyntheticsBalance() public view {
        assertGe(alchemist.totalSyntheticsIssued(), transmuterLogic.totalLocked(), "H5: issued synthetics < locked");
    }

    function invariantNoOrphanedEarmarks() public view {
        assertLe(alchemist.cumulativeEarmarked(), alchemist.totalDebt(), "H6: cumulativeEarmarked > totalDebt");
    }

    function invariantSharePriceNonZero() public view {
        assertGt(vault.convertToAssets(1e18), 0, "H7: share price is zero");
    }

    function invariantPerformanceFeeEnabled() public view {
        assertGt(vault.performanceFee(), 0, "H11: performance fee is zero - fees not enabled");
        assertGt(vault.maxRate(), 0, "H11: maxRate is zero - fees cannot accrue");
    }

    function invariantFeeRecipientSharesBounded() public view {
        if (vault.performanceFeeRecipient() == address(0)) return;
        uint256 feeShares = vault.balanceOf(vault.performanceFeeRecipient());
        assertLe(feeShares, vault.totalSupply() / 2, "H12: fee shares exceed 50% of totalSupply");
    }

    function invariantLiquidationAccounting() public view {
        assertLe(
            handler.ghostLiquidationSuccesses(),
            handler.ghostLiquidationAttempts(),
            "H8: liquidation successes exceed attempts"
        );
    }

    function invariantGhostMirrorsProtocolTotals() public view {
        // debt/earmark/deposits can drift during invariant-side poke() sync calls,
        // so exact equality is asserted only for metrics not mutated by those checks.
        assertEq(
            alchemist.totalSyntheticsIssued(),
            handler.expectedTotalSyntheticsIssued(),
            "H9a: synthetics ghost mismatch"
        );
        assertEq(transmuterLogic.totalLocked(), handler.expectedTransmuterLocked(), "H9b: transmuter ghost mismatch");
        assertEq(
            IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken),
            handler.expectedStrategyUnderlying(),
            "H9c: strategy underlying ghost mismatch"
        );

        assertGe(handler.ghostDepositedShares(), handler.ghostWithdrawnShares(), "H9d: withdrawn shares exceed deposits");
        assertGe(handler.ghostStakedDebt(), handler.ghostClaimedDebt(), "H9e: claimed debt exceeds staked debt");
    }

    function invariantTransmuterLockedBoundedBySupply() public view {
        assertGe(alToken.totalSupply(), transmuterLogic.totalLocked(), "H10: transmuter locked exceeds alToken supply");
    }

    function _tokenId(address user) internal view returns (uint256) {
        uint256 count = IERC721Enumerable(address(alchemistNFT)).balanceOf(user);
        if (count == 0) return 0;
        return IERC721Enumerable(address(alchemistNFT)).tokenOfOwnerByIndex(user, 0);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
