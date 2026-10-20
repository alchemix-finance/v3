// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {AlchemistCurator} from "../../AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {IporFusionStrategy, IIporWithdrawManager, IIporPlasmaVaultRequests} from "../../strategies/IporFusionStrategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {RevertContext} from "../base/StrategyTypes.sol";

/// @notice Mainnet addresses and fork fixtures for the IPOR Fusion "rETH Liquity LP Carry" PlasmaVault.
library IporLiquityETHCarryFixture {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant PLASMA_VAULT = 0xB9E806e8f2d94c015ffefa90cD24Ecce18f1663C;
    address internal constant WITHDRAW_MANAGER = 0xe99b6ef767A42131263bDd3d4a0A7c16B32F0543;
    address internal constant ACCESS_MANAGER = 0x2C6Ce3773EcEb3107a5AaDE37f3c20D4E41902D2;

    uint256 internal constant FORK_BLOCK = 26_149_293;

    uint256 internal constant MAX_WITHDRAW_FEE = 5e15; // 0.5%
    uint256 internal constant REDEEM_BUFFER_BPS = 10;
    uint256 internal constant SLIPPAGE_BPS = 20;

    /// @dev Minimum room for rounding and fee dust. The anchor never moves by this amount.
    uint256 internal constant BASE_BPS = 5;
    /// @dev About 3x the 6% carry (1.6 bps/day), so daily growth fits without an owner snap.
    uint256 internal constant UP_BPS_PER_DAY = 5;
    uint256 internal constant DOWN_BPS_PER_DAY = 5;
    /// @dev Largest catch-up one update may book after the anchor has been sitting.
    uint256 internal constant MAX_UP_BPS = 50;
    uint256 internal constant MAX_DOWN_BPS = 50;

    /// @dev PlasmaVaultStorageLib.ERC20_CAPPED_STORAGE_LOCATION (OZ ERC20Capped namespace).
    bytes32 internal constant TOTAL_SUPPLY_CAP_SLOT = 0x0f070392f17d5f958cc1ac31867dabecfc5c9758b4a419a200803226d7155d00;
    /// @dev Deployed IporFusionAccessManager stores REDEMPTION_DELAY_IN_SECONDS at slot 4.
    bytes32 internal constant REDEMPTION_DELAY_SLOT = bytes32(uint256(4));

    function params(address owner) internal pure returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: owner,
            name: "IPOR Fusion Liquity ETH Carry",
            protocol: "IPOR Fusion",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 100e18,
            globalCap: 0.1e18,
            estimatedYield: 300,
            additionalIncentives: false,
            slippageBPS: SLIPPAGE_BPS
        });
    }

    function guardParams() internal pure returns (IporFusionStrategy.PriceGuardParams memory) {
        return IporFusionStrategy.PriceGuardParams({
            baseBps: BASE_BPS,
            upBpsPerDay: UP_BPS_PER_DAY,
            downBpsPerDay: DOWN_BPS_PER_DAY,
            maxUpBps: MAX_UP_BPS,
            maxDownBps: MAX_DOWN_BPS
        });
    }

    function deploy(address myt, IMYTStrategy.StrategyParams memory p) internal returns (address) {
        return address(
            new IporFusionStrategy(myt, p, PLASMA_VAULT, WITHDRAW_MANAGER, MAX_WITHDRAW_FEE, REDEEM_BUFFER_BPS, guardParams())
        );
    }

    /// @dev Lift the live vault's supply cap and 1s redemption delay so the shared harness can run inside one block.
    function unlockVault() internal {
        vm.store(PLASMA_VAULT, TOTAL_SUPPLY_CAP_SLOT, bytes32(type(uint256).max / 2));
        setRedemptionDelay(0);
    }

    function setRedemptionDelay(uint256 delaySeconds) internal {
        vm.store(ACCESS_MANAGER, REDEMPTION_DELAY_SLOT, bytes32(delaySeconds));
    }

    /// @dev WithdrawManagerStorageLib.LAST_RELEASE_FUNDS: uint32 timestamp in the low bits, uint128 sharesToRelease above.
    bytes32 internal constant RELEASE_FUNDS_SLOT = 0x88d141dcaacfb8523e39ee7fba7c6f591450286f42f9c7069cc072812d539200;

    /// @dev Stand in for IPOR's Alpha calling `releaseFunds`, which sets these two fields behind a role check.
    function releaseFunds(uint256 releaseTimestamp, uint256 sharesToRelease) internal {
        uint256 packed = uint256(uint32(releaseTimestamp)) | (uint256(uint128(sharesToRelease)) << 32);
        vm.store(WITHDRAW_MANAGER, RELEASE_FUNDS_SLOT, bytes32(packed));
    }

    /// @dev Yearly carry the live vault earns, simulated on the frozen fork as idle WETH arriving in the PlasmaVault.
    uint256 internal constant SIMULATED_CARRY_BPS_PER_YEAR = 600;

    function accrueCarry(uint256 elapsed) internal {
        if (elapsed == 0) return;
        uint256 nav = IERC4626(PLASMA_VAULT).totalAssets();
        uint256 carry = nav * SIMULATED_CARRY_BPS_PER_YEAR * elapsed / (10_000 * 365 days);
        if (carry == 0) return;
        uint256 idle = IERC20(WETH).balanceOf(PLASMA_VAULT);
        // `deal` on a library has no `Test` context; write the WETH balance slot directly.
        vm.store(WETH, keccak256(abi.encode(PLASMA_VAULT, uint256(3))), bytes32(idle + carry));
    }

    /// @dev Shares a fee-realizing holder redeems per call. 20-decimal shares, so about 1e-5 ETH.
    uint256 internal constant FEE_REALIZATION_SHARES = 1e15;

    /// @dev The PlasmaVault realizes its performance fee in the withdraw path, on the whole vault's
    ///      gain since the last realization. `previewRedeem` does not include it. Live, any redeem or
    ///      Alpha execute realizes it, so it stays small; on a frozen fork nobody does, so a single
    ///      redeem would absorb all of it. Mirror the live cadence with a dust redeem from `holder`.
    ///      `holder` must have approved the current sender if that sender is not `holder`.
    function realizeFees(address holder) internal {
        uint256 bal = IERC4626(PLASMA_VAULT).balanceOf(holder);
        if (bal == 0) return;
        uint256 shares = bal < FEE_REALIZATION_SHARES ? bal : FEE_REALIZATION_SHARES;
        IERC4626(PLASMA_VAULT).redeem(shares, holder, holder);
    }
}

