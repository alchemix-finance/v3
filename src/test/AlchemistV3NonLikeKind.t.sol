// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ICollateralPriceOracle} from "../interfaces/ICollateralPriceOracle.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {AlchemicTokenV3} from "./mocks/AlchemicTokenV3.sol";

contract NonLikeKindTestToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(uint8 decimals_) ERC20("Collateral or reference", "REF") {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

/// @dev Minimal ERC4626 conversion surface. The rate is native asset units per
/// whole MYT; it is independent of the market price supplied by the oracle.
contract NonLikeKindTestVault is ERC20 {
    address public immutable asset;
    uint256 public assetsPerShare;

    constructor(address asset_, uint256 assetsPerShare_) ERC20("Test MYT", "MYT") {
        asset = asset_;
        assetsPerShare = assetsPerShare_;
    }

    function setAssetsPerShare(uint256 value) external {
        require(value > 0);
        assetsPerShare = value;
    }

    function mint(address recipient, uint256 shares) external {
        _mint(recipient, shares);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerShare / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * 1e18 / assetsPerShare;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 numerator = assets * 1e18;
        return numerator / assetsPerShare + (numerator % assetsPerShare == 0 ? 0 : 1);
    }
}

contract NonLikeKindTestOracle is ICollateralPriceOracle {
    address public immutable baseToken;
    address public immutable quoteToken;
    uint256 public currentPrice;
    bool public unavailable;

    error PriceUnavailable();

    constructor(address base_, address quote_, uint256 price_) {
        baseToken = base_;
        quoteToken = quote_;
        currentPrice = price_;
    }

    function setPrice(uint256 value) external {
        currentPrice = value;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function price() external view returns (uint256) {
        if (unavailable) revert PriceUnavailable();
        return currentPrice;
    }
}

contract AlchemistV3NonLikeKindTest is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant MIN_CR = 2e18;
    uint256 private constant TARGET_CR = 22e17;
    uint256 private constant TRANSMUTATION_BLOCKS = 100;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    address private constant LIQUIDATOR = address(0x11);
    address private constant FEE_RECIPIENT = address(0xfee);

    NonLikeKindTestToken private collateral;
    NonLikeKindTestToken private referenceToken;
    NonLikeKindTestVault private vault;
    NonLikeKindTestOracle private oracle;
    AlchemicTokenV3 private synthetic;
    AlchemistV3 private alchemist;
    AlchemistV3 private implementation;
    Transmuter private transmuter;
    AlchemistTokenVault private feeVault;
    uint256 private assetUnit;

    function setUp() public {
        _deploy(18, 2000e18, true);
    }

    function test_NonLikeKind_AtomicInitializationAndFixedReference() public {
        assertEq(alchemist.debtReferenceToken(), address(referenceToken));
        assertEq(address(alchemist.collateralPriceOracle()), address(oracle));
        // Reference-token decimals do not change a price quoted per whole token.
        assertEq(referenceToken.decimals(), 6);
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(ONE), 2000e18);
        vm.expectRevert();
        alchemist.initialize(_params());
    }

    function test_NonLikeKind_SingleInitializerSupportsExplicitLikeKindMode() public {
        _deploy(6, ONE, false);
        assertEq(alchemist.debtReferenceToken(), address(collateral));
        assertEq(address(alchemist.collateralPriceOracle()), address(0));
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(1e6), ONE);
        AlchemistInitializationParams memory params = _params();
        params.debtReferenceToken = address(referenceToken);
        params.collateralPriceOracle = address(oracle);
        vm.expectRevert();
        alchemist.initialize(params);
    }

    function test_NonLikeKind_InitializerRejectsZeroReferenceToken() public {
        AlchemistInitializationParams memory params = _params();
        params.debtReferenceToken = address(0);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(implementation), address(this), abi.encodeCall(AlchemistV3.initialize, (params)));
    }

    function test_NonLikeKind_ConfigurationRequiresAdminAndMatchingPair() public {
        NonLikeKindTestOracle replacement = new NonLikeKindTestOracle(address(collateral), address(referenceToken), 1500e18);
        vm.prank(ALICE);
        vm.expectRevert();
        alchemist.setCollateralPriceOracle(address(replacement));
        NonLikeKindTestOracle wrongBase = new NonLikeKindTestOracle(address(referenceToken), address(referenceToken), ONE);
        NonLikeKindTestOracle wrongQuote = new NonLikeKindTestOracle(address(collateral), address(collateral), ONE);
        vm.expectRevert();
        alchemist.setCollateralPriceOracle(address(wrongBase));
        vm.expectRevert();
        alchemist.setCollateralPriceOracle(address(wrongQuote));
        vm.expectRevert();
        alchemist.setCollateralPriceOracle(address(0));
        alchemist.setCollateralPriceOracle(address(replacement));
        assertEq(alchemist.debtReferenceToken(), address(referenceToken));
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(ONE), 1500e18);
    }

    function test_NonLikeKind_InitializerRejectsMissingOrMismatchedOracle() public {
        AlchemistInitializationParams memory params = _params();
        params.debtReferenceToken = address(referenceToken);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(implementation), address(this), abi.encodeCall(AlchemistV3.initialize, (params)));
        NonLikeKindTestOracle wrongQuote = new NonLikeKindTestOracle(address(collateral), address(collateral), ONE);
        params.collateralPriceOracle = address(wrongQuote);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(implementation), address(this), abi.encodeCall(AlchemistV3.initialize, (params)));
    }

    function test_NonLikeKind_MarketPriceAndVaultRateAreIndependent() public {
        vault.setAssetsPerShare(2e18);
        uint256 id = _open(ALICE, 10e18, 0);
        assertEq(alchemist.convertYieldTokensToUnderlying(10e18), 20e18);
        assertEq(alchemist.convertYieldTokensToDebt(10e18), 40_000e18);
        assertEq(alchemist.convertDebtTokensToYield(4000e18), ONE);
        assertEq(alchemist.totalValue(id), 40_000e18);
        assertEq(alchemist.getMaxBorrowable(id), 20_000e18);
        oracle.setPrice(1000e18);
        assertEq(alchemist.convertYieldTokensToUnderlying(10e18), 20e18);
        assertEq(alchemist.totalValue(id), 20_000e18);
        assertEq(alchemist.getMaxBorrowable(id), 10_000e18);
    }

    function test_NonLikeKind_SixDecimalCollateralAndFractionalPrice() public {
        _deploy(6, 5e17, true);
        vault.setAssetsPerShare(2e6);
        uint256 id = _open(ALICE, 10e18, 4e18);
        assertEq(alchemist.underlyingConversionFactor(), 1e12);
        assertEq(alchemist.convertYieldTokensToUnderlying(10e18), 20e6);
        assertEq(alchemist.totalValue(id), 10e18);
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(3e6), 15e17);
        assertEq(alchemist.normalizeDebtTokensToUnderlying(15e17), 3e6);
        assertEq(alchemist.convertDebtTokensToYield(ONE), ONE);
        assertEq(alchemist.getMaxBorrowable(id), ONE);
    }

    function test_NonLikeKind_MintAndWithdrawLimitsReprice() public {
        uint256 id = _open(ALICE, 10e18, 5000e18);
        assertEq(alchemist.getMaxWithdrawable(id), 5e18);
        oracle.setPrice(1000e18);
        assertEq(alchemist.getMaxBorrowable(id), 0);
        assertEq(alchemist.getMaxWithdrawable(id), 0);
        vm.startPrank(ALICE);
        vm.expectRevert();
        alchemist.mint(id, 1, ALICE);
        vm.expectRevert();
        alchemist.withdraw(1, ALICE, id);
        vm.stopPrank();
        oracle.setPrice(2000e18);
        vm.prank(ALICE);
        alchemist.withdraw(5e18, ALICE, id);
        assertEq(alchemist.totalValue(id), 10_000e18);
    }

    function test_NonLikeKind_UnavailablePriceFailsWithoutChangingBalances() public {
        uint256 id = _open(ALICE, 10e18, 1000e18);
        uint256 deposited = alchemist.getTotalDeposited();
        oracle.setUnavailable(true);
        vm.expectRevert(NonLikeKindTestOracle.PriceUnavailable.selector);
        alchemist.totalValue(id);
        vm.startPrank(ALICE);
        vm.expectRevert();
        alchemist.mint(id, ONE, ALICE);
        vm.expectRevert();
        alchemist.withdraw(ONE, ALICE, id);
        vm.stopPrank();
        assertEq(alchemist.totalDebt(), 1000e18);
        assertEq(alchemist.getTotalDeposited(), deposited);
        assertEq(vault.balanceOf(address(alchemist)), deposited);
        oracle.setUnavailable(false);
        oracle.setPrice(0);
        vm.expectRevert();
        alchemist.totalValue(id);
    }

    function test_NonLikeKind_ClaimsUseCurrentPriceWithoutInventory() public {
        _claimWithInventory(0, 4e18);
    }

    function test_NonLikeKind_ClaimsCombineInventoryAndFreshRedemption() public {
        _claimWithInventory(100e18, 4e18);
    }

    function test_NonLikeKind_ClaimsUseOnlyInventoryWhenSufficient() public {
        _claimWithInventory(600e18, 4e18);
    }

    function test_NonLikeKind_ClaimFeesArePaidInCorrectShares() public {
        _deploy(18, 2e18, true);
        _open(ALICE, 1000e18, 1000e18);
        transmuter.setTransmutationFee(100);
        _stake(ALICE, 100e18);
        oracle.setPrice(4e18);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        vm.prank(ALICE);
        (uint256 received, uint256 fee, uint256 returned, uint256 exitFee) = transmuter.claimRedemption(1);
        assertEq(received, 2475e16);
        assertEq(fee, 25e16);
        assertEq(returned, 0);
        assertEq(exitFee, 0);
        assertEq(vault.balanceOf(FEE_RECIPIENT), fee);
        assertEq(alchemist.totalSyntheticsIssued(), 900e18);
    }

    function test_NonLikeKind_OracleLossScalesClaimsByDebtValuedBacking() public {
        _deploy(18, 2e18, true);
        _open(ALICE, 100e18, 100e18);
        _stake(ALICE, 100e18);
        oracle.setPrice(5e17);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        // Backing is100 MYT *0.5 debt/MYT =50 debt against100 synthetics.
        vm.prank(ALICE);
        (uint256 received, uint256 fee, uint256 returned,) = transmuter.claimRedemption(1);
        assertEq(received, 100e18);
        assertEq(received * 5e17 / ONE, 50e18);
        assertEq(fee, 0);
        assertEq(returned, 0);
        assertEq(alchemist.getTotalDeposited(), 0);
        assertEq(alchemist.totalSyntheticsIssued(), 0);
        assertEq(transmuter.totalLocked(), 0);
    }

    function test_NonLikeKind_ZeroDebtValuedBackingBurnsMaturedClaimWithoutRedemption() public {
        _open(ALICE, 1e12, 1e15);
        _stake(ALICE, 1e15);
        oracle.setPrice(1); // Positive price; a fractional native token is worth zero debt wei.
        assertEq(alchemist.getTotalLockedUnderlyingValue(), 1e12);
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(1e12), 0);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        vm.mockCallRevert(
            address(alchemist), abi.encodeWithSelector(AlchemistV3.redeem.selector), abi.encodeWithSignature("Error(string)", "unexpected redemption")
        );
        vm.prank(ALICE);
        (uint256 received, uint256 fee, uint256 returned, uint256 exitFee) = transmuter.claimRedemption(1);
        assertEq(received, 0);
        assertEq(fee, 0);
        assertEq(returned, 0);
        assertEq(exitFee, 0);
        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(address(transmuter)), 0);
        assertEq(vault.balanceOf(address(alchemist)), 1e12);
        assertEq(alchemist.getTotalDeposited(), 1e12);
        assertEq(alchemist.totalDebt(), 1e15, "claim must not redeem fresh debt");
        // Existing insolvency policy burns the matured synthetic claim even
        // when its scaled payout is zero; the redemption position closes.
        assertEq(alchemist.totalSyntheticsIssued(), 0);
        assertEq(synthetic.totalSupply(), 0);
        assertEq(synthetic.balanceOf(address(transmuter)), 0);
        assertEq(transmuter.totalLocked(), 0);
        assertEq(transmuter.totalActiveLocked(), 0);
        vm.expectRevert();
        transmuter.ownerOf(1);
    }

    function test_NonLikeKind_OracleLossMakesPositionLiquidatable() public {
        _deploy(18, 2e18, true);
        _open(BOB, 1000e18, 0);
        uint256 id = _open(ALICE, 100e18, 100e18);
        alchemist.setLiquidatorFee(0);
        oracle.setPrice(12e17);
        vm.prank(LIQUIDATOR);
        (uint256 seized,,) = alchemist.liquidate(id);
        (uint256 shares, uint256 debt,) = alchemist.getCDP(id);
        assertGt(seized, 0);
        assertGt(debt, 0);
        assertEq(shares + seized, 100e18);
        assertEq(vault.balanceOf(address(transmuter)), seized);
        uint256 collateralValue = shares * 12e17 / ONE;
        assertApproxEqAbs(collateralValue * ONE / debt, TARGET_CR, 16);
        assertApproxEqAbs((100e18 - debt) * ONE / 12e17, seized, 2);
    }

    function test_NonLikeKind_InsolventLiquidationPaysNativeSixDecimalFee() public {
        _deploy(6, 2e18, true);
        uint256 id = _open(ALICE, 100e18, 100e18);
        oracle.setPrice(5e17);
        uint256 feeVaultBefore = collateral.balanceOf(address(feeVault));
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 shareFee, uint256 nativeFee) = alchemist.liquidate(id);
        // A3-debt-unit fee at0.5 debt per collateral token is6 native tokens.
        assertEq(seized, 100e18);
        assertEq(shareFee, 0);
        assertEq(nativeFee, 6e6);
        assertEq(collateral.balanceOf(LIQUIDATOR), 6e6);
        assertEq(feeVaultBefore - collateral.balanceOf(address(feeVault)), 6e6);
        (uint256 shares, uint256 debt,) = alchemist.getCDP(id);
        assertEq(shares, 0);
        assertEq(debt, 0);
    }

    function test_NonLikeKind_TinyDebtRepaymentTransfersRoundedUpCollateral() public {
        _deploy(6, 2000e18, true);
        uint256 id = _open(ALICE, ONE, 1);
        assertEq(alchemist.convertDebtTokensToYield(1), 0, "public conversion remains a floor");
        vault.mint(ALICE, 1e12);
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        uint256 paidShares = alchemist.repay(1e12, id);
        assertEq(paidShares, 1e12, "one native collateral unit must be collected");
        assertEq(vault.balanceOf(address(transmuter)), 1e12);
        (, uint256 debt,) = alchemist.getCDP(id);
        assertEq(debt, 0);
    }

    function test_NonLikeKind_TinyDebtSelfLiquidationCannotReturnAllCollateral() public {
        _deploy(6, 2000e18, true);
        uint256 id = _open(ALICE, ONE, 1);
        vm.prank(ALICE);
        uint256 paidShares = alchemist.selfLiquidate(id, ALICE);
        assertEq(paidShares, 1e12);
        assertEq(vault.balanceOf(address(transmuter)), 1e12);
        assertEq(vault.balanceOf(ALICE), ONE - 1e12);
        assertEq(alchemist.totalDebt(), 0);
    }

    function test_NonLikeKind_ForcedEarmarkedRepaymentRoundsUpNativeCollateral() public {
        _deploy(6, 2000e18, true);
        uint256 id = _open(ALICE, 1e12, 1e12);
        _stake(ALICE, 1e12);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        alchemist.poke(id);
        (, uint256 debtBefore, uint256 earmarkedBefore) = alchemist.getCDP(id);
        assertEq(earmarkedBefore, debtBefore);
        assertEq(debtBefore, 1e12);
        oracle.setPrice(12e17);
        // One native atom is worth1.2e12 debt wei, making this position unhealthy.
        // Paying its1e12 earmarked debt needs that atom despite a floor of zero.
        assertEq(alchemist.convertDebtTokensToYield(debtBefore), 0);
        vm.prank(LIQUIDATOR);
        (uint256 paidShares, uint256 shareFee, uint256 nativeFee) = alchemist.liquidate(id);
        assertEq(paidShares, 1e12);
        assertEq(shareFee, 0);
        assertEq(nativeFee, 0);
        assertEq(vault.balanceOf(address(transmuter)), 1e12);
        assertGe(alchemist.convertYieldTokensToDebt(paidShares), debtBefore);
        (uint256 shares, uint256 debt, uint256 earmarked) = alchemist.getCDP(id);
        assertEq(shares, 0);
        assertEq(debt, 0);
        assertEq(earmarked, 0);
        assertEq(alchemist.totalDebt(), 0);
        assertEq(alchemist.cumulativeEarmarked(), 0);
        assertEq(alchemist.getTotalDeposited(), 0);
    }

    function test_NonLikeKind_TinyDebtLocksNonzeroCollateral() public {
        _deploy(6, 2000e18, true);
        uint256 id = _open(ALICE, ONE, 1);
        uint256 maxWithdraw = alchemist.getMaxWithdrawable(id);
        assertEq(maxWithdraw, ONE - 1e12);
        vm.prank(ALICE);
        alchemist.withdraw(maxWithdraw, ALICE, id);
        assertGe(alchemist.totalValue(id), 2);
        vm.prank(ALICE);
        vm.expectRevert();
        alchemist.withdraw(1, ALICE, id);
    }

    function test_NonLikeKind_WithdrawalRoundsRequiredDebtBeforeNativeConversion() public {
        _deploy(6, ONE, true);
        alchemist.setCollateralizationLowerBound(105e16);
        alchemist.setMinimumCollateralization(11e17);
        uint256 id = _open(ALICE, ONE, 1e12);
        // 1.1 native atoms of backing requires two atoms. Rounding debt to one
        // atom before applying110% would incorrectly keep only one native atom.
        uint256 maxWithdraw = alchemist.getMaxWithdrawable(id);
        assertEq(maxWithdraw, ONE - 2e12);
        vm.prank(ALICE);
        alchemist.withdraw(maxWithdraw, ALICE, id);
        assertEq(alchemist.totalValue(id), 2e12);
        assertGe(alchemist.totalValue(id), 11e11);
        assertEq(alchemist.getMaxWithdrawable(id), 0);
    }

    function test_NonLikeKind_DefaultAndUnitOracleHaveIdenticalLikeKindReplay() public {
        bytes32 defaultResult = _parityReplay(false);
        bytes32 oracleResult = _parityReplay(true);
        assertEq(defaultResult, oracleResult);
    }

    function test_LikeKind_NewAccountAfterFullRedemptionResetMatchesPendingView() public {
        _deploy(18, ONE, false);
        uint256 aliceId = _open(ALICE, 100e18, 40e18);
        _stake(ALICE, 40e18);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        vm.prank(ALICE);
        (uint256 firstPayout,,,) = transmuter.claimRedemption(1);
        assertEq(firstPayout, 40e18);
        assertEq(alchemist.totalDebt(), 0);
        assertEq(alchemist.cumulativeEarmarked(), 0);

        // Alice remains unsynced across both full earmark and redemption resets.
        // Bob's new account must checkpoint the current indices without inheriting history.
        uint256 bobId = _open(BOB, 200e18, 60e18);
        (uint256 bobCollateral, uint256 bobDebt, uint256 bobEarmarked) = alchemist.getCDP(bobId);
        assertEq(bobCollateral, 200e18);
        assertEq(bobDebt, 60e18);
        assertEq(bobEarmarked, 0);
        _stake(BOB, 60e18);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);

        // The next full earmark is still prospective: its boundary is not stored yet.
        assertEq(alchemist.cumulativeEarmarked(), 0);
        (uint256 pendingCollateral, uint256 pendingDebt, uint256 pendingEarmarked) = alchemist.getCDP(bobId);
        assertEq(pendingCollateral, 200e18);
        assertEq(pendingDebt, 60e18);
        assertEq(pendingEarmarked, 60e18);
        assertEq(alchemist.cumulativeEarmarked(), 0, "view must not commit the epoch");
        alchemist.poke(bobId);
        (bobCollateral, bobDebt, bobEarmarked) = alchemist.getCDP(bobId);
        assertEq(bobCollateral, pendingCollateral);
        assertEq(bobDebt, pendingDebt);
        assertEq(bobEarmarked, pendingEarmarked);
        assertEq(alchemist.cumulativeEarmarked(), 60e18);

        vm.prank(BOB);
        (uint256 secondPayout,,,) = transmuter.claimRedemption(2);
        assertEq(secondPayout, 60e18);
        alchemist.poke(aliceId);
        alchemist.poke(bobId);
        (uint256 aliceCollateral, uint256 aliceDebt, uint256 aliceEarmarked) = alchemist.getCDP(aliceId);
        (bobCollateral, bobDebt, bobEarmarked) = alchemist.getCDP(bobId);
        assertEq(aliceCollateral, 60e18);
        assertEq(bobCollateral, 140e18);
        assertEq(aliceDebt, 0);
        assertEq(aliceEarmarked, 0);
        assertEq(bobDebt, 0);
        assertEq(bobEarmarked, 0);
        assertEq(alchemist.totalDebt(), 0);
        assertEq(alchemist.cumulativeEarmarked(), 0);
        assertEq(alchemist.getTotalDeposited(), aliceCollateral + bobCollateral);
        assertEq(vault.balanceOf(address(alchemist)), aliceCollateral + bobCollateral);
        assertEq(alchemist.totalSyntheticsIssued(), 0);
        assertEq(synthetic.totalSupply(), 0);
        assertEq(transmuter.totalLocked(), 0);
    }

    function testFuzz_NonLikeKind_ConversionsMatchIndependentUnits(uint96 rawShares, uint64 rawPrice, bool sixDecimals) public {
        uint256 price = bound(rawPrice, 1e14, 10e18);
        _deploy(sixDecimals ? 6 : 18, price, true);
        uint256 shares = bound(rawShares, ONE, 1e25);
        uint256 rate = assetUnit * 3 / 2;
        vault.setAssetsPerShare(rate);
        uint256 assets = shares * rate / ONE;
        uint256 expectedDebt = assets * price / assetUnit;
        assertEq(alchemist.convertYieldTokensToDebt(shares), expectedDebt);
        assertEq(alchemist.normalizeUnderlyingTokensToDebt(assets), expectedDebt);
        uint256 recoveredAssets = expectedDebt * assetUnit / price;
        assertEq(alchemist.convertDebtTokensToYield(expectedDebt), recoveredAssets * ONE / rate);
        assertLe(recoveredAssets, assets);
    }

    /// @dev A bounded stateful campaign. Expected account quantities are updated
    /// directly from each action; market price and vault rate are independent.
    function testFuzz_NonLikeKind_PriceChangesPreserveAccounting(uint256 seed) public {
        _deploy(6, 2e18, true);
        uint256 id = _open(ALICE, 10_000e18, 100e18);
        uint256 expectedShares = 10_000e18;
        uint256 expectedDebt = 100e18;
        for (uint256 step; step < 20; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 price = 5e17 + seed % 35e17;
            uint256 rate = assetUnit / 2 + (seed >> 64) % (3 * assetUnit / 2);
            oracle.setPrice(price);
            vault.setAssetsPerShare(rate);
            vm.roll(block.number + 1);
            uint256 action = (seed >> 128) % 5;
            if (action == 0) {
                vm.prank(ALICE);
                alchemist.mint(id, ONE, ALICE);
                expectedDebt += ONE;
            } else if (action == 1) {
                uint256 suppliedShares = 1e16;
                uint256 creditedDebt = (suppliedShares * rate / ONE) * price / assetUnit;
                vault.mint(ALICE, suppliedShares);
                vm.prank(ALICE);
                uint256 paid = alchemist.repay(suppliedShares, id);
                uint256 nativeToPay = _ceilDiv(creditedDebt * assetUnit, price);
                assertEq(paid, _ceilDiv(nativeToPay * ONE, rate));
                assertLe(paid, suppliedShares, "repayment exceeded the supplied shares");
                assertGe((paid * rate / ONE) * price / assetUnit, creditedDebt, "repayment did not back its debt credit");
                expectedDebt -= creditedDebt;
            } else if (action == 2) {
                vm.startPrank(ALICE);
                synthetic.approve(address(alchemist), ONE);
                alchemist.burn(ONE, id);
                vm.stopPrank();
                expectedDebt -= ONE;
            } else if (action == 3) {
                vault.mint(ALICE, 2e18);
                vm.prank(ALICE);
                alchemist.deposit(2e18, ALICE, id);
                expectedShares += 2e18;
            } else {
                vm.prank(ALICE);
                alchemist.withdraw(ONE, ALICE, id);
                expectedShares -= ONE;
            }
            (uint256 actualShares, uint256 actualDebt, uint256 earmarked) = alchemist.getCDP(id);
            assertEq(actualShares, expectedShares);
            assertEq(actualDebt, expectedDebt);
            assertEq(earmarked, 0);
            assertEq(alchemist.totalDebt(), expectedDebt);
            assertEq(alchemist.getTotalDeposited(), expectedShares);
            assertEq(vault.balanceOf(address(alchemist)), expectedShares);
            assertEq(alchemist.totalSyntheticsIssued(), synthetic.totalSupply());
            uint256 expectedValue = (expectedShares * rate / ONE) * price / assetUnit;
            assertEq(alchemist.totalValue(id), expectedValue);
            assertEq(alchemist.getMaxBorrowable(id), expectedValue / 2 - expectedDebt);
        }
    }

    function _deploy(uint8 collateralDecimals, uint256 price, bool useOracle) private {
        assetUnit = 10 ** collateralDecimals;
        collateral = new NonLikeKindTestToken(collateralDecimals);
        referenceToken = new NonLikeKindTestToken(6);
        vault = new NonLikeKindTestVault(address(collateral), assetUnit);
        oracle = new NonLikeKindTestOracle(address(collateral), address(referenceToken), price);
        synthetic = new AlchemicTokenV3("Synthetic reference", "alREF", 0);
        transmuter = new Transmuter(
            ITransmuter.TransmuterInitializationParams({
                syntheticToken: address(synthetic),
                feeReceiver: FEE_RECIPIENT,
                timeToTransmute: TRANSMUTATION_BLOCKS,
                transmutationFee: 0,
                exitFee: 0,
                graphSize: 100_000
            })
        );
        implementation = new AlchemistV3();
        AlchemistInitializationParams memory params = _params();
        if (useOracle) {
            params.debtReferenceToken = address(referenceToken);
            params.collateralPriceOracle = address(oracle);
        }
        bytes memory data = abi.encodeCall(AlchemistV3.initialize, (params));
        alchemist = AlchemistV3(address(new TransparentUpgradeableProxy(address(implementation), address(this), data)));
        synthetic.setWhitelist(address(alchemist), true);
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(type(uint128).max);
        alchemist.setAlchemistPositionNFT(address(new AlchemistV3Position(address(alchemist), address(this))));
        feeVault = new AlchemistTokenVault(address(collateral), address(alchemist), address(this));
        alchemist.setAlchemistFeeVault(address(feeVault));
        collateral.mint(address(feeVault), 10_000 * assetUnit);
    }

    function _params() private view returns (AlchemistInitializationParams memory) {
        return AlchemistInitializationParams({
            admin: address(this),
            debtToken: address(synthetic),
            underlyingToken: address(collateral),
            depositCap: type(uint128).max,
            minimumCollateralization: MIN_CR,
            globalMinimumCollateralization: MIN_CR,
            collateralizationLowerBound: 15e17,
            liquidationTargetCollateralization: TARGET_CR,
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: FEE_RECIPIENT,
            liquidatorFee: 300,
            repaymentFee: 0,
            myt: address(vault),
            debtReferenceToken: address(collateral),
            collateralPriceOracle: address(0)
        });
    }

    function _open(address user, uint256 shares, uint256 debt) private returns (uint256 id) {
        vault.mint(user, shares);
        vm.startPrank(user);
        vault.approve(address(alchemist), type(uint256).max);
        (id,) = alchemist.deposit(shares, user, 0);
        if (debt != 0) alchemist.mint(id, debt, user);
        vm.stopPrank();
    }

    function _stake(address user, uint256 amount) private {
        vm.startPrank(user);
        synthetic.approve(address(transmuter), amount);
        transmuter.createRedemption(amount, user);
        vm.stopPrank();
    }

    function _claimWithInventory(uint256 repaidDebt, uint256 finalPrice) private {
        _deploy(18, 2e18, true);
        uint256 id = _open(ALICE, 1000e18, 1000e18);
        if (repaidDebt != 0) {
            uint256 repaymentShares = repaidDebt / 2;
            vault.mint(ALICE, repaymentShares);
            vm.roll(block.number + 1);
            vm.prank(ALICE);
            alchemist.repay(repaymentShares, id);
        }
        _stake(ALICE, 300e18);
        oracle.setPrice(finalPrice);
        uint256 inventory = vault.balanceOf(address(transmuter));
        uint256 inventoryDebt = inventory * finalPrice / ONE;
        uint256 redeemedDebt = inventoryDebt >= 300e18 ? 0 : 300e18 - inventoryDebt;
        uint256 beforeDebt = alchemist.totalDebt();
        uint256 beforeCollateral = alchemist.getTotalDeposited();
        uint256 expectedShares = 300e18 * ONE / finalPrice;
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        vm.prank(ALICE);
        (uint256 received, uint256 fee, uint256 returned, uint256 exitFee) = transmuter.claimRedemption(1);
        assertEq(received, expectedShares);
        assertEq(fee, 0);
        assertEq(returned, 0);
        assertEq(exitFee, 0);
        assertEq(beforeDebt - alchemist.totalDebt(), redeemedDebt);
        assertEq(beforeCollateral - alchemist.getTotalDeposited(), redeemedDebt * ONE / finalPrice);
        assertEq(alchemist.totalSyntheticsIssued(), 700e18);
        assertEq(synthetic.totalSupply(), 700e18);
        assertEq(transmuter.totalLocked(), 0);
    }

    function _parityReplay(bool useOracle) private returns (bytes32) {
        _deploy(6, ONE, useOracle);
        uint256 id = _open(ALICE, 100e18, 40e18);
        vm.roll(block.number + 1);
        vault.mint(ALICE, 10e18);
        vm.startPrank(ALICE);
        alchemist.repay(10e18, id);
        synthetic.approve(address(alchemist), 5e18);
        alchemist.burn(5e18, id);
        alchemist.withdraw(10e18, ALICE, id);
        vm.stopPrank();
        _stake(ALICE, 10e18);
        vm.roll(block.number + TRANSMUTATION_BLOCKS);
        vm.prank(ALICE);
        transmuter.claimRedemption(1);
        (uint256 shares, uint256 debt, uint256 earmarked) = alchemist.getCDP(id);
        return keccak256(
            abi.encode(
                shares, debt, earmarked, alchemist.totalSyntheticsIssued(), alchemist.getTotalDeposited(), vault.balanceOf(ALICE), synthetic.balanceOf(ALICE)
            )
        );
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
    }
}
