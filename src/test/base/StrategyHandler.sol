// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IStrategyClassifier} from "../../interfaces/IStrategyClassifier.sol";
import {RevertContext, IRevertAllowlistProvider} from "./StrategyTypes.sol";
import {StrategyRevertUtils} from "./StrategyRevertUtils.sol";

/// @notice Invariant handler module for base strategy testing.
/// @dev Instantiate from setup and target its selectors for invariant/fuzz-driven state transitions.
/// @notice Handler contract for invariant testing according to Foundry best practices.
/// It wraps the vault and strategy, constrains inputs, and tracks ghost variables.
contract StrategyHandler is Test, StrategyRevertUtils {
    IVaultV2 public vault;
    IMYTStrategy public strategy;
    address public allocator;
    address public asset;
    address public admin;
    address public classifier;
    uint256 public minAllocateAmount;

    // Ghost variables to track cumulative state changes
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalDeallocated;
    uint256 public ghost_initialVaultAssets;

    // Call counters for coverage analysis
    mapping(bytes4 => uint256) public calls;

    address public limitProvider;

    constructor(
        address _vault,
        address _strategy,
        address _allocator,
        address _admin,
        address _limitProvider,
        address _classifier,
        uint256 _minAllocateAmount
    ) {
        vault = IVaultV2(_vault);
        strategy = IMYTStrategy(_strategy);
        allocator = _allocator;
        admin = _admin;
        limitProvider = _limitProvider;
        classifier = _classifier;
        minAllocateAmount = _minAllocateAmount;
        asset = vault.asset();
        ghost_initialVaultAssets = vault.totalAssets();
    }

    modifier countCall(bytes4 selector) {
        calls[selector]++;
        _;
    }

    function _isWhitelistedRevert(bytes4 sel, RevertContext context) internal view returns (bool) {
        return IRevertAllowlistProvider(limitProvider).isProtocolRevertAllowed(sel, context)
            || IRevertAllowlistProvider(limitProvider).isMytRevertAllowed(sel, context);
    }

    function allocate(uint256 amount) external countCall(this.allocate.selector) {
        uint256 vaultAssets = vault.totalAssets();
        // If vault has no assets, we cannot allocate
        if (vaultAssets == 0) return;

        // Get the strategy's allocation limits
        bytes32 allocationId = strategy.adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);

        // Calculate remaining headroom in absolute cap
        uint256 absoluteRemaining = absoluteCap > currentAllocation ? absoluteCap - currentAllocation : 0;

        // Calculate remaining headroom in relative cap (convert from WAD to WEI)
        uint256 maxAllowedByRelative = (vaultAssets * relativeCap) / 1e18;
        uint256 relativeRemaining = maxAllowedByRelative > currentAllocation ? maxAllowedByRelative - currentAllocation : 0;

        // The effective limit is the minimum of the two caps
        uint256 effectiveLimit = absoluteRemaining < relativeRemaining ? absoluteRemaining : relativeRemaining;

        // Factor in classifier global risk cap (WAD percentage of totalAssets)
        if (classifier != address(0)) {
            uint8 riskLevel = IStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            uint256 globalRiskCap = (vaultAssets * IStrategyClassifier(classifier).getGlobalCap(riskLevel)) / 1e18;
            uint256 currentRiskAllocation = 0;
            uint256 len = vault.adaptersLength();
            for (uint256 i = 0; i < len; i++) {
                address stratAdapter = vault.adapters(i);
                bytes32 stratId = IMYTStrategy(stratAdapter).adapterId();
                if (IStrategyClassifier(classifier).getStrategyRiskLevel(uint256(stratId)) == riskLevel) {
                    currentRiskAllocation += vault.allocation(stratId);
                }
            }
            uint256 globalRiskRemaining = globalRiskCap > currentRiskAllocation ? globalRiskCap - currentRiskAllocation : 0;
            effectiveLimit = effectiveLimit < globalRiskRemaining ? effectiveLimit : globalRiskRemaining;
        }

        if (effectiveLimit < minAllocateAmount) return;

        amount = bound(amount, minAllocateAmount, effectiveLimit);
        {
            uint256 currentIdle = IERC20(vault.asset()).balanceOf(address(vault));
            deal(vault.asset(), address(vault), currentIdle + amount);
        }

        vm.startPrank(admin);
        try IAllocator(allocator).allocate(address(strategy), amount) {
            vm.stopPrank();
        } catch (bytes memory errData) {
            vm.stopPrank();
            _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), RevertContext.HandlerAllocate));
            return;
        }

        ghost_totalAllocated += amount;
    }

    function deallocate(uint256 amount) external countCall(this.deallocate.selector) {
        bytes32 allocationId = strategy.adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);

        // If nothing is allocated, we cannot deallocate
        if (currentAllocation == 0) return;

        // Bound deallocation to current allocation
        amount = bound(amount, 1, currentAllocation);

        vm.startPrank(admin);
        try IAllocator(allocator).deallocate(address(strategy), amount) {
            vm.stopPrank();
        } catch (bytes memory errData) {
            vm.stopPrank();
            _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), RevertContext.HandlerDeallocate));
            return;
        }

        ghost_totalDeallocated += amount;
    }

    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        vm.warp(block.timestamp + bound(timeDelta, 1, 365 days));
    }

    function callSummary() external view {
        console.log("Handler Call Summary:");
        console.log("allocate calls:", calls[this.allocate.selector]);
        console.log("deallocate calls:", calls[this.deallocate.selector]);
        console.log("warpTime calls:", calls[this.warpTime.selector]);
    }
}