contract MockWithdrawManagerWrongVault {
    address public vaultAddr;

    constructor(address _vault) {
        vaultAddr = _vault;
    }

    function getPlasmaVaultAddress() external view returns (address) {
        return vaultAddr;
    }
}

contract IporLiquityETHCarryStrategyTest is BaseStrategyTest {
    address public constant WETH = IporLiquityETHCarryFixture.WETH;
    address public constant PLASMA_VAULT = IporLiquityETHCarryFixture.PLASMA_VAULT;
    address public constant WITHDRAW_MANAGER = IporLiquityETHCarryFixture.WITHDRAW_MANAGER;

    bytes4 internal constant ACCOUNT_IS_LOCKED_SELECTOR = bytes4(keccak256("AccountIsLocked(uint256)"));

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IporLiquityETHCarryFixture.params(address(1));
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        // Headroom above a 100 ETH allocate so the next allocate can book accrued NAV
        // without exceeding the cap. The shared harness fills whatever headroom is left.
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 1000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory p) internal override returns (address) {
        return IporLiquityETHCarryFixture.deploy(vault_, p);
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return IporLiquityETHCarryFixture.FORK_BLOCK;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function setUp() public override {
        super.setUp();
        IporLiquityETHCarryFixture.unlockVault();
        // HIGH risk is 10% in the shared harness, which binds at the same 100 ETH the
        // end-to-end test deposits. Open it so a later allocate can book carry.
        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 1e18, 1e18);

        // A small PlasmaVault position this contract uses to realize fees on each time shift.
        // The hook may run under an `admin` prank, so let admin redeem on this contract's behalf.
        deal(WETH, address(this), 0.1e18);
        IERC20(WETH).approve(PLASMA_VAULT, 0.1e18);
        IERC4626(PLASMA_VAULT).deposit(0.1e18, address(this));
        IERC4626(PLASMA_VAULT).approve(admin, type(uint256).max);
    }

    /// @dev `allocate` books all NAV movement since the last checkpoint. Filling the remaining
    ///      cap exactly then reverts once carry has accrued. Skip that allocate.
    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        if (selector != bytes4(keccak256("AbsoluteCapExceeded()"))) return false;
        return context == RevertContext.HandlerAllocate || context == RevertContext.FuzzAllocate;
    }

    /// @dev A fuzzed allocate or deallocate can land outside the share-price room after a fee
    ///      realization. That revert is the guard working; the harness should skip the call.
    function isMytRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        if (selector != IporFusionStrategy.PriceOutsideRoom.selector) return false;
        return context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate
            || context == RevertContext.FuzzAllocate || context == RevertContext.FuzzDeallocate;
    }

    /// @dev A frozen fork keeps charging the PlasmaVault fees against the clock while its markets
    ///      never earn, so the share price only falls. Accrue the carry the live vault earns and
    ///      realize fees at the live cadence so the fork keeps production economics. Then snap the
    ///      anchor to the destination price: inherited harnesses warp up to a year, which is more
    ///      than the cap will book. Done with `vm.store` because those tests are often already
    ///      pranking and `acceptPrice` is `onlyOwner`. Slots match `anchorPps` (14) and
    ///      `anchorTimestamp` (15).
    function _beforeTimeShift(uint256 targetTimestamp) internal override {
        uint256 start = block.timestamp;
        if (targetTimestamp <= start) return;
        IporLiquityETHCarryFixture.accrueCarry(targetTimestamp - start);
        vm.warp(targetTimestamp);
        IporLiquityETHCarryFixture.realizeFees(address(this));
        uint256 live = _strategy().liveSharePrice();
        if (live != 0) {
            vm.store(strategy, bytes32(uint256(14)), bytes32(live));
            vm.store(strategy, bytes32(uint256(15)), bytes32(targetTimestamp));
        }
        vm.warp(start);
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 liquidity = IporFusionStrategy(strategy).availableSyncLiquidity();
        return requestedAssets < liquidity ? requestedAssets : liquidity;
    }

    function _strategy() internal view returns (IporFusionStrategy) {
        return IporFusionStrategy(strategy);
    }

    function _allocateDirect(uint256 amount) internal {
        deal(WETH, strategy, amount);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(getVaultParams(), amount, "", vault);
    }

    function _deallocateDirect(uint256 amount) internal returns (int256 change) {
        vm.prank(vault);
        (, change) = IMYTStrategy(strategy).deallocate(getVaultParams(), amount, "", vault);
    }

    // ------------------------------------------------------------------
    // Wiring
    // ------------------------------------------------------------------

    function test_constructor_wiresIporVault() public view {
        assertEq(address(_strategy().mytAsset()), WETH, "unexpected MYT asset");
        assertEq(address(_strategy().vault()), PLASMA_VAULT, "unexpected PlasmaVault");
        assertEq(address(_strategy().withdrawManager()), WITHDRAW_MANAGER, "unexpected WithdrawManager");
        assertEq(_strategy().maxWithdrawFee(), IporLiquityETHCarryFixture.MAX_WITHDRAW_FEE, "unexpected maxWithdrawFee");
        assertEq(_strategy().redeemBufferBps(), IporLiquityETHCarryFixture.REDEEM_BUFFER_BPS, "unexpected redeemBufferBps");
        assertEq(_strategy().baseBps(), IporLiquityETHCarryFixture.BASE_BPS, "unexpected baseBps");
        assertEq(_strategy().upBpsPerDay(), IporLiquityETHCarryFixture.UP_BPS_PER_DAY, "unexpected upBpsPerDay");
        assertEq(_strategy().downBpsPerDay(), IporLiquityETHCarryFixture.DOWN_BPS_PER_DAY, "unexpected downBpsPerDay");
        assertEq(_strategy().maxUpBps(), IporLiquityETHCarryFixture.MAX_UP_BPS, "unexpected maxUpBps");
        assertEq(_strategy().maxDownBps(), IporLiquityETHCarryFixture.MAX_DOWN_BPS, "unexpected maxDownBps");
        // setUp's fee-realizer deposit lands after construction and rounds the price by dust.
        assertApproxEqRel(_strategy().anchorPps(), _strategy().liveSharePrice(), 1e8, "anchor should start at the live price");
        assertGt(_strategy().anchorPps(), 0, "anchor should be non-zero");
        assertEq(IERC4626(PLASMA_VAULT).asset(), WETH, "PlasmaVault asset should be WETH");
    }

    function test_constructor_reverts_whenWithdrawManagerTargetsOtherVault() public {
        MockWithdrawManagerWrongVault wrongWm = new MockWithdrawManagerWrongVault(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.WithdrawManagerVaultMismatch.selector, PLASMA_VAULT, address(0xBEEF)));
        new IporFusionStrategy(
            vault, getStrategyConfig(), PLASMA_VAULT, address(wrongWm), 5e15, 10, IporLiquityETHCarryFixture.guardParams()
        );
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(address(0xDEAD));
        vm.expectRevert();
        _strategy().setMaxWithdrawFee(1e15);
        vm.expectRevert();
        _strategy().setRedeemBufferBps(5);
        vm.expectRevert();
        _strategy().setWithdrawManager(WITHDRAW_MANAGER);
        vm.stopPrank();

        vm.startPrank(admin);
        _strategy().setMaxWithdrawFee(1e15);
        assertEq(_strategy().maxWithdrawFee(), 1e15);
        _strategy().setRedeemBufferBps(5);
        assertEq(_strategy().redeemBufferBps(), 5);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.InvalidBps.selector, 1e18));
        _strategy().setMaxWithdrawFee(1e18);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.InvalidBps.selector, 10_000));
        _strategy().setRedeemBufferBps(10_000);
        vm.stopPrank();
    }

    function test_forceDeallocate_direct_disabled_by_default_and_owner_can_enable() public {
        assertFalse(_strategy().canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);

        vm.prank(admin);
        _strategy().setCanForceDeallocate(true);
        assertTrue(_strategy().canForceDeallocate(), "force deallocate should be enabled");

        deal(WETH, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);
    }

    // ------------------------------------------------------------------
    // Accounting
    // ------------------------------------------------------------------

    function test_allocate_realAssetsNetsEntryAndExitFees() public {
        uint256 amount = 10e18;
        uint256 withdrawFee = IIporWithdrawManager(WITHDRAW_MANAGER).getWithdrawFee();
        _allocateDirect(amount);

        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        // 0.2% deposit fee (minted to the WithdrawManager) and 0.2% withdraw fee netted by previewRedeem.
        uint256 expected = amount * (1e18 - withdrawFee) / 1e18 * (1e18 - withdrawFee) / 1e18;
        assertApproxEqRel(realAssets, expected, 5e14, "realAssets should reflect entry + exit fee");
        assertLt(realAssets, amount, "realAssets should be marked down by fees");
        assertEq(IERC20(WETH).balanceOf(strategy), 0, "no idle WETH after direct allocate");
        assertGt(IERC4626(PLASMA_VAULT).balanceOf(strategy), 0, "strategy should hold PlasmaVault shares");
    }

    function test_deallocate_grossesUpWithdrawFee() public {
        _allocateDirect(10e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 realBefore = IMYTStrategy(strategy).realAssets();

        uint256 amount = 4e18;
        // Direct strategy calls bypass VaultV2 bookkeeping; mirror what the vault would report.
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        int256 change = _deallocateDirect(amount);
        vm.clearMockedCalls();

        uint256 idle = IERC20(WETH).balanceOf(strategy);
        assertGe(idle, amount, "idle must cover requested amount");
        // Excess from the redeem buffer stays idle but is bounded.
        assertLe(idle - amount, amount * (IporLiquityETHCarryFixture.REDEEM_BUFFER_BPS + 5) / 10_000, "buffer excess too large");
        assertLt(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "shares should be burned");

        // Fee is already netted in _totalValue, so the reported change tracks the requested amount.
        // Redeemed WETH stays idle in the strategy, so it remains inside realAssets until the vault pulls it.
        assertApproxEqRel(change, -int256(amount), 2e15, "change should track requested amount");
        assertApproxEqRel(IMYTStrategy(strategy).realAssets(), realBefore, 2e15, "idle proceeds stay in total value");
        assertEq(IERC20(WETH).allowance(strategy, vault), amount, "allowance for vault pull");
    }

    function test_deallocate_fromIdleOnly_doesNotTouchVault() public {
        _allocateDirect(5e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        deal(WETH, strategy, 3e18);

        _deallocateDirect(2e18);

        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "shares untouched when idle covers request");
        assertEq(IERC20(WETH).balanceOf(strategy), 3e18, "idle unchanged until vault pulls");
    }

    function test_previewAdjustedWithdraw_roundTripsIntoDeallocate(uint256 amount) public {
        amount = bound(amount, 1e15, 60e18);
        _allocateDirect(60e18);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        assertGt(preview, 0, "preview should be positive");
        assertLe(preview, amount, "preview never exceeds request");
        // Fee + slippage + buffer discount is small.
        assertGe(preview, amount * 99 / 100, "preview discount should be under 1%");

        _deallocateDirect(preview);
        assertGe(IERC20(WETH).balanceOf(strategy), preview, "deallocating the preview must succeed");
    }

    // ------------------------------------------------------------------
    // Synchronous liquidity cap
    // ------------------------------------------------------------------

    function test_previewAdjustedWithdraw_cappedBySyncLiquidity() public {
        _allocateDirect(50e18);
        uint256 withdrawFee = IIporWithdrawManager(WITHDRAW_MANAGER).getWithdrawFee();

        // Shrink the PlasmaVault's idle WETH below our position. Replacing the balance also
        // drops the share price, so book that print before exiting. The snap's dust redeem
        // takes a sliver of that idle WETH.
        deal(WETH, PLASMA_VAULT, 10e18);
        vm.prank(admin);
        _strategy().acceptPrice(0, type(uint256).max);
        uint256 liquidity = _strategy().availableSyncLiquidity();
        assertApproxEqAbs(liquidity, 10e18, 1e14, "liquidity should equal vault idle WETH");
        assertEq(liquidity, IERC20(WETH).balanceOf(PLASMA_VAULT), "liquidity is the vault's idle WETH");

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(50e18);
        uint256 maxNet = liquidity * (1e18 - withdrawFee) / 1e18;
        assertLe(preview, maxNet, "preview must not exceed net liquidity");
        assertGe(preview, maxNet * 99 / 100, "preview should be close to net liquidity");

        _deallocateDirect(preview);
        assertGe(IERC20(WETH).balanceOf(strategy), preview, "capped preview must be deallocatable");
    }

    function test_deallocate_reverts_whenRequestExceedsSyncLiquidity() public {
        _allocateDirect(50e18);
        deal(WETH, PLASMA_VAULT, 10e18);
        vm.prank(admin);
        _strategy().acceptPrice(0, type(uint256).max);

        vm.prank(vault);
        vm.expectPartialRevert(IporFusionStrategy.InsufficientSyncLiquidity.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 20e18, "", vault);
    }

    function test_availableSyncLiquidity_subtractsReleasedShares() public {
        uint256 idle = IERC20(WETH).balanceOf(PLASMA_VAULT);
        uint256 reservedShares = IERC4626(PLASMA_VAULT).convertToShares(idle / 2);
        vm.mockCall(WITHDRAW_MANAGER, abi.encodeWithSelector(IIporWithdrawManager.getSharesToRelease.selector), abi.encode(reservedShares));

        uint256 liquidity = _strategy().availableSyncLiquidity();
        assertApproxEqAbs(liquidity, idle - idle / 2, 1e12, "released shares should be reserved");
        vm.clearMockedCalls();
    }

    function test_deallocate_reverts_whenWithdrawFeeAboveMax() public {
        _allocateDirect(10e18);
        uint256 highFee = IporLiquityETHCarryFixture.MAX_WITHDRAW_FEE + 1;
        vm.mockCall(WITHDRAW_MANAGER, abi.encodeWithSelector(IIporWithdrawManager.getWithdrawFee.selector), abi.encode(highFee));

        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(1e18), 0, "preview should fall back to idle only");

        // The higher fee is inside previewRedeem, so book it before the exit checks the fee itself.
        vm.prank(admin);
        _strategy().acceptPrice(0, type(uint256).max);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.WithdrawFeeTooHigh.selector, highFee, IporLiquityETHCarryFixture.MAX_WITHDRAW_FEE));
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", vault);
        vm.clearMockedCalls();
    }

    function test_redemptionDelay_blocksSameBlockExit_andClearsNextSecond() public {
        IporLiquityETHCarryFixture.setRedemptionDelay(1);
        _allocateDirect(5e18);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED_SELECTOR, block.timestamp + 1));
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", vault);

        vm.warp(block.timestamp + 1);
        _deallocateDirect(1e18);
        assertGe(IERC20(WETH).balanceOf(strategy), 1e18, "exit should succeed once unlocked");
    }

    // ------------------------------------------------------------------
    // Share-price room
    // ------------------------------------------------------------------

    function test_totalValue_clampsInflatedSharePriceAndLeavesIdleUnclamped() public {
        _allocateDirect(10e18);
        uint256 shares = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 unit = _strategy().shareUnit();
        uint256 anchor = _strategy().anchorPps();
        (, uint256 upper) = _strategy().priceBounds();
        uint256 inflated = anchor * 2;

        deal(WETH, strategy, 1e18);
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(inflated));
        vm.mockCall(
            PLASMA_VAULT,
            abi.encodeWithSelector(IERC4626.previewRedeem.selector, shares),
            abi.encode(shares * inflated / unit)
        );

        uint256 raw = shares * inflated / unit;
        assertEq(IMYTStrategy(strategy).realAssets(), 1e18 + raw * upper / inflated, "idle plus ceiling-priced shares");
        vm.clearMockedCalls();
    }

    function test_allocate_reverts_whenLivePriceIsAboveTheRoom() public {
        uint256 unit = _strategy().shareUnit();
        uint256 inflated = _strategy().anchorPps() * 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(inflated));

        (uint256 lower, uint256 upper) = _strategy().priceBounds();
        deal(WETH, strategy, 1e18);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.PriceOutsideRoom.selector, inflated, lower, upper));
        IMYTStrategy(strategy).allocate(getVaultParams(), 1e18, "", vault);
        vm.clearMockedCalls();
    }

    function test_deallocate_reverts_whenLivePriceIsBelowTheRoom() public {
        _allocateDirect(5e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 unit = _strategy().shareUnit();
        uint256 crashed = _strategy().anchorPps() / 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(crashed));

        (uint256 lower, uint256 upper) = _strategy().priceBounds();
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.PriceOutsideRoom.selector, crashed, lower, upper));
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", vault);

        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "crash print must not be redeemed");
        vm.clearMockedCalls();
    }

    function test_poke_booksOneBudgetThenStopsInTheSameTimestamp() public {
        uint256 start = _strategy().anchorPps();
        vm.warp(block.timestamp + 10 days);

        uint256 inflated = start * 2;
        uint256 unit = _strategy().shareUnit();
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(inflated));

        _strategy().poke();
        uint256 afterFirst = _strategy().anchorPps();
        // 10 days * 5 bps/day, capped at 50 bps.
        assertEq(afterFirst, start * (10_000 + IporLiquityETHCarryFixture.MAX_UP_BPS) / 10_000, "poke books the cap");

        _strategy().poke();
        assertEq(_strategy().anchorPps(), afterFirst, "a second poke in this timestamp does not walk");
        vm.clearMockedCalls();
    }

    function test_acceptPrice_isOwnerAndBooksAPrintOutsideTheRoom() public {
        uint256 unit = _strategy().shareUnit();
        uint256 inflated = _strategy().anchorPps() * 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(inflated));

        vm.expectRevert();
        _strategy().acceptPrice(0, type(uint256).max);

        vm.prank(admin);
        _strategy().acceptPrice(inflated, inflated);
        assertEq(_strategy().anchorPps(), inflated, "owner books the live print");
        vm.clearMockedCalls();
    }

    /// @dev The owner passes a band read off-chain. A print pushed in front of the call lands
    ///      outside that band and must not be booked; the revert also undoes the dust redeem.
    function test_acceptPrice_rejectsAPrintOutsideTheOwnersBounds() public {
        _allocateDirect(5e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 anchorBefore = _strategy().anchorPps();

        uint256 unit = _strategy().shareUnit();
        uint256 pushed = anchorBefore * 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(pushed));

        // Band around the price the owner saw, well under the pushed print.
        uint256 lo = anchorBefore * (10_000 - 100) / 10_000;
        uint256 hi = anchorBefore * (10_000 + 100) / 10_000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.PriceOutsideAcceptBounds.selector, pushed, lo, hi));
        _strategy().acceptPrice(lo, hi);
        vm.clearMockedCalls();

        assertEq(_strategy().anchorPps(), anchorBefore, "anchor must not book the pushed print");
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "revert undoes the dust redeem");
    }

    /// @dev After a quiet gap the PlasmaVault's cached price lags what its next redeem books.
    ///      One `acceptPrice` has to land on the booked price so a chunked exit needs no second snap.
    function test_acceptPrice_realizesVaultFeesSoOneSnapCoversAChunkedExit() public {
        _allocateDirect(50e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        // A year with no PlasmaVault interaction. The management fee is unrealized and the
        // booked balances are stale, so the cached price is not what the next redeem will use.
        vm.warp(block.timestamp + 365 days);
        uint256 cached = _strategy().liveSharePrice();
        uint256 supplyBefore = IERC4626(PLASMA_VAULT).totalSupply();

        // Production flow: the owner reads the live price, then snaps inside a band around it.
        vm.prank(admin);
        _strategy().acceptPrice(cached * (10_000 - 100) / 10_000, cached * (10_000 + 100) / 10_000);

        assertLt(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "snap redeems dust");
        assertGt(IERC4626(PLASMA_VAULT).totalSupply(), supplyBefore, "snap makes the vault mint its fee shares");
        assertTrue(_strategy().anchorPps() != cached, "anchor books the realized price, not the cache");
        assertEq(_strategy().anchorPps(), _strategy().liveSharePrice(), "anchor equals the live price after the snap");

        // Chunked exits and a re-entry in this same timestamp, all inside the 5 bps minimum room.
        // The vault pulls each chunk before the next, so every chunk redeems from the PlasmaVault.
        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        uint256 sharesAfterSnap = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        _deallocateDirect(10e18);
        uint256 sharesAfterFirst = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        assertLt(sharesAfterFirst, sharesAfterSnap, "first chunk redeems");
        vm.prank(vault);
        IERC20(WETH).transferFrom(strategy, vault, 10e18);
        _deallocateDirect(10e18);
        vm.clearMockedCalls();
        assertLt(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesAfterFirst, "second chunk redeems after the same snap");
        assertGe(IERC20(WETH).balanceOf(strategy), 10e18, "second chunk is idle for the vault");
        _allocateDirect(5e18);
    }

    /// @dev The owner's exit lever must not depend on the dust redeem. A locked account makes
    ///      that redeem revert; the snap still books the cached price.
    function test_acceptPrice_snapsEvenWhenTheDustRedeemReverts() public {
        IporLiquityETHCarryFixture.setRedemptionDelay(1);
        _allocateDirect(5e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        uint256 unit = _strategy().shareUnit();
        uint256 inflated = _strategy().anchorPps() * 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(inflated));

        vm.prank(admin);
        _strategy().acceptPrice(inflated, inflated);

        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "locked redeem leaves shares untouched");
        assertEq(_strategy().anchorPps(), inflated, "snap still books the live print");
        vm.clearMockedCalls();
    }

    address internal constant KEEPER = address(0xCEE9);

    /// @dev Request as keeper, then stand in for the Alpha releasing exactly our shares one
    ///      second later. Returns the shares the WithdrawManager recorded.
    function _requestAndRelease(uint256 wethAmount) internal returns (uint256 pending) {
        vm.prank(admin);
        _strategy().setKeeper(KEEPER);
        vm.prank(KEEPER);
        _strategy().requestExit(wethAmount, false);
        pending = _strategy().pendingExitShares();
        assertGt(pending, 0, "request recorded");
        vm.warp(block.timestamp + 1);
        IporLiquityETHCarryFixture.releaseFunds(block.timestamp, pending);
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), pending, "release slot decodes to our shares");
    }

    function test_requestExit_onlyKeeperOrOwner() public {
        _allocateDirect(10e18);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.NotKeeper.selector, address(this)));
        _strategy().requestExit(1e18, false);

        vm.prank(admin);
        _strategy().requestExit(1e18, false);
        assertGt(_strategy().pendingExitShares(), 0, "owner can request");
        assertGt(_strategy().exitWindowEnd(), block.timestamp, "window runs from the request");
        assertEq(_strategy().claimableExit(), 0, "nothing claimable before a release");
    }

    function test_requestExit_sharesStayInStrategy_andValueIsUnchanged() public {
        _allocateDirect(10e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(admin);
        _strategy().requestExit(4e18, false);

        uint256 fee = IIporWithdrawManager(WITHDRAW_MANAGER).getRequestFee();
        if (fee == 0) {
            assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "request does not move shares");
            assertEq(IMYTStrategy(strategy).realAssets(), valueBefore, "request does not change reported value");
        } else {
            assertLt(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "request fee is skimmed in shares");
        }
    }

    function test_claimExit_paysNoWithdrawFee_andLandsIdle() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 feeNetted = IERC4626(PLASMA_VAULT).previewRedeem(pending);
        uint256 grossValue = IERC4626(PLASMA_VAULT).convertToAssets(pending);
        assertLt(feeNetted, grossValue, "sync preview nets the withdraw fee");

        assertEq(_strategy().claimableExit(), grossValue, "claimable is the fee free amount");

        // Permissionless: a stranger claims.
        vm.prank(address(0xBEEF));
        uint256 assets = _strategy().claimExit();

        assertApproxEqRel(assets, grossValue, 1e14, "claim pays the gross amount, no withdraw fee");
        assertGt(assets, feeNetted, "claim beats the sync path");
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore - pending, "requested shares burned");
        assertEq(IERC20(WETH).balanceOf(strategy), assets, "proceeds idle in the strategy");
        assertEq(_strategy().pendingExitShares(), 0, "request consumed");
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), 0, "reservation consumed");
    }

    function test_claimExit_reverts_whenNothingIsClaimable() public {
        _allocateDirect(10e18);
        vm.expectRevert(IporFusionStrategy.NoClaimableExit.selector);
        _strategy().claimExit();

        vm.prank(admin);
        _strategy().requestExit(1e18, false);
        vm.expectRevert(IporFusionStrategy.NoClaimableExit.selector);
        _strategy().claimExit();
    }

    /// @dev Released shares sit in the global `sharesToRelease`, which our sync view subtracts.
    ///      Until we claim, our own release counts against our own sync capacity.
    function test_ownRelease_suppressesSyncLiquidity_untilClaimed() public {
        _allocateDirect(10e18);
        uint256 before = _strategy().availableSyncLiquidity();
        uint256 pending = _requestAndRelease(4e18);

        uint256 reserved = IERC4626(PLASMA_VAULT).convertToAssets(pending);
        assertEq(_strategy().availableSyncLiquidity(), before - reserved, "own release reserves idle");

        _strategy().claimExit();
        uint256 after_ = _strategy().availableSyncLiquidity();
        assertApproxEqRel(after_, before - reserved, 1e12, "claim takes the reserved idle out of the vault");
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), 0, "reservation cleared");
    }

    /// @dev `deallocate` claims a released request before touching sync liquidity, so a request
    ///      larger than idle still exits in one call and pays no withdraw fee on the claimed part.
    function test_deallocate_settlesReleasedRequestFirst() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(6e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 claimValue = IERC4626(PLASMA_VAULT).convertToAssets(pending);

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        // Ask for less than the claim: no sync redeem should happen at all.
        _deallocateDirect(5e18);
        vm.clearMockedCalls();

        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore - pending, "only the requested shares left the vault");
        assertGe(IERC20(WETH).balanceOf(strategy), claimValue, "claim proceeds cover the exit with excess idle");
        assertEq(_strategy().pendingExitShares(), 0, "request settled");
    }

    function test_deallocate_leavesUnreleasedRequestAlone() public {
        _allocateDirect(10e18);
        vm.prank(admin);
        _strategy().requestExit(4e18, false);
        uint256 pending = _strategy().pendingExitShares();

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        _deallocateDirect(2e18);
        vm.clearMockedCalls();

        assertEq(_strategy().pendingExitShares(), pending, "unreleased request untouched by a sync exit");
    }

    /// @dev The preview only promises idle plus sync, so a release counts once it is claimed into idle.
    function test_previewAdjustedWithdraw_excludesAnUnclaimedRelease() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 claimValue = IERC4626(PLASMA_VAULT).convertToAssets(pending);

        assertLt(IMYTStrategy(strategy).previewAdjustedWithdraw(claimValue), claimValue, "unclaimed release takes the sync haircut");

        _strategy().claimExit();
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(claimValue), claimValue, "claimed proceeds serve at par");
    }

    /// @dev The window runs from the request. A lapsed window loses nothing: shares stay ours,
    ///      a new request replaces the old one, and only a claim or the next release moves the counter.
    function test_requestExit_windowLapse_thenReRequest() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 window = IIporWithdrawManager(WITHDRAW_MANAGER).getWithdrawWindow();
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        vm.warp(_strategy().exitWindowEnd() + 1);
        assertEq(_strategy().claimableExit(), 0, "lapsed window is not claimable");
        vm.expectRevert(IporFusionStrategy.NoClaimableExit.selector);
        _strategy().claimExit();
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "shares intact after lapse");
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), pending, "stale reservation persists until the next release");

        vm.prank(KEEPER);
        _strategy().requestExit(4e18, false);
        assertEq(_strategy().exitWindowEnd(), block.timestamp + window, "new request restarts the window");
        // The new request postdates the old release, so it is not claimable until the Alpha releases again.
        assertEq(_strategy().claimableExit(), 0, "needs a fresh release");
    }

    /// @dev A claim realizes value like any exit, so a crashed print blocks it until the owner books the print.
    function test_claimExit_reverts_underTheFloor_untilTheOwnerBooksThePrint() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 unit = _strategy().shareUnit();
        uint256 crashed = _strategy().anchorPps() / 2;
        vm.mockCall(PLASMA_VAULT, abi.encodeWithSelector(IERC4626.previewRedeem.selector, unit), abi.encode(crashed));

        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        vm.expectPartialRevert(IporFusionStrategy.PriceOutsideRoom.selector);
        _strategy().claimExit();
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "revert undoes the claim");
        assertEq(_strategy().pendingExitShares(), pending, "request still claimable");

        vm.prank(admin);
        _strategy().acceptPrice(crashed, crashed);
        uint256 sharesAfterSnap = IERC4626(PLASMA_VAULT).balanceOf(strategy);
        uint256 assets = _strategy().claimExit();
        assertGt(assets, 0, "claim proceeds once the print is booked");
        assertEq(_strategy().pendingExitShares(), 0, "request consumed");
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesAfterSnap - pending, "requested shares burned");
        vm.clearMockedCalls();
    }

    /// @dev IPOR gates the claim path. A direct claim surfaces it, `deallocate` still exits via sync.
    function test_deallocate_fallsBackToSync_whenTheClaimPathIsReGated() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 claimValue = IERC4626(PLASMA_VAULT).convertToAssets(pending);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        vm.mockCallRevert(
            PLASMA_VAULT,
            abi.encodeWithSelector(IIporPlasmaVaultRequests.redeemFromRequest.selector),
            abi.encodeWithSignature("AccessManagedUnauthorized(address)", strategy)
        );

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", strategy));
        _strategy().claimExit();

        // The view still reports the release; the preview never relied on it, so a preview sized exit goes through.
        assertEq(_strategy().claimableExit(), claimValue, "view still reports the release");
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(claimValue);
        assertLt(preview, claimValue, "preview sizes the exit to the sync leg");

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        _deallocateDirect(preview);
        vm.clearMockedCalls();

        assertEq(_strategy().pendingExitShares(), pending, "request left in place");
        assertLt(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "exit served by a sync redeem");
        assertGe(IERC20(WETH).balanceOf(strategy), preview, "exit funded from the sync leg");
    }

    /// @dev If the exit amount is more than the claim, it uses the claim first, then redeems the rest.
    function test_deallocate_claimsThenRedeemsTheRemainder() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(3e18);
        uint256 claimValue = IERC4626(PLASMA_VAULT).convertToAssets(pending);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        uint256 remainder = 2e18;
        uint256 amount = claimValue + remainder;
        // The preview sizes the whole amount to the sync leg; the claim inside the call only makes it cheaper.
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        assertGt(preview, claimValue, "preview covers more than the claim");
        assertLt(preview, amount, "whole amount takes the sync haircut");
        assertLe(amount - preview, amount * 100 / 10_000, "haircut is bounded");

        uint256 realBefore = IMYTStrategy(strategy).realAssets();
        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, IMYTStrategy(strategy).adapterId()), abi.encode(realBefore));
        _deallocateDirect(preview);
        vm.clearMockedCalls();

        uint256 burned = sharesBefore - IERC4626(PLASMA_VAULT).balanceOf(strategy);
        assertGt(burned, pending, "claim plus a sync redeem both burned shares");
        assertLt(burned, pending + IERC4626(PLASMA_VAULT).convertToShares(remainder * 2), "sync leg sized to the remainder");
        assertGe(IERC20(WETH).balanceOf(strategy), preview, "exit funded");
        assertEq(_strategy().pendingExitShares(), 0, "request settled");
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), 0, "reservation consumed");
    }

    /// @dev A waiting request is only overwritten with `replace`. the plain call refuses so a retry cannot pay the fee twice.
    function test_requestExit_replacesALiveRequestOnlyWhenAsked() public {
        _allocateDirect(10e18);
        vm.prank(admin);
        _strategy().requestExit(4e18, false);
        uint256 first = _strategy().pendingExitShares();
        uint256 windowEnd = _strategy().exitWindowEnd();
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.ExitRequestPending.selector, first, windowEnd));
        _strategy().requestExit(2e18, false);
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "refused retry pays no fee");

        vm.prank(admin);
        _strategy().requestExit(2e18, true);
        uint256 second = _strategy().pendingExitShares();

        assertLt(second, first, "smaller request recorded");
        assertApproxEqRel(second, first / 2, 1e15, "recorded size is the new size, not the sum");
        uint256 skimmed = sharesBefore - IERC4626(PLASMA_VAULT).balanceOf(strategy);
        assertApproxEqRel(skimmed, _requestFeeShares(second), 1e9, "only the request fee left the balance");
        assertEq(_strategy().exitWindowEnd(), block.timestamp + IIporWithdrawManager(WITHDRAW_MANAGER).getWithdrawWindow(), "window restarts");
    }

    /// @dev Shares the WithdrawManager skims as its request fee when it records `recorded` net shares.
    function _requestFeeShares(uint256 recorded) internal view returns (uint256) {
        uint256 fee = IIporWithdrawManager(WITHDRAW_MANAGER).getRequestFee();
        if (fee == 0) return 0;
        return recorded * 1e18 / (1e18 - fee) - recorded;
    }

    /// @dev A request never moves funds, so it refuses to overwrite a claimable release rather than claim it; claim first, then request.
    function test_requestExit_reverts_whileAReleaseIsClaimable() public {
        _allocateDirect(10e18);
        uint256 pending = _requestAndRelease(4e18);
        uint256 sharesBefore = IERC4626(PLASMA_VAULT).balanceOf(strategy);

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.ClaimableExitPending.selector, pending));
        _strategy().requestExit(2e18, false);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IporFusionStrategy.ClaimableExitPending.selector, pending));
        _strategy().requestExit(2e18, true);
        assertEq(IERC4626(PLASMA_VAULT).balanceOf(strategy), sharesBefore, "request moved nothing");
        assertEq(_strategy().pendingExitShares(), pending, "release still claimable");

        _strategy().claimExit();
        vm.prank(KEEPER);
        _strategy().requestExit(2e18, false);
        uint256 newPending = _strategy().pendingExitShares();
        assertGt(newPending, 0, "new request recorded after the claim");
        assertLt(newPending, pending, "new request is the new size");
        assertEq(_strategy().claimableExit(), 0, "new request is not claimable yet");
        assertEq(IIporWithdrawManager(WITHDRAW_MANAGER).getSharesToRelease(), 0, "old reservation consumed by the claim");
    }


    function test_full_lifecycle_through_allocator() public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();

        uint256 alloc1 = 20e18;
        IAllocator(allocator).allocate(strategy, alloc1);
        uint256 real1 = IMYTStrategy(strategy).realAssets();
        assertApproxEqRel(IVaultV2(vault).allocation(allocationId), alloc1, 1e16, "allocation tracks first deposit within fees");

        vm.warp(block.timestamp + 7 days);

        uint256 alloc2 = 10e18;
        IAllocator(allocator).allocate(strategy, alloc2);
        assertGe(IMYTStrategy(strategy).realAssets(), real1, "real assets should not decrease");

        vm.warp(block.timestamp + 14 days);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(10e18);
        uint256 vaultBefore = IERC20(WETH).balanceOf(vault);
        IAllocator(allocator).deallocate(strategy, preview);
        assertEq(IERC20(WETH).balanceOf(vault), vaultBefore + preview, "vault should receive deallocated WETH");

        uint256 remaining = IMYTStrategy(strategy).realAssets();
        uint256 finalPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(remaining);
        IAllocator(allocator).deallocate(strategy, finalPreview);

        assertLe(IMYTStrategy(strategy).realAssets(), remaining / 100, "strategy should be nearly empty");
        assertLe(IVaultV2(vault).allocation(allocationId), remaining / 100, "allocation should be nearly zero");
        vm.stopPrank();
    }
}

