// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "./mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../AlchemistV3PositionRenderer.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MockAlchemistAllocator} from "./mocks/MockAlchemistAllocator.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IERC721Enumerable} from "../../lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

contract AlchemistV3PerformanceFeeTest is Test {
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;
    AlchemistTokenVault alchemistFeeVault;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    VaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;
    address public admin = address(0x4444444444444444444444444444444444444444);
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public operator = address(0x2222222222222222222222222222222222222222);
    address public mockVaultCollateral;
    address public mockStrategyYieldToken;
    address public user = address(0xbeef);
    address public user2 = address(0xdad);
    address public protocolFeeReceiver = address(10);
    address public alOwner;

    uint256 public minimumCollateralization = uint256(1e36) / 9e17;
    uint256 public liquidationTargetCollateralization = uint256(1e36) / 88e16;
    uint256 public liquidatorFeeBPS = 300;
    uint256 public repaymentFeeBPS = 100;

    function setUp() public {
        vm.startPrank(admin);
        mockVaultCollateral = address(new TestERC20(100e18, 18));
        mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(
            address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW
        );
        allocator =
            new MockAlchemistAllocator(address(vault), admin, operator, address(new AlchemistStrategyClassifier(admin)));
        vm.stopPrank();

        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 2_000_000_000e18)));
        vault.increaseAbsoluteCap(idData, 2_000_000_000e18);
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        _deployAlchemistCore();

        _seedAndAllocate(1_000_000e18);
        _depositUsers();

        vm.startPrank(admin);
        allocator.setMaxRate(200e16 / uint256(365 days));
        vm.stopPrank();

        uint256 supply = IERC20(mockStrategyYieldToken).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(supply / 2);
        vm.warp(block.timestamp + 365 days);
    }

    function testDepositValueReflectsFeeDilution() public {
        uint256 priceBefore = vault.convertToAssets(1e18);
        assertGt(priceBefore, 1e18, "share price must exceed 1:1 after yield");

        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        vm.stopPrank();

        (uint256 deposited,,) = alchemist.getCDP(tokenId);
        assertEq(deposited, depositAmt, "deposited shares must equal input");

        uint256 underlyingValue = alchemist.convertYieldTokensToUnderlying(deposited);
        assertGt(underlyingValue, depositAmt, "underlying value must exceed deposited shares after yield");
    }

    function testMintDebtAfterYieldAccrual() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);

        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        assertGt(maxBorrow, 0, "must be able to borrow against collateral");

        uint256 mintAmt = maxBorrow / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        (, uint256 debt,) = alchemist.getCDP(tokenId);
        assertEq(debt, mintAmt, "debt must equal minted amount");
    }

    function testWithdrawAfterYieldAccrual() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);

        uint256 balBefore = IERC20(address(vault)).balanceOf(user);
        alchemist.withdraw(depositAmt / 2, user, tokenId);
        uint256 received = IERC20(address(vault)).balanceOf(user) - balBefore;
        vm.stopPrank();

        assertEq(received, depositAmt / 2, "withdrawn shares must equal requested");
        assertGt(vault.convertToAssets(received), received, "withdrawn shares worth more than face value");
    }

    function testCollateralValueAfterYieldAccrual() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        vm.stopPrank();

        uint256 totalVal = alchemist.totalValue(tokenId);
        uint256 underlyingVal = alchemist.convertYieldTokensToUnderlying(depositAmt);
        assertEq(totalVal, underlyingVal, "total value must match yield-to-underlying conversion");
        assertGt(totalVal, depositAmt, "total value must exceed deposited shares after yield");
    }

    function testTotalUnderlyingValueReflectsFees() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.prank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        vm.prank(user);
        alchemist.deposit(depositAmt, user, 0);

        uint256 totalUnderlying = alchemist.getTotalUnderlyingValue();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        uint256 impliedPrice = vault.convertToAssets(totalDeposited);
        assertGt(impliedPrice, totalDeposited, "vault share price must exceed 1:1 after yield");
        assertGe(totalUnderlying, impliedPrice - 1, "total underlying must reflect fee-diluted share price");
    }

    function testRepayAfterYieldAccrual() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt + 50e18);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt + 50e18);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);

        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 4;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(user);
        uint256 repayYieldShares = alchemist.convertDebtTokensToYield(mintAmt / 2);
        alchemist.repay(repayYieldShares, tokenId);
        vm.stopPrank();

        (, uint256 debtAfter,) = alchemist.getCDP(tokenId);
        assertLt(debtAfter, mintAmt, "debt must decrease after repayment");
    }

    function _deployAlchemistCore() internal {
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.startPrank(caller);
        alOwner = caller;

        alToken = new AlchemicTokenV3("", "", 0);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        transmuter = new Transmuter(transParams);
        whitelist = new Whitelist();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(vault.asset()),
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000,
            globalMinimumCollateralization: 1_111_111_111_111_111_111,
            liquidationTargetCollateralization: liquidationTargetCollateralization,
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: liquidatorFeeBPS,
            repaymentFee: repaymentFeeBPS,
            myt: address(vault)
        });

        bytes memory init = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(new AlchemistV3()), proxyOwner, init);
        alchemist = AlchemistV3(address(proxy));

        alToken.setWhitelist(address(proxy), true);
        whitelist.add(user);
        whitelist.add(user2);

        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist), alOwner);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        alchemistFeeVault = new AlchemistTokenVault(address(vault.asset()), address(alchemist), alOwner);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        vm.stopPrank();
    }

    function _seedAndAllocate(uint256 amount) internal {
        address yieldWhale = address(0x7777);
        deal(mockVaultCollateral, yieldWhale, amount);
        vm.startPrank(yieldWhale);
        TokenUtils.safeApprove(mockVaultCollateral, mockStrategyYieldToken, amount);
        IMockYieldToken(mockStrategyYieldToken).mint(amount, yieldWhale);
        vm.stopPrank();
    }

    function _depositUsers() internal {
        _magicDepositToVault(address(vault), user, 400e18);
        _magicDepositToVault(address(vault), user2, 400e18);

        uint256 allocateAmt = vault.convertToAssets(vault.totalSupply());
        vm.prank(admin);
        allocator.allocate(address(mytStrategy), allocateAmt);
    }

    function testVaultFeeRateChangeSettlesPendingFeesWithActivePositions() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        uint256 currentMocked = IMockYieldToken(mockStrategyYieldToken).mockedSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(currentMocked / 2);
        vm.warp(block.timestamp + 180 days);

        uint256 adminSharesBefore = vault.balanceOf(admin);
        uint256 colValueBefore = alchemist.totalValue(tokenId);
        assertGt(colValueBefore, 0, "position must have value before fee change");

        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (0.5e18)));
        vault.setPerformanceFee(0.5e18);
        vm.stopPrank();

        uint256 feeSharesSettled = vault.balanceOf(admin) - adminSharesBefore;
        assertGt(feeSharesSettled, 0, "fee rate change must settle pending fees at old rate");
        assertEq(vault.performanceFee(), 0.5e18, "new fee rate must be applied");

        uint256 colValueAfter = alchemist.totalValue(tokenId);
        assertLe(colValueAfter, colValueBefore, "collateral value must not increase after fee settlement");

        vm.prank(user);
        alchemist.withdraw(1, user, tokenId);
        (uint256 colAfterWithdraw, uint256 debtAfterWithdraw,) = alchemist.getCDP(tokenId);
        assertEq(colAfterWithdraw, depositAmt - 1, "withdrawn amount must be deducted");
        assertEq(debtAfterWithdraw, mintAmt, "debt must be unchanged after withdraw");
    }

    function testVaultFeeRateChangeToZeroThenNewYieldDoesNotAccrue() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (0)));
        vault.setPerformanceFee(0);
        vm.stopPrank();

        assertEq(vault.performanceFee(), 0, "fee must be zeroed");

        uint256 currentMocked = IMockYieldToken(mockStrategyYieldToken).mockedSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(currentMocked / 2);
        vm.warp(block.timestamp + 180 days);

        uint256 adminSharesBefore = vault.balanceOf(admin);
        vault.accrueInterest();
        assertEq(vault.balanceOf(admin) - adminSharesBefore, 0, "no fees should accrue after zeroing");

        uint256 totalVal = alchemist.totalValue(tokenId);
        assertGt(totalVal, depositAmt, "share price must still appreciate without fees");
    }

    function testVaultFeeRecipientChangeSettlesAtOldRecipient() public {
        uint256 depositAmt = 100e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        uint256 currentMocked = IMockYieldToken(mockStrategyYieldToken).mockedSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(currentMocked / 2);
        vm.warp(block.timestamp + 180 days);

        uint256 adminSharesBefore = vault.balanceOf(admin);
        address newRecipient = address(0x9999);

        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (newRecipient)));
        vault.setPerformanceFeeRecipient(newRecipient);
        vm.stopPrank();

        uint256 feeSharesToOldRecipient = vault.balanceOf(admin) - adminSharesBefore;
        assertGt(feeSharesToOldRecipient, 0, "pending fees must settle to old recipient before switch");
        assertEq(vault.performanceFeeRecipient(), newRecipient, "recipient must be updated");

        uint256 colValue = alchemist.totalValue(tokenId);
        assertGt(colValue, 0, "position must still be healthy after recipient change");
        (, uint256 debt,) = alchemist.getCDP(tokenId);
        assertEq(debt, mintAmt, "debt must be unchanged");

        vm.prank(user);
        alchemist.withdraw(1, user, tokenId);
        (uint256 colAfter, uint256 debtAfter,) = alchemist.getCDP(tokenId);
        assertLt(colAfter, depositAmt, "withdraw must reduce collateral");
        assertEq(debtAfter, mintAmt, "debt must be unchanged after withdraw");
    }

    function testInterleavedVaultSettlementBetweenAlchemistOps() public {
        uint256 depositAmt = 200e18;
        uint256 extraForRepay = 50e18;
        deal(address(vault), user, depositAmt + extraForRepay);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt + extraForRepay);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        uint256 currentMocked = IMockYieldToken(mockStrategyYieldToken).mockedSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(currentMocked * 3 / 4);
        vm.warp(block.timestamp + 90 days);

        vm.roll(block.number + 1);
        vm.startPrank(user);
        uint256 repayShares = alchemist.convertDebtTokensToYield(mintAmt / 4);
        if (repayShares > extraForRepay) repayShares = extraForRepay / 2;
        alchemist.repay(repayShares, tokenId);
        vm.stopPrank();

        (, uint256 debtAfterRepay,) = alchemist.getCDP(tokenId);
        assertLt(debtAfterRepay, mintAmt, "debt must decrease after repay");

        vm.prank(user);
        alchemist.withdraw(depositAmt / 10, user, tokenId);

        (uint256 colAfter, uint256 debtAfter,) = alchemist.getCDP(tokenId);
        assertLt(colAfter, depositAmt, "collateral must decrease after withdraw");
        assertEq(debtAfter, debtAfterRepay, "debt must be unchanged after withdraw");

        uint256 totalUnderlying = alchemist.getTotalUnderlyingValue();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        assertGe(totalUnderlying, totalDeposited - 1, "total underlying must at least equal deposited after yield");
    }

    function testTransmuterFlowUnderFeeDilution() public {
        uint256 depositAmt = 200e18;
        deal(address(vault), user, depositAmt);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmt);
        (uint256 tokenId,) = alchemist.deposit(depositAmt, user, 0);
        uint256 mintAmt = alchemist.getMaxBorrowable(tokenId) / 2;
        alchemist.mint(tokenId, mintAmt, user);
        vm.stopPrank();

        vm.prank(alOwner);
        alToken.setWhitelist(user, true);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(alToken), address(transmuter), mintAmt);
        transmuter.createRedemption(mintAmt, user);
        vm.stopPrank();

        uint256 currentMocked = IMockYieldToken(mockStrategyYieldToken).mockedSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(currentMocked / 2);
        vm.warp(block.timestamp + 365 days);

        uint256 redemptionTokenId = IERC721Enumerable(address(transmuter)).tokenOfOwnerByIndex(user, 0);
        ITransmuter.StakingPosition memory pos = transmuter.getPosition(redemptionTokenId);
        vm.roll(pos.maturationBlock);

        uint256 transmuterBalanceBefore = IERC20(address(vault)).balanceOf(address(transmuter));

        vm.prank(user);
        transmuter.claimRedemption(redemptionTokenId);

        uint256 transmuterBalanceAfter = IERC20(address(vault)).balanceOf(address(transmuter));
        assertGe(
            transmuterBalanceBefore,
            transmuterBalanceAfter,
            "transmuter must send shares to claimer"
        );

        (uint256 colAfter,,) = alchemist.getCDP(tokenId);
        assertLt(colAfter, depositAmt, "redeem must debit collateral from position");
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal {
        deal(mockVaultCollateral, depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(mockVaultCollateral, _vault, amount);
        IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
    }
}
