// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {Test, Vm} from "lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "./mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../AlchemistV3PositionRenderer.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";

import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MockAlchemistAllocator} from "./mocks/MockAlchemistAllocator.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";

contract InvariantsTest is Test {
    bytes4[] internal selectors;
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

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public protocolFee = 100;

    uint256 public liquidatorFeeBPS = 300; // in BPS, 3%

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

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
    VaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;
    address public operator = address(0x2222222222222222222222222222222222222222); // default operator
    address public admin = address(0x4444444444444444444444444444444444444444); // DAO OSX
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 2_000_000_000e18;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%

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

    function setUp() public virtual {
        adJustTestFunds(18);
        setUpMYT(18);
        deployCoreContracts(18);
    }

    function adJustTestFunds(uint256 alchemistUnderlyingTokenDecimals) public {
        accountFunds = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
        whaleSupply = 20_000_000_000 * 10 ** alchemistUnderlyingTokenDecimals;
        depositAmount = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
    }

    function setUpMYT(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(admin);
        uint256 TOKEN_AMOUNT = 1_000_000; // Base token amount
        uint256 initialSupply = TOKEN_AMOUNT * 10 ** alchemistUnderlyingTokenDecimals;
        mockVaultCollateral = address(new TestERC20(initialSupply, uint8(alchemistUnderlyingTokenDecimals)));
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

        vm.prank(admin);
        allocator.setMaxRate(200e16 / uint256(365 days));
    }

    function _magicDepositToVault(address vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), vault, amount);
        uint256 shares = IVaultV2(vault).deposit(amount, depositor);
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
            liquidationTargetCollateralization: uint256(1e36) / 88e16, // ~113.63% (88% LTV)
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: liquidatorFeeBPS,
            repaymentFee: 100,
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

        _targetSenders();

        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    modifier logCall(address onBehalf, string memory name) {
        console2.log(onBehalf, "->", name);

        _;
    }

    function _targetSenders() internal virtual {
        _targetSender(makeAddr("Sender1"));
        _targetSender(makeAddr("Sender2"));
        _targetSender(makeAddr("Sender3"));
        _targetSender(makeAddr("Sender4"));
        _targetSender(makeAddr("Sender5"));
        _targetSender(makeAddr("Sender6"));
        _targetSender(makeAddr("Sender7"));
        _targetSender(makeAddr("Sender8"));
    }

    function _targetSender(address sender) internal {
        targetSender(sender);

        vm.prank(address(0xdead));
        alToken.setWhitelist(sender, true);

        vm.startPrank(sender);
        TokenUtils.safeApprove(address(alToken), address(alchemist), type(uint256).max);
        TokenUtils.safeApprove(address(alchemist.myt()), address(alchemist), type(uint256).max);
        vm.stopPrank();
    }

    /* HANDLERS */

    function mine(uint256 blocks) external {
        blocks = bound(blocks, 1, 72_000);

        console2.log("block number ->", block.number + blocks);

        vm.roll(block.number + blocks);
    }

    /* UTILS */

    function _randomDepositor(address[] memory users, uint256 seed) internal pure returns (address) {
        return _randomNonZero(users, seed);
    }

    function _randomWithdrawer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 withdrawable = 0;
            if (tokenId != 0) withdrawable = alchemist.getMaxWithdrawable(tokenId);

            if (withdrawable > 0) candidates[i] = user;
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomMinter(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 borrowable;


            if (tokenId != 0) borrowable = alchemist.getMaxBorrowable(tokenId);
            
            if (borrowable > 0) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomRepayer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
            uint256 collateral;
            uint256 debt;

            if (tokenId != 0) (collateral, debt,) = alchemist.getCDP(tokenId);

            if (debt > 0) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomBurner(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 collateral;
            uint256 debt;
            uint256 earmarked;

            if (tokenId != 0) (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

            if (debt > 0 && debt > earmarked) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomStaker(address[] memory users, uint256 seed) internal pure returns (address) {
        return _randomNonZero(users, seed);
    }

    function _randomClaimer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];

            uint256 tokenCount = IERC721Enumerable(address(transmuterLogic)).balanceOf(user);
            uint256[] memory tokenIds = new uint256[](tokenCount);

            if (tokenCount > 0) {
                // Loop through each token and retrieve its token ID via the enumerable interface.
                for (uint256 j = 0; j < tokenCount; j++) {
                    tokenIds[j] = IERC721Enumerable(address(transmuterLogic)).tokenOfOwnerByIndex(user, j);
                }

                if (tokenIds[0] != 0) candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomNonZero(address[] memory users, uint256 seed) internal pure returns (address) {
        users = _removeAll(users, address(0));

        return _randomCandidate(users, seed);
    }

    function _randomCandidate(address[] memory candidates, uint256 seed) internal pure returns (address) {
        if (candidates.length == 0) return address(0);

        return candidates[seed % candidates.length];
    }

    function _removeAll(address[] memory inputs, address removed) internal pure returns (address[] memory result) {
        result = new address[](inputs.length);

        uint256 nbAddresses;
        for (uint256 i; i < inputs.length; ++i) {
            address input = inputs[i];

            if (input != removed) {
                result[nbAddresses] = input;
                ++nbAddresses;
            }
        }

        assembly {
            mstore(result, nbAddresses)
        }
    }
}
