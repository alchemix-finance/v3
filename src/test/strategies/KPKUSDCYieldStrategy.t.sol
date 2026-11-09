// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";
import {ERC4626Candidates} from "./base/ERC4626Candidates.sol";

interface IMorphoVaultV2Meta {
    function curator() external view returns (address);
    function adaptersLength() external view returns (uint256);
    function liquidityAdapter() external view returns (address);
}

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorphoBlueLite {
    function market(bytes32 id) external view returns (MorphoMarket memory);
    function accrueInterest(MorphoMarketParams memory marketParams) external;
}

interface IMorphoIrmLite {
    function borrowRateView(MorphoMarketParams memory marketParams, MorphoMarket memory market) external view returns (uint256);
}

interface IMorphoMarketAdapterLite {
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}

/// @notice The Morpho market a Vault V2 uses for deposits and withdrawals.
library KpkLiquidityMarket {
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @dev Past this linear growth the share price is far beyond one asset per share.
    uint256 internal constant BREACH_LINEAR_WAD = 1e6 * WAD;

    function paramsOf(address vault_) internal view returns (MorphoMarketParams memory) {
        return abi.decode(IVaultV2(vault_).liquidityData(), (MorphoMarketParams));
    }

    /// @dev Supply balances Morpho will use on the next interaction. `ok` is false once the projection overflows.
    function projectedSupply(address vault_) internal view returns (bool ok, uint256 supplyAssets, uint256 supplyShares, uint256 borrowAssets) {
        MorphoMarketParams memory mp = paramsOf(vault_);
        MorphoMarket memory m = IMorphoBlueLite(MORPHO).market(keccak256(abi.encode(mp)));
        supplyAssets = m.totalSupplyAssets;
        supplyShares = m.totalSupplyShares;
        borrowAssets = m.totalBorrowAssets;

        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0 || borrowAssets == 0 || mp.irm == address(0)) return (true, supplyAssets, supplyShares, borrowAssets);

        uint256 rate = IMorphoIrmLite(mp.irm).borrowRateView(mp, m);
        if (rate != 0 && elapsed > type(uint256).max / rate) return (false, 0, 0, 0);
        uint256 firstTerm = rate * elapsed;
        if (firstTerm >= BREACH_LINEAR_WAD) return (false, 0, 0, 0);

        uint256 compounded = firstTerm + firstTerm * firstTerm / (2 * WAD) + firstTerm * firstTerm / (2 * WAD) * firstTerm / (3 * WAD);
        uint256 interest = borrowAssets * compounded / WAD;
        supplyAssets += interest;
        borrowAssets += interest;

        if (m.fee != 0) {
            uint256 feeAmount = interest * m.fee / WAD;
            supplyShares += feeAmount * (supplyShares + VIRTUAL_SHARES) / (supplyAssets - feeAmount + VIRTUAL_ASSETS);
        }
        return (true, supplyAssets, supplyShares, borrowAssets);
    }

    /// @dev True while a deposit mints at least one share per asset, so SharePriceAboveOne cannot fire.
    function inBand(address vault_) internal view returns (bool) {
        (bool ok, uint256 supplyAssets, uint256 supplyShares,) = projectedSupply(vault_);
        if (!ok) return false;
        return supplyShares + VIRTUAL_SHARES >= supplyAssets + VIRTUAL_ASSETS;
    }

    /// @dev USDC the vault can release now: idle balance plus its liquidity-market position.
    function withdrawable(address vault_) internal view returns (uint256) {
        (bool ok, uint256 supplyAssets,, uint256 borrowAssets) = projectedSupply(vault_);
        uint256 idle = IERC20(IVaultV2(vault_).asset()).balanceOf(vault_);
        if (!ok) return idle;

        MorphoMarketParams memory mp = paramsOf(vault_);
        uint256 position = IMorphoMarketAdapterLite(IMorphoVaultV2Meta(vault_).liquidityAdapter()).expectedSupplyAssets(keccak256(abi.encode(mp)));
        uint256 free = supplyAssets > borrowAssets ? supplyAssets - borrowAssets : 0;
        return idle + (position < free ? position : free);
    }
}

