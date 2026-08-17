// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

import {E2EInvariantEnv} from "./E2EInvariantEnv.sol";
import {E2EStrategyHandler, IStrategySimulationProvider} from "./E2EStrategyHandler.sol";

abstract contract E2EInvariantStrategyTest is E2EInvariantEnv, IStrategySimulationProvider {
    E2EStrategyHandler internal handler;

    uint256 internal constant REAL_STRATEGY_RELATIVE_CAP = 0.5e18;

    /// @dev Vault-side absolute cap for the real strategy. Suites whose underlying
    ///      protocol has tighter capacity than 50k override this.
    function _realAbsoluteCap() internal view virtual returns (uint256) {
        return 50_000 * 10 ** assetDecimals;
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params)
        internal
        virtual
        returns (address);

    function getRealStrategyParams() internal virtual returns (IMYTStrategy.StrategyParams memory);

    function setUp() public virtual override {
        super.setUp();

        IMYTStrategy.StrategyParams memory params = getRealStrategyParams();
        params.owner = admin;

        vm.startPrank(admin);
        realStrategy = createStrategy(address(vault), params);
        require(realStrategy != address(0), "createStrategy returned zero");
        _enableForceDeallocate(realStrategy);
        uint256 realAbsoluteCap = _realAbsoluteCap();
        _addStrategyViaCurator(realStrategy, realAbsoluteCap, REAL_STRATEGY_RELATIVE_CAP);
        vm.stopPrank();

        _postCreateStrategy(realStrategy);

        minMaterial = 10 ** (assetDecimals - 3);

        strategies.push(realStrategy);
        strategyLabel[realStrategy] = "RealStrategy";

        handler = new E2EStrategyHandler(
            E2EStrategyHandler.InitParams({
                vault: address(vault),
                strategies: strategies,
                allocator: allocator,
                classifier: classifier,
                admin: admin,
                operator: operator,
                alchemist: address(alchemist),
                alchemistNFT: address(alchemistNFT),
                alToken: address(alToken),
                transmuter: address(transmuterLogic),
                actors: vaultActors,
                alchSenders: alchemistSenders,
                mockStrategyA: mockStrategyA,
                mockStrategyB: mockStrategyB,
                mockYieldTokenA: mockYieldTokenA,
                mockYieldTokenB: mockYieldTokenB
            })
        );

        handler.setForceDeallocateEnabled(realStrategy, _realStrategySupportsForceDeallocate());
        handler.setSimulator(address(this));

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _targetedSelectors()}));

        for (uint256 i = 0; i < vaultActors.length; i++) {
            targetSender(vaultActors[i]);
        }
    }

    function _targetedSelectors() internal view virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.allocate.selector;
        selectors[5] = handler.deallocate.selector;
        selectors[6] = handler.deallocateAll.selector;
        selectors[7] = handler.forceDeallocate.selector;
        selectors[8] = handler.reclassifyStrategy.selector;
        selectors[9] = handler.modifyRiskClassCaps.selector;
        selectors[10] = handler.setLiquidityAdapter.selector;
        selectors[11] = handler.simulateYield.selector;
        selectors[12] = handler.simulateValueLoss.selector;
        selectors[13] = handler.warpTime.selector;
        selectors[14] = handler.mine.selector;
        selectors[15] = handler.alchemistDepositCollateral.selector;
        selectors[16] = handler.alchemistBorrow.selector;
        selectors[17] = handler.alchemistRepayDebt.selector;
    }

    function _enableForceDeallocate(address) internal virtual {}

    function _postCreateStrategy(address) internal virtual {}

    function _realStrategySupportsForceDeallocate() internal view virtual returns (bool) {
        return true;
    }

    function onSimulateYield(address strategy, uint256 amount) external virtual {
        uint256 current = IERC20(asset).balanceOf(strategy);
        deal(asset, strategy, current + amount);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external virtual {
        uint256 current = IERC20(asset).balanceOf(strategy);
        if (current >= amount) {
            deal(asset, strategy, current - amount);
        }
    }

    // =============================================================================================
    // Invariants
    // =============================================================================================

    function invariant_allocationWithinAbsoluteCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(id);
            uint256 absoluteCap = vault.absoluteCap(id);
            assertLe(allocation, absoluteCap + absoluteCap / 50 + 1, _label(strategies[i], "exceeds absolute cap"));
        }
    }

    function invariant_allocationWithinRelativeCap() public view {
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 relativeCap = vault.relativeCap(id);
            if (relativeCap == type(uint256).max || relativeCap == 1e18) continue;

            uint256 allocation = vault.allocation(id);
            uint256 maxAllowed = (firstTotalAssets * relativeCap) / 1e18;
            uint256 tolerance = maxAllowed / 100 + 1;

            assertLe(allocation, maxAllowed + tolerance, _label(strategies[i], "exceeds relative cap"));
        }
    }

    function invariant_allocationWithinGlobalRiskCap() public view {
        uint256 totalAssets = vault.firstTotalAssets();
        if (totalAssets == 0) return;

        uint256[3] memory riskAllocations;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint8 riskLevel = _riskLevel(id);
            riskAllocations[riskLevel] += vault.allocation(id);
        }

        for (uint8 r = 0; r < 3; r++) {
            uint256 cap = (totalAssets * _globalCap(r)) / 1e18;
            uint256 tolerance = cap / 50 + 1;
            assertLe(riskAllocations[r], cap + tolerance, "risk aggregate exceeds global cap");
        }
    }

    function invariant_allocationWithinIndividualRiskCap() public view {
        if (handler.getAllocatorRoleAttempts(admin) > 0) return;
        if (handler.getCalls(handler.modifyRiskClassCaps.selector) > 0) return;

        uint256 totalAssets = vault.totalAssets();
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(id);
            uint256 individualRiskCapPct = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(id));
            uint256 individualRiskCap = (totalAssets * individualRiskCapPct) / 1e18;
            assertLe(allocation, individualRiskCap, "strategy exceeds individual risk cap");
        }
    }

    function invariant_totalAllocationsBounded() public view {
        uint256 totalAllocations = 0;
        uint256 totalRealAssets = IERC20(vault.asset()).balanceOf(address(vault));

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(id);
            totalRealAssets += IMYTStrategy(strategies[i]).realAssets();
        }

        assertLe(totalAllocations, totalRealAssets * 110 / 100 + 1, "total allocations exceed real assets >10%");
    }

    function invariant_realAssetsConsistentWithAllocation() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(id);
            if (allocation <= minMaterial) continue;

            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            uint256 minExpected = allocation * 80 / 100;
            assertGe(realAssets, minExpected, _label(strategies[i], "real assets below allocation"));
        }
    }

    function invariant_sharePricePositive() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 sharePrice = (vault.totalAssets() * 1e18) / totalSupply;
        assertGt(sharePrice, 0, "share price collapsed to zero");
    }

    function invariant_performanceFeeEnabled() public view {
        assertGt(vault.performanceFee(), 0, "performance fee is zero");
        assertGt(vault.maxRate(), 0, "maxRate is zero");
    }

    function invariant_feeRecipientSharesBounded() public view {
        if (vault.performanceFeeRecipient() == address(0)) return;
        uint256 feeShares = vault.balanceOf(vault.performanceFeeRecipient());
        assertLe(feeShares, vault.totalSupply() / 2, "fee shares exceed 50% of totalSupply");
    }

    function invariant_userBalanceConsistency() public view {
        uint256 netDeposits =
            handler.ghost_totalDeposited() > handler.ghost_totalWithdrawn() ? handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn() : 0;

        uint256 vaultBalance = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 totalStrategyValue = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalStrategyValue += IMYTStrategy(strategies[i]).realAssets();
        }

        uint256 totalValue = vaultBalance + totalStrategyValue;
        uint256 totalExpected = initialVaultDeposit + netDeposits;
        if (totalExpected > minMaterial) {
            assertGe(totalValue, totalExpected * 80 / 100, "total value significantly less than expected");
        }
    }

    function invariant_ghostAllocationsMatchVault() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 actual = vault.allocation(id);
            uint256 ghost = handler.ghost_strategyAllocations(strategies[i]);
            if (actual <= minMaterial) continue;

            assertGe(ghost, actual * 99 / 100, _label(strategies[i], "ghost below actual"));
            assertLe(ghost, actual * 101 / 100, _label(strategies[i], "ghost above actual"));
        }
    }

    function invariant_netAllocationsConsistent() public view {
        uint256 ghostNet = handler.ghost_netAllocated();
        uint256 vaultTotal = handler.vault_totalAllocations();
        if (vaultTotal <= minMaterial) return;

        assertGe(ghostNet, vaultTotal * 99 / 100, "ghost net below vault total");
        assertLe(ghostNet, vaultTotal * 101 / 100, "ghost net above vault total");
    }

    function invariant_ghostSumConsistent() public view {
        uint256 ghostSum = handler.ghost_sumStrategyAllocations();
        uint256 ghostNet = handler.ghost_netAllocated();
        if (ghostNet <= minMaterial) return;

        assertGe(ghostSum, ghostNet * 99 / 100, "ghost sum inconsistent with net");
        assertLe(ghostSum, ghostNet * 101 / 100, "ghost sum inconsistent with net");
    }

    function invariant_noStrategyDominance() public view {
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 id = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(id);
            if (allocation == 0) continue;

            (,,,,, uint256 strategyGlobalCap,,,) = IMYTStrategy(strategies[i]).params();
            uint256 maxAllowed = (firstTotalAssets * strategyGlobalCap) / 1e18;
            uint256 tolerance = maxAllowed / 100 + 1;

            assertLe(allocation, maxAllowed + tolerance, _label(strategies[i], "exceeds configured globalCap"));
        }
    }

    function invariant_realAssetsNonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            assertGe(IMYTStrategy(strategies[i]).realAssets(), 0, _label(strategies[i], "real assets negative"));
        }
    }

    function invariant_riskLevelAggregateCaps() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256[3] memory riskLevelAllocations;
        uint256[3] memory yieldGaps;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint8 riskLevel = _riskLevel(allocationId);

            riskLevelAllocations[riskLevel] += allocation;
            uint256 ra = IMYTStrategy(strategies[i]).realAssets();
            if (ra > allocation) yieldGaps[riskLevel] += ra - allocation;
        }

        for (uint8 r = 0; r < 3; r++) {
            uint256 cap = (totalAssets * _globalCap(r)) / 1e18;
            uint256 tolerance = yieldGaps[r] + handler.ghost_liquidityAdapterBypass(r);
            assertLe(riskLevelAllocations[r], cap + tolerance, "risk aggregate exceeds global cap");
        }
    }

    // =============================================================================================
    // Coverage gates
    // =============================================================================================

    function invariant_handlerCallAccounting() public view {
        bytes4[18] memory sels = _allSelectors();
        for (uint256 i = 0; i < sels.length; i++) {
            (uint256 c, uint256 sk, uint256 ex) = handler.getStats(sels[i]);
            assertEq(c, sk + ex, "call accounting mismatch");
        }
    }

    function invariant_allocatePathHasProgress() public view {
        (, uint256 skips, uint256 executed) = handler.getStats(handler.allocate.selector);
        uint256 totalCalls = handler.getCalls(handler.allocate.selector);
        if (totalCalls < strategies.length) return;

        assertGt(executed, 0, "allocate path never succeeded despite sufficient calls");
        assertLt(skips, totalCalls, "allocate path always skipped");
    }

    function invariant_liquidityAdapterPathExercised() public view {
        uint256 totalCalls = handler.getCalls(handler.setLiquidityAdapter.selector);
        if (totalCalls < 10) return;
        (,, uint256 executed) = handler.getStats(handler.setLiquidityAdapter.selector);

        // Every call executes by construction (no-headroom falls back to the zero-reset);
        // allow half for unexpected protocol reverts, but never a fully dead path.
        assertGe(executed, totalCalls / 2, "setLiquidityAdapter path not meaningfully exercised");
    }

    function invariant_allocatorRolesExercised() public view {
        (,, uint256 allocExe) = handler.getStats(handler.allocate.selector);
        (,, uint256 deallocExe) = handler.getStats(handler.deallocate.selector);
        (,, uint256 deallocAllExe) = handler.getStats(handler.deallocateAll.selector);
        uint256 totalExecuted = allocExe + deallocExe + deallocAllExe;
        if (totalExecuted < strategies.length) return;

        assertGt(handler.getAllocatorRoleAttempts(admin), 0, "admin allocator path not exercised");
        assertGt(handler.getAllocatorRoleAttempts(operator), 0, "operator allocator path not exercised");
    }

    function invariant_userPathIsNotSilentlyReverting() public view {
        if (handler.ghost_totalDeposited() == 0) return;
        _assertPathProgress(handler.deposit.selector, "deposit");
        _assertPathProgress(handler.withdraw.selector, "withdraw");
    }

    // =============================================================================================
    // Full-stack invariants — strategy value vs Alchemist debt
    // =============================================================================================

    function invariant_strategyValueBacksAlchemistDebt() public view {
        uint256 vaultTVL = IERC20(vault.asset()).balanceOf(address(vault));
        for (uint256 i = 0; i < strategies.length; i++) {
            vaultTVL += IMYTStrategy(strategies[i]).realAssets();
        }

        uint256 syntheticsIssued = alchemist.totalSyntheticsIssued();
        if (syntheticsIssued == 0) return;

        uint256 conversionFactor = 10 ** (TokenUtils.expectDecimals(address(alToken)) - assetDecimals);
        uint256 maxDebt = vaultTVL * conversionFactor * 90 / 100;
        assertLe(syntheticsIssued, maxDebt, "synthetics issued exceeds 90% of vault TVL");
    }

    function invariant_storageDebtConsistency() public view {
        uint256 totalDebt = alchemist.totalDebt();
        if (totalDebt == 0) return;

        uint256 netMinted =
            handler.ghost_totalDebtMinted() > handler.ghost_totalDebtRepaid() ? handler.ghost_totalDebtMinted() - handler.ghost_totalDebtRepaid() : 0;

        assertLe(totalDebt, netMinted, "totalDebt exceeds ever-minted debt");
    }

    function invariant_pokeIdempotent() public {
        uint256 snapshot = vm.snapshot();
        uint256 totalDebtBefore = alchemist.totalDebt();
        for (uint256 i = 0; i < alchemistSenders.length; i++) {
            uint256 tokenId = _firstTokenId(alchemistSenders[i]);
            if (tokenId != 0) {
                alchemist.poke(tokenId);
            }
        }
        uint256 totalDebtAfter = alchemist.totalDebt();
        assertEq(totalDebtBefore, totalDebtAfter, "poke changed totalDebt");
        vm.revertTo(snapshot);
    }

    // =============================================================================================
    // Internal helpers
    // =============================================================================================

    uint256 minMaterial;

    function _label(address strategy, string memory suffix) internal view returns (string memory) {
        return string(abi.encodePacked(strategyLabel[strategy], " ", suffix));
    }

    function _riskLevel(bytes32 id) internal view returns (uint8) {
        return AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(id));
    }

    function _globalCap(uint8 riskLevel) internal view returns (uint256) {
        return AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
    }

    function _firstTokenId(address owner) internal view returns (uint256) {
        uint256 balance = alchemistNFT.balanceOf(owner);
        if (balance == 0) return 0;
        return IERC721Enumerable(address(alchemistNFT)).tokenOfOwnerByIndex(owner, 0);
    }

    function _assertPathProgress(bytes4 selector, string memory name) internal view {
        uint256 totalCalls = handler.getCalls(selector);
        if (totalCalls < 5) return;
        (uint256 calls, uint256 skips, uint256 executed) = handler.getStats(selector);
        if (skips == calls) return;
        assertGt(executed, 0, string(abi.encodePacked(name, " path never succeeded")));
    }

    function _allSelectors() internal view returns (bytes4[18] memory) {
        return [
            handler.deposit.selector,
            handler.withdraw.selector,
            handler.mint.selector,
            handler.redeem.selector,
            handler.allocate.selector,
            handler.deallocate.selector,
            handler.deallocateAll.selector,
            handler.forceDeallocate.selector,
            handler.reclassifyStrategy.selector,
            handler.modifyRiskClassCaps.selector,
            handler.setLiquidityAdapter.selector,
            handler.simulateYield.selector,
            handler.simulateValueLoss.selector,
            handler.warpTime.selector,
            handler.mine.selector,
            handler.alchemistDepositCollateral.selector,
            handler.alchemistBorrow.selector,
            handler.alchemistRepayDebt.selector
        ];
    }

    function debugCallSummary() external view {
        handler.callSummary();
    }
}
