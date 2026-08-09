// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AlchemistV3} from "../../AlchemistV3.sol";
import {AlchemicTokenV3} from "../mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../../Transmuter.sol";
import {AlchemistV3Position} from "../../AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../../AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../../AlchemistTokenVault.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistCurator} from "../../AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {Whitelist} from "../../utils/Whitelist.sol";

import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";

import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "lib/vault-v2/src/VaultV2Factory.sol";

import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../../interfaces/ITransmuter.sol";

import {TokenUtils} from "../../libraries/TokenUtils.sol";

abstract contract E2EInvariantEnv is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_VAULT_USERS = 10;
    uint256 internal constant MAX_ALCHEMIST_SENDERS = 8;
    uint256 internal constant PERFORMANCE_FEE = 15e16;
    uint256 internal constant MINIMUM_COLLATERALIZATION = uint256(1e18 * 1e18) / 9e17;

    uint256 internal constant MOCK_A_RELATIVE_CAP = 0.5e18;
    uint256 internal constant MOCK_B_RELATIVE_CAP = 0.3e18;

    address internal admin = address(0x0001);
    address internal operator = address(0x0003);
    address internal curator = address(0x0008);
    address internal alchemistAdmin = address(0xdead);
    address internal feeRecipient = address(0xfeed);
    address internal protocolFeeReceiver = address(10);

    AlchemistV3 internal alchemist;
    Transmuter internal transmuterLogic;
    AlchemicTokenV3 internal alToken;
    AlchemistV3Position internal alchemistNFT;
    AlchemistTokenVault internal alchemistFeeVault;
    TransparentUpgradeableProxy internal proxyAlchemist;
    Whitelist internal whitelist;

    IVaultV2 internal vault;
    address internal allocator;
    address internal classifier;
    address internal curatorContract;

    address[] internal strategies;
    address internal mockStrategyA;
    address internal mockStrategyB;
    address internal mockYieldTokenA;
    address internal mockYieldTokenB;
    address internal realStrategy;
    mapping(address => string) internal strategyLabel;

    address[] internal vaultActors;
    address[] internal alchemistSenders;

    address internal asset;
    uint256 internal assetDecimals;
    uint256 internal initialVaultDeposit;
    uint256 internal mockAbsoluteCapA;
    uint256 internal mockAbsoluteCapB;
    uint256 internal forkId;

    function getRpcUrl() internal virtual returns (string memory);
    function getForkBlockNumber() internal virtual returns (uint256);
    function getAsset() internal virtual returns (address);

    function setUp() public virtual {
        _selectFork();
        asset = getAsset();
        assetDecimals = TokenUtils.expectDecimals(asset);
        initialVaultDeposit = 10_000 * 10 ** assetDecimals;
        mockAbsoluteCapA = 5000 * 10 ** assetDecimals;
        mockAbsoluteCapB = 20_000 * 10 ** assetDecimals;
        _setupVaultStack();
        _deployMockStrategies();
        _wireMockStrategies();
        _deployCoreProtocol();
        _seedInitialLiquidity();
        _setupActors();
    }

    function _selectFork() internal {
        string memory rpc = getRpcUrl();
        uint256 block = getForkBlockNumber();
        if (block != 0) {
            forkId = vm.createFork(rpc, block);
        } else {
            forkId = vm.createFork(rpc);
        }
        vm.selectFork(forkId);
    }

    function _setupVaultStack() internal {
        vm.startPrank(admin);
        VaultV2Factory factory = new VaultV2Factory();
        vault = IVaultV2(factory.createVaultV2(admin, asset, bytes32(0)));

        classifier = address(new AlchemistStrategyClassifier(admin));
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18);
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18);
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18);

        curatorContract = address(new AlchemistCurator(admin, admin));
        VaultV2(address(vault)).setCurator(curatorContract);
        _applyPerformanceFee();

        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
        vm.stopPrank();
    }

    function _applyPerformanceFee() internal {
        AlchemistCurator(curatorContract).submitSetPerformanceFeeRecipient(address(vault), feeRecipient);
        vault.setPerformanceFeeRecipient(feeRecipient);
        AlchemistCurator(curatorContract).submitSetPerformanceFee(address(vault), PERFORMANCE_FEE);
        vault.setPerformanceFee(PERFORMANCE_FEE);
    }

    function _deployMockStrategies() internal {
        vm.startPrank(admin);
        mockYieldTokenA = address(new MockYieldToken(asset));
        mockYieldTokenB = address(new MockYieldToken(asset));

        mockStrategyA =
            address(new MockMYTStrategy(address(vault), mockYieldTokenA, _mockParams(admin, "MockA LOW", "MockProtocolA", IMYTStrategy.RiskClass.LOW)));
        mockStrategyB =
            address(new MockMYTStrategy(address(vault), mockYieldTokenB, _mockParams(admin, "MockB MEDIUM", "MockProtocolB", IMYTStrategy.RiskClass.MEDIUM)));
        vm.stopPrank();
    }

    function _mockParams(address owner, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass)
        internal
        pure
        returns (IMYTStrategy.StrategyParams memory)
    {
        return IMYTStrategy.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 0,
            globalCap: 1e18,
            estimatedYield: 100 ether,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function _wireMockStrategies() internal {
        vm.startPrank(admin);
        AlchemistCurator(curatorContract).submitSetAllocator(address(vault), allocator, true);
        vault.setIsAllocator(allocator, true);

        _addStrategyViaCurator(mockStrategyA, mockAbsoluteCapA, MOCK_A_RELATIVE_CAP);
        _addStrategyViaCurator(mockStrategyB, mockAbsoluteCapB, MOCK_B_RELATIVE_CAP);

        AlchemistAllocator(allocator).setMaxRate(200e16 / uint256(365 days));
        vm.stopPrank();

        strategies.push(mockStrategyA);
        strategies.push(mockStrategyB);
        strategyLabel[mockStrategyA] = "MockA LOW";
        strategyLabel[mockStrategyB] = "MockB MEDIUM";
    }

    function _addStrategyViaCurator(address strategy, uint256 absoluteCap, uint256 relativeCap) internal {
        AlchemistCurator(curatorContract).submitSetStrategy(strategy, address(vault));
        AlchemistCurator(curatorContract).setStrategy(strategy, address(vault));
        AlchemistCurator(curatorContract).submitIncreaseAbsoluteCap(strategy, absoluteCap);
        AlchemistCurator(curatorContract).increaseAbsoluteCap(strategy, absoluteCap);
        AlchemistCurator(curatorContract).submitIncreaseRelativeCap(strategy, relativeCap);
        AlchemistCurator(curatorContract).increaseRelativeCap(strategy, relativeCap);

        bytes32 strategyId = IMYTStrategy(strategy).adapterId();
        (,,, IMYTStrategy.RiskClass riskClass,,,,,) = IMYTStrategy(strategy).params();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(riskClass));
        require(vault.isAdapter(strategy), "adapter not registered");
    }

    function _deployCoreProtocol() internal {
        vm.startPrank(alchemistAdmin);
        alToken = new AlchemicTokenV3("", "", 0);

        transmuterLogic = new Transmuter(
            ITransmuter.TransmuterInitializationParams({
                syntheticToken: address(alToken),
                feeReceiver: address(this),
                timeToTransmute: 5_256_000,
                transmutationFee: 10,
                exitFee: 20,
                graphSize: 52_560_000
            })
        );

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alchemistAdmin,
            debtToken: address(alToken),
            underlyingToken: vault.asset(),
            depositCap: type(uint256).max,
            minimumCollateralization: MINIMUM_COLLATERALIZATION,
            collateralizationLowerBound: 1_052_631_578_950_000_000,
            globalMinimumCollateralization: 1_111_111_111_111_111_111,
            liquidationTargetCollateralization: uint256(1e36) / 88e16,
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300,
            repaymentFee: 100,
            myt: address(vault)
        });

        proxyAlchemist =
            new TransparentUpgradeableProxy(address(new AlchemistV3()), alchemistAdmin, abi.encodeWithSelector(AlchemistV3.initialize.selector, params));
        alchemist = AlchemistV3(address(proxyAlchemist));

        alToken.setWhitelist(address(alchemist), true);
        transmuterLogic.setAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist), alchemistAdmin);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        alchemistFeeVault = new AlchemistTokenVault(vault.asset(), address(alchemist), alchemistAdmin);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        vm.stopPrank();
    }

    function _seedInitialLiquidity() internal {
        vm.startPrank(admin);
        deal(asset, admin, initialVaultDeposit);
        TokenUtils.safeApprove(asset, address(vault), initialVaultDeposit);
        vault.deposit(initialVaultDeposit, admin);
        require(vault.totalAssets() == initialVaultDeposit, "vault seed mismatch");
        vm.stopPrank();
    }

    function _setupActors() internal {
        uint256 actorUnit = 100 * 10 ** assetDecimals;
        for (uint256 i = 0; i < MAX_VAULT_USERS; i++) {
            address actor = makeAddr(string(abi.encodePacked("vaultActor", i)));
            vaultActors.push(actor);
            deal(asset, actor, (i + 1) * actorUnit);
            vm.prank(actor);
            TokenUtils.safeApprove(asset, address(vault), type(uint256).max);
        }

        uint256 senderDeposit = 1000 * 10 ** assetDecimals;
        for (uint256 i = 0; i < MAX_ALCHEMIST_SENDERS; i++) {
            address sender = makeAddr(string(abi.encodePacked("alchSender", i)));
            alchemistSenders.push(sender);

            vm.prank(alchemistAdmin);
            alToken.setWhitelist(sender, true);
            _magicDepositToVault(address(vault), sender, senderDeposit);

            vm.startPrank(sender);
            TokenUtils.safeApprove(address(alToken), address(alchemist), type(uint256).max);
            TokenUtils.safeApprove(address(vault), address(alchemist), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(asset, depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(asset, _vault, amount);
        uint256 shares = IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }
}
