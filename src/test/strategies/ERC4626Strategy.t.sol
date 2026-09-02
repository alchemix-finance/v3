// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Generic test suite for `ERC4626Strategy` against any remote ERC4626 vault.
 * @dev Runs the identical unit + e2e suites for any vault on any network, driven by env vars:
 *
 *      ERC4626_VAULT      - vault address to test against (activates remote mode)
 *      ERC4626_RPC_URL    - RPC URL of the vault's network (required with ERC4626_VAULT)
 *      ERC4626_FORK_BLOCK - optional fork block; unset forks latest (remote mode only)
 *
 *      With no env vars set, the suite defaults to the Steakhouse High Yield USDC (bbqUSDC)
 *      vault on Base. Asset, decimals and vault name are discovered from the vault itself;
 *      strategy params and test amounts are scaled from the asset decimals.
 *
 *      Example:
 *        ERC4626_VAULT=0x696d02Db93291651ED510704c9b286841d506987 \
 *        ERC4626_RPC_URL=$MAINNET_RPC_URL \
 *        forge test --match-path src/test/strategies/ERC4626Strategy.t.sol
 */
abstract contract ERC4626RemoteEnv is Test {
    struct RemoteConfig {
        address vault;
        address asset;
        string rpcUrl;
        string vaultName;
        uint256 forkBlock;
        uint256 assetDecimals;
    }

    // Default (no env vars): Steakhouse High Yield USDC (bbqUSDC) on Base
    address internal constant DEFAULT_VAULT = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    uint256 internal constant DEFAULT_FORK_BLOCK = 50_765_525;

    RemoteConfig internal cfg;

    /// @dev Loads vault config from env vars (or defaults) and discovers asset/decimals/name
    ///      from the vault on a temporary fork. Must run before `super.setUp()` so the base
    ///      hooks (`getRpcUrl`, `getTestConfig`, ...) observe the resolved config.
    function _loadRemoteConfig() internal {
        address vault_ = vm.envOr("ERC4626_VAULT", address(0));
        string memory rpc_ = vm.envOr("ERC4626_RPC_URL", string(""));
        uint256 block_ = vm.envOr("ERC4626_FORK_BLOCK", uint256(0));

        if (vault_ == address(0)) {
            vault_ = DEFAULT_VAULT;
            rpc_ = vm.envString("BASE_RPC_URL");
            block_ = DEFAULT_FORK_BLOCK;
        } else if (bytes(rpc_).length == 0) {
            revert("ERC4626_RPC_URL must be set when ERC4626_VAULT is provided");
        }

        if (block_ == 0) {
            vm.createSelectFork(rpc_);
        } else {
            vm.createSelectFork(rpc_, block_);
        }

        (bool ok, bytes memory data) = vault_.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && data.length >= 32, "ERC4626_VAULT: asset() call failed (not an ERC4626 vault?)");
        address asset_ = abi.decode(data, (address));
        require(asset_ != address(0), "ERC4626_VAULT: vault asset is zero");

        (ok, data) = asset_.staticcall(abi.encodeWithSignature("decimals()"));
        uint256 decimals_ = ok && data.length >= 32 ? uint256(abi.decode(data, (uint8))) : 18;

        (ok, data) = vault_.staticcall(abi.encodeWithSignature("name()"));
        string memory name_ = ok && data.length >= 32 ? abi.decode(data, (string)) : "ERC4626";

        cfg = RemoteConfig({vault: vault_, asset: asset_, rpcUrl: rpc_, vaultName: name_, forkBlock: block_, assetDecimals: decimals_});
    }

    function _strategyParams(address owner_) internal view returns (IMYTStrategy.StrategyParams memory) {
        uint256 unit = 10 ** cfg.assetDecimals;
        return IMYTStrategy.StrategyParams({
            owner: owner_,
            name: cfg.vaultName,
            protocol: "ERC4626",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000 * unit,
            globalCap: 1e18,
            estimatedYield: 100 * unit,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }
}

contract ERC4626StrategyTest is ERC4626RemoteEnv, BaseStrategyTest {
    function setUp() public virtual override {
        _loadRemoteConfig();
        super.setUp();
    }

    function getRpcUrl() internal view override returns (string memory) {
        return cfg.rpcUrl;
    }

    function getForkBlockNumber() internal view override returns (uint256) {
        return cfg.forkBlock;
    }

    function getStrategyConfig() internal view override returns (IMYTStrategy.StrategyParams memory) {
        return _strategyParams(address(1));
    }

    function getTestConfig() internal view override returns (TestConfig memory) {
        uint256 unit = 10 ** cfg.assetDecimals;
        return TestConfig({vaultAsset: cfg.asset, vaultInitialDeposit: 1000 * unit, absoluteCap: 10_000 * unit, relativeCap: 1e18, decimals: cfg.assetDecimals});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault, params, cfg.vault));
    }

    function test_vaultWiring() public view {
        assertEq(address(ERC4626Strategy(strategy).mytAsset()), cfg.asset, "unexpected MYT asset");
        assertEq(address(ERC4626Strategy(strategy).vault()), cfg.vault, "unexpected vault");
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        ERC4626Strategy erc4626Strategy = ERC4626Strategy(strategy);
        assertFalse(erc4626Strategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));

        vm.prank(admin);
        erc4626Strategy.setCanForceDeallocate(true);
        assertTrue(erc4626Strategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(cfg.asset, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, address(vault));
    }

    // End-to-end test: Full lifecycle with time accumulation
    function test_erc4626_full_lifecycle_with_time() public {
        uint256 unit = 10 ** testConfig.decimals;
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();

        // Initial allocation
        uint256 alloc1 = 500 * unit;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        uint256 allocAfter1 = IVaultV2(vault).allocation(allocationId);
        assertGe(allocAfter1, alloc1 - alloc1 / 1000, "allocation should track first deposit");

        // Warp forward 7 days
        vm.warp(block.timestamp + 7 days);

        // Additional allocation
        uint256 alloc2 = 300 * unit;
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        uint256 allocAfter2 = IVaultV2(vault).allocation(allocationId);
        assertGe(allocAfter2, alloc1 + alloc2 - (alloc1 + alloc2) / 1000, "allocation should track both deposits");

        // Warp forward 14 days
        vm.warp(block.timestamp + 14 days);

        // Partial deallocation
        uint256 deallocAmount1 = 200 * unit;
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLt(realAssets3, realAssets2, "Real assets should decrease after deallocation");

        // Warp forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Check vault asset balance reflects accumulated value
        uint256 vaultAssetBalance = IERC20(cfg.asset).balanceOf(vault);
        assertGt(vaultAssetBalance, 0, "Vault should hold the asset");

        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > unit) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        uint256 finalVaultAssetBalance = IERC20(cfg.asset).balanceOf(vault);
        assertGt(finalVaultAssetBalance, vaultAssetBalance, "Vault asset balance should increase after deallocation");

        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_erc4626_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        uint256 unit = 10 ** testConfig.decimals;
        // Use bound for array length instead of assume
        uint256 numOps = bound(amounts.length, 1, 8);
        // Ensure we don't access beyond array bounds
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;

        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        for (uint256 i = 0; i < maxIterations; i++) {
            // Alternate between allocation and deallocation
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 10 * unit, 100 * unit);

            if (isAllocate) {
                IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                if (currentAllocation > 0) {
                    uint256 maxDealloc = currentAllocation < 10 * unit ? currentAllocation : 10 * unit;
                    uint256 deallocAmount = bound(amount, 0, maxDealloc);
                    if (deallocAmount > 0) {
                        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount);
                        if (deallocPreview > 0) {
                            IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                        }
                    }
                }
            }

            // Warp forward (with bounds check for timeDelays array)
            uint256 timeDelay = i < timeDelays.length ? bound(timeDelays[i], 1 hours, 30 days) : 1 hours;
            vm.warp(block.timestamp + timeDelay);
        }

        // Final sanity checks
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultAssetBalance = IERC20(cfg.asset).balanceOf(vault);

        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultAssetBalance, 0, "Vault should hold the asset");

        vm.stopPrank();
    }

    // Test: Yield accumulation over time
    function test_erc4626_yield_accumulation() public {
        uint256 unit = 10 ** testConfig.decimals;
        vm.startPrank(allocator);

        // Allocate initial amount
        uint256 allocAmount = 400 * unit;
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();

        // Track real assets over time with warps
        uint256[] memory realAssetsSnapshots = new uint256[](5);
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 30 days);

            // Simulate yield by transferring small amount to strategy (0.5% per period)
            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);

            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();

            // Real assets should not significantly decrease (may increase with yield)
            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            // Update minExpected to the new baseline
            minExpected = realAssetsSnapshots[i];

            // Small deallocation on second snapshot
            if (i == 1) {
                uint256 smallDealloc = 50 * unit;
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                // Update minExpected after deallocation to account for the reduction
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }

        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > unit) {
            uint256 finalDeallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(finalRealAssets);
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        // Allow small tolerance for slippage/rounding (up to 1% of initial)
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, initialRealAssets / 100, "All real assets should be deallocated");

        vm.stopPrank();
    }
}

contract ERC4626StrategyInvariantTest is ERC4626RemoteEnv, E2EInvariantStrategyTest {
    function setUp() public virtual override {
        _loadRemoteConfig();
        super.setUp();
    }

    function getRpcUrl() internal view override returns (string memory) {
        return cfg.rpcUrl;
    }

    function getForkBlockNumber() internal view override returns (uint256) {
        return cfg.forkBlock;
    }

    function getAsset() internal view override returns (address) {
        return cfg.asset;
    }

    function getRealStrategyParams() internal view override returns (IMYTStrategy.StrategyParams memory) {
        return _strategyParams(address(0));
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new ERC4626Strategy(vault_, params, cfg.vault));
    }

    function _enableForceDeallocate(address strategy) internal override {
        ERC4626Strategy(strategy).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 shares = IERC4626(cfg.vault).convertToShares(amount);
        uint256 bal = IERC20(cfg.vault).balanceOf(strategy);
        shares = shares > bal ? bal : shares;
        if (shares == 0) return;
        vm.prank(strategy);
        IERC20(cfg.vault).transfer(address(0xdead), shares);
    }
}
