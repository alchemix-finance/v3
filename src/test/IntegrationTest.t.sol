// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import "lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "./mocks/AlchemicTokenV3.sol";
import {EulerUSDCAdapter} from "../adapters/EulerUSDCAdapter.sol";
import {Transmuter} from "../Transmuter.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {IAlchemicToken} from "../interfaces/IAlchemicToken.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../AlchemistV3PositionRenderer.sol";
import {AlchemistETHVault} from "../AlchemistETHVault.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {MockAlchemistAllocator} from "./mocks/MockAlchemistAllocator.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";

// Tests for integration with Euler V2 Earn Vault
contract IntegrationTest is Test {
    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address ETH_USD_PRICE_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;
    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = FIXED_POINT_SCALAR;
    // Fee receiver
    address receiver = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    address alUSD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;

    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address EULER_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // another random EOA for testing
    address yetAnotherExternalUser = address(0x520aB24368e5Ba8B727E9b8aB967073Ff9316961);


    // MYT variables
    VaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;
    address public operator = address(20); // default operator
    address public admin = address(21); // DAO OSX
    address public curator = address(22);
    address public mockVaultCollateral;
    address public mockStrategyYieldToken;
    uint256 public defaultStrategyAbsoluteCap = 2_000_000_000e18;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%

    event TestIntegrationLog(string message, uint256 value);

    function setUp() external {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc);
        vm.selectFork(forkId);

        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        setUpMYT(6); // 6 decimals for USDC underlying token
        addDepositsToMYT();

        vm.startPrank(caller);

        /*         deal(EULER_USDC, address(0xbeef), 100_000e18);
        deal(EULER_USDC, address(0xdad), 100_000e18); */
        deal(alUSD, address(0xdad), 100_000e18);
        deal(alUSD, address(0xdead), 100_000e18);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alUSD,
            feeReceiver: receiver,
            timeToTransmute: 5_256_000,
            transmutationFee: 100,
            exitFee: 200,
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
            debtToken: alUSD,
            underlyingToken: USDC,
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            liquidationTargetCollateralization: uint256(1e36) / 88e16, // ~113.63% (88% LTV)
            transmuter: address(transmuterLogic),
            protocolFee: 100,
            protocolFeeReceiver: receiver,
            liquidatorFee: 300, // in bps? 3%
            repaymentFee: 100,
            myt: address(vault),
            debtReferenceToken: USDC,
            collateralPriceOracle: address(0)
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        transmuterLogic.setDepositCap(uint256(type(int256).max));

        transmuterLogic.setAlchemist(address(alchemist));

        alchemistNFT = new AlchemistV3Position(address(alchemist), alOwner);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        vm.stopPrank();

        vm.startPrank(0x8392F6669292fA56123F71949B52d883aE57e225);
        IAlchemicToken(alUSD).setWhitelist(address(alchemist), true);
        IAlchemicToken(alUSD).setCeiling(address(alchemist), type(uint256).max);
        vm.stopPrank();
    }

    function setUpMYT(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(admin);
        uint256 TOKEN_AMOUNT = 1_000_000; // Base token amount
        uint256 initialSupply = TOKEN_AMOUNT * 10 ** alchemistUnderlyingTokenDecimals;
        mockVaultCollateral = USDC;
        mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW);
        allocator = new MockAlchemistAllocator(address(vault), admin, operator, address(new AlchemistStrategyClassifier(admin)));
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

    function addDepositsToMYT() public {
        uint256 shares = _magicDepositToVault(address(vault), address(0xbeef), 1_000_000e6);
        emit TestIntegrationLog("0xbeef shares", shares);
        shares = _magicDepositToVault(address(vault), address(0xdad), 1_000_000e6);
        emit TestIntegrationLog("0xdad shares", shares);

        // then allocate to the strategy
        vm.startPrank(address(admin));
        allocator.allocate(address(mytStrategy), vault.convertToAssets(vault.totalSupply()));
        vm.stopPrank();
    }

    function _magicDepositToVault(address vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(USDC, address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(USDC, vault, amount);
        uint256 shares = IVaultV2(vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function testRoundTrip() external {
        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e18);
        assertEq(IERC20(address(vault)).balanceOf(address(alchemist)), 100_000e18);

        alchemist.withdraw(100_000e18, address(0xbeef), tokenId);
        vm.stopPrank();

        (collateral,,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 0);
        assertEq(IERC20(address(vault)).balanceOf(address(0xbeef)), 1_000_000e18);
    }

    function testMint() external {
        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, alchemist.getMaxBorrowable(tokenId), address(0xbeef));
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e18);
        assertEq(debt, alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111);
        vm.stopPrank();
    }

    function testRepay() external {
        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);

        vm.roll(block.number + 1);

        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        assertEq(collateral, 100_000e18);
        assertEq(IERC20(address(vault)).balanceOf(receiver), 0);
    }
    // ├─ emit TestIntegrationLog(message: "0xdad shares", value: 100000000000000000000000 [1e23])

    function testRepayEarmarkedFull() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertEq(collateral, 100_000e18);
        assertApproxEqAbs(earmarked, maxBorrow, 1);

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        assertEq(collateral, 100_000e18 - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10_000);
        assertApproxEqAbs(earmarked, 0, 9201);
        assertApproxEqAbs(IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow), 1);
        assertEq(IERC20(address(vault)).balanceOf(receiver), alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10_000);
    }

    function testRepayEarmarkedPartialEarmarked() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertApproxEqAbs(collateral, 100_000e18, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        uint256 expectedProtocolFee = alchemist.convertDebtTokensToYield(maxBorrow / 2) * 100 / 10_000;
        assertApproxEqAbs(collateral, 100_000e18 - expectedProtocolFee, 1);
        assertApproxEqAbs(earmarked, 0, 9201);

        assertApproxEqAbs(IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow), 1);
        assertEq(IERC20(address(vault)).balanceOf(receiver), expectedProtocolFee);
    }

    function testRepayEarmarkedPartialRepayment() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertApproxEqAbs(collateral, 100_000e18, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow) / 2, tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, (maxBorrow / 2), 9201);
        assertApproxEqAbs(collateral, 100_000e18 - (alchemist.convertDebtTokensToYield(maxBorrow) / 2) * 100 / 10_000, 1);
        assertApproxEqAbs(earmarked, 0, 9201);

        assertApproxEqAbs(IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow) / 2, 1);
        assertEq(IERC20(address(vault)).balanceOf(receiver), (alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10_000) / 2);
    }

    function testRepayEarmarkedOverRepayment() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertApproxEqAbs(collateral, 100_000e18, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        uint256 beefStartingBalance = IERC20(alchemist.myt()).balanceOf(address(0xbeef));

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow) * 2, tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        uint256 beefEndBalance = IERC20(alchemist.myt()).balanceOf(address(0xbeef));

        // Loss of precision. Small, but consider using LTV rather than minimum collateralization
        assertApproxEqAbs(debt, 0, 1);
        uint256 expectedProtocolFee = alchemist.convertDebtTokensToYield(maxBorrow / 2) * 100 / 10_000;
        assertEq(collateral, 100_000e18 - expectedProtocolFee);
        assertApproxEqAbs(earmarked, 0, 9201);

        // Overpayment sent back to user and transmuter received what was credited
        // uint256 amountSpent = maxBorrow / 2;
        // assertApproxEqAbs(beefStartingBalance - beefEndBalance, alchemist.convertDebtTokensToYield(amountSpent), 1);
        // assertApproxEqAbs(IERC20(alchemist.yieldToken()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(amountSpent), 1);
    }

    function test_target_Burn() external {
        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);

        vm.roll(block.number + 1);

        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        assertEq(debt, 0);
        assertEq(collateral, 100_000e18);
        assertEq(IERC20(address(vault)).balanceOf(receiver), 0);
    }

    function testBurnWithEarmarkPartial() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xdad), 0);
        // a single position nft would have been minted to address(0xdad)
        uint256 tokenId2 = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        uint256 maxBorrow2 = alchemist.getMaxBorrowable(tokenId2);
        alchemist.mint(tokenId2, maxBorrow2, address(0xdad));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        vm.startPrank(address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);
        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        // Make sure only unEarmarked debt is repaid
        assertApproxEqAbs(debt, maxBorrow / 4, 2);
        // assertEq(collateral, 100_000e18);

        // // Make sure 0xbeef get remaining tokens back
        // // Overpayment goes towards fees accrued as well
        // assertApproxEqAbs(IERC20(alUSD).balanceOf(address(0xbeef)), maxBorrow / 4 - (debtAmount * 5_256_000 / 2_600_000 * 100 / 10_000) / 2, 1);
    }

    function testBurnFullyEarmarked() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        vm.startPrank(address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);
        vm.expectRevert();
        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();
    }

    function testPositionToFullMaturity() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e18) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, alchemist.getMaxBorrowable(tokenId), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, address(0xdad));
        vm.stopPrank();

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e18);
        assertEq(debt, debtAmount);

        // Transmuter Cycle
        vm.roll(block.number + 5_256_000);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        // 9% remaining since 90% was borrowed against initially + fee
        assertApproxEqAbs(collateral, 100_000e18 - alchemist.convertDebtTokensToYield(debtAmount) - (alchemist.convertDebtTokensToYield(debtAmount) * 100 / 10_000), 1);

        // Only remaining debt should be from the fees paid on debt
        assertApproxEqAbs(debt, 0, 1);

        assertEq(earmarked, 0);
    }

    function testAudit_Sync_IncorrectEarmarkWeightUpdate() external {
        uint256 bn = block.number;
        // 1. Add collateral and mints 10,000 alUSD as debt
        vm.startPrank(address(0xbeef));
        IERC20(address(vault)).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, 10_000e18, address(0xbeef));
        vm.stopPrank();
        // 2. Create a redemption for 1,000 alUSD
        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), 1000e18);
        transmuterLogic.createRedemption(1000e18, address(0xdad));
        vm.stopPrank();
        vm.roll(bn += 5_256_000);
        // 3. Claim redemption
        vm.prank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.roll(bn += 1);
        // 4. Update debt and earmark
        vm.prank(address(0xbeef));
        alchemist.poke(tokenId);
        (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        assertEq(debt, 10_000e18 - 1000e18); // 10,000 - 1,000
        assertEq(earmarked, 0);
        // 5. Create another redemption for 1,000 alUSD
        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), 1000e18);
        transmuterLogic.createRedemption(1000e18, address(0xdad));
        vm.stopPrank();
        vm.roll(bn += 5_256_000);
        // 6. Update debt and earmark
        vm.prank(address(0xbeef));
        alchemist.poke(tokenId);
        // 7. Create another redemption for 1,000 alUSD
        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), 1000e18);
        transmuterLogic.createRedemption(1000e18, address(0xdad));
        vm.stopPrank();
        vm.roll(bn += 5_256_000);
        // 8. Update debt and earmark
        vm.prank(address(0xbeef));
        alchemist.poke(tokenId);
    }

    function ClaimResdemptionTransmuter(address user) internal {
        vm.startPrank(user);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(transmuterLogic));
        transmuterLogic.claimRedemption(tokenId);
        vm.stopPrank();

    }

    function depositToAlchemix(uint256 shares, address user) internal {
        vm.startPrank(user);
        IERC20(address(vault)).approve(address(alchemist),shares);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
        alchemist.deposit(shares,user, tokenId);

        vm.stopPrank();
    }

    function MintOnAlchemix(uint256 toMint, address user) internal {
        vm.startPrank(user);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
        assertGt(tokenId,0,"cannot mint to user with no positions");
        alchemist.mint(tokenId, toMint, user);
        vm.stopPrank();
    }

    function RedeemOnTransmuter(address user, uint256 debtAmount) internal {
        vm.startPrank(user);

        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount, user);

        vm.stopPrank();

    }

    function moveTime(uint256 blocks) internal {
        vm.warp(block.timestamp+blocks*12);
        vm.roll(block.number+blocks);
    }

    function printState(address user, string memory message) internal {
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
        //poke to refresh _earmark and sync
        alchemist.poke(tokenId);
        uint256 totalDebt = alchemist.totalDebt();
        uint256 synthIssued = alchemist.totalSyntheticsIssued();
        uint256 transmuterCollBalance = IERC20(address(alchemist.myt())).balanceOf(address(transmuterLogic));
        uint256 transmuterDebtCoverage = alchemist.convertYieldTokensToDebt(transmuterCollBalance);
        uint256 transmuterLocked = transmuterLogic.totalLocked();

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        uint256 alchemistCollBalance = IERC20(address(alchemist.myt())).balanceOf(address(alchemist));
        uint256 alchemistCollInDebt = alchemist.convertYieldTokensToDebt(alchemistCollBalance);
        console.log("%s",message);
        console.log("Alchemist Total Debt: %s",totalDebt/1e18);
        console.log("Alchemist cumulative earmarked: %s", alchemist.cumulativeEarmarked() / 1e18);
        console.log("Alchemist getTotalUnderlyingValue (_mytSharesDeposited value in debt tokens)", alchemist.getTotalUnderlyingValue()/1e6);
        console.log("Alchemist Actual Collateral balance value in debt tokens", alchemistCollInDebt / 1e18);
        console.log("Transmuter Debt Coverage (collateral balance value in debt tokens): %s",transmuterDebtCoverage/1e18);
        console.log("Transmuter Locked Synthetic tokens: %s",transmuterLocked/1e18);
        console.log("Total Synthetic token Issuance: %s",synthIssued/1e18);

        console.log("CDP info - collateral: %s, debt %s, earmarked %s\n\n", collateral/1e18, debt/1e18, earmarked/1e18);

    }

    function testEarmarkTransmuterIncreasePOC() public {
        address bob = makeAddr("bob");
        address redeemer1 = makeAddr("redeemer1");


        //deposit 300 underlying to vault
        uint256 sharesBob = _magicDepositToVault(address(vault), bob, 300e6);

        //deposit 115 vault shares to alchemix
        uint256 depositedCollateral = 115e18;
        depositToAlchemix(depositedCollateral, bob);

        //mint a debt of 100
        uint256 mintAmount = 100e18;
        MintOnAlchemix(mintAmount,bob);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(bob, address(alchemistNFT));

        //transfer 50 to redeemer
        vm.startPrank(bob);
        IERC20(alUSD).transfer(redeemer1, mintAmount /2);
        vm.stopPrank();

        //donation of 50 coll tokens to Transmuter
        vm.startPrank(bob);
        vault.transfer(address(transmuterLogic), 50e18);
        vm.stopPrank();

        // make sure _earmark can run in a new block
        vm.roll(block.number + 1);

        // IMPORTANT: force Alchemist to observe the cover *before* the redemption exists
        alchemist.poke(tokenId);

        //create, vest and redeem
        RedeemOnTransmuter(redeemer1, mintAmount / 2);
        moveTime(transmuterLogic.timeToTransmute());
        ClaimResdemptionTransmuter(redeemer1);

        printState(bob,"System final state");
    }

    function testVulnerability_Repay_PrecisionLoss_LocksCollateral_FullTrigger() external {
        // 1. ARRANGE: Ensure we are in a 6-decimal underlying token environment
        require(TokenUtils.expectDecimals(alchemist.underlyingToken()) == 6, "Test setup failed: Underlying token is not 6 decimals");
        require(TokenUtils.expectDecimals(alchemist.debtToken()) == 18, "Test setup failed: Debt token is not 18 decimals");

        // Participants:
        address userA_victim = yetAnotherExternalUser; // The victim whose funds will be locked
        address userB_burner = anotherExternalUser;    // The burner who sets the trap
        address userC_global = address(0xbeef);      // Another user to ensure global state is redeemable

        deal(address(vault), yetAnotherExternalUser,  100_000e18);
        deal(address(vault), anotherExternalUser,  100_000e18);
        // 2. ARRANGE: Set up the scenario
        // User A (Victim) deposits and mints
        vm.startPrank(userA_victim);
        uint256 depositAmountA = 100_000e18; // 100,000 MYT
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmountA);
        alchemist.deposit(depositAmountA, userA_victim, 0); // tokenId 1
        uint256 tokenId_A = AlchemistNFTHelper.getFirstTokenId(userA_victim, address(alchemistNFT));
        uint256 debtToMintA = 50_000e18; // 50,000 alToken
        alchemist.mint(tokenId_A, debtToMintA, userB_burner); // Send the debtToken to User B
        vm.stopPrank();

        // User C (Global participant) deposits, mints, and *repays* to fund the Transmuter
        vm.startPrank(userC_global);
        uint256 depositAmountC = 100_000e18; // 100,000 MYT
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmountC);
        alchemist.deposit(depositAmountC, userC_global, 0); // tokenId 2
        uint256 tokenId_C = AlchemistNFTHelper.getFirstTokenId(userC_global, address(alchemistNFT));
        uint256 debtToMintC = 50_000e18; // 50,000 alToken
        alchemist.mint(tokenId_C, debtToMintC, userC_global);
        
        uint256 repayAmountC = 10_000e18; // 10,000 MYT
        SafeERC20.safeApprove(address(vault), address(alchemist), repayAmountC);
        
        // We must advance one block to avoid the `CannotRepayOnMintBlock` check on `repay`
        vm.roll(block.number + 1);
        
        alchemist.repay(repayAmountC, tokenId_C);
        vm.stopPrank();

        // [FIX]: 
        // 2.5 ARRANGE: 
        // The `repay` call sent 1e22 (repayAmountC) of MYT to the transmuter.
        // We must simulate the transmuter calling setTransmuterTokenBalance
        // to update Alchemist's `lastTransmuterTokenBalance` accounting.
        // Otherwise, this 1e22 MYT will be counted as "cover" during `_earmark`
        // and offset our simulated yield.
        vm.startPrank(address(transmuterLogic));
        alchemist.setTransmuterTokenBalance(repayAmountC);
        vm.stopPrank();

        // 3. ARRANGE: Calculate the `amountToBurn` needed to trigger the vulnerability
        uint256 conversionFactor = 10**(TokenUtils.expectDecimals(alchemist.debtToken()) - TokenUtils.expectDecimals(alchemist.underlyingToken()));
        uint256 amountToBurn = conversionFactor - 1; // Key: amount is less than the conversion factor

        // 4. ARRANGE: Warp time forward significantly
        vm.roll(block.number + 5_256_000 / 2); // Warp forward half a year

        // 4.5 ARRANGE: Simulate Transmuter yield generation
        // Explanation: This is a valid prerequisite for testing the AlchemistV3 vulnerability.
        uint256 simulatedYieldInDebt = 10_000e18; // Simulate 10,000 alToken of yield

        // Mock *any* call to the `queryGraph(uint256,uint256)` function
        vm.mockCall(
            address(transmuterLogic),
            abi.encodeWithSelector(ITransmuter.queryGraph.selector, 0, 0), // Match any arguments
            abi.encode(simulatedYieldInDebt) // The mocked return value
        );
        // Clear previous mocks, just keep this one
        vm.clearMockedCalls(); 
        vm.mockCall(
            address(transmuterLogic),
            abi.encodeWithSelector(ITransmuter.queryGraph.selector), // Match selector with no args (just in case)
            abi.encode(simulatedYieldInDebt)
        );
        // **The most critical mock rule**:
        // AlchemistV3 calls `queryGraph` with arguments
        vm.mockCall(
            address(transmuterLogic),
            abi.encodeWithSelector(
                ITransmuter.queryGraph.selector,
                block.number, // lastEarmarkBlock + 1
                block.number + 1  // block.number (inside burn)
            ),
            abi.encode(simulatedYieldInDebt)
        );
        // **Wildcard mock (most reliable)**
        vm.mockCall(
            address(transmuterLogic),
            bytes4(keccak256("queryGraph(uint256,uint256)")),
            abi.encode(simulatedYieldInDebt)
        );

        // 5. ACT: (Set the trap) User B burns a tiny amount of debt
        vm.startPrank(userB_burner);
        TokenUtils.safeApprove(alchemist.debtToken(), address(alchemist), amountToBurn);
        alchemist.burn(amountToBurn, tokenId_A); // This will call _earmark
        vm.stopPrank();

        // 6. ASSERT: (Verify the trap is set)
        (uint256 collateralBefore, uint256 debtAfterBurn,) = alchemist.getCDP(tokenId_A);
        assertEq(debtAfterBurn, debtToMintA - amountToBurn, "Debt was not reduced correctly after burn");
        
        // 7. ARRANGE: (Trigger global event) Transmuter executes redeem
        uint256 earmarked = alchemist.cumulativeEarmarked();
        
        // Assert Earmark was successful
        assertTrue(earmarked > 0, "Earmark failed, no funds to redeem. Transmuter did not generate yield.");

       (uint256 collBefore, uint256 debtBefore, ) = alchemist.getCDP(tokenId_A);

        uint256 totalDebtBeforeRedeem = alchemist.totalDebt();
        uint256 bps = 10_000;
        uint256 feeBps = alchemist.protocolFee();


        vm.startPrank(address(transmuterLogic));
        alchemist.redeem(earmarked);
        vm.stopPrank();

        (uint256 collAfter, uint256 debtAfter, ) = alchemist.getCDP(tokenId_A);

        // Basic sanity: redeem must change something
        assertLt(debtAfter, debtBefore, "Debt did not decrease after redeem (this would be suspicious)");
        assertLt(collAfter, collBefore, "Collateral did not decrease after redeem (unexpected for redemption)");

        // Actual deltas for the victim
        uint256 debtDelta = debtBefore - debtAfter;
        uint256 collDelta = collBefore - collAfter;

        // How much debt was actually redeemed globally (redeem() does: totalDebt -= amount)
        uint256 totalDebtAfterRedeem = alchemist.totalDebt();
        uint256 redeemedDebt = totalDebtBeforeRedeem - totalDebtAfterRedeem;

        // In this test, you pass `earmarked` and there is no clamp expected
        assertEq(redeemedDebt, earmarked, "Redeemed debt != earmarked (unexpected clamp/change)");

        // ---- Expected pro‑rata behavior checks ----

        // Victim should be debited collateral proportional to their debt forgiven, including protocol fee.
        // redeem() transfers out:
        //   collRedeemed  = convertDebtTokensToYield(redeemedDebt)
        //   feeCollateral = collRedeemed * protocolFee / BPS
        //   totalOut      = collRedeemed + feeCollateral
        uint256 collRedeemed = alchemist.convertDebtTokensToYield(redeemedDebt);
        uint256 totalOut = collRedeemed + (collRedeemed * feeBps) / bps;

        // In _sync(), per-account collateral debit is:
        // sharesToDebit = mulDivUp(redeemedTotal, globalSharesDelta, globalDebtDelta)
        // where globalSharesDelta == totalOut, globalDebtDelta == redeemedDebt,
        // and redeemedTotal == debtDelta (the victim’s debt reduction from redemption).
        uint256 expectedCollDelta = (debtDelta * totalOut + redeemedDebt - 1) / redeemedDebt; // mulDivUp

        assertEq(
            collDelta,
            expectedCollDelta,
            "Collateral delta does not match redemption accounting (principal + fee)"
        );

        // Optional but useful: debtDelta should be ~ pro‑rata share of redeemedDebt based on victim debt
        // (allow a tolerance of `conversionFactor` because of flooring to underlying units).
        uint256 expectedDebtDelta = (redeemedDebt * debtBefore) / totalDebtBeforeRedeem;
        uint256 tol = conversionFactor; // you already computed this above as 10^(debtDecimals-underlyingDecimals)
        assertApproxEqAbs(
            debtDelta,
            expectedDebtDelta,
            tol,
            "Debt delta is not roughly prorata to redeemed amount"
        );

        // Optional: equity loss should be ~ protocol fee only (not principal).
        // Equity (in debt units) = collateralValueInDebt - debt.
        // redemption reduces debt by debtDelta, and collateral by ~ (debtDelta + fee)
        uint256 valueBefore = alchemist.convertYieldTokensToDebt(collBefore);
        uint256 valueAfter  = alchemist.convertYieldTokensToDebt(collAfter);
        uint256 equityBefore = valueBefore - debtBefore;
        uint256 equityAfter  = valueAfter - debtAfter;

        uint256 equityLoss = equityBefore - equityAfter;
        uint256 expectedEquityLoss = (debtDelta * feeBps) / bps;
        assertApproxEqAbs(
            equityLoss,
            expectedEquityLoss,
            tol,
            "Equity loss not approximately equal to protocol fee"
        );
    }

    function test_claimRedemption_locked_POC() external {
        deal(alUSD, address(0xdad), 0);
        deal(alUSD, address(0xdead), 0);
        uint256 amount = 100e18;
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xdad), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xDad = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xDad, ((amount *1e18)/ alchemist.minimumCollateralization()), address(0xdad));

        SafeERC20.safeApprove(address(alUSD), address(transmuterLogic), alchemist.totalSyntheticsIssued());
        transmuterLogic.createRedemption(IERC20(alUSD).balanceOf(address(0xdad)), address(0xdad));
        vm.roll(block.number + transmuterLogic.timeToTransmute());
        alchemist.poke(tokenIdFor0xDad);
        uint256 stateBefore = vm.snapshotState();
        SafeERC20.safeTransfer(address(vault), address(transmuterLogic), 91e18);

        transmuterLogic.claimRedemption(1);
        // SafeERC20.safeTransfer(address(vault), address(transmuterLogic), 40e18);
        uint256 cumulativeEarmark_After_Claim_With_Transfer=alchemist.cumulativeEarmarked();
        uint256 totalDebt_After_Claim_With_Transfer=alchemist.totalDebt();
        uint256 totalSyntheticsIssued_After_Claim_With_Transfer=alchemist.totalSyntheticsIssued();
        vm.roll(block.number + 1);
        vm.expectRevert(IllegalArgument.selector);
        uint256 leave = 1e12; // smallest unit that becomes >=1 underlying “microunit” in convertToAssets
        alchemist.withdraw(9.1e18 - leave, address(0xdad), tokenIdFor0xDad);
        vm.revertTo(stateBefore);
        transmuterLogic.claimRedemption(1);
        uint256 cumulativeEarmark_After_Claim_Without_Transfer=alchemist.cumulativeEarmarked();
        uint256 totalDebt_After_Claim_Without_Transfer=alchemist.totalDebt();
        uint256 totalSyntheticsIssued_After_Claim_Without_Transfer=alchemist.totalSyntheticsIssued();

        assertEq(cumulativeEarmark_After_Claim_Without_Transfer,0);
        assertEq(totalDebt_After_Claim_Without_Transfer,0);
        assertLt(totalSyntheticsIssued_After_Claim_With_Transfer, 1e12);
        assertLt(totalSyntheticsIssued_After_Claim_Without_Transfer, 1e12);

        assertEq(cumulativeEarmark_After_Claim_With_Transfer,90000000000000000009);
        assertEq(totalDebt_After_Claim_With_Transfer,90000000000000000009);

        vm.roll(block.number + 1);
        alchemist.withdraw(9.1e18 - leave, address(0xdad), tokenIdFor0xDad);
        vm.stopPrank();
    }
}
