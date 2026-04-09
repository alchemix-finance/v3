// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for DEPTH-ST-1: Phantom totalSyntheticsIssued After selfLiquidate
/// selfLiquidate() calls _subDebt() which decrements totalDebt but NOT totalSyntheticsIssued.
/// After full self-liquidation, totalDebt=0 but totalSyntheticsIssued>0 permanently.
///
/// Finding: DEPTH-ST-1 | Severity: High | CONFIRMED (PoC verified)
/// Related: B6-5, B6-6, B6-10

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

contract PocPhantomSyntheticsIssuedTest is Test {
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
    uint256 minimumCollateralization = FIXED_POINT_SCALAR * FIXED_POINT_SCALAR / 9e17;
    uint256 liquidationTargetCollateralization = uint256(1e36) / 88e16;

    address alice = address(0xA1CE);
    address bob   = address(0xB0B);

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
            collateralizationLowerBound:     1_052_631_578_950_000_000,
            globalMinimumCollateralization:  1_111_111_111_111_111_111,
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

        _magicDepositToVault(alice, 10_000e18);

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
    // PoC: selfLiquidate does NOT decrement totalSyntheticsIssued
    // 
    // Steps:
    // 1. Alice deposits MYT shares and borrows max
    // 2. Alice self-liquidates (healthy position)
    // 3. totalDebt goes to 0, but totalSyntheticsIssued stays at minted amount
    // 
    // This proves the phantom issuance bug: totalSyntheticsIssued is never
    // decremented by selfLiquidate, only by burn() and reduceSyntheticsIssued().
    // ================================================================
    function test_selfLiquidate_phantom_totalSyntheticsIssued() public {
        uint256 aliceShares = vault.balanceOf(alice);

        // 1. Alice deposits and borrows
        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(alchemist), aliceShares);
        (uint256 tokenId,) = alchemist.deposit(aliceShares, alice, 0);

        uint256 maxMint = alchemist.totalValue(tokenId) * FIXED_POINT_SCALAR / minimumCollateralization;
        alchemist.mint(tokenId, maxMint, alice);
        vm.stopPrank();

        uint256 tsiBefore = alchemist.totalSyntheticsIssued();
        uint256 tdBefore  = alchemist.totalDebt();
        assertEq(tsiBefore, tdBefore, "tsi should equal td before liquidation");

        // 2. Alice self-liquidates
        vm.prank(alice);
        alchemist.selfLiquidate(tokenId, alice);

        // 3. Verify phantom issuance
        uint256 tsiAfter = alchemist.totalSyntheticsIssued();
        uint256 tdAfter  = alchemist.totalDebt();

        assertEq(tdAfter, 0, "totalDebt should be 0 after self-liquidation");
        assertGt(tsiAfter, 0, "BUG CONFIRMED: totalSyntheticsIssued stuck at pre-liquidation value");
        assertEq(tsiAfter, tsiBefore, "totalSyntheticsIssued unchanged by selfLiquidate");

        console.log("=== DEPTH-ST-1 CONFIRMED ===");
        console.log("totalSyntheticsIssued before:", tsiBefore);
        console.log("totalDebt before:           ", tdBefore);
        console.log("totalSyntheticsIssued after: ", tsiAfter);
        console.log("totalDebt after:            ", tdAfter);
        console.log("Phantom gap:                ", tsiAfter - tdAfter);
    }
}
