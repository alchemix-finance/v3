// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AlchemistRouter} from "../../router/AlchemistRouter.sol";
import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../../AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../../AlchemistTokenVault.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {Transmuter} from "../../Transmuter.sol";
import {Whitelist} from "../../utils/Whitelist.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {MockAlchemistAllocator} from "../mocks/MockAlchemistAllocator.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {SafeERC20} from "../../libraries/SafeERC20.sol";

contract AlchemistRouterTest is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;
    AlchemistTokenVault alchemistFeeVault;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    uint256 internal constant ONE_Q128 = uint256(1) << 128;

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public protocolFee = 100;

    uint256 public liquidatorFeeBPS = 300; // in BPS, 3%
    uint256 public repaymentFeeBPS = 100;

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;
    uint256 public liquidationTargetCollateralization = uint256(1e36) / 88e16; // ~113.63% (88% LTV)

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds;

    // large amount to test with
    uint256 whaleSupply;

    // amount of yield/underlying token to deposit
    uint256 depositAmount;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = FIXED_POINT_SCALAR;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // another random EOA for testing
    address yetAnotherExternalUser = address(0x520aB24368e5Ba8B727E9b8aB967073Ff9316961);

    // another random EOA for testing
    address someWhale = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    // WETH address
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public protocolFeeReceiver = address(10);

    // MYT variables
    IVaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;
    address public operator = address(0x2222222222222222222222222222222222222222); // default operator
    address public admin = address(0x4444444444444444444444444444444444444444); // DAO OSX
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 2_000_000_000e18;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%

    // Router test variables
    AlchemistRouter router;
    address user;
    address underlying;
    address debtToken;
    address mytVault;
    AlchemistV3Position nft;
    uint256 constant AMOUNT = 1000e18;
    uint256 constant BORROW_AMOUNT = 100e18;

    struct CalculateLiquidationResult {
        uint256 liquidationAmountInYield;
        uint256 debtToBurn;
        uint256 outSourcedFee;
        uint256 baseFeeInYield;
    }

    struct AccountPosition {
        address user;
        uint256 collateral;
        uint256 debt;
        uint256 tokenId;
    }

    function setUp() external {
        adJustTestFunds(18);
        setUpMYT();
        deployCoreContracts(18);

        router = new AlchemistRouter(address(alchemist));
        user = makeAddr("user");
        underlying = address(vault.asset());
        debtToken = address(alToken);
        mytVault = address(vault);
        nft = alchemistNFT;
        transmuter = transmuterLogic;
    }

    function adJustTestFunds(uint256 alchemistUnderlyingTokenDecimals) public {
        accountFunds = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
        whaleSupply = 20_000_000_000 * 10 ** alchemistUnderlyingTokenDecimals;
        depositAmount = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
    }

    function setUpMYT() public {
        vm.startPrank(admin);
        mockVaultCollateral = address(new MockWETH());
        mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(
            address(vault),
            mockStrategyYieldToken,
            admin,
            "MockToken",
            "MockTokenProtocol",
            IMYTStrategy.RiskClass.LOW
        );
        allocator = new MockAlchemistAllocator(
            address(vault),
            admin,
            operator,
            address(new AlchemistStrategyClassifier(admin))
        );
        vm.stopPrank();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), _vault, amount);
        uint256 shares = IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function deployCoreContracts(uint256 alchemistUnderlyingTokenDecimals) public {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // AlchemistV3 proxy
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(vault.asset()),
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            liquidationTargetCollateralization: liquidationTargetCollateralization,
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: liquidatorFeeBPS,
            repaymentFee: repaymentFeeBPS,
            myt: address(vault)
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        transmuterLogic.setAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist), alOwner);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        alchemistFeeVault = new AlchemistTokenVault(address(vault.asset()), address(alchemist), alOwner);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));

        _magicDepositToVault(address(vault), address(0xbeef), accountFunds);
        _magicDepositToVault(address(vault), address(0xdad), accountFunds);
        _magicDepositToVault(address(vault), externalUser, accountFunds);
        _magicDepositToVault(address(vault), yetAnotherExternalUser, accountFunds);
        _magicDepositToVault(address(vault), anotherExternalUser, accountFunds);
        vm.stopPrank();

        vm.startPrank(address(admin));
        allocator.allocate(address(mytStrategy), vault.convertToAssets(vault.totalSupply()));
        vm.stopPrank();

        deal(address(alToken), address(0xdad), accountFunds);
        deal(address(alToken), address(anotherExternalUser), accountFunds);
        deal(address(vault.asset()), address(0xbeef), accountFunds);
        deal(address(vault.asset()), externalUser, accountFunds);
        deal(address(vault.asset()), yetAnotherExternalUser, accountFunds);
        deal(address(vault.asset()), anotherExternalUser, accountFunds);
        deal(address(vault.asset()), alchemist.alchemistFeeVault(), 10_000 * (10 ** alchemistUnderlyingTokenDecimals));

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();

        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();

        vm.startPrank(someWhale);
        deal(address(vault), someWhale, whaleSupply);
        deal(address(vault.asset()), someWhale, whaleSupply);
        SafeERC20.safeApprove(address(vault.asset()), address(mockStrategyYieldToken), whaleSupply);
        vm.stopPrank();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositUnderlying — new position
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositUnderlying_newPosition() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositUnderlying_withBorrow() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETH — new position
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETH_newPosition() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositETH_withBorrow() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositUnderlyingToExisting
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositUnderlyingToExisting() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        router.depositUnderlying(tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositUnderlyingToExisting_withBorrow() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);

        router.depositUnderlying(tokenId, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETHToExisting
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETHToExisting() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());

        router.depositETH{value: AMOUNT}(tokenId, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositETHToExisting_withBorrow() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());

        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);

        router.depositETH{value: AMOUNT}(tokenId, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositMYT — new position
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositMYT_newPosition() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);

        IERC20(mytVault).approve(address(router), shares);
        uint256 tokenId = router.depositMYT(0, shares, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositMYT_withBorrow() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);

        IERC20(mytVault).approve(address(router), shares);
        uint256 tokenId = router.depositMYT(0, shares, BORROW_AMOUNT, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositMYTToExisting
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositMYTToExisting() public {
        deal(underlying, user, AMOUNT * 2);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);

        IERC20(mytVault).approve(address(router), shares);
        router.depositMYT(tokenId, shares, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositMYTToExisting_withBorrow() public {
        deal(underlying, user, AMOUNT * 2);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);

        IERC20(mytVault).approve(address(router), shares);
        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);

        router.depositMYT(tokenId, shares, BORROW_AMOUNT, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    function test_revert_depositMYTToExisting_notOwner() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        deal(underlying, attacker, AMOUNT);
        vm.startPrank(attacker);
        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, attacker);
        IERC20(mytVault).approve(address(router), shares);

        vm.expectRevert("Not position owner");
        router.depositMYT(tokenId, shares, 0, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETHToVaultOnly
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETHToVaultOnly() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 shares = router.depositETHToVaultOnly{value: AMOUNT}(0, _deadline());

        assertGt(shares, 0, "No shares returned");
        assertGt(IERC20(mytVault).balanceOf(user), 0, "User has no MYT shares");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reverts
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.depositUnderlying(0, AMOUNT, 0, 0, block.timestamp - 1);
    }

    function test_revert_depositETH_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETH{value: 0}(0, 0, 0, _deadline());
    }

    function test_revert_depositETHToExisting_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETH{value: 0}(1, 0, 0, _deadline());
    }

    function test_revert_depositETHToVaultOnly_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETHToVaultOnly{value: 0}(0, _deadline());
    }

    function test_revert_slippage() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        vm.expectRevert("Slippage");
        router.depositUnderlying(0, AMOUNT, 0, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_directETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert("Use depositETH");
        (bool s, ) = address(router).call{value: 1 ether}("");
        s;
    }

    function test_revert_depositToExisting_notOwner() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        deal(underlying, attacker, AMOUNT);
        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), AMOUNT);

        vm.expectRevert("Not position owner");
        router.depositUnderlying(tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Statelessness invariants
    // ═══════════════════════════════════════════════════════════════════════

    function test_routerIsEmptyAfterDeposit() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterETHDeposit() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterExistingDeposit() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        router.depositUnderlying(tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  No residual approvals
    // ═══════════════════════════════════════════════════════════════════════

    function test_noResidualApprovals() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying to MYT approval not cleared");
        assertEq(
            IERC20(mytVault).allowance(address(router), address(alchemist)),
            0,
            "MYT to Alchemist approval not cleared"
        );
    }

    function test_noResidualApprovals_existing() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        router.depositUnderlying(tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying to MYT approval not cleared");
        assertEq(
            IERC20(mytVault).allowance(address(router), address(alchemist)),
            0,
            "MYT to Alchemist approval not cleared"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  repayUnderlying
    // ═══════════════════════════════════════════════════════════════════════

    function test_repayUnderlying() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());

        uint256 debtBefore = IERC20(debtToken).balanceOf(user);
        assertGe(debtBefore, BORROW_AMOUNT, "No debt tokens minted");

        vm.roll(block.number + 1);

        router.repayUnderlying(tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Approval not cleared");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT approval not cleared");
    }

    function test_repayUnderlying_overpayReturnsShares() public {
        uint256 smallBorrow = 10 ether;
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, smallBorrow, 0, _deadline());

        uint256 mytBefore = IERC20(mytVault).balanceOf(user);

        vm.roll(block.number + 1);

        router.repayUnderlying(tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        uint256 mytAfter = IERC20(mytVault).balanceOf(user);
        assertGt(mytAfter, mytBefore, "No MYT shares returned from overpay");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck in router");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  repayETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_repayETH() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);

        router.repayETH{value: AMOUNT}(tokenId, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_repayETH_overpayReturnsShares() public {
        uint256 smallBorrow = 10 ether;
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, smallBorrow, 0, _deadline());

        uint256 mytBefore = IERC20(mytVault).balanceOf(user);

        vm.roll(block.number + 1);

        router.repayETH{value: AMOUNT}(tokenId, 0, _deadline());
        vm.stopPrank();

        uint256 mytAfter = IERC20(mytVault).balanceOf(user);
        assertGt(mytAfter, mytBefore, "No MYT shares returned from overpay");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck in router");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claimRedemptionUnderlying
    // ═══════════════════════════════════════════════════════════════════════

    function _createTransmuterPosition(uint256 debtAmount) internal returns (uint256 positionId) {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.depositUnderlying(0, AMOUNT, debtAmount, 0, _deadline());

        IERC20(debtToken).approve(address(transmuter), debtAmount);
        transmuter.createRedemption(debtAmount, user);

        uint256 bal = IERC721(address(transmuter)).balanceOf(user);
        positionId = IAlchemistV3Position(address(transmuter)).tokenOfOwnerByIndex(user, bal - 1);
        vm.stopPrank();
    }

    function test_claimRedemptionUnderlying() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);

        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        uint256 underlyingBefore = IERC20(underlying).balanceOf(user);

        vm.startPrank(user);
        IERC721(address(transmuter)).approve(address(router), positionId);
        router.claimRedemption(positionId, 0, _deadline(), false);
        vm.stopPrank();

        assertGt(IERC20(underlying).balanceOf(user), underlyingBefore, "No underlying received");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(debtToken).balanceOf(address(router)), 0, "Synth stuck");
    }

    function test_claimRedemptionUnderlying_partialMaturation() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);

        vm.roll(block.number + transmuter.timeToTransmute() / 2);

        uint256 underlyingBefore = IERC20(underlying).balanceOf(user);
        uint256 synthBefore = IERC20(debtToken).balanceOf(user);

        vm.startPrank(user);
        IERC721(address(transmuter)).approve(address(router), positionId);
        router.claimRedemption(positionId, 0, _deadline(), false);
        vm.stopPrank();

        assertGt(IERC20(underlying).balanceOf(user), underlyingBefore, "No underlying received");
        assertGt(IERC20(debtToken).balanceOf(user), synthBefore, "No synth returned");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(debtToken).balanceOf(address(router)), 0, "Synth stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claimRedemptionETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimRedemptionETH() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        IERC20(debtToken).approve(address(transmuter), BORROW_AMOUNT);
        transmuter.createRedemption(BORROW_AMOUNT, ethUser);

        uint256 bal = IERC721(address(transmuter)).balanceOf(ethUser);
        uint256 positionId = IAlchemistV3Position(address(transmuter)).tokenOfOwnerByIndex(ethUser, bal - 1);
        vm.stopPrank();

        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        uint256 ethBefore = ethUser.balance;

        vm.startPrank(ethUser);
        IERC721(address(transmuter)).approve(address(router), positionId);
        router.claimRedemption(positionId, 0, _deadline(), true);
        vm.stopPrank();

        assertGt(ethUser.balance, ethBefore, "No ETH received");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(debtToken).balanceOf(address(router)), 0, "Synth stuck");
        assertEq(address(router).balance, 0, "ETH stuck in router");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  selfLiquidate
    // ═══════════════════════════════════════════════════════════════════════

    function test_selfLiquidateUnderlying() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());

        (uint256 collateralBefore, uint256 debtBefore,) = alchemist.getCDP(tokenId);
        uint256 expectedSharesOut = collateralBefore - alchemist.convertDebtTokensToYield(debtBefore);
        uint256 expectedUnderlyingOut = IVaultV2(mytVault).previewRedeem(expectedSharesOut);
        uint256 underlyingBefore = IERC20(underlying).balanceOf(user);

        IERC721(address(nft)).approve(address(router), tokenId);
        router.selfLiquidateToUnderlying(tokenId, 0, _deadline());
        vm.stopPrank();

        (uint256 collateralAfter, uint256 debtAfter, uint256 earmarkedAfter) = alchemist.getCDP(tokenId);
        assertEq(collateralAfter, 0, "Collateral should be fully cleared");
        assertEq(debtAfter, 0, "Debt should be fully cleared");
        assertEq(earmarkedAfter, 0, "Earmarked debt should be fully cleared");
        assertEq(nft.ownerOf(tokenId), user, "NFT should be returned to the owner");
        assertApproxEqAbs(
            IERC20(underlying).balanceOf(user) - underlyingBefore,
            expectedUnderlyingOut,
            1,
            "Unexpected underlying returned"
        );
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
    }

    function test_selfLiquidateETH() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());
        uint256 ethBefore = ethUser.balance;

        IERC721(address(nft)).approve(address(router), tokenId);
        router.selfLiquidateToETH(tokenId, 0, _deadline());
        vm.stopPrank();

        (uint256 collateralAfter, uint256 debtAfter, uint256 earmarkedAfter) = alchemist.getCDP(tokenId);
        assertEq(collateralAfter, 0, "Collateral should be fully cleared");
        assertEq(debtAfter, 0, "Debt should be fully cleared");
        assertEq(earmarkedAfter, 0, "Earmarked debt should be fully cleared");
        assertEq(nft.ownerOf(tokenId), ethUser, "NFT should be returned to the owner");
        assertGt(ethUser.balance, ethBefore, "No ETH returned");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_revert_selfLiquidateUnderlying_notOwner() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        IERC721(address(nft)).approve(address(router), tokenId);
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(bytes("Not position owner"));
        router.selfLiquidateToUnderlying(tokenId, 0, _deadline());
        vm.stopPrank();
    }

    function test_revert_selfLiquidateUnderlying_slippage() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        IERC721(address(nft)).approve(address(router), tokenId);

        vm.expectRevert(bytes("Slippage"));
        router.selfLiquidateToUnderlying(tokenId, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_selfLiquidateUnderlying_noDebt() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        IERC721(address(nft)).approve(address(router), tokenId);
        vm.expectRevert();
        router.selfLiquidateToUnderlying(tokenId, 0, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: mintFrom allowance theft prevention
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_mintFromTheft_underlying() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 victimTokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        alchemist.approveMint(victimTokenId, address(router), BORROW_AMOUNT);
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        deal(underlying, attacker, 1 ether);
        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), 1 ether);

        vm.expectRevert("Not position owner");
        router.depositUnderlying(victimTokenId, 1 ether, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();
    }

    function test_revert_mintFromTheft_ETH() public {
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 victimTokenId = router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());
        alchemist.approveMint(victimTokenId, address(router), BORROW_AMOUNT);
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);

        vm.expectRevert("Not position owner");
        router.depositETH{value: 1 ether}(victimTokenId, BORROW_AMOUNT, 0, _deadline());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: zero amount checks
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_depositUnderlying_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.depositUnderlying(0, 0, 0, 0, _deadline());
    }

    function test_revert_depositUnderlyingToExisting_zeroAmount() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.depositUnderlying(tokenId, 0, 0, 0, _deadline());
    }

    function test_revert_repayUnderlying_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.repayUnderlying(1, 0, 0, _deadline());
    }

    function test_revert_withdrawUnderlying_zeroShares() public {
        vm.prank(user);
        vm.expectRevert("Zero shares");
        router.withdrawUnderlying(1, 0, 0, _deadline());
    }

    function test_revert_withdrawETH_zeroShares() public {
        vm.prank(user);
        vm.expectRevert("Zero shares");
        router.withdrawETH(1, 0, 0, _deadline());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  withdrawUnderlying
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawUnderlying() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        (uint256 collateral, , ) = alchemist.getCDP(tokenId);
        uint256 underlyingBefore = IERC20(underlying).balanceOf(user);

        nft.approve(address(router), tokenId);

        router.withdrawUnderlying(tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        uint256 underlyingAfter = IERC20(underlying).balanceOf(user);
        assertGt(underlyingAfter, underlyingBefore, "No underlying received");
        assertEq(nft.ownerOf(tokenId), user, "NFT not returned");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  withdrawETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawETH() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, 0, 0, _deadline());
        (uint256 collateral, , ) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        vm.stopPrank();

        uint256 ethBefore = ethUser.balance;

        vm.prank(ethUser);
        router.withdrawETH(tokenId, collateral, 0, _deadline());

        assertGt(ethUser.balance, ethBefore, "No ETH received");
        assertEq(nft.ownerOf(tokenId), ethUser, "NFT not returned");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(address(router).balance, 0, "ETH stuck in router");
    }

    function test_routerIsEmptyAfterWithdraw() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        (uint256 collateral, , ) = alchemist.getCDP(tokenId);

        nft.approve(address(router), tokenId);
        router.withdrawUnderlying(tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: withdraw by non-owner reverts
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_withdrawUnderlying_notOwner() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        router.withdrawUnderlying(tokenId, 1, 0, _deadline());
    }

    function test_noResidualApprovals_withdraw() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        (uint256 collateral, , ) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        router.withdrawUnderlying(tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying->MYT approval");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT->Alchemist approval");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: claimRedemption by non-owner reverts
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_claimRedemptionUnderlying_notOwner() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);
        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        router.claimRedemption(positionId, 0, _deadline(), false);
    }

    function test_revert_claimRedemptionETH_notOwner() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);
        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        router.claimRedemption(positionId, 0, _deadline(), true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: no residual approvals after repay
    // ═══════════════════════════════════════════════════════════════════════

    function test_noResidualApprovals_repay() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayUnderlying(tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying->MYT approval");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT->Alchemist approval");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: router statelessness after every flow
    // ═══════════════════════════════════════════════════════════════════════

    function test_routerIsEmptyAfterRepay() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayUnderlying(tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterRepayETH() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayETH{value: AMOUNT}(tokenId, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterClaimRedemption() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);
        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        vm.startPrank(user);
        IERC721(address(transmuter)).approve(address(router), positionId);
        router.claimRedemption(positionId, 0, _deadline(), false);
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(debtToken).balanceOf(address(router)), 0, "Synth stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: deadline enforcement on all functions
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_repayUnderlying_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.repayUnderlying(1, AMOUNT, 0, block.timestamp - 1);
    }

    function test_revert_repayETH_expired() public {
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vm.expectRevert("Expired");
        router.repayETH{value: AMOUNT}(1, 0, block.timestamp - 1);
    }

    function test_revert_claimRedemptionUnderlying_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.claimRedemption(1, 0, block.timestamp - 1, false);
    }

    function test_revert_claimRedemptionETH_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.claimRedemption(1, 0, block.timestamp - 1, true);
    }

    function test_revert_depositETHToVaultOnly_expired() public {
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vm.expectRevert("Expired");
        router.depositETHToVaultOnly{value: AMOUNT}(0, block.timestamp - 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: slippage on claimRedemption
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_claimRedemptionUnderlying_slippage() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);
        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        vm.startPrank(user);
        IERC721(address(transmuter)).approve(address(router), positionId);

        vm.expectRevert("Slippage");
        router.claimRedemption(positionId, type(uint256).max, _deadline(), false);
        vm.stopPrank();
    }

    function test_revert_claimRedemptionETH_slippage() public {
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        IERC20(debtToken).approve(address(transmuter), BORROW_AMOUNT);
        transmuter.createRedemption(BORROW_AMOUNT, user);

        uint256 bal = IERC721(address(transmuter)).balanceOf(user);
        uint256 positionId = IAlchemistV3Position(address(transmuter)).tokenOfOwnerByIndex(user, bal - 1);
        vm.stopPrank();

        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        vm.startPrank(user);
        IERC721(address(transmuter)).approve(address(router), positionId);

        vm.expectRevert("Slippage");
        router.claimRedemption(positionId, type(uint256).max, _deadline(), true);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: slippage on repay vault deposit
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_repayUnderlying_slippage() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);

        vm.expectRevert("Slippage");
        router.repayUnderlying(tokenId, AMOUNT, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_repayETH_slippage() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(0, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);

        vm.expectRevert("Slippage");
        router.repayETH{value: AMOUNT}(tokenId, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Statelessness: MYT deposit routes
    // ═══════════════════════════════════════════════════════════════════════

    function test_routerIsEmptyAfterDepositMYT() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);
        IERC20(mytVault).approve(address(router), shares);
        router.depositMYT(0, shares, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
    }

    function test_routerIsEmptyAfterDepositMYTToExisting() public {
        deal(underlying, user, AMOUNT * 2);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        IERC20(underlying).approve(mytVault, AMOUNT);
        uint256 shares = IVaultV2(mytVault).deposit(AMOUNT, user);
        IERC20(mytVault).approve(address(router), shares);
        router.depositMYT(tokenId, shares, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT->Alchemist approval");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Attack scenarios
    // ═══════════════════════════════════════════════════════════════════════

    function test_attack_borrowFromVictimPosition_MYT() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 victimTokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        alchemist.approveMint(victimTokenId, address(router), BORROW_AMOUNT);
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        deal(underlying, attacker, 1 ether);
        vm.startPrank(attacker);
        IERC20(underlying).approve(mytVault, 1 ether);
        uint256 shares = IVaultV2(mytVault).deposit(1 ether, attacker);
        IERC20(mytVault).approve(address(router), shares);

        vm.expectRevert("Not position owner");
        router.depositMYT(victimTokenId, shares, BORROW_AMOUNT, _deadline());
        vm.stopPrank();
    }

    function test_attack_claimRedemption_victimPosition() public {
        uint256 positionId = _createTransmuterPosition(BORROW_AMOUNT);
        vm.roll(block.number + transmuter.timeToTransmute() + 1);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        router.claimRedemption(positionId, 0, _deadline(), false);
    }

    function test_attack_frontRunDeposit_nftGoesToCaller() public {
        deal(underlying, user, AMOUNT);
        address attacker = makeAddr("attacker");
        deal(underlying, attacker, AMOUNT);

        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 attackerTokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 userTokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(attackerTokenId), attacker, "Attacker doesn't own their NFT");
        assertEq(nft.ownerOf(userTokenId), user, "User doesn't own their NFT");
        assertTrue(attackerTokenId != userTokenId, "Same token ID");
    }

    function test_attack_directETHSend() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success, ) = address(router).call{value: 1 ether}("");
        assertFalse(success, "Direct ETH should be rejected");
    }

    function test_attack_sendNFTToRouter() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(0, AMOUNT, 0, 0, _deadline());

        vm.expectRevert();
        nft.safeTransferFrom(user, address(router), tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT ownership changed");
    }

    function test_attack_repayOtherPosition_usesAttackerFunds() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 userTokenId = router.depositUnderlying(0, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        vm.roll(block.number + 1);

        address attacker = makeAddr("attacker");
        deal(underlying, attacker, AMOUNT);
        uint256 attackerBalBefore = IERC20(underlying).balanceOf(attacker);

        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.repayUnderlying(userTokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        uint256 attackerBalAfter = IERC20(underlying).balanceOf(attacker);
        assertLt(attackerBalAfter, attackerBalBefore, "Attacker didn't spend funds");
        assertEq(nft.ownerOf(userTokenId), user, "User lost NFT");
    }
}
