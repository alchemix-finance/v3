// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IStrategyClassifier} from "../../interfaces/IStrategyClassifier.sol";

import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../../Transmuter.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";

import {ITestYieldToken} from "../../interfaces/test/ITestYieldToken.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {AlchemistNFTHelper} from "../libraries/AlchemistNFTHelper.sol";

interface IStrategySimulationProvider {
    function onSimulateYield(address strategy, uint256 amount) external;
    function onSimulateValueLoss(address strategy, uint256 amount) external;
}

contract E2EStrategyHandler is Test {

    IVaultV2 public vault;
    address public allocator;
    address public classifier;
    address public asset;
    address public admin;
    address public operator;

    AlchemistV3 public alchemist;
    AlchemistV3Position public alchemistNFT;
    AlchemicTokenV3 public alToken;
    Transmuter public transmuter;

    address[] public strategies;
    mapping(address => string) public strategyNames;

    address[] public actors;
    address[] public alchSenders;
    address internal currentActor;

    address public mockStrategyA;
    address public mockStrategyB;
    address public mockYieldTokenA;
    address public mockYieldTokenB;

    mapping(address => bool) public forceDeallocateEnabled;

    /// when address(0), the handler applies the default deal-to-strategy logic inline.
    address public simulator;

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalDeallocated;
    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_strategyAllocations;
    uint256 public ghost_totalCollateralDeposited;
    uint256 public ghost_totalDebtMinted;
    uint256 public ghost_totalDebtRepaid;
    mapping(uint8 => uint256) public ghost_liquidityAdapterBypass;

    mapping(bytes4 => uint256) public calls;
    mapping(bytes4 => uint256) public skips;
    mapping(bytes4 => uint256) public executed;
    mapping(address => uint256) public allocatorRoleAttempts;
    mapping(uint256 => uint256) internal lastBorrowBlock;
    mapping(uint256 => uint256) internal lastRepayBlock;
    uint256 internal allocatorRoleNonce;

    uint256 public MIN_DEPOSIT;
    uint256 public MIN_ALLOCATE;
    uint256 public constant BPS = 10_000;

    struct InitParams {
        address vault;
        address[] strategies;
        address allocator;
        address classifier;
        address admin;
        address operator;
        address alchemist;
        address alchemistNFT;
        address alToken;
        address transmuter;
        address[] actors;
        address[] alchSenders;
        address mockStrategyA;
        address mockStrategyB;
        address mockYieldTokenA;
        address mockYieldTokenB;
    }

    constructor(InitParams memory p) {
        vault = IVaultV2(p.vault);
        strategies = p.strategies;
        allocator = p.allocator;
        classifier = p.classifier;
        admin = p.admin;
        operator = p.operator;
        alchemist = AlchemistV3(p.alchemist);
        alchemistNFT = AlchemistV3Position(p.alchemistNFT);
        alToken = AlchemicTokenV3(p.alToken);
        transmuter = Transmuter(p.transmuter);
        asset = vault.asset();
        uint256 dec = TokenUtils.expectDecimals(asset);
        MIN_DEPOSIT = 10 ** (dec - 3);
        MIN_ALLOCATE = 10 ** (dec - 4);
        actors = p.actors;
        alchSenders = p.alchSenders;
        mockStrategyA = p.mockStrategyA;
        mockStrategyB = p.mockStrategyB;
        mockYieldTokenA = p.mockYieldTokenA;
        mockYieldTokenB = p.mockYieldTokenB;
        
        forceDeallocateEnabled[p.mockStrategyA] = true;
        forceDeallocateEnabled[p.mockStrategyB] = true;
    }

    modifier countCall(bytes4 selector) {
        calls[selector]++;
        _;
    }

    modifier useActor(uint256 actorSeed) {
        require(actors.length > 0, "no actors");
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function deposit(uint256 amount, uint256 actorSeed) external countCall(this.deposit.selector) useActor(actorSeed) {
        bytes4 selector = this.deposit.selector;
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) {
            skips[selector]++;
            return;
        }

        uint256 maxEnter = _maxEnterAssets();
        uint256 upperBound = balance < maxEnter ? balance : maxEnter;
        if (upperBound < MIN_DEPOSIT) {
            skips[selector]++;
            return;
        }

        amount = bound(amount, MIN_DEPOSIT, upperBound);

        IERC20(asset).approve(address(vault), amount);
        uint256[] memory snap = _snapshotAllocations();

        vault.deposit(amount, currentActor);
        executed[selector]++;

        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
        _recordAllocationDeltas(snap);
    }

    function withdraw(uint256 amount, uint256 actorSeed) external countCall(this.withdraw.selector) useActor(actorSeed) {
        bytes4 selector = this.withdraw.selector;
        uint256 shares = vault.balanceOf(currentActor);
        if (shares == 0) {
            skips[selector]++;
            return;
        }
        uint256 maxAssets = vault.convertToAssets(shares);
        if (maxAssets == 0) {
            skips[selector]++;
            return;
        }

        uint256 vaultIdle = IERC20(asset).balanceOf(address(vault));
        if (vaultIdle == 0) {
            skips[selector]++;
            return;
        }
        uint256 upperBound = maxAssets < vaultIdle ? maxAssets : vaultIdle;

        amount = bound(amount, 1, upperBound);
        uint256[] memory snap = _snapshotAllocations();

        vault.withdraw(amount, currentActor, currentActor);
        executed[selector]++;

        ghost_totalWithdrawn += amount;
        if (ghost_userDeposits[currentActor] >= amount) {
            ghost_userDeposits[currentActor] -= amount;
        } else {
            ghost_userDeposits[currentActor] = 0;
        }
        _recordAllocationDeltas(snap);
    }

    function mint(uint256 shares, uint256 actorSeed) external countCall(this.mint.selector) useActor(actorSeed) {
        bytes4 selector = this.mint.selector;
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) {
            skips[selector]++;
            return;
        }
        uint256 maxEnter = _maxEnterAssets();
        uint256 maxAssets = balance < maxEnter ? balance : maxEnter;
        if (maxAssets < MIN_DEPOSIT) {
            skips[selector]++;
            return;
        }
        uint256 maxShares = vault.convertToShares(maxAssets);
        if (maxShares == 0) {
            skips[selector]++;
            return;
        }

        shares = bound(shares, 1, maxShares);

        IERC20(asset).approve(address(vault), balance);
        uint256[] memory snap = _snapshotAllocations();

        uint256 assetsDeposited = vault.mint(shares, currentActor);
        executed[selector]++;

        ghost_totalDeposited += assetsDeposited;
        ghost_userDeposits[currentActor] += assetsDeposited;
        _recordAllocationDeltas(snap);
    }

    function redeem(uint256 shares, uint256 actorSeed) external countCall(this.redeem.selector) useActor(actorSeed) {
        bytes4 selector = this.redeem.selector;
        uint256 userShares = vault.balanceOf(currentActor);
        if (userShares == 0) {
            skips[selector]++;
            return;
        }

        uint256 vaultIdle = IERC20(asset).balanceOf(address(vault));
        if (vaultIdle == 0) {
            skips[selector]++;
            return;
        }
        uint256 maxSharesFromIdle = vault.convertToShares(vaultIdle);
        uint256 upperBound = userShares < maxSharesFromIdle ? userShares : maxSharesFromIdle;
        if (upperBound == 0) {
            skips[selector]++;
            return;
        }

        shares = bound(shares, 1, upperBound);
        uint256[] memory snap = _snapshotAllocations();

        uint256 assetsRedeemed = vault.redeem(shares, currentActor, currentActor);
        executed[selector]++;

        ghost_totalWithdrawn += assetsRedeemed;
        if (ghost_userDeposits[currentActor] >= assetsRedeemed) {
            ghost_userDeposits[currentActor] -= assetsRedeemed;
        } else {
            ghost_userDeposits[currentActor] = 0;
        }
        _recordAllocationDeltas(snap);
    }

    function allocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.allocate.selector) {
        bytes4 selector = this.allocate.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }

        address strategy = strategies[strategyIndexSeed % len];
        address caller = _pickAllocatorCaller();
        (bool canProceed, uint256 maxAllocate) = _computeAllocateBounds(strategy, caller);

        uint256 idle = IERC20(asset).balanceOf(address(vault));
        if (maxAllocate > idle) maxAllocate = idle;

        if (!canProceed || maxAllocate < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        amount = bound(amount, MIN_ALLOCATE, maxAllocate);

        uint256[] memory snap = _snapshotAllocations();

        vm.prank(caller);
        IAllocator(allocator).allocate(strategy, amount);
        executed[selector]++;

        _recordAllocationDeltas(snap);
    }

    function deallocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.deallocate.selector) {
        bytes4 selector = this.deallocate.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        address strategy = strategies[strategyIndexSeed % len];

        (bool canProceed, uint256 maxDeallocate) = _computeDeallocateBounds(strategy);
        if (!canProceed || maxDeallocate < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        amount = bound(amount, MIN_ALLOCATE, maxDeallocate);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        if (preview == 0) {
            skips[selector]++;
            return;
        }

        uint256[] memory snap = _snapshotAllocations();

        vm.prank(_pickAllocatorCaller());
        IAllocator(allocator).deallocate(strategy, preview);
        executed[selector]++;

        _recordAllocationDeltas(snap);
    }

    function deallocateAll(uint256 strategyIndexSeed) external countCall(this.deallocateAll.selector) {
        bytes4 selector = this.deallocateAll.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        address strategy = strategies[strategyIndexSeed % len];

        (bool canProceed, uint256 maxDeallocate) = _computeDeallocateBounds(strategy);
        if (!canProceed || maxDeallocate < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(maxDeallocate);
        if (preview == 0) {
            skips[selector]++;
            return;
        }

        uint256[] memory snap = _snapshotAllocations();

        vm.prank(_pickAllocatorCaller());
        IAllocator(allocator).deallocate(strategy, preview);
        executed[selector]++;

        _recordAllocationDeltas(snap);
    }

    /// strategies that have force-deallocate enabled
    function forceDeallocate(uint256 strategyIndexSeed, uint256 amount, uint256 actorSeed)
        external
        countCall(this.forceDeallocate.selector)
        useActor(actorSeed)
    {
        bytes4 selector = this.forceDeallocate.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        address strategy = strategies[strategyIndexSeed % len];
        if (!forceDeallocateEnabled[strategy]) {
            skips[selector]++;
            return;
        }

        uint256 userShares = vault.balanceOf(currentActor);
        if (userShares == 0) {
            skips[selector]++;
            return;
        }
        uint256 maxAssets = vault.convertToAssets(userShares);
        if (maxAssets < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        if (currentAllocation < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        uint256 strategyRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 upperBound = maxAssets < currentAllocation ? maxAssets : currentAllocation;
        if (strategyRealAssets < upperBound) {
            upperBound = strategyRealAssets;
        }
        if (upperBound < MIN_ALLOCATE) {
            skips[selector]++;
            return;
        }

        amount = bound(amount, MIN_ALLOCATE, upperBound);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        bytes memory data = abi.encode(params);

        uint256[] memory snap = _snapshotAllocations();

        vault.forceDeallocate(strategy, data, amount, currentActor);
        executed[selector]++;

        _recordAllocationDeltas(snap);
    }

    function reclassifyStrategy(uint256 strategyIndexSeed, uint256 newRiskClassSeed) external countCall(this.reclassifyStrategy.selector) {
        bytes4 selector = this.reclassifyStrategy.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        if (newRiskClassSeed % 100 != 0) {
            skips[selector]++;
            return;
        }

        address strategy = strategies[strategyIndexSeed % len];
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint8 currentRisk = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint8 newRisk = uint8((newRiskClassSeed / 10) % 3);
        if (newRisk == currentRisk) {
            newRisk = (newRisk + 1) % 3;
        }

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
        if (existingInNewClass + strategyAllocation > newGlobalCap) {
            skips[selector]++;
            return;
        }

        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(allocationId), newRisk);
        executed[selector]++;
    }

    function modifyRiskClassCaps(uint256 riskClassSeed, uint256 capSeed) external countCall(this.modifyRiskClassCaps.selector) {
        bytes4 selector = this.modifyRiskClassCaps.selector;
        if (capSeed % 100 != 0) {
            skips[selector]++;
            return;
        }

        uint8 riskClass = uint8(riskClassSeed % 3);
        uint256 totalAssets = vault.totalAssets();

        uint256 currentAggregate = 0;
        uint256 maxIndividual = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 stratId = IMYTStrategy(strategies[i]).adapterId();
            if (AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(stratId)) == riskClass) {
                uint256 alloc = vault.allocation(stratId);
                currentAggregate += alloc;
                if (alloc > maxIndividual) {
                    maxIndividual = alloc;
                }
            }
        }

        uint256 minGlobalPct = currentAggregate > 0 ? ((currentAggregate + MIN_ALLOCATE) * 1e18 + totalAssets - 1) / totalAssets : 0.01e18;
        uint256 maxGlobalPct = 1e18;
        if (minGlobalPct > maxGlobalPct) {
            skips[selector]++;
            return;
        }

        uint256 minLocalPct = maxIndividual > 0 ? ((maxIndividual + MIN_ALLOCATE) * 1e18 + totalAssets - 1) / totalAssets : 0.01e18;
        uint256 maxLocalPct = 1e18;
        if (minLocalPct > maxLocalPct) {
            skips[selector]++;
            return;
        }

        uint256 newGlobalPct = bound(capSeed / 10, minGlobalPct, maxGlobalPct);
        uint256 newLocalPct = bound(capSeed / 100, minLocalPct, maxLocalPct);

        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).setRiskClass(riskClass, newGlobalPct, newLocalPct);
        executed[selector]++;
    }

    function setLiquidityAdapter(uint256 strategySeed, uint256 modeSeed) external countCall(this.setLiquidityAdapter.selector) {
        bytes4 selector = this.setLiquidityAdapter.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }

        address newLiquidityAdapter = address(0);
        if (modeSeed % 3 != 0) {
            address candidate = strategies[strategySeed % len];
            if (_liquidityAdapterHasHeadroom(candidate)) {
                newLiquidityAdapter = candidate;
            }
        }

        vm.prank(_pickAllocatorCaller());
        try IAllocator(allocator).setLiquidityAdapter(newLiquidityAdapter, _directLiquidityData()) {
            executed[selector]++;
        } catch {
            skips[selector]++;
        }
    }

    function _directLiquidityData() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    // bounded to cap headroom
    function _maxEnterAssets() internal view returns (uint256 maxEnter) {
        address adapter = vault.liquidityAdapter();
        if (adapter == address(0)) return type(uint256).max;

        bytes32 id = IMYTStrategy(adapter).adapterId();
        uint256 allocation = vault.allocation(id);
        uint256 absoluteCap = vault.absoluteCap(id);
        if (absoluteCap == 0 || allocation >= absoluteCap) return 0;

        maxEnter = absoluteCap - allocation;

        uint256 relativeCap = vault.relativeCap(id);
        if (relativeCap != type(uint256).max && relativeCap != 1e18) {
            uint256 firstTotalAssets = vault.firstTotalAssets();
            if (firstTotalAssets == 0) return 0;
            uint256 relativeLimit = (firstTotalAssets * relativeCap) / 1e18;
            if (relativeLimit <= allocation) return 0;
            uint256 relativeHeadroom = relativeLimit - allocation;
            if (relativeHeadroom < maxEnter) maxEnter = relativeHeadroom;
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
        return hardLimit - currentAllocation >= MIN_DEPOSIT * 10;
    }

    function simulateYield(uint256 strategyIndexSeed, uint256 bpsSeed) external countCall(this.simulateYield.selector) {
        bytes4 selector = this.simulateYield.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        address strategy = strategies[strategyIndexSeed % len];

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        if (currentAllocation == 0) {
            skips[selector]++;
            return;
        }

        uint256 bps = bound(bpsSeed, 1, 10); // ~0.01%-0.1% per call
        uint256 yieldAmount = (currentAllocation * bps) / BPS;
        if (yieldAmount == 0) {
            skips[selector]++;
            return;
        }

        if (strategy == mockStrategyA) {
            _depositToMockYieldToken(strategy, mockYieldTokenA, yieldAmount);
        } else if (strategy == mockStrategyB) {
            _depositToMockYieldToken(strategy, mockYieldTokenB, yieldAmount);
        } else if (simulator != address(0)) {
            IStrategySimulationProvider(simulator).onSimulateYield(strategy, yieldAmount);
        } else {
            uint256 currentIdle = IERC20(asset).balanceOf(strategy);
            deal(asset, strategy, currentIdle + yieldAmount);
        }
        executed[selector]++;
    }

    function simulateValueLoss(uint256 strategyIndexSeed, uint256 bpsSeed) external countCall(this.simulateValueLoss.selector) {
        bytes4 selector = this.simulateValueLoss.selector;
        uint256 len = strategies.length;
        if (len == 0) {
            skips[selector]++;
            return;
        }
        address strategy = strategies[strategyIndexSeed % len];

        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        if (currentRealAssets == 0) {
            skips[selector]++;
            return;
        }

        uint256 bps = bound(bpsSeed, 1, 10);
        uint256 lossAmount = (currentRealAssets * bps) / BPS;
        if (lossAmount == 0) {
            skips[selector]++;
            return;
        }

        address yieldToken;
        if (strategy == mockStrategyA) {
            yieldToken = mockYieldTokenA;
        } else if (strategy == mockStrategyB) {
            yieldToken = mockYieldTokenB;
        }

        if (yieldToken != address(0)) {
            uint256 shareBal = IERC20(yieldToken).balanceOf(strategy);
            uint256 lossShares = (shareBal * bps) / BPS;
            if (lossShares == 0) {
                skips[selector]++;
                return;
            }
            vm.prank(strategy);
            IERC20(yieldToken).transfer(address(0xdead), lossShares);
        } else if (simulator != address(0)) {
            IStrategySimulationProvider(simulator).onSimulateValueLoss(strategy, lossAmount);
        } else {
            uint256 currentIdle = IERC20(asset).balanceOf(strategy);
            if (currentIdle < lossAmount) {
                skips[selector]++;
                return;
            }
            deal(asset, strategy, currentIdle - lossAmount);
        }
        executed[selector]++;
    }

    function _depositToMockYieldToken(address strategy, address yieldToken, uint256 amount) internal {
        deal(asset, strategy, IERC20(asset).balanceOf(strategy) + amount);
        vm.startPrank(strategy);
        TokenUtils.safeApprove(asset, yieldToken, amount);
        MockYieldToken(yieldToken).deposit(amount);
        vm.stopPrank();
    }

    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        vm.warp(block.timestamp + timeDelta);
        executed[this.warpTime.selector]++;
    }

    function mine(uint256 blocks) external countCall(this.mine.selector) {
        blocks = bound(blocks, 1, 72_000);
        vm.roll(block.number + blocks);
        executed[this.mine.selector]++;
    }

    function alchemistDepositCollateral(uint256 senderSeed, uint256 amountSeed) external countCall(this.alchemistDepositCollateral.selector) {
        bytes4 selector = this.alchemistDepositCollateral.selector;
        if (alchSenders.length == 0) {
            skips[selector]++;
            return;
        }
        address sender = alchSenders[senderSeed % alchSenders.length];

        uint256 shareBalance = vault.balanceOf(sender);
        if (shareBalance < MIN_DEPOSIT) {
            skips[selector]++;
            return;
        }

        if (_protocolInBadDebt()) {
            skips[selector]++;
            return;
        }

        uint256 amount = bound(amountSeed, MIN_DEPOSIT, shareBalance);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(sender, address(alchemistNFT));

        vm.startPrank(sender);
        (tokenId,) = alchemist.deposit(amount, sender, tokenId);
        vm.stopPrank();
        executed[selector]++;

        ghost_totalCollateralDeposited += amount;
    }

    function alchemistBorrow(uint256 senderSeed, uint256 amountSeed) external countCall(this.alchemistBorrow.selector) {
        bytes4 selector = this.alchemistBorrow.selector;
        if (alchSenders.length == 0) {
            skips[selector]++;
            return;
        }
        address sender = alchSenders[senderSeed % alchSenders.length];
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(sender, address(alchemistNFT));
        if (tokenId == 0) {
            skips[selector]++;
            return;
        }

        uint256 maxBorrowable = alchemist.getMaxBorrowable(tokenId);
        if (maxBorrowable == 0) {
            skips[selector]++;
            return;
        }

        if (_protocolInBadDebt()) {
            skips[selector]++;
            return;
        }

        uint256 amount = bound(amountSeed, 1, maxBorrowable);
        if (block.number == lastRepayBlock[tokenId]) {
            skips[selector]++;
            return;
        }
        vm.prank(sender);
        alchemist.mint(tokenId, amount, sender);
        executed[selector]++;
        lastBorrowBlock[tokenId] = block.number;

        ghost_totalDebtMinted += amount;
    }

    function alchemistRepayDebt(uint256 senderSeed, uint256 amountSeed) external countCall(this.alchemistRepayDebt.selector) {
        bytes4 selector = this.alchemistRepayDebt.selector;
        if (alchSenders.length == 0) {
            skips[selector]++;
            return;
        }
        address sender = alchSenders[senderSeed % alchSenders.length];
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(sender, address(alchemistNFT));
        if (tokenId == 0) {
            skips[selector]++;
            return;
        }

        (, uint256 debt,) = alchemist.getCDP(tokenId);
        if (debt == 0) {
            skips[selector]++;
            return;
        }

        uint256 alBalance = alToken.balanceOf(sender);
        uint256 repayAmount = bound(amountSeed, 1, debt < alBalance ? debt : alBalance);
        if (repayAmount == 0) {
            skips[selector]++;
            return;
        }

        if (block.number == lastBorrowBlock[tokenId]) {
            skips[selector]++;
            return;
        }

        if (_protocolInBadDebt()) {
            skips[selector]++;
            return;
        }

        uint256 collateralValue = alchemist.totalValue(tokenId);
        uint256 required = (debt * alchemist.minimumCollateralization() + 1e18 - 1) / 1e18;
        if (collateralValue < required) {
            skips[selector]++;
            return;
        }

        vm.prank(sender);
        alchemist.burn(repayAmount, tokenId);
        executed[selector]++;
        lastRepayBlock[tokenId] = block.number;

        ghost_totalDebtRepaid += repayAmount;
    }

    function _computeAllocateBounds(address strategy, address caller) internal view returns (bool canProceed, uint256 maxAllocate) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);

        if (absoluteCap == 0) return (false, 0);
        if (currentAllocation >= absoluteCap) return (false, 0);


        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint256 globalRiskHeadroom = _remainingGlobalRiskHeadroom(riskLevel);
        if (globalRiskHeadroom < MIN_ALLOCATE) return (false, 0);

        uint256 underlyingMaxDeposit = _getUnderlyingMaxDeposit(strategy);
        if (underlyingMaxDeposit < MIN_ALLOCATE) return (false, 0);

        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 pendingYield = currentRealAssets > currentAllocation ? currentRealAssets - currentAllocation : 0;
        uint256 postCallAllocation = currentAllocation + pendingYield;

        uint256 maxByAbsoluteRemaining = absoluteCap > postCallAllocation ? absoluteCap - postCallAllocation : 0;
        uint256 maxByRelativeCap = _relativeCapHeadroom(relativeCap, postCallAllocation);

        maxAllocate = maxByAbsoluteRemaining;
        if (maxByRelativeCap < maxAllocate) maxAllocate = maxByRelativeCap;
        if (globalRiskHeadroom < maxAllocate) maxAllocate = globalRiskHeadroom;
        if (underlyingMaxDeposit < maxAllocate) maxAllocate = underlyingMaxDeposit;

        // Individual risk cap is allocator-enforced (operator path only, matching production).
        if (caller != admin) {
            uint256 maxByIndividual = _individualCapHeadroom(allocationId, currentAllocation);
            if (maxByIndividual < maxAllocate) maxAllocate = maxByIndividual;
        }

        return (true, maxAllocate);
    }

    function _relativeCapHeadroom(uint256 relativeCap, uint256 effectiveAllocation) internal view returns (uint256) {
        if (relativeCap == type(uint256).max) return type(uint256).max;

        uint256 capValue = (vault.totalAssets() * relativeCap) / 1e18;
        return capValue > effectiveAllocation ? capValue - effectiveAllocation : 0;
    }

    function _individualCapHeadroom(bytes32 allocationId, uint256 effectiveAllocation) internal view returns (uint256) {
        uint256 individualCapPct = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
        uint256 individualCap = (vault.totalAssets() * individualCapPct) / 1e18;
        return individualCap > effectiveAllocation ? individualCap - effectiveAllocation : 0;
    }

    function _computeDeallocateBounds(address strategy) internal view returns (bool canProceed, uint256 maxDeallocate) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        if (currentAllocation < MIN_ALLOCATE) return (false, 0);

        maxDeallocate = currentAllocation;
        uint256 protocolMaxWithdraw = _getUnderlyingMaxWithdraw(strategy);
        if (protocolMaxWithdraw >= MIN_ALLOCATE && protocolMaxWithdraw < maxDeallocate) {
            maxDeallocate = protocolMaxWithdraw;
        }
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        if (currentRealAssets < maxDeallocate) {
            maxDeallocate = currentRealAssets;
        }
        if (maxDeallocate < MIN_ALLOCATE) return (false, 0);

        return (true, maxDeallocate);
    }

    function _remainingGlobalRiskHeadroom(uint8 riskLevel) internal view returns (uint256) {
        uint256 globalRiskCapPct = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        uint256 globalRiskCap = (vault.totalAssets() * globalRiskCapPct) / 1e18;
        uint256 currentRiskAllocation = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 stratId = IMYTStrategy(strategies[i]).adapterId();
            if (AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(stratId)) == riskLevel) {
                currentRiskAllocation += vault.allocation(stratId);
            }
        }

        if (currentRiskAllocation >= globalRiskCap) return 0;
        return globalRiskCap - currentRiskAllocation;
    }

    function _protocolInBadDebt() internal view returns (bool) {
        AlchemistV3 al = AlchemistV3(alchemist);
        uint256 tsi = al.totalSyntheticsIssued();
        if (tsi == 0) return false;

        uint256 lockedUnderlying = al.getTotalLockedUnderlyingValue();
        uint256 transmuterShares = IERC20(al.myt()).balanceOf(al.transmuter());
        uint256 backingUnderlying = lockedUnderlying + al.convertYieldTokensToUnderlying(transmuterShares);
        uint256 backingDebt = al.normalizeUnderlyingTokensToDebt(backingUnderlying);

        return tsi > backingDebt;
    }

    function _snapshotAllocations() internal view returns (uint256[] memory snapshot) {
        uint256 len = strategies.length;
        snapshot = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            snapshot[i] = vault.allocation(allocationId);
        }
    }

    function _recordAllocationDeltas(uint256[] memory beforeAllocations) internal {
        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address strategy = strategies[i];
            bytes32 allocationId = IMYTStrategy(strategy).adapterId();
            uint256 afterAllocation = vault.allocation(allocationId);
            uint256 beforeAllocation = beforeAllocations[i];
            uint8 riskLevel = IStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));

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

            _recordLiquidityAdapterBypassDelta(riskLevel, beforeAllocation, afterAllocation);
        }
    }

    function _recordLiquidityAdapterBypassDelta(uint8 riskLevel, uint256 beforeAllocation, uint256 afterAllocation) internal {
        if (afterAllocation > beforeAllocation) {
            ghost_liquidityAdapterBypass[riskLevel] += afterAllocation - beforeAllocation;
        } else if (beforeAllocation > afterAllocation) {
            uint256 decrease = beforeAllocation - afterAllocation;
            ghost_liquidityAdapterBypass[riskLevel] =
                ghost_liquidityAdapterBypass[riskLevel] > decrease ? ghost_liquidityAdapterBypass[riskLevel] - decrease : 0;
        }
    }

    function _getUnderlyingMaxDeposit(address strategy) internal view returns (uint256) {
        address underlyingVault = _resolveUnderlyingVault(strategy);
        if (underlyingVault == address(0)) return type(uint256).max;

        (bool ok, bytes memory data) = underlyingVault.staticcall(abi.encodeWithSignature("maxDeposit(address)", strategy));
        if (!ok || data.length < 32) return type(uint256).max;
        return abi.decode(data, (uint256));
    }

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

    function _pickAllocatorCaller() internal returns (address caller) {
        caller = allocatorRoleNonce % 2 == 0 ? admin : operator;
        allocatorRoleNonce++;
        allocatorRoleAttempts[caller]++;
    }

    function ghost_netAllocated() external view returns (uint256) {
        if (ghost_totalAllocated >= ghost_totalDeallocated) {
            return ghost_totalAllocated - ghost_totalDeallocated;
        }
        return 0;
    }

    function ghost_sumStrategyAllocations() external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            sum += ghost_strategyAllocations[strategies[i]];
        }
        return sum;
    }

    function vault_totalAllocations() external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            sum += vault.allocation(allocationId);
        }
        return sum;
    }

    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function getCalls(bytes4 selector) external view returns (uint256) {
        return calls[selector];
    }

    function getStats(bytes4 selector) external view returns (uint256 calls_, uint256 skips_, uint256 executed_) {
        return (calls[selector], skips[selector], executed[selector]);
    }

    function getAllocatorRoleAttempts(address role) external view returns (uint256) {
        return allocatorRoleAttempts[role];
    }

    ///      force-deallocate (i.e. its `_canForceDeallocate` returns true / was enabled).
    function setForceDeallocateEnabled(address strategy, bool enabled) external {
        forceDeallocateEnabled[strategy] = enabled;
    }

    ///      handler delegates yield/loss injection to this address instead of dealing inline.
    function setSimulator(address _simulator) external {
        simulator = _simulator;
    }

    function callSummary() external view {
        console.log("=== E2E Strategy Handler Call Summary ===");
        console.log("deposit:       ", calls[this.deposit.selector]);
        console.log("withdraw:      ", calls[this.withdraw.selector]);
        console.log("mint:          ", calls[this.mint.selector]);
        console.log("redeem:        ", calls[this.redeem.selector]);
        console.log("allocate:      ", calls[this.allocate.selector]);
        console.log("deallocate:    ", calls[this.deallocate.selector]);
        console.log("deallocateAll: ", calls[this.deallocateAll.selector]);
        console.log("forceDealloc:  ", calls[this.forceDeallocate.selector]);
        console.log("reclassify:    ", calls[this.reclassifyStrategy.selector]);
        console.log("modifyCaps:    ", calls[this.modifyRiskClassCaps.selector]);
        console.log("setLiqAdapter: ", calls[this.setLiquidityAdapter.selector]);
        console.log("simulateYield: ", calls[this.simulateYield.selector]);
        console.log("simulateLoss:  ", calls[this.simulateValueLoss.selector]);
        console.log("warpTime:      ", calls[this.warpTime.selector]);
        console.log("mine:          ", calls[this.mine.selector]);
        console.log("alchDeposit:   ", calls[this.alchemistDepositCollateral.selector]);
        console.log("alchBorrow:    ", calls[this.alchemistBorrow.selector]);
        console.log("alchRepay:     ", calls[this.alchemistRepayDebt.selector]);
        console.log("ghost_totalAllocated:   ", ghost_totalAllocated);
        console.log("ghost_totalDeallocated: ", ghost_totalDeallocated);
        console.log("ghost_totalDeposited:   ", ghost_totalDeposited);
        console.log("ghost_totalWithdrawn:   ", ghost_totalWithdrawn);
    }
}
