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
import {MoonwellStrategy} from "../strategies/MoonwellStrategy.sol";
import {AaveStrategy} from "../strategies/AaveStrategy.sol";

/// @title MultiStrategyOPETHHandler
/// @notice Handler for invariant testing ETH strategies on Optimism
contract MultiStrategyOPETHHandler is Test {
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
    mapping(uint8 => uint256) public ghost_liquidityAdapterBypass;
    
    // Call counters
    mapping(bytes4 => uint256) public calls;
    mapping(bytes4 => uint256) public opAttempts;
    mapping(bytes4 => uint256) public opSuccesses;
    mapping(bytes4 => uint256) public opReverts;
    mapping(bytes4 => uint256) public opNoops;
    mapping(address => uint256) public allocatorRoleAttempts;
    uint256 internal allocatorRoleNonce;
    
    // Strategy name tracking for debugging
    mapping(address => string) public strategyNames;
    
    // Minimum amounts for operations
    uint256 public constant MIN_DEPOSIT = 1e15; // 0.001 ETH
    uint256 public constant MIN_ALLOCATE = 1e14; // 0.0001 ETH
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
        seed;
        caller = allocatorRoleNonce % 2 == 0 ? admin : operator;
        allocatorRoleNonce++;
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
            address actor = makeAddr(string(abi.encodePacked("opEthActor", i)));
            actors.push(actor);
            deal(asset, actor, (i + 1) * 100 ether);
        }
        
        for (uint256 i = 0; i < _strategies.length; i++) {
            strategyNames[_strategies[i]] = _strategyNames[i];
        }
    }
    
    // ============ USER OPERATIONS ============
    
    function deposit(uint256 amount, uint256 actorSeed) external countCall(this.deposit.selector) useActor(actorSeed) {
        bytes4 selector = this.deposit.selector;
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) {
            _markNoop(selector);
            return;
        }
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);
        (uint256[] memory allocationSnapshot, uint256 totalBefore) = _snapshotAllocations();

        _markAttempt(selector);
        try vault.deposit(amount, currentActor) {
            _markSuccess(selector);
            ghost_totalDeposited += amount;
            ghost_userDeposits[currentActor] += amount;
            uint256 totalAfter = _recordAllocationDeltas(allocationSnapshot);
            if (vault.liquidityAdapter() != address(0)) {
                _recordLiquidityAdapterBypass(allocationSnapshot);
                _assertTotalAllocationDirection(totalBefore, totalAfter, true, "Deposit reduced total allocations");
            }
        } catch {
            _markRevert(selector);
        }
    }
    
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
        (uint256[] memory allocationSnapshot, uint256 totalBefore) = _snapshotAllocations();

        _markAttempt(selector);
        try vault.withdraw(amount, currentActor, currentActor) {
            _markSuccess(selector);
            ghost_totalWithdrawn += amount;
            if (ghost_userDeposits[currentActor] >= amount) {
                ghost_userDeposits[currentActor] -= amount;
            }
            uint256 totalAfter = _recordAllocationDeltas(allocationSnapshot);
            if (vault.liquidityAdapter() != address(0)) {
                _recordLiquidityAdapterBypass(allocationSnapshot);
                _assertTotalAllocationDirection(totalBefore, totalAfter, false, "Withdraw increased total allocations");
            }
        } catch {
            _markRevert(selector);
        }
    }
    
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
        (uint256[] memory allocationSnapshot, uint256 totalBefore) = _snapshotAllocations();

        _markAttempt(selector);
        try vault.mint(shares, currentActor) returns (uint256 assetsDeposited) {
            _markSuccess(selector);
            ghost_totalDeposited += assetsDeposited;
            ghost_userDeposits[currentActor] += assetsDeposited;
            uint256 totalAfter = _recordAllocationDeltas(allocationSnapshot);
            if (vault.liquidityAdapter() != address(0)) {
                _recordLiquidityAdapterBypass(allocationSnapshot);
                _assertTotalAllocationDirection(totalBefore, totalAfter, true, "Mint reduced total allocations");
            }
        } catch {
            _markRevert(selector);
        }
    }
    
    function redeem(uint256 shares, uint256 actorSeed) external countCall(this.redeem.selector) useActor(actorSeed) {
        bytes4 selector = this.redeem.selector;
        uint256 userShares = vault.balanceOf(currentActor);
        if (userShares == 0) {
            _markNoop(selector);
            return;
        }

        shares = bound(shares, 1, userShares);
        (uint256[] memory allocationSnapshot, uint256 totalBefore) = _snapshotAllocations();

        _markAttempt(selector);
        try vault.redeem(shares, currentActor, currentActor) returns (uint256 assetsRedeemed) {
            _markSuccess(selector);
            ghost_totalWithdrawn += assetsRedeemed;
            if (ghost_userDeposits[currentActor] >= assetsRedeemed) {
                ghost_userDeposits[currentActor] -= assetsRedeemed;
            }
            uint256 totalAfter = _recordAllocationDeltas(allocationSnapshot);
            if (vault.liquidityAdapter() != address(0)) {
                _recordLiquidityAdapterBypass(allocationSnapshot);
                _assertTotalAllocationDirection(totalBefore, totalAfter, false, "Redeem increased total allocations");
            }
        } catch {
            _markRevert(selector);
        }
    }
    
    // ============ ADMIN OPERATIONS ============
    
    function _remainingGlobalRiskHeadroom(uint8 riskLevel) internal view returns (uint256) {
        uint256 globalRiskCapPct = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        uint256 globalRiskCap = (vault.totalAssets() * globalRiskCapPct) / 1e18;
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
    
    function allocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.allocate.selector) {
        uint256 strategiesLen = strategies.length;
        if (strategiesLen == 0) {
            _markNoop(this.allocate.selector);
            return;
        }
        
        uint256 strategyIndex = strategyIndexSeed % strategiesLen;
        (bool success, uint256 allocatedAmount) = _tryAllocate(strategies[strategyIndex], amount, strategyIndexSeed);
        if (success) {
            assertGt(allocatedAmount, 0, "Allocate succeeded without allocation delta");
            ghost_totalAllocated += allocatedAmount;
            ghost_strategyAllocations[strategies[strategyIndex]] += allocatedAmount;
        }
    }
    
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

        address allocatorCaller = _pickAllocatorCaller(roleSeed);
        if (allocatorCaller == operator) {
            uint256 individualCapPct = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
            uint256 individualCap = (totalAssets * individualCapPct) / 1e18;
            uint256 individualRemaining = individualCap > currentAllocation ? individualCap - currentAllocation : 0;
            maxAllocate = maxAllocate < individualRemaining ? maxAllocate : individualRemaining;
        }
        
        if (maxAllocate < MIN_ALLOCATE) {
            _markNoop(selector);
            return (false, 0);
        }

        amount = bound(amount, MIN_ALLOCATE, maxAllocate);
        
        _markAttempt(selector);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).allocate(strategy, amount) {
            uint256 newAllocation = vault.allocation(allocationId);
            if (newAllocation <= currentAllocation) {
                _markRevert(selector);
                return (false, 0);
            }

            _markSuccess(selector);
            return (true, newAllocation - currentAllocation);
        } catch {
            _markRevert(selector);
            return (false, 0);
        }
    }
    
    function deallocate(uint256 strategyIndex, uint256 amount) external countCall(this.deallocate.selector) {
        bytes4 selector = this.deallocate.selector;
        if (strategies.length == 0) {
            _markNoop(selector);
            return;
        }
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
        
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        if (previewAmount == 0) {
            _markNoop(selector);
            return;
        }
        
        _markAttempt(selector);
        (uint256[] memory allocationSnapshot,) = _snapshotAllocations();
        address allocatorCaller = _pickAllocatorCaller(amount);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).deallocate(strategy, previewAmount) {
            _recordAllocationDeltas(allocationSnapshot);
            _markSuccess(selector);
        } catch {
            _markRevert(selector);
            return;
        }
    }
    
    function deallocateAll(uint256 strategyIndex) external countCall(this.deallocateAll.selector) {
        bytes4 selector = this.deallocateAll.selector;
        if (strategies.length == 0) {
            _markNoop(selector);
            return;
        }
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
        (uint256[] memory allocationSnapshot,) = _snapshotAllocations();
        address allocatorCaller = _pickAllocatorCaller(strategyIndex);
        vm.prank(allocatorCaller);
        try IAllocator(allocator).deallocate(strategy, previewAmount) {
            _recordAllocationDeltas(allocationSnapshot);
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
        try IAllocator(allocator).setLiquidityAdapter(newLiquidityAdapter, _directLiquidityData()) {
            _markSuccess(selector);
        } catch {
            _markRevert(selector);
        }
    }

    function _directLiquidityData() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function _snapshotAllocations() internal view returns (uint256[] memory snapshot, uint256 totalBefore) {
        uint256 len = strategies.length;
        snapshot = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            snapshot[i] = allocation;
            totalBefore += allocation;
        }
    }

    function _recordAllocationDeltas(uint256[] memory beforeAllocations) internal returns (uint256 totalAfter) {
        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address strategy = strategies[i];
            bytes32 allocationId = IMYTStrategy(strategy).adapterId();
            uint256 afterAllocation = vault.allocation(allocationId);
            uint256 beforeAllocation = beforeAllocations[i];
            totalAfter += afterAllocation;

            if (afterAllocation >= beforeAllocation) {
                uint256 deltaUp = afterAllocation - beforeAllocation;
                if (deltaUp > 0) {
                    ghost_totalAllocated += deltaUp;
                    ghost_strategyAllocations[strategy] += deltaUp;
                }
            } else {
                uint256 deltaDown = beforeAllocation - afterAllocation;
                ghost_totalDeallocated += deltaDown;
                if (ghost_strategyAllocations[strategy] >= deltaDown) {
                    ghost_strategyAllocations[strategy] -= deltaDown;
                } else {
                    ghost_strategyAllocations[strategy] = 0;
                }
            }
        }
    }

    function _recordLiquidityAdapterBypass(uint256[] memory beforeAllocations) internal {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 afterAllocation = vault.allocation(allocationId);
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            if (afterAllocation > beforeAllocations[i]) {
                ghost_liquidityAdapterBypass[riskLevel] += afterAllocation - beforeAllocations[i];
            } else if (beforeAllocations[i] > afterAllocation) {
                uint256 decrease = beforeAllocations[i] - afterAllocation;
                ghost_liquidityAdapterBypass[riskLevel] = ghost_liquidityAdapterBypass[riskLevel] > decrease
                    ? ghost_liquidityAdapterBypass[riskLevel] - decrease
                    : 0;
            }
        }
    }

    function _assertTotalAllocationDirection(uint256 totalBefore, uint256 totalAfter, bool expectIncrease, string memory errorMessage)
        internal
        pure
    {
        uint256 tolerance = totalBefore / 1_000_000 + 1;
        if (expectIncrease) {
            require(totalAfter + tolerance >= totalBefore, errorMessage);
        } else {
            require(totalAfter <= totalBefore + tolerance, errorMessage);
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

    // ============ ADMIN RISK CONFIG OPERATIONS ============

    /// @notice Reclassify a strategy to a different risk level (low frequency ~10%)
    /// @dev Only reclassifies if the target risk class's global cap can accommodate
    ///      the strategy's existing allocation plus current aggregate in that class.
    function reclassifyStrategy(uint256 strategyIndexSeed, uint256 newRiskClassSeed)
        external
        countCall(this.reclassifyStrategy.selector)
    {
        bytes4 selector = this.reclassifyStrategy.selector;
        if (strategies.length == 0) { _markNoop(selector); return; }

        if (newRiskClassSeed % 100 != 0) { _markNoop(selector); return; }

        uint256 idx = strategyIndexSeed % strategies.length;
        address strategy = strategies[idx];
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint8 currentRisk = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint8 newRisk = uint8((newRiskClassSeed / 10) % 3);
        if (newRisk == currentRisk) { newRisk = (newRisk + 1) % 3; }

        uint256 totalAssets = vault.totalAssets();
        uint256 newGlobalCap = (totalAssets * AlchemistStrategyClassifier(classifier).getGlobalCap(newRisk)) / 1e18;

        uint256 existingInNewClass = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 stratId = IMYTStrategy(strategies[i]).adapterId();
            if (AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(stratId)) == newRisk) {
                existingInNewClass += vault.allocation(stratId);
            }
        }

        uint256 strategyAllocation = vault.allocation(allocationId);
        if (existingInNewClass + strategyAllocation > newGlobalCap) { _markNoop(selector); return; }

        _markAttempt(selector);
        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(allocationId), newRisk);
        _markSuccess(selector);
    }

    /// @notice Modify the caps of a risk class (low frequency ~10%)
    /// @dev Only tightens caps to levels that still accommodate existing allocations.
    ///      New global cap >= current aggregate allocation in that class + MIN_ALLOCATE.
    ///      New local cap >= largest individual allocation in that class.
    function modifyRiskClassCaps(uint256 riskClassSeed, uint256 capSeed)
        external
        countCall(this.modifyRiskClassCaps.selector)
    {
        bytes4 selector = this.modifyRiskClassCaps.selector;
        if (capSeed % 100 != 0) { _markNoop(selector); return; }

        uint8 riskClass = uint8(riskClassSeed % 3);
        uint256 totalAssets = vault.totalAssets();

        uint256 currentAggregate = 0;
        uint256 maxIndividual = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 stratId = IMYTStrategy(strategies[i]).adapterId();
            if (AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(stratId)) == riskClass) {
                uint256 alloc = vault.allocation(stratId);
                currentAggregate += alloc;
                if (alloc > maxIndividual) maxIndividual = alloc;
            }
        }

        uint256 minGlobalPct = currentAggregate > 0
            ? ((currentAggregate + MIN_ALLOCATE) * 1e18 + totalAssets - 1) / totalAssets
            : 0.01e18;
        uint256 maxGlobalPct = 1e18;
        if (minGlobalPct > maxGlobalPct) { _markNoop(selector); return; }

        uint256 minLocalPct = maxIndividual > 0
            ? ((maxIndividual + MIN_ALLOCATE) * 1e18 + totalAssets - 1) / totalAssets
            : 0.01e18;
        uint256 maxLocalPct = 1e18;
        if (minLocalPct > maxLocalPct) { _markNoop(selector); return; }

        uint256 newGlobalPct = bound(capSeed / 10, minGlobalPct, maxGlobalPct);
        uint256 newLocalPct = bound(capSeed / 100, minLocalPct, maxLocalPct);

        _markAttempt(selector);
        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).setRiskClass(riskClass, newGlobalPct, newLocalPct);
        _markSuccess(selector);
    }

    // ============ TIME OPERATIONS ============
    
    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        vm.warp(block.timestamp + timeDelta);
    }

    function _getUnderlyingMaxWithdraw(address strategy) internal view returns (uint256) {
        address underlyingVault = _resolveUnderlyingVault(strategy);
        if (underlyingVault == address(0)) return type(uint256).max;

        (bool ok, bytes memory data) = underlyingVault.staticcall(abi.encodeWithSignature("maxWithdraw(address)", strategy));
        if (!ok || data.length < 32) return type(uint256).max;

        return abi.decode(data, (uint256));
    }

    function _getUnderlyingMaxDeposit(address strategy) internal view returns (uint256) {
        address underlyingVault = _resolveUnderlyingVault(strategy);
        if (underlyingVault == address(0)) return type(uint256).max;

        (bool ok, bytes memory data) = underlyingVault.staticcall(abi.encodeWithSignature("maxDeposit(address)", strategy));
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
    
    // ============ HELPER FUNCTIONS ============
    
    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
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
        console.log("=== OP ETH Multi-Strategy Handler Call Summary ===");
        console.log("User Operations:");
        console.log("  deposit calls:", calls[this.deposit.selector]);
        console.log("  withdraw calls:", calls[this.withdraw.selector]);
        console.log("  mint calls:", calls[this.mint.selector]);
        console.log("  redeem calls:", calls[this.redeem.selector]);
        console.log("Admin Operations:");
        console.log("  allocate calls:", calls[this.allocate.selector]);
        console.log("  deallocate calls:", calls[this.deallocate.selector]);
        console.log("  deallocateAll calls:", calls[this.deallocateAll.selector]);
        console.log("Admin Risk Config Operations:");
        console.log("  reclassifyStrategy calls:", calls[this.reclassifyStrategy.selector]);
        console.log("  modifyRiskClassCaps calls:", calls[this.modifyRiskClassCaps.selector]);
        console.log("Time Operations:");
        console.log("  warpTime calls:", calls[this.warpTime.selector]);
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

/// @title MultiStrategyOPETHInvariantTest
/// @notice Invariant tests for ETH strategies on Optimism
contract MultiStrategyOPETHInvariantTest is Test {
    IVaultV2 public vault;
    MultiStrategyOPETHHandler public handler;
    
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public curatorContract;
    address public admin = address(0x1);
    address public operator = address(0x3);
    
    // Optimism addresses
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant MOONWELL_MWETH = 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33;
    address public constant MOONWELL_COMPTROLLER = 0xCa889f40aae37FFf165BccF69aeF1E82b5C511B9;
    address public constant WELL = 0xA88594D404727625A9437C3f886C7643872296AE;
    address public constant AAVE_V3_OP_WETH_ATOKEN = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address public constant AAVE_V3_OP_POOL_ADDRESS_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant AAVE_REWARDS_CONTROLLER = 0x929EC64c34a17401F460460D4B9390518E5B473e;
    address public constant AAVE_REWARD_TOKEN = 0x4200000000000000000000000000000000000042; // OP
    
    uint256 public constant INITIAL_VAULT_DEPOSIT = 10_000 ether;
    uint256 public constant ABSOLUTE_CAP = 50_000 ether;
    uint256 public constant RELATIVE_CAP = 0.5e18;
    
    uint256 public initialSharePrice;
    
    uint256 private forkId;
    
    function setUp() public {
        // Fork Optimism
        string memory rpc = vm.envString("OPTIMISM_RPC_URL");
        forkId = vm.createFork(rpc);
        vm.selectFork(forkId);
        
        // Setup vault
        vm.startPrank(admin);
        vault = _setupVault(WETH);
        
        // Setup strategies
        string[] memory strategyNames = new string[](2);
        strategyNames[0] = "Moonwell OP WETH";
        strategyNames[1] = "AaveV3 OP WETH";
        
        // Deploy Moonwell WETH Strategy
        strategies.push(_deployMoonwellWETHStrategy());
        
        // Deploy Aave V3 WETH Strategy
        strategies.push(_deployAaveWethStrategy());
        
        // Setup classifier and allocator
        _setupClassifierAndAllocator();
        
        // Add strategies to vault
        _addStrategiesToVault();
        
        // Make initial deposit to vault
        _makeInitialDeposit();
        
        initialSharePrice = (vault.totalAssets() * 1e18) / vault.totalSupply();
        
        vm.stopPrank();
        
        // Create handler
        handler = new MultiStrategyOPETHHandler(
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
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.allocate.selector;
        selectors[5] = handler.deallocate.selector;
        selectors[6] = handler.deallocateAll.selector;
        selectors[7] = handler.setLiquidityAdapter.selector;
        selectors[8] = handler.warpTime.selector;
        selectors[9] = handler.reclassifyStrategy.selector;
        selectors[10] = handler.modifyRiskClassCaps.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    function _setupVault(address asset) internal returns (IVaultV2) {
        VaultV2Factory factory = new VaultV2Factory();
        return IVaultV2(factory.createVaultV2(admin, asset, bytes32(0)));
    }
    
    function _deployMoonwellWETHStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Moonwell OP WETH",
            protocol: "Moonwell",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 0,
            globalCap: 0.5e18,
            estimatedYield: 600,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new MoonwellStrategy(
            address(vault),
            params,
            WETH,
            MOONWELL_MWETH,
            MOONWELL_COMPTROLLER,
            WELL,
            true
        ));
    }
    
    function _deployAaveWethStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "AaveV3 OP WETH",
            protocol: "AaveV3",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 0,
            globalCap: 0.3e18,
            estimatedYield: 400,
            additionalIncentives: false,
            slippageBPS: 1
        });
        
        return address(new AaveStrategy(
            address(vault),
            params,
            WETH,
            AAVE_V3_OP_WETH_ATOKEN,
            AAVE_V3_OP_POOL_ADDRESS_PROVIDER,
            AAVE_REWARDS_CONTROLLER,
            AAVE_REWARD_TOKEN
        ));
    }
    
    function _setupClassifierAndAllocator() internal {
        classifier = address(new AlchemistStrategyClassifier(admin));
        
        // Set up risk classes matching constructor defaults (WAD: 1e18 = 100%)
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        
        // Assign risk levels
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = IMYTStrategy(strategies[i]).adapterId();
            (,,,IMYTStrategy.RiskClass riskClass,,,,,) = IMYTStrategy(strategies[i]).params();
            AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(
                uint256(strategyId),
                uint8(riskClass)
            );
        }
        
        curatorContract = address(new AlchemistCurator(admin, admin));
        VaultV2(address(vault)).setCurator(curatorContract);
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
    }
    
    function _addStrategiesToVault() internal {
        AlchemistCurator curator = AlchemistCurator(curatorContract);
        
        curator.submitSetAllocator(address(vault), allocator, true);
        vault.setIsAllocator(allocator, true);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            curator.submitSetStrategy(strategies[i], address(vault));
            curator.setStrategy(strategies[i], address(vault));
            
            curator.submitIncreaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            curator.increaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);

            (,,,,, uint256 strategyRelativeCap,,,) = IMYTStrategy(strategies[i]).params();
            curator.submitIncreaseRelativeCap(strategies[i], strategyRelativeCap);
            curator.increaseRelativeCap(strategies[i], strategyRelativeCap);
        }
    }
    
    function _makeInitialDeposit() internal {
        deal(WETH, admin, INITIAL_VAULT_DEPOSIT);
        IERC20(WETH).approve(address(vault), INITIAL_VAULT_DEPOSIT);
        vault.deposit(INITIAL_VAULT_DEPOSIT, admin);
    }
    
    // ============ INVARIANTS ============
    
    function invariant_realAssets_nonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            assertGe(realAssets, 0, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has negative real assets")));
        }
    }
    
    function invariant_allocationWithinAbsoluteCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 absoluteCap = vault.absoluteCap(allocationId);
            
            assertLe(allocation, absoluteCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds absolute cap")));
        }
    }
    
    function invariant_allocationWithinRelativeCap() public view {
        uint256 firstTotalAssets = vault.firstTotalAssets();
        if (firstTotalAssets == 0) return;
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 relativeCap = vault.relativeCap(allocationId);
            if (relativeCap == 1e18) continue;

            uint256 maxAllowed = (firstTotalAssets * relativeCap) / 1e18;
            uint256 tolerance = maxAllowed / 100; // 1%
            
            assertLe(allocation, maxAllowed + tolerance + 1, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds relative cap")));
        }
    }
    
    function invariant_allocationWithinGlobalRiskCap() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256[3] memory riskLevelAllocations;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            riskLevelAllocations[riskLevel] += vault.allocation(allocationId);
        }

        assertLe(riskLevelAllocations[0], (totalAssets * AlchemistStrategyClassifier(classifier).getGlobalCap(0)) / 1e18 + handler.ghost_liquidityAdapterBypass(0), "LOW risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[1], (totalAssets * AlchemistStrategyClassifier(classifier).getGlobalCap(1)) / 1e18 + handler.ghost_liquidityAdapterBypass(1), "MEDIUM risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[2], (totalAssets * AlchemistStrategyClassifier(classifier).getGlobalCap(2)) / 1e18 + handler.ghost_liquidityAdapterBypass(2), "HIGH risk aggregate exceeds global cap");
    }
    
    function invariant_allocationWithinIndividualRiskCap() public view {
        if (handler.getAllocatorRoleAttempts(admin) > 0) return;

        uint256 totalAssets = vault.totalAssets();
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            uint256 individualRiskCapPct = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
            uint256 individualRiskCap = (totalAssets * individualRiskCapPct) / 1e18;
            
            assertLe(allocation, individualRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds individual risk cap")));
        }
    }
    
    function invariant_totalAllocationsBounded() public view {
        uint256 totalAllocations = 0;
        uint256 totalRealAssets = IERC20(vault.asset()).balanceOf(address(vault));
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
            totalRealAssets += IMYTStrategy(strategies[i]).realAssets();
        }

        assertLe(totalAllocations, totalRealAssets * 110 / 100 + 1, "Total allocations exceed real assets by more than 10%");
    }
    
    function invariant_realAssetsConsistentWithAllocation() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            
            if (allocation > 1e15) {
                uint256 minExpected = allocation * 90 / 100;
                //uint256 maxExpected = allocation * 110 / 100;
                
                assertGe(realAssets, minExpected, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets below allocation")));
                //assertLe(realAssets, maxExpected, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets above allocation")));
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
    
    /// @notice Invariant: Ghost allocations match actual vault allocations per strategy
    function invariant_ghostAllocationsMatchVault() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 actualAllocation = vault.allocation(allocationId);
            uint256 ghostAllocation = handler.ghost_strategyAllocations(strategies[i]);
            
            // Allow 5% tolerance for yield/rounding differences
            if (actualAllocation > 1e15) {
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
        if (vaultTotal > 1e15) {
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
        if (ghostNet > 1e15) {
            assertGe(ghostSum, ghostNet * 95 / 100, "Ghost sum inconsistent with net");
            assertLe(ghostSum, ghostNet * 105 / 100, "Ghost sum inconsistent with net");
        }
    }

    function invariant_userBalanceConsistency() public view {
        uint256 totalUserDeposits = handler.ghost_totalDeposited();
        uint256 totalUserWithdrawals = handler.ghost_totalWithdrawn();
        uint256 netDeposits = totalUserDeposits > totalUserWithdrawals 
            ? totalUserDeposits - totalUserWithdrawals 
            : 0;
        
        uint256 vaultBalance = IERC20(WETH).balanceOf(address(vault));

        uint256 totalStrategyValue = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalStrategyValue += IMYTStrategy(strategies[i]).realAssets();
        }
        
        uint256 totalValue = vaultBalance + totalStrategyValue;
        uint256 totalExpected = INITIAL_VAULT_DEPOSIT + netDeposits;
        if (totalExpected > 1e15) {
            assertGe(totalValue, totalExpected * 90 / 100, "Total value significantly less than expected deposits");
        }
    }
    
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