contract KPKUSDCYieldStrategyTest is ERC4626StrategyUnitTestBase {
    /// @dev Fourteen days stays far inside the share price band even when the fuzz repeats it.
    function _maxFuzzTimeShift() internal view override returns (uint256) {
        return 14 days;
    }

    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.kpkUSDCYield();
    }

    /// @dev Withdrawals come from the liquidity market, so they stop at what that market can release.
    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 withdrawable = KpkLiquidityMarket.withdrawable(_candidate().targetVault);
        return requestedAssets < withdrawable ? requestedAssets : withdrawable;
    }

    function test_morphoVaultV2_zeroMaxMethodsAreNonBindingSentinels() public view {
        IERC4626 morphoVault = IERC4626(_candidate().targetVault);

        assertEq(morphoVault.maxDeposit(strategy), 0, "unexpected maxDeposit");
        assertEq(morphoVault.maxMint(strategy), 0, "unexpected maxMint");
        assertEq(morphoVault.maxWithdraw(strategy), 0, "unexpected maxWithdraw");
        assertEq(morphoVault.maxRedeem(strategy), 0, "unexpected maxRedeem");
    }

    function test_kpkUsdcYield_vaultMetadata() public view {
        ERC4626Candidate memory candidate = _candidate();
        IMorphoVaultV2Meta vaultV2 = IMorphoVaultV2Meta(candidate.targetVault);

        assertEq(IERC20Metadata(candidate.targetVault).name(), "KPK USDC Yield", "unexpected vault name");
        assertEq(IERC20Metadata(candidate.targetVault).symbol(), "KPK_USDC_Yield", "unexpected vault symbol");
        assertEq(IERC4626(candidate.targetVault).asset(), candidate.asset, "unexpected underlying");
        assertEq(IVaultV2(candidate.targetVault).performanceFee(), 0, "expected zero performance fee");
        assertEq(IVaultV2(candidate.targetVault).managementFee(), 0, "expected zero management fee");
        assertEq(vaultV2.adaptersLength(), 1, "expected a single market adapter");
        assertEq(vaultV2.liquidityAdapter(), IVaultV2(candidate.targetVault).adapters(0), "liquidity adapter should be the market adapter");
        assertTrue(vaultV2.curator() != address(0), "curator should be set");
    }

    function test_kpkUsdcYield_allocateAndPartiallyDeallocate() public {
        ERC4626Candidate memory candidate = _candidate();
        uint256 allocationAmount = 1_000e6;
        uint256 requestedDeallocation = 400e6;

        vm.prank(allocator);
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocationAmount);

        uint256 realAssetsAfterAllocation = IMYTStrategy(strategy).realAssets();
        assertApproxEqAbs(realAssetsAfterAllocation, allocationAmount, 2, "strategy should hold allocation value");
        assertGt(IERC4626(candidate.targetVault).balanceOf(strategy), 0, "strategy should hold KPK shares");

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(requestedDeallocation);
        assertLt(preview, requestedDeallocation, "preview should include configured slippage");

        uint256 mytUsdcBefore = IERC20Metadata(candidate.asset).balanceOf(vault);
        vm.prank(allocator);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), preview);

        assertEq(IERC20Metadata(candidate.asset).balanceOf(vault) - mytUsdcBefore, preview, "MYT should receive exact USDC");
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), realAssetsAfterAllocation - preview, 2, "remaining value");
        assertGt(IERC4626(candidate.targetVault).balanceOf(strategy), 0, "strategy should retain shares after partial exit");
    }

    /// @dev Drive the liquidity market past one asset per share, where every deposit size reverts.
    function test_kpkUsdcYield_sharePriceAboveOneRevertsAllocate() public {
        address targetVault = _candidate().targetVault;
        assertTrue(KpkLiquidityMarket.inBand(targetVault), "market should start inside the share price band");

        MorphoMarketParams memory mp = KpkLiquidityMarket.paramsOf(targetVault);
        uint256 steps;
        while (KpkLiquidityMarket.inBand(targetVault) && steps < 48) {
            vm.warp(block.timestamp + 180 days);
            IMorphoBlueLite(KpkLiquidityMarket.MORPHO).accrueInterest(mp);
            steps++;
        }
        assertGt(steps, 0, "band should take time to breach");
        assertFalse(KpkLiquidityMarket.inBand(targetVault), "share price should breach the band");

        vm.prank(allocator);
        vm.expectRevert(bytes4(0xff8d32ad)); // SharePriceAboveOne()
        IVaultV2(vault).allocate(strategy, getVaultParams(), 100e6);
    }
}

contract KPKUSDCYieldInvariantTest is ERC4626StrategyInvariantTestBase {
    function _candidate() internal pure override returns (ERC4626Candidate memory) {
        return ERC4626Candidates.kpkUSDCYield();
    }

    /// @dev Handler warps run up to a year each. Repeated at the IRM ceiling they push the liquidity market out of band,
    ///      after which every deposit reverts, so this suite does not warp.
    function _targetedSelectors() internal view override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
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
        selectors[10] = handler.simulateYield.selector;
        selectors[11] = handler.simulateValueLoss.selector;
        selectors[12] = handler.mine.selector;
        selectors[13] = handler.alchemistDepositCollateral.selector;
        selectors[14] = handler.alchemistBorrow.selector;
        selectors[15] = handler.alchemistRepayDebt.selector;
    }
}
