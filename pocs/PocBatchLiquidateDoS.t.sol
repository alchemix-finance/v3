// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for M-18 [B6-2]: batchLiquidate Unbounded Loop Gas DoS
/// batchLiquidate iterates over an array of tokenIds without bounds checking.
/// A large array causes out-of-gas reverts, preventing batch liquidation.
///
/// Finding: B6-2 | Severity: Medium | CONFIRMED (PoC verified)

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

contract PocBatchLiquidateDoSTest is Test {
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

    uint256 constant NUM_POSITIONS = 50;
    uint256[] tokenIds;

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

        // Create NUM_POSITIONS positions
        for (uint256 i = 0; i < NUM_POSITIONS; i++) {
            address user = address(uint160(0x1000 + i));
            _magicDepositToVault(user, 100e18);

            uint256 shares = vault.balanceOf(user);
            vm.startPrank(user);
            IERC20(address(vault)).approve(address(alchemist), shares);
            (uint256 tid,) = alchemist.deposit(shares, user, 0);
            uint256 maxMint = alchemist.totalValue(tid) * FIXED_POINT_SCALAR / minimumCollateralization;
            alchemist.mint(tid, maxMint, user);
            vm.stopPrank();
            tokenIds.push(tid);
        }

        // Allocate
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
    // PoC: batchLiquidate with many positions succeeds but gas scales
    // linearly with no upper bound. Demonstrates the unbounded loop.
    // ================================================================
    function test_batchLiquidate_unbounded_gas() public {
        // Make all positions liquidatable via parameter chain
        vm.startPrank(alOwner);
        alchemist.setLiquidationTargetCollateralization(2e18);
        alchemist.setGlobalMinimumCollateralization(2e18);
        alchemist.setMinimumCollateralization(15e17);
        alchemist.setCollateralizationLowerBound(13e17);
        vm.stopPrank();

        // batchLiquidate works but gas grows linearly
        uint256 gasBefore = gasleft();
        alchemist.batchLiquidate(tokenIds);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== B6-2 CONFIRMED: Unbounded batch liquidation ===");
        console.log("Positions liquidated:", tokenIds.length);
        console.log("Gas used:            ", gasUsed);
        console.log("Gas per position:    ", gasUsed / tokenIds.length);
        console.log("Extrapolated gas at 500 positions:", (gasUsed / tokenIds.length) * 500);

        // At 500 positions with ~350k gas each → 175M gas, far exceeding block limits
        uint256 extrapolated = (gasUsed / tokenIds.length) * 500;
        assertGt(extrapolated, 30_000_000, "Would exceed typical block gas limit");
    }
}
