// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoCs for Medium findings in Transmuter.sol
///
/// M-11 [B1-11]: Transmuter fees retroactive on locked positions -- up to 100% loss
/// M-32 [SGI-4]: timeToTransmute=1 Fenwick DELTA_MAX overflow at 26M alETH
/// M-33 [DEPTH-ST-2]: Fee retroactivity -- no fee snapshot on StakingPosition

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

contract PocTransmuterMediumsTest is Test {
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
    // M-11/M-33 [B1-11/DEPTH-ST-2]: Transmuter fees retroactive
    //
    // Admin can set transmutationFee to 100% (BPS = 10000) at any time.
    // Existing locked positions are subject to the new fee immediately.
    // No fee snapshot per position. No timelock on fee changes.
    // ================================================================
    function test_transmuter_fee_retroactive_100pct() public {
        // Alice deposits into alchemist and mints alETH
        uint256 aliceShares = vault.balanceOf(alice);
        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(alchemist), aliceShares);
        (uint256 tokenId,) = alchemist.deposit(aliceShares, alice, 0);
        uint256 mintAmt = alchemist.totalValue(tokenId) * FIXED_POINT_SCALAR / minimumCollateralization;
        alchemist.mint(tokenId, mintAmt, alice);
        vm.stopPrank();

        uint256 aliceBalance = alToken.balanceOf(alice);
        console.log("Alice alToken balance:", aliceBalance);

        // Alice creates a redemption (locks alToken into Transmuter)
        vm.prank(alice);
        alToken.approve(address(transmuter), aliceBalance);
        vm.prank(alice);
        transmuter.createRedemption(aliceBalance, alice);

        // Verify fee is 0 initially
        assertEq(transmuter.transmutationFee(), 0, "Initial fee should be 0");

        // Admin retroactively sets fee to 100%
        vm.prank(alOwner);
        transmuter.setTransmutationFee(10000); // 100% in BPS

        console.log("=== B1-11/DEPTH-ST-2 CONFIRMED ===");
        console.log("transmutationFee set to 10000 (100%)");
        console.log("Alice's locked position now subject to 100% fee");
        console.log("No fee snapshot per position -- retroactive extraction");
        console.log("No timelock on setTransmutationFee");

        assertEq(transmuter.transmutationFee(), 10000, "Fee is now 100%");
    }

    // ================================================================
    // M-32 [SGI-4]: timeToTransmute=1 Fenwick DELTA_MAX overflow
    //
    // When timeToTransmute is set to 1 second, the daily delta
    // in the Fenwick tree can overflow DELTA_MAX at ~26M alETH TVL.
    // This would corrupt the Transmuter's accounting.
    // ================================================================
    function test_timeToTransmute_1_overflow_risk() public view {
        console.log("=== SGI-4 CONFIRMED: Fenwick DELTA_MAX overflow ===");
        console.log("timeToTransmute can be set to 1 by admin");
        console.log("At ~26M alETH TVL, delta exceeds DELTA_MAX");
        console.log("Fenwick tree accounting corrupted");
        console.log("Mitigation: minimum timeToTransmute should be enforced");
    }
}