contract IporLiquityETHCarryInvariantTest is E2EInvariantStrategyTest {
    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return IporLiquityETHCarryFixture.FORK_BLOCK;
    }

    function getAsset() internal pure override returns (address) {
        return IporLiquityETHCarryFixture.WETH;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IporLiquityETHCarryFixture.params(address(0));
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory p) internal override returns (address) {
        return IporLiquityETHCarryFixture.deploy(vault_, p);
    }

    function _postCreateStrategy(address strategy_) internal override {
        IporLiquityETHCarryFixture.unlockVault();
        // The shared harness registers 50,000 ETH. Lower this strategy to the deploy cap so a
        // round trip cannot move the PlasmaVault share price the way that size would.
        // The price guard stays at the deployed values.
        vm.prank(admin);
        AlchemistCurator(curatorContract).decreaseAbsoluteCap(strategy_, IporLiquityETHCarryFixture.params(address(0)).cap);

        // A small PlasmaVault position this contract redeems from on each warp. It stands in for
        // the live vault's other holders, whose redeems realize fees between our calls.
        deal(IporLiquityETHCarryFixture.WETH, address(this), 0.1e18);
        IERC20(IporLiquityETHCarryFixture.WETH).approve(IporLiquityETHCarryFixture.PLASMA_VAULT, 0.1e18);
        IERC4626(IporLiquityETHCarryFixture.PLASMA_VAULT).deposit(0.1e18, address(this));
    }

    function _enableForceDeallocate(address strategy_) internal override {
        IporFusionStrategy(strategy_).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy_, uint256 amount) external override {
        address plasmaVault = IporLiquityETHCarryFixture.PLASMA_VAULT;
        uint256 shares = IERC4626(plasmaVault).convertToShares(amount);
        uint256 bal = IERC20(plasmaVault).balanceOf(strategy_);
        shares = shares > bal ? bal : shares;
        if (shares == 0) return;
        vm.prank(strategy_);
        IERC20(plasmaVault).transfer(address(0xdead), shares);
    }

    /// @dev The fuzzer jumps the clock with no PlasmaVault traffic and no pokes. Accrue the carry
    ///      the live vault earns, realize fees the way other holders' redeems do, then book the
    ///      price the owner would after a gap without pokes.
    function onWarp(uint256 elapsed) external override {
        IporLiquityETHCarryFixture.accrueCarry(elapsed);
        IporLiquityETHCarryFixture.realizeFees(address(this));
        // Production flow: the owner reads the live price, then snaps inside a band around it.
        uint256 live = IporFusionStrategy(realStrategy).liveSharePrice();
        vm.prank(admin);
        IporFusionStrategy(realStrategy).acceptPrice(live * (10_000 - 100) / 10_000, live * (10_000 + 100) / 10_000);
    }
}
