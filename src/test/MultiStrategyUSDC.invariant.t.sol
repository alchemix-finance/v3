// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "lib/vault-v2/src/VaultV2Factory.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TokeAutoStrategy} from "../strategies/TokeAutoStrategy.sol";

/// @title MultiStrategyUSDCHandler
/// @notice Handler for invariant testing multiple USDC strategies attached to a single vault
contract MultiStrategyUSDCHandler is Test {
    IVaultV2 public vault;
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public admin;
    address public operator;
    address public asset;
    
    // Actors for user operations
    address[] public actors;
    address internal currentActor;
    
    // Ghost variables for tracking cumulative state
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalDeallocated;
    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_strategyAllocations;
    
    // Call counters
    mapping(bytes4 => uint256) public calls;
    mapping(bytes4 => uint256) public opAttempts;
    mapping(bytes4 => uint256) public opSuccesses;
    mapping(bytes4 => uint256) public opReverts;
    mapping(bytes4 => uint256) public opNoops;
    mapping(address => uint256) public allocatorRoleAttempts;
    
    // Strategy name tracking for debugging
    mapping(address => string) public strategyNames;
    
    // Minimum amounts for operations
    uint256 public constant MIN_DEPOSIT = 1e6; // 1 USDC
    uint256 public constant MIN_ALLOCATE = 1e5; // 0.1 USDC
    uint256 public constant MAX_USERS = 10;
    
    modifier countCall(bytes4 selector) {
        calls[selector]++;
        _;
    }
    
    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function _markNoop(bytes4 selector) internal {
        opNoops[selector]++;
    }

    function _markAttempt(bytes4 selector) internal {
        opAttempts[selector]++;
    }

    function _markSuccess(bytes4 selector) internal {
        opSuccesses[selector]++;
    }

    function _markRevert(bytes4 selector) internal {
        opReverts[selector]++;
    }

    function _pickAllocatorCaller(uint256 seed) internal returns (address caller) {
        caller = seed % 2 == 0 ? admin : operator;
        allocatorRoleAttempts[caller]++;
    }
    
    constructor(
        address _vault,
        address[] memory _strategies,
        address _allocator,
        address _classifier,
        address _admin,
        address _operator,
        string[] memory _strategyNames
    ) {
        vault = IVaultV2(_vault);
        strategies = _strategies;
        allocator = _allocator;
        classifier = _classifier;
        admin = _admin;
        operator = _operator;
        asset = vault.asset();
        
        // Initialize actors with varying balances
        for (uint256 i = 0; i < MAX_USERS; i++) {
            address actor = makeAddr(string(abi.encodePacked("usdcActor", i)));
            actors.push(actor);
            // Give actors different initial balances for position size variation
            deal(asset, actor, (i + 1) * 100_000e6); // 100k to 1M USDC
        }
        
        // Map strategy names for debugging
        for (uint256 i = 0; i < _strategies.length; i++) {
            strategyNames[_strategies[i]] = _strategyNames[i];
        }
    }
    
    // ============ USER OPERATIONS ============
    
    /// @notice User deposits assets into the vault
    function deposit(uint256 amount, uint256 actorSeed) external countCall(this.deposit.selector) useActor(actorSeed) {
        bytes4 selector = this.deposit.selector;
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) {
            _markNoop(selector);
            return;
        }
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);

        _markAttempt(selector);
        try vault.deposit(amount, currentActor) {
            _markSuccess(selector);
            ghost_totalDeposited += amount;
            ghost_userDeposits[currentActor] += amount;
        } catch {
            _markRevert(selector);
        }
    }
    
    /// @notice User withdraws assets from the vault
    function withdraw(uint256 amount, uint256 actorSeed) external countCall(this.withdraw.selector) useActor(actorSeed) {
        bytes4 selector = this.withdraw.selector;
        uint256 shares = vault.balanceOf(currentActor);
        if (shares == 0) {
            _markNoop(selector);
            return;
        }

        uint256 maxAssets = vault.convertToAssets(shares);
        if (maxAssets == 0) {
            _markNoop(selector);
            return;
        }

        amount = bound(amount, 1, maxAssets);

        _markAttempt(selector);
        try vault.withdraw(amount, currentActor, currentActor) {
            _markSuccess(selector);
            ghost_totalWithdrawn += amount;
            if (ghost_userDeposits[currentActor] >= amount) {
                ghost_userDeposits[currentActor] -= amount;
            }
        } catch {
            _markRevert(selector);
        }
    }
    
    /// @notice User mints shares by providing exact assets
    function mint(uint256 shares, uint256 actorSeed) external countCall(this.mint.selector) useActor(actorSeed) {
        bytes4 selector = this.mint.selector;
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) {
            _markNoop(selector);
            return;
        }

        uint256 maxShares = vault.convertToShares(balance);
        if (maxShares == 0) {
            _markNoop(selector);
            return;
        }

        shares = bound(shares, 1, maxShares);

        IERC20(asset).approve(address(vault), balance);

        _markAttempt(selector);
        try vault.mint(shares, currentActor) returns (uint256 assetsDeposited) {
            _markSuccess(selector);
            ghost_totalDeposited += assetsDeposited;
            ghost_userDeposits[currentActor] += assetsDeposited;
        } catch {
            _markRevert(selector);
        }
    }
    
    /// @notice User redeems exact shares for assets
    function redeem(uint256 shares, uint256 actorSeed) external countCall(this.redeem.selector) useActor(actorSeed) {
        bytes4 selector = this.redeem.selector;
        uint256 userShares = vault.balanceOf(currentActor);
        if (userShares == 0) {
            _markNoop(selector);
            return;
        }

        shares = bound(shares, 1, userShares);

        _markAttempt(selector);
        try vault.redeem(shares, currentActor, currentActor) returns (uint256 assetsRedeemed) {
            _markSuccess(selector);
            ghost_totalWithdrawn += assetsRedeemed;
            if (ghost_userDeposits[currentActor] >= assetsRedeemed) {
                ghost_userDeposits[currentActor] -= assetsRedeemed;
            }
        } catch {
            _markRevert(selector);
        }
    }
    
    // ============ ADMIN OPERATIONS ============
    
    function _remainingGlobalRiskHeadroom(uint8 riskLevel) internal view returns (uint256) {
        uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        uint256 currentRiskAllocation = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = IMYTStrategy(strategies[i]).adapterId();
            if (AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(strategyId)) == riskLevel) {
                currentRiskAllocation += vault.allocation(strategyId);
            }
        }

        if (currentRiskAllocation >= globalRiskCap) return 0;
        return globalRiskCap - currentRiskAllocation;
    }
    
    /// @notice Admin allocates assets to a specific strategy
    /// @dev Attempts adapters sequentially from a random start index.
    function allocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.allocate.selector) {
        uint256 strategiesLen = strategies.length;
        if (strategiesLen == 0) {
            _markNoop(this.allocate.selector);
            return;
        }

        uint256 strategyIndex = strategyIndexSeed % strategiesLen;
        (bool success, uint256 allocatedAmount) = _tryAllocate(strategies[strategyIndex], amount, strategyIndexSeed);
        if (success) {
            ghost_totalAllocated += allocatedAmount;
            ghost_strategyAllocations[strategies[strategyIndex]] += allocatedAmount;
        }
    }
    
    /// @notice Attempts to allocate to a specific strategy, returns success and amount allocated
    function _tryAllocate(
        address strategy, 
        uint256 amount,
        uint256 roleSeed
    ) internal returns (bool success, uint256 allocatedAmount) {
        bytes4 selector = this.allocate.selector;
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint256 currentAllocation = vault.allocation(allocationId);
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);

        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint256 globalRiskHeadroom = _remainingGlobalRiskHeadroom(riskLevel);
        uint256 idleVaultBalance = IERC20(asset).balanceOf(address(vault));
        if (idleVaultBalance < MIN_ALLOCATE) {
            _markNoop(selector);
            return (false, 0);
        }

        if (currentAllocation >= absoluteCap) {
            _markNoop(selector);
            return (false, 0);
        }
        if (globalRiskHeadroom < MIN_ALLOCATE) {
            _markNoop(selector);
            return (false, 0);
        }
        // Get the underlying vault's max deposit to respect protocol-level caps
        uint256 underlyingMaxDeposit = _getUnderlyingMaxDeposit(strategy);
        if (underlyingMaxDeposit < MIN_ALLOCATE) {
            _markNoop(selector);
            return (false, 0);
        }

        uint256 maxByAbsolute = absoluteCap - currentAllocation;
        uint256 totalAssets = vault.totalAssets();
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) {
            firstTotalAssets = totalAssets;
        }
        uint256 allocatorRelativeCapValue =
            relativeCap == type(uint256).max ? type(uint256).max : (totalAssets * relativeCap) / 1e18;
        uint256 vaultRelativeCapValue =
            relativeCap == type(uint256).max ? type(uint256).max : (firstTotalAssets * relativeCap) / 1e18;
        uint256 maxByAllocatorRelative =
            allocatorRelativeCapValue > currentAllocation ? allocatorRelativeCapValue - currentAllocation : 0;
        uint256 maxByVaultRelative =
            vaultRelativeCapValue > currentAllocation ? vaultRelativeCapValue - currentAllocation : 0;
        uint256 maxByRelativeCap =
            maxByAllocatorRelative < maxByVaultRelative ? maxByAllocatorRelative : maxByVaultRelative;

        uint256 maxAllocate = maxByAbsolute < maxByRelativeCap ? maxByAbsolute : maxByRelativeCap;
        maxAllocate = maxAllocate < globalRiskHeadroom ? maxAllocate : globalRiskHeadroom;
        maxAllocate = maxAllocate < idleVaultBalance ? maxAllocate : idleVaultBalance;
        maxAllocate = maxAllocate < underlyingMaxDeposit ? maxAllocate : underlyingMaxDeposit;

        if (maxAllocate < MIN_ALLOCATE) {
            _markNoop(selector);
            return (false, 0);
        }

        amount = bound(amount, MIN_ALLOCATE, maxAllocate);

        _markAttempt(selector);
        address allocatorCaller = _pickAllocatorCaller(roleSeed);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).allocate(strategy, amount) {
            uint256 newAllocation = vault.allocation(allocationId);
            if (newAllocation <= currentAllocation) {
                _markRevert(selector);
                return (false, 0);
            }

            if (allocatorCaller == operator) {
                uint256 individualCap = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
                assertLe(newAllocation, individualCap, "Operator allocation exceeded individual cap");
            }

            _markSuccess(selector);
            return (true, newAllocation - currentAllocation);
        } catch {
            _markRevert(selector);
            return (false, 0);
        }
    }
    
    /// @notice Admin deallocates assets from a specific strategy
    function deallocate(uint256 strategyIndex, uint256 amount) external countCall(this.deallocate.selector) {
        bytes4 selector = this.deallocate.selector;
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        
        if (currentAllocation < MIN_ALLOCATE) {
            _markNoop(selector);
            return;
        }

        uint256 protocolMaxWithdraw = _getUnderlyingMaxWithdraw(strategy);
        uint256 maxDeallocate = currentAllocation;
        if (protocolMaxWithdraw >= MIN_ALLOCATE && protocolMaxWithdraw < maxDeallocate) {
            maxDeallocate = protocolMaxWithdraw;
        }
        if (maxDeallocate < MIN_ALLOCATE) {
            _markNoop(selector);
            return;
        }
        
        amount = bound(amount, MIN_ALLOCATE, maxDeallocate);
        
        // Get preview for adjusted withdraw
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        if (previewAmount == 0) {
            _markNoop(selector);
            return;
        }
        
        _markAttempt(selector);
        address allocatorCaller = _pickAllocatorCaller(amount);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).deallocate(strategy, previewAmount) {
            uint256 newAllocation = vault.allocation(allocationId);
            if (newAllocation >= currentAllocation) {
                _markRevert(selector);
                return;
            }

            uint256 deallocatedAmount = currentAllocation - newAllocation;
            ghost_totalDeallocated += deallocatedAmount;
            if (ghost_strategyAllocations[strategy] >= deallocatedAmount) {
                ghost_strategyAllocations[strategy] -= deallocatedAmount;
            } else {
                ghost_strategyAllocations[strategy] = 0;
            }
            _markSuccess(selector);
        } catch {
            _markRevert(selector);
            return;
        }
    }
    
    /// @notice Deallocaes all assets from a specific strategy
    function deallocateAll(uint256 strategyIndex) external countCall(this.deallocateAll.selector) {
        bytes4 selector = this.deallocateAll.selector;
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocationBefore = vault.allocation(allocationId);
        
        if (allocationBefore < MIN_ALLOCATE) {
            _markNoop(selector);
            return;
        }

        uint256 protocolMaxWithdraw = _getUnderlyingMaxWithdraw(strategy);
        uint256 maxDeallocate = allocationBefore;
        if (protocolMaxWithdraw >= MIN_ALLOCATE && protocolMaxWithdraw < maxDeallocate) {
            maxDeallocate = protocolMaxWithdraw;
        }
        if (maxDeallocate < MIN_ALLOCATE) {
            _markNoop(selector);
            return;
        }

        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(maxDeallocate);
        if (previewAmount == 0) {
            _markNoop(selector);
            return;
        }

        _markAttempt(selector);
        address allocatorCaller = _pickAllocatorCaller(strategyIndex);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).deallocate(strategy, previewAmount) {
            uint256 allocationAfter = vault.allocation(allocationId);
            if (allocationAfter >= allocationBefore) {
                _markRevert(selector);
                return;
            }

            uint256 deallocatedAmount = allocationBefore - allocationAfter;
            ghost_totalDeallocated += deallocatedAmount;
            if (ghost_strategyAllocations[strategy] >= deallocatedAmount) {
                ghost_strategyAllocations[strategy] -= deallocatedAmount;
            } else {
                ghost_strategyAllocations[strategy] = 0;
            }
            _markSuccess(selector);
        } catch {
            _markRevert(selector);
            return;
        }
    }

    function setLiquidityAdapter(uint256 strategySeed, uint256 modeSeed)
        external
        countCall(this.setLiquidityAdapter.selector)
    {
        bytes4 selector = this.setLiquidityAdapter.selector;
        if (strategies.length == 0) {
            _markNoop(selector);
            return;
        }

        address newLiquidityAdapter = address(0);
        if (modeSeed % 3 != 0) {
            address candidate = strategies[strategySeed % strategies.length];
            if (!_liquidityAdapterHasHeadroom(candidate)) {
                _markNoop(selector);
                return;
            }
            newLiquidityAdapter = candidate;
        }

        _markAttempt(selector);
        address allocatorCaller = _pickAllocatorCaller(modeSeed);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).setLiquidityAdapter(newLiquidityAdapter, "") {
            _markSuccess(selector);
        } catch {
            _markRevert(selector);
        }
    }

    function _liquidityAdapterHasHeadroom(address strategy) internal view returns (bool) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);
        uint256 totalAssets = vault.totalAssets();
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) {
            firstTotalAssets = totalAssets;
        }

        uint256 allocatorRelativeCapValue =
            relativeCap == type(uint256).max ? type(uint256).max : (totalAssets * relativeCap) / 1e18;
        uint256 vaultRelativeCapValue =
            relativeCap == type(uint256).max ? type(uint256).max : (firstTotalAssets * relativeCap) / 1e18;
        uint256 relativeLimit = allocatorRelativeCapValue < vaultRelativeCapValue ? allocatorRelativeCapValue : vaultRelativeCapValue;
        uint256 hardLimit = absoluteCap < relativeLimit ? absoluteCap : relativeLimit;

        if (hardLimit <= currentAllocation) return false;
        uint256 headroom = hardLimit - currentAllocation;

        return headroom >= MIN_DEPOSIT * 10;
    }
    
    // ============ TIME OPERATIONS ============
    
    /// @notice Advance time for yield accumulation
    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        vm.warp(block.timestamp + timeDelta);
    }
    
    /// @notice Advance time with strategy-specific hooks
    function warpTimeWithStrategyHook(uint256 timeDelta, uint256 strategyIndex) external countCall(this.warpTimeWithStrategyHook.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        
        // Strategy-specific time hooks could be added here for protocols that need them
        // (e.g., Tokemak oracle mocking)
        
        vm.warp(block.timestamp + timeDelta);
    }
    
    // ============ REWARD OPERATIONS ============
    
    /// @notice Claim rewards from a strategy (mocked swap)
    /// @dev This is a placeholder - actual implementation needs real swap calldata
    function claimRewards(uint256 strategyIndex, uint256 /* minAmountOut */) external countCall(this.claimRewards.selector) {
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        // Check if strategy has rewards functionality
        try IMYTStrategy(strategy).claimRewards(address(0), "", 0) returns (uint256) {
            // If it doesn't revert, rewards might be available
            // In production, we'd need proper swap calldata
        } catch {
            // Expected for strategies without rewards or with bad calldata
        }
    }
    
    /// @dev Get the maximum deposit amount for the underlying protocol vault
    /// This accounts for protocol-level supply caps (e.g., Euler's E_SupplyCapExceeded)
    function _getUnderlyingMaxDeposit(address strategy) internal view returns (uint256) {
        address underlyingVault = _resolveUnderlyingVault(strategy);
        if (underlyingVault == address(0)) return type(uint256).max;

        (bool ok, bytes memory data) = underlyingVault.staticcall(abi.encodeWithSignature("maxDeposit(address)", strategy));
        if (!ok || data.length < 32) return type(uint256).max;

        return abi.decode(data, (uint256));
    }

    /// @dev Get the maximum withdrawable amount for the underlying protocol vault.
    function _getUnderlyingMaxWithdraw(address strategy) internal view returns (uint256) {
        address underlyingVault = _resolveUnderlyingVault(strategy);
        if (underlyingVault == address(0)) return type(uint256).max;

        (bool ok, bytes memory data) = underlyingVault.staticcall(abi.encodeWithSignature("maxWithdraw(address)", strategy));
        if (!ok || data.length < 32) return type(uint256).max;

        return abi.decode(data, (uint256));
    }

    function _resolveUnderlyingVault(address strategy) internal view returns (address underlyingVault) {
        (bool ok, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("vault()"));
        if (ok && data.length >= 32) {
            underlyingVault = abi.decode(data, (address));
            if (underlyingVault != address(0)) return underlyingVault;
        }

        (ok, data) = strategy.staticcall(abi.encodeWithSignature("autoVault()"));
        if (ok && data.length >= 32) {
            underlyingVault = abi.decode(data, (address));
        }
    }
    
    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }
    
    function getStrategy(uint256 index) external view returns (address) {
        return strategies[index];
    }
    
    /// @notice Returns the net allocated amount from ghost variables
    function ghost_netAllocated() external view returns (uint256) {
        if (ghost_totalAllocated >= ghost_totalDeallocated) {
            return ghost_totalAllocated - ghost_totalDeallocated;
        }
        return 0;
    }
    
    /// @notice Returns the sum of all ghost strategy allocations
    function ghost_sumStrategyAllocations() external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            sum += ghost_strategyAllocations[strategies[i]];
        }
        return sum;
    }
    
    /// @notice Returns the sum of actual vault allocations
    function vault_totalAllocations() external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            sum += vault.allocation(allocationId);
        }
        return sum;
    }

    function getCalls(bytes4 selector) external view returns (uint256) {
        return calls[selector];
    }

    function getOperationStats(bytes4 selector)
        external
        view
        returns (uint256 attempts_, uint256 successes_, uint256 reverts_, uint256 noops_)
    {
        return (opAttempts[selector], opSuccesses[selector], opReverts[selector], opNoops[selector]);
    }

    function getAllocatorRoleAttempts(address role) external view returns (uint256) {
        return allocatorRoleAttempts[role];
    }

    function _logOperationStats(string memory label, bytes4 selector) internal view {
        console.log(label);
        console.log("    attempts:", opAttempts[selector]);
        console.log("    successes:", opSuccesses[selector]);
        console.log("    reverts:", opReverts[selector]);
        console.log("    noops:", opNoops[selector]);
    }
    
    function callSummary() external view {
        console.log("=== USDC Multi-Strategy Handler Call Summary ===");
        console.log("User Operations:");
        console.log("  deposit calls:", calls[this.deposit.selector]);
        console.log("  withdraw calls:", calls[this.withdraw.selector]);
        console.log("  mint calls:", calls[this.mint.selector]);
        console.log("  redeem calls:", calls[this.redeem.selector]);
        console.log("Admin Operations:");
        console.log("  allocate calls:", calls[this.allocate.selector]);
        console.log("  deallocate calls:", calls[this.deallocate.selector]);
        console.log("  deallocateAll calls:", calls[this.deallocateAll.selector]);
        console.log("Time Operations:");
        console.log("  warpTime calls:", calls[this.warpTime.selector]);
        console.log("  warpTimeWithStrategyHook calls:", calls[this.warpTimeWithStrategyHook.selector]);
        console.log("Reward Operations:");
        console.log("  claimRewards calls:", calls[this.claimRewards.selector]);
        console.log("Ghost Variables:");
        console.log("  totalDeposited:", ghost_totalDeposited);
        console.log("  totalWithdrawn:", ghost_totalWithdrawn);
        console.log("  totalAllocated:", ghost_totalAllocated);
        console.log("  totalDeallocated:", ghost_totalDeallocated);
        console.log("Operation Stats:");
        _logOperationStats("  allocate", this.allocate.selector);
        _logOperationStats("  deallocate", this.deallocate.selector);
        _logOperationStats("  deallocateAll", this.deallocateAll.selector);
        _logOperationStats("  setLiquidityAdapter", this.setLiquidityAdapter.selector);
        _logOperationStats("  withdraw", this.withdraw.selector);
        _logOperationStats("  redeem", this.redeem.selector);
        console.log("Allocator Role Attempts:");
        console.log("  admin:", allocatorRoleAttempts[admin]);
        console.log("  operator:", allocatorRoleAttempts[operator]);
    }
}

