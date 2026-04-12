// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {RevertContext, IRevertAllowlistProvider} from "./StrategyTypes.sol";
import {StrategyHandler} from "./StrategyHandler.sol";

/// @notice Environment/bootstrap layer for all strategy base tests.
/// @dev Owns fork selection, vault/allocator wiring, shared state, and strategy extension hooks.
abstract contract StrategySetup is Test, IRevertAllowlistProvider {
    IMYTStrategy.StrategyParams public strategyConfig;
    TestConfig public testConfig;

    // Common state variables
    address public strategy;
    address public vault;
    address public allocator;
    address public classifier;
    StrategyHandler public handler;
    uint256 private _forkId;

    // Common addresses - can be overridden by child contracts
    address public admin = address(1);
    address public curator = address(2);
    address public operator = address(3);
    address public vaultDepositor = address(4);

    struct TestConfig {
        address vaultAsset;
        uint256 vaultInitialDeposit;
        uint256 absoluteCap;
        uint256 relativeCap;
        uint256 decimals;
    }

    // Minimum allocation amount to satisfy underlying protocol requirements (e.g., Aave V3 min supply)
    // Represents 0.001 tokens - computed dynamically based on asset decimals
    uint256 public constant MIN_ALLOCATE_AMOUNT_SCALAR = 3; // 10^(decimals - 3) = 0.001 tokens

    // Abstract functions that must be implemented by child contracts
    function getTestConfig() internal virtual returns (TestConfig memory);
    function getStrategyConfig() internal virtual returns (IMYTStrategy.StrategyParams memory);
    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal virtual returns (address);
    function getForkBlockNumber() internal virtual returns (uint256);
    function getRpcUrl() internal virtual returns (string memory);
    function isProtocolRevertAllowed(bytes4, RevertContext) external view virtual returns (bool) {
        return false;
    }

    function getAllocateVaultParams(uint256) internal view virtual returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    /// @dev Optional strategy-specific deallocation params hook.
    ///      Default behavior uses direct action, matching `getVaultParams()`.
    function getDeallocateVaultParams(uint256) internal view virtual returns (bytes memory) {
        return getVaultParams();
    }

    /// @dev Optional strategy-specific allocator deallocate mode.
    ///      Default behavior uses direct allocator deallocate.
    function _useAllocatorDeallocateSwap() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Optional strategy-specific calldata provider for allocator swap deallocate.
    function _allocatorDeallocateSwapData(uint256) internal view virtual returns (bytes memory) {
        return bytes("");
    }

    function isMytRevertAllowed(bytes4, RevertContext) external view virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        testConfig = getTestConfig();
        strategyConfig = getStrategyConfig();

        // Fork setup
        string memory rpc = getRpcUrl();
        if (getForkBlockNumber() > 0) {
            _forkId = vm.createFork(rpc, getForkBlockNumber());
        } else {
            _forkId = vm.createFork(rpc);
        }
        vm.selectFork(_forkId);

        // Core setup
        vm.startPrank(admin);
        vault = _getVault(testConfig.vaultAsset);
        strategy = createStrategy(vault, strategyConfig);
        vm.stopPrank();

        _setUpMYT(vault, strategy, testConfig.absoluteCap, testConfig.relativeCap);
        _magicDepositToVault(vault, vaultDepositor, testConfig.vaultInitialDeposit);
        require(IVaultV2(vault).totalAssets() == testConfig.vaultInitialDeposit, "vault total assets mismatch");
        vm.makePersistent(strategy);

        // Setup Invariant Handler
        handler = new StrategyHandler(vault, strategy, allocator, admin, address(this), classifier, _getMinAllocateAmount());
        targetContract(address(handler));

        // Target specific functions in the handler for invariant fuzzing
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.allocate.selector;
        selectors[1] = handler.deallocate.selector;
        selectors[2] = handler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _getVault(address asset) internal returns (address) {
        return address(MYTTestHelper._setupVault(asset, admin, curator));
    }

    function _setUpMYT(address _vault, address _mytStrategy, uint256 absoluteCap, uint256 relativeCap) internal {
        vm.startPrank(admin);
        classifier = address(new AlchemistStrategyClassifier(admin));
        // Set up risk classes matching constructor defaults (WAD: 1e18 = 100%)
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        // Assign risk level to the strategy
        bytes32 strategyId = IMYTStrategy(_mytStrategy).adapterId();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(strategyConfig.riskClass));
        allocator = address(new AlchemistAllocator(_vault, admin, operator, classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        IVaultV2(_vault).setIsAllocator(allocator, true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, _mytStrategy));
        IVaultV2(_vault).addAdapter(_mytStrategy);

        bytes memory idData = IMYTStrategy(_mytStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, absoluteCap)));
        IVaultV2(_vault).increaseAbsoluteCap(idData, absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, relativeCap)));
        IVaultV2(_vault).increaseRelativeCap(idData, relativeCap);

        // Validation
        require(IVaultV2(_vault).adaptersLength() == 1, "adaptersLength must be 1");
        require(IVaultV2(_vault).isAllocator(allocator), "allocator is not set");
        require(IVaultV2(_vault).isAdapter(_mytStrategy), "strategy is not set");

        require(IVaultV2(_vault).absoluteCap(strategyId) == absoluteCap, "absoluteCap is not set");
        require(IVaultV2(_vault).relativeCap(strategyId) == relativeCap, "relativeCap is not set");
        vm.stopPrank();
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(IVaultV2(_vault).asset()), depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(IVaultV2(_vault).asset()), _vault, amount);
        uint256 shares = IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(vault).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(vault).timelock(selector));
    }

    function getVaultParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    /// @dev Optional strategy-specific hook invoked before time-shifts in base tests.
    function _beforeTimeShift(uint256 targetTimestamp) internal virtual {}

    /// @dev Optional strategy-specific hook invoked before previewAdjustedWithdraw calls.
    function _beforePreviewWithdraw(uint256 requestedAssets) internal virtual {}

    /// @dev Optional strategy-specific clamp for deallocation requests.
    ///      Default behavior uses the requested amount directly.
    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view virtual returns (uint256) {
        return requestedAssets;
    }

    /// @dev Base helper to keep time-shift behavior extensible for strategy-specific tests.
    function _warpWithHook(uint256 timeDelta) internal {
        uint256 targetTimestamp = block.timestamp + timeDelta;
        _beforeTimeShift(targetTimestamp);
        vm.warp(targetTimestamp);
    }

    /// @dev Helper to get decimals-aware minimum allocation amount (0.001 tokens).
    function _getMinAllocateAmount() internal view virtual returns (uint256) {
        return 10 ** (testConfig.decimals - MIN_ALLOCATE_AMOUNT_SCALAR);
    }

    /// @dev Helper to get valid allocation bounds based on effective cap and vault assets.
    function _getAllocationBounds() internal view returns (uint256 min, uint256 max) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        uint256 vaultAssets = IVaultV2(vault).totalAssets();
        console.log("vaultAssets", vaultAssets);
        uint256 maxAlloc = effectiveCap < vaultAssets ? effectiveCap : vaultAssets;
        console.log("final maxAlloc", maxAlloc);
        
        uint256 minAlloc = _getMinAllocateAmount();
        // If available headroom is below minimum, return (0, 0) to signal no valid allocation possible
        if (maxAlloc < minAlloc) {
            return (0, 0);
        }
        
        return (minAlloc, maxAlloc);
    }

    /// @dev Helper to deal specific amount of assets to the vault.
    function _prepareVaultAssets(uint256 amount) internal {
        uint256 currentBalance = TokenUtils.safeBalanceOf(testConfig.vaultAsset, vault);
        deal(testConfig.vaultAsset, vault, currentBalance + amount);
    }

    /// @dev Helper to calculate effective cap headroom (matches AlchemistAllocator._validateCaps logic)
    function _getEffectiveCapHeadroom(bytes32 allocationId) internal view returns (uint256) {
        uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
        console.log("currentAllocation", currentAllocation);
        uint256 absoluteCap = IVaultV2(vault).absoluteCap(allocationId);
        uint256 relativeCap = IVaultV2(vault).relativeCap(allocationId);
        uint256 totalAssets = IVaultV2(vault).totalAssets();

        uint256 absoluteRemaining = absoluteCap > currentAllocation ? absoluteCap - currentAllocation : 0;
        console.log("absoluteRemaining", absoluteRemaining);
        uint256 absoluteValueOfRelativeCap = (totalAssets * relativeCap) / 1e18;
        console.log("absoluteValueOfRelativeCap", absoluteValueOfRelativeCap);
        uint256 relativeRemaining = absoluteValueOfRelativeCap > currentAllocation
            ? absoluteValueOfRelativeCap - currentAllocation
            : 0;
        console.log("relativeRemaining", relativeRemaining);
        uint256 limit = absoluteRemaining < relativeRemaining ? absoluteRemaining : relativeRemaining;
        uint256 strategyId = uint256(allocationId);
        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(strategyId);
        uint256 globalRiskCapPct = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        uint256 globalRiskCap = (totalAssets * globalRiskCapPct) / 1e18;
        uint256 globalRiskRemaining = globalRiskCap > currentAllocation ? globalRiskCap - currentAllocation : 0;
        limit = limit < globalRiskRemaining ? limit : globalRiskRemaining;

        console.log("limit", limit);
        return limit;
    }
}