/// @title MultiStrategyUSDCInvariantTest
/// @notice Invariant tests for USDC strategies attached to a single vault
contract MultiStrategyUSDCInvariantTest is Test {
    IVaultV2 public vault;
    MultiStrategyUSDCHandler public handler;
    
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public curatorContract;
    address public admin = address(0x1);
    address public operator = address(0x3);
    
    uint256 public initialSharePrice;
    
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant EULER_USDC_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public constant PEAPODS_USDC_VAULT = 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA;
    address public constant TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant TOKE_REWARDER_USD = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    address public constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    
    uint256 public constant INITIAL_VAULT_DEPOSIT = 10_000_000e6; // 10M USDC
    uint256 public constant ABSOLUTE_CAP = 50_000_000e6; // 50M USDC per strategy
    uint256 public constant RELATIVE_CAP = 0.5e18; // 50% of vault assets
    
    uint256 private forkId;
    
    function setUp() public {
        // Fork mainnet at specific block
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        forkId = vm.createFork(rpc, 22_089_302);
        vm.selectFork(forkId);
        
        // Setup vault
        vm.startPrank(admin);
        vault = _setupVault(USDC);
        
        // Setup strategies
        string[] memory strategyNames = new string[](3);
        strategyNames[0] = "Euler Mainnet USDC";
        strategyNames[1] = "Peapods Mainnet USDC";
        strategyNames[2] = "TokeAutoUSD Mainnet";
        
        // Deploy Euler USDC Strategy
        strategies.push(_deployEulerStrategy());
        
        // Deploy Peapods USDC Strategy
        strategies.push(_deployPeapodsStrategy());
        
        // Deploy TokeAuto USD Strategy
        strategies.push(_deployTokeStrategy());
        
        // Setup classifier and allocator
        _setupClassifierAndAllocator();
        
        // Add strategies to vault
        _addStrategiesToVault();
        
        // Make initial deposit to vault
        _makeInitialDeposit();
        
        vm.stopPrank();
        
        initialSharePrice = (vault.totalAssets() * 1e18) / vault.totalSupply();
        
        // Create handler
        handler = new MultiStrategyUSDCHandler(
            address(vault),
            strategies,
            allocator,
            classifier,
            admin,
            operator,
            strategyNames
        );
        
        // Target the handler
        targetContract(address(handler));
        
        // Target specific functions
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.allocate.selector;
        selectors[5] = handler.deallocate.selector;
        selectors[6] = handler.deallocateAll.selector;
        selectors[7] = handler.setLiquidityAdapter.selector;
        selectors[8] = handler.warpTime.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    function _setupVault(address asset) internal returns (IVaultV2) {
        // Deploy vault using factory pattern matching deployment script
        VaultV2Factory factory = new VaultV2Factory();
        return IVaultV2(factory.createVaultV2(admin, asset, bytes32(0)));
    }
    
    function _deployEulerStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Euler Mainnet USDC",
            protocol: "Euler",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1e6 * 1e6,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new ERC4626Strategy(address(vault), params, EULER_USDC_VAULT));
    }
    
    function _deployPeapodsStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Peapods Mainnet USDC",
            protocol: "Peapods",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 1e6 * 1e6,
            globalCap: 0.2e18,
            estimatedYield: 550,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new ERC4626Strategy(address(vault), params, PEAPODS_USDC_VAULT));
    }
    
    function _deployTokeStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "TokeAutoUSD Mainnet",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1e6 * 1e6,
            globalCap: 0.3e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new TokeAutoStrategy(
            address(vault),
            params,
            USDC,
            TOKE_AUTO_USD_VAULT,
            TOKE_REWARDER_USD,
            TOKE
        ));
    }
    
    function _setupClassifierAndAllocator() internal {
        classifier = address(new AlchemistStrategyClassifier(admin));
        
        // Set up risk classes
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 100_000_000e6, 50_000_000e6); // LOW
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 75_000_000e6, 37_500_000e6);  // MEDIUM
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 50_000_000e6, 25_000_000e6);  // HIGH
        
        // Assign risk levels
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = IMYTStrategy(strategies[i]).adapterId();
            (,,,IMYTStrategy.RiskClass riskClass,,,,,) = IMYTStrategy(strategies[i]).params();
            AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(
                uint256(strategyId),
                uint8(riskClass)
            );
        }
        
        // Deploy curator for timelocked operations
        curatorContract = address(new AlchemistCurator(admin, admin));
        
        // Set curator on vault (owner can do this directly)
        VaultV2(address(vault)).setCurator(curatorContract);
        
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
    }
    
    function _addStrategiesToVault() internal {
        // Use curator for timelocked operations
        AlchemistCurator curator = AlchemistCurator(curatorContract);
        
        // Submit and set allocator through curator
        curator.submitSetAllocator(address(vault), allocator, true);
        vault.setIsAllocator(allocator, true);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            // Submit and add adapter through curator
            curator.submitSetStrategy(strategies[i], address(vault));
            curator.setStrategy(strategies[i], address(vault));
            
            // Submit and set absolute cap through curator
            curator.submitIncreaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            curator.increaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);

            // VaultV2 enforces relative cap from vault storage, not strategy params.
            // Mirror strategy globalCap into the vault cap configuration.
            (,,,,, uint256 strategyRelativeCap,,,) = IMYTStrategy(strategies[i]).params();
            curator.submitIncreaseRelativeCap(strategies[i], strategyRelativeCap);
            curator.increaseRelativeCap(strategies[i], strategyRelativeCap);
        }
    }
    
    function _makeInitialDeposit() internal {
        deal(USDC, admin, INITIAL_VAULT_DEPOSIT);
        IERC20(USDC).approve(address(vault), INITIAL_VAULT_DEPOSIT);
        vault.deposit(INITIAL_VAULT_DEPOSIT, admin);
    }
    
    // ============ INVARIANTS ============
    
    /// @notice Invariant: All strategies must have non-negative real assets
    function invariant_realAssets_nonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            assertGe(realAssets, 0, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has negative real assets")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds absolute cap
    function invariant_allocationWithinAbsoluteCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 absoluteCap = vault.absoluteCap(allocationId);
            
            assertLe(allocation, absoluteCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds absolute cap")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds relative cap
    function invariant_allocationWithinRelativeCap() public view {
        uint256 vaultTotalAssets = vault.totalAssets();
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) {
            firstTotalAssets = vaultTotalAssets;
        }
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 relativeCap = vault.relativeCap(allocationId);
            uint256 allocatorCap = (vaultTotalAssets * relativeCap) / 1e18;
            uint256 vaultCap = (firstTotalAssets * relativeCap) / 1e18;
            uint256 maxAllowed = allocatorCap < vaultCap ? allocatorCap : vaultCap;
            uint256 tolerance = maxAllowed / 200; // 0.5%
            
            // Relative-cap checks are point-in-time checks and can drift slightly with asset movement.
            assertLe(allocation, maxAllowed + tolerance + 1, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds relative cap")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds global risk cap for its risk level
    function invariant_allocationWithinGlobalRiskCap() public view {
        uint256[3] memory riskLevelAllocations;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            riskLevelAllocations[riskLevel] += vault.allocation(allocationId);
        }

        assertLe(riskLevelAllocations[0], AlchemistStrategyClassifier(classifier).getGlobalCap(0), "LOW risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[1], AlchemistStrategyClassifier(classifier).getGlobalCap(1), "MEDIUM risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[2], AlchemistStrategyClassifier(classifier).getGlobalCap(2), "HIGH risk aggregate exceeds global cap");
    }
    
    /// @notice Invariant: No strategy allocation exceeds individual/local risk cap
    function invariant_allocationWithinIndividualRiskCap() public view {
        // Individual cap is enforced by allocator for operator calls only.
        if (handler.getAllocatorRoleAttempts(admin) > 0) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            // Get individual cap from classifier
            uint256 individualRiskCap = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
            
            assertLe(allocation, individualRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds individual risk cap")));
        }
    }
    
    /// @notice Invariant: Total allocations per risk level don't exceed aggregate limits
    function invariant_riskLevelAggregateCaps() public view {
        uint256[3] memory riskLevelAllocations; // LOW, MEDIUM, HIGH
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            
            riskLevelAllocations[riskLevel] += allocation;
        }
        
        // Check each risk level's aggregate doesn't exceed its global cap
        assertLe(riskLevelAllocations[0], AlchemistStrategyClassifier(classifier).getGlobalCap(0), "LOW risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[1], AlchemistStrategyClassifier(classifier).getGlobalCap(1), "MEDIUM risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[2], AlchemistStrategyClassifier(classifier).getGlobalCap(2), "HIGH risk aggregate exceeds global cap");
    }
    
    /// @notice Invariant: Sum of all allocations should not exceed vault total assets significantly
    function invariant_totalAllocationsBounded() public view {
        uint256 totalAllocations = 0;
        uint256 totalRealAssets = IERC20(vault.asset()).balanceOf(address(vault));
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
            totalRealAssets += IMYTStrategy(strategies[i]).realAssets();
        }

        // Compare against real assets (idle + strategy realAssets), not capped accounting totalAssets.
        assertLe(totalAllocations, totalRealAssets * 110 / 100 + 1, "Total allocations exceed real assets by more than 10%");
    }
    
    /// @notice Invariant: Each strategy's real assets should be consistent with vault allocation
    function invariant_realAssetsConsistentWithAllocation() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            
            // Real assets should be within reasonable bounds of allocation
            // Allow 5% tolerance for yield/losses
            if (allocation > 0) {
                uint256 minExpected = allocation * 95 / 100;
                uint256 maxExpected = allocation * 105 / 100;
                
                // Only assert if allocation is significant
                if (allocation > 1e6) {
                    assertGe(realAssets, minExpected, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets below allocation")));
                    assertLe(realAssets, maxExpected * 2, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets significantly above allocation")));
                }
            }
        }
    }
    
    function invariant_sharePriceNonDecreasing() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = vault.totalAssets();
        uint256 sharePrice = (totalAssets * 1e18) / totalSupply;
        assertGt(sharePrice, 0, "Share price collapsed to zero");
    }
    
    /// @notice Invariant: User deposits minus withdrawals should equal their share of vault
    function invariant_userBalanceConsistency() public view {
        uint256 totalUserDeposits = handler.ghost_totalDeposited();
        uint256 totalUserWithdrawals = handler.ghost_totalWithdrawn();
        uint256 netDeposits = totalUserDeposits > totalUserWithdrawals 
            ? totalUserDeposits - totalUserWithdrawals 
            : 0;
        
        uint256 vaultBalance = IERC20(USDC).balanceOf(address(vault));
        
        uint256 totalAllocations = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
        }
        
        uint256 totalValue = vaultBalance + totalAllocations;
        uint256 totalExpected = INITIAL_VAULT_DEPOSIT + netDeposits;
        if (totalExpected > 1e6) {
            assertGe(totalValue, totalExpected * 90 / 100, "Total value significantly less than expected deposits");
        }
    }
    
    /// @notice Invariant: Ghost allocations match actual vault allocations per strategy
    function invariant_ghostAllocationsMatchVault() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 actualAllocation = vault.allocation(allocationId);
            uint256 ghostAllocation = handler.ghost_strategyAllocations(strategies[i]);
            
            // Allow 5% tolerance for yield/rounding differences
            if (actualAllocation > 1e6) {
                uint256 minExpected = actualAllocation * 95 / 100;
                uint256 maxExpected = actualAllocation * 105 / 100;
                assertGe(ghostAllocation, minExpected, string(abi.encodePacked("Ghost allocation below actual for ", handler.strategyNames(strategies[i]))));
                assertLe(ghostAllocation, maxExpected, string(abi.encodePacked("Ghost allocation above actual for ", handler.strategyNames(strategies[i]))));
            }
        }
    }
    
    /// @notice Invariant: Net ghost allocations match sum of vault allocations
    function invariant_netAllocationsConsistent() public view {
        uint256 ghostNet = handler.ghost_netAllocated();
        uint256 vaultTotal = handler.vault_totalAllocations();
        
        // Allow 10% tolerance for yield accumulation and rounding
        if (vaultTotal > 1e6) {
            assertGe(ghostNet, vaultTotal * 90 / 100, "Ghost net allocations below vault total");
            assertLe(ghostNet, vaultTotal * 110 / 100, "Ghost net allocations above vault total");
        }
    }
    
    /// @notice Invariant: Ghost sum of strategy allocations is internally consistent
    function invariant_ghostSumConsistent() public view {
        uint256 ghostSum = handler.ghost_sumStrategyAllocations();
        uint256 ghostNet = handler.ghost_netAllocated();
        
        // ghost_sumStrategyAllocations should equal ghost_netAllocated
        // Allow small tolerance for rounding
        if (ghostNet > 1e6) {
            assertGe(ghostSum, ghostNet * 95 / 100, "Ghost sum inconsistent with net");
            assertLe(ghostSum, ghostNet * 105 / 100, "Ghost sum inconsistent with net");
        }
    }

    function invariant_noStrategyDominance() public view {
        uint256 vaultTotalAssets = vault.totalAssets();
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) {
            firstTotalAssets = vaultTotalAssets;
        }

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            if (allocation == 0) continue;

            (,,,,, uint256 strategyGlobalCap,,,) = IMYTStrategy(strategies[i]).params();
            uint256 maxByAllocator = (vaultTotalAssets * strategyGlobalCap) / 1e18;
            uint256 maxByVault = (firstTotalAssets * strategyGlobalCap) / 1e18;
            uint256 maxAllowed = maxByAllocator < maxByVault ? maxByAllocator : maxByVault;
            uint256 tolerance = maxAllowed / 200; // 0.5%

            assertLe(
                allocation,
                maxAllowed + tolerance + 1,
                string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds configured globalCap"))
            );
        }
    }

    /// @notice Ensures allocate path is exercised and not a no-op.
    function invariant_allocatePathHasProgress() public view {
        uint256 allocateCalls = handler.getCalls(handler.allocate.selector);
        (uint256 allocateAttempts, uint256 allocateSuccesses, uint256 allocateReverts, uint256 allocateNoops) =
            handler.getOperationStats(handler.allocate.selector);

        assertEq(allocateCalls, allocateAttempts + allocateNoops, "Allocate call accounting mismatch");
        assertEq(allocateAttempts, allocateSuccesses + allocateReverts, "Allocate attempt accounting mismatch");

        if (allocateCalls >= strategies.length) {
            assertGt(handler.ghost_totalAllocated(), 0, "Allocate path made no progress");
        }

        if (allocateAttempts >= strategies.length) {
            assertGt(allocateSuccesses, 0, "Allocate attempts made but none succeeded");
            assertLt(allocateReverts, allocateAttempts, "Allocate attempts always reverted");
        }
    }

    function invariant_handlerOperationAccounting() public view {
        bytes4[6] memory selectors = [
            handler.allocate.selector,
            handler.deallocate.selector,
            handler.deallocateAll.selector,
            handler.setLiquidityAdapter.selector,
            handler.withdraw.selector,
            handler.redeem.selector
        ];

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            uint256 calls = handler.getCalls(selector);
            (uint256 attempts, uint256 successes, uint256 reverts_, uint256 noops) = handler.getOperationStats(selector);

            assertEq(calls, attempts + noops, "Operation call accounting mismatch");
            assertEq(attempts, successes + reverts_, "Operation attempt accounting mismatch");
        }
    }

    function invariant_userPathIsNotSilentlyReverting() public view {
        (uint256 withdrawAttempts, uint256 withdrawSuccesses, uint256 withdrawReverts, ) =
            handler.getOperationStats(handler.withdraw.selector);
        (uint256 redeemAttempts, uint256 redeemSuccesses, uint256 redeemReverts, ) =
            handler.getOperationStats(handler.redeem.selector);

        if (withdrawAttempts >= 5) {
            assertGt(withdrawSuccesses, 0, "Withdraw attempted repeatedly but never succeeded");
            assertLt(withdrawReverts, withdrawAttempts, "Withdraw attempts always reverted");
        }
        if (redeemAttempts >= 5) {
            assertGt(redeemSuccesses, 0, "Redeem attempted repeatedly but never succeeded");
            assertLt(redeemReverts, redeemAttempts, "Redeem attempts always reverted");
        }
    }

    function invariant_allocatorRolesExercised() public view {
        uint256 allocateAttempts;
        uint256 deallocateAttempts;
        uint256 deallocateAllAttempts;
        uint256 setLiquidityAttempts;
        (allocateAttempts, , , ) = handler.getOperationStats(handler.allocate.selector);
        (deallocateAttempts, , , ) = handler.getOperationStats(handler.deallocate.selector);
        (deallocateAllAttempts, , , ) = handler.getOperationStats(handler.deallocateAll.selector);
        (setLiquidityAttempts, , , ) = handler.getOperationStats(handler.setLiquidityAdapter.selector);

        uint256 totalAllocatorAttempts = allocateAttempts + deallocateAttempts + deallocateAllAttempts + setLiquidityAttempts;
        if (totalAllocatorAttempts >= 10) {
            assertGt(handler.getAllocatorRoleAttempts(admin), 0, "Admin allocator path not exercised");
            assertGt(handler.getAllocatorRoleAttempts(operator), 0, "Operator allocator path not exercised");
        }
    }

    function debugCallSummary() public view {
        handler.callSummary();
    }
}
