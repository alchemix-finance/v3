// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {VaultV2Factory} from "lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";


import {MYTStrategy} from "../MYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemicTokenV3} from "./mocks/AlchemicTokenV3.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";

import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";

import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "../test/libraries/AlchemistNFTHelper.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @notice Exposes the internal dexSwap function for testing.
contract DexSwapHarness is MYTStrategy {
    constructor(address _myt, StrategyParams memory _params)
        MYTStrategy(_myt, _params)
    {}

    function exposedDexSwap(address to, address from, uint256 amount, uint256 minAmountOut, bytes memory callData)
        external
        returns (uint256)
    {
        return dexSwap(to, from, amount, minAmountOut, callData);
    }
}

/// @notice Mock allowance holder that simulates a successful swap by
///         transferring toToken to the caller.
contract MockAllowanceHolderSuccess {
    IERC20 public immutable toToken;
    uint256 public immutable transferAmount;

    constructor(address _toToken, uint256 _transferAmount) {
        toToken = IERC20(_toToken);
        transferAmount = _transferAmount;
    }

    fallback() external {
        toToken.transfer(msg.sender, transferAmount);
    }
}

/// @notice Mock allowance holder that succeeds but does not transfer any tokens.
contract MockAllowanceHolderNoOp {
    fallback() external {}
}

/// @notice Mock allowance holder that always reverts, simulating a failed swap.
contract MockAllowanceHolderFail {
    fallback() external {
        revert("intentional failure");
    }
}

contract MYTStrategyTest is Test {
    using SafeERC20 for IERC20;

    // Addresses
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address alOwner = makeAddr("alOwner");
    address proxyOwner = makeAddr("proxyOwner");

    // Tokens
    TestERC20 public fakeUnderlyingToken;
    AlchemicTokenV3 public alToken;

    // Contracts
    AlchemistV3 public alchemist;
    IVaultV2 public vault;
    MYTStrategy public strategy;
    AlchemistAllocator public allocator;
    address public classifier;
    Transmuter public transmuterLogic;
    AlchemistV3Position public alchemistNFT;
    VaultV2Factory public vaultFactory;

    // Additional addresses for Alchemist initialization
    address public protocolFeeReceiver;
    uint256 public minimumCollateralization = 1_052_631_578_950_000_000; // 1.05 collateralization
    uint256 public liquidatorFeeBPS = 1000; // 10% liquidator fee

    // Strategy parameters
    IMYTStrategy.StrategyParams public strategyParams = IMYTStrategy.StrategyParams({
        owner: admin,
        name: "Test Strategy",
        protocol: "Test Protocol",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000e18,
        globalCap: 5000e18,
        estimatedYield: 100e18,
        additionalIncentives: false,
        slippageBPS: 1
    });

    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant BPS = 10_000;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 23567434);
        vm.selectFork(forkId);
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(alOwner);

        // Fake tokens
        fakeUnderlyingToken = new TestERC20(100e18, uint8(alchemistUnderlyingTokenDecimals));

        vaultFactory = new VaultV2Factory();

        alToken = new AlchemicTokenV3("Alchemic Token", "AL", 0);

        // Transmuter initialization params
        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        transmuterLogic = new Transmuter(transParams);
        AlchemistV3 alchemistLogic = new AlchemistV3();
        vault = IVaultV2(vaultFactory.createVaultV2(address(proxyOwner), address(fakeUnderlyingToken), bytes32("strategy-vault")));
        vm.stopPrank();

        vm.startPrank(proxyOwner);
        VaultV2(address(vault)).setCurator(alOwner);
        vm.stopPrank();

        vm.startPrank(alOwner);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (alOwner)));
        vault.setPerformanceFeeRecipient(alOwner);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (15e16)));
        vault.setPerformanceFee(15e16);
        vm.stopPrank();

        vm.startPrank(alOwner);

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
        TransparentUpgradeableProxy proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        transmuterLogic.setAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist), address(this));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        protocolFeeReceiver = address(this);

        // Add funds to test accounts
        deal(address(vault), address(0xbeef), 1000e18);
        deal(address(vault), user, 1000e18);
        deal(address(alToken), address(0xdad), 1000e18);
        deal(address(alToken), user, 1000e18);

        deal(address(fakeUnderlyingToken), address(0xbeef), 1000e18);
        deal(address(fakeUnderlyingToken), user, 1000e18);
        deal(address(fakeUnderlyingToken), alchemist.alchemistFeeVault(), 10_000 ether);

        // Set up classifier
        classifier = address(new AlchemistStrategyClassifier(admin));
        vm.startPrank(admin);
        // Set up risk classes matching constructor defaults (WAD: 1e18 = 100%)
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18); // LOW: 100%/100%
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18); // MEDIUM: 40%/25%
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18); // HIGH: 10%/10%
        vm.stopPrank();
        vm.startPrank(user);
        IERC20(address(fakeUnderlyingToken)).approve(address(vault), 1000e18);
        vm.stopPrank();

        strategy = new MYTStrategy(address(vault), strategyParams);

        
        // Assign risk level to the strategy
        bytes32 strategyId = strategy.adapterId();
        vm.prank(admin);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(strategyParams.riskClass));

        // Create allocator
        allocator = new AlchemistAllocator(address(vault), admin, operator, classifier);
    }

    // Test that allocator can allocate and deallocate
/*     function test_allocatorCanAllocateAndDeallocate() public {
        // Vault allocates
        vm.prank(address(vault));
        strategy.allocate(getVaultParams(), 100e18, bytes4(0x00000000), address(allocator));

        // Vault deallocates
        vm.prank(address(vault));
        strategy.deallocate(getVaultParams(), 50e18, bytes4(0x00000000), address(allocator));
    } */

    // Test that strategy kill switch works
    // function test_killSwitchPreventsAllocation() public {
    //     // Enable kill switch
    //     vm.prank(admin);
    //     strategy.setKillSwitch(true);

    //     // Vault should fail to allocate
    //     vm.prank(address(vault));
    //     vm.expectRevert(bytes("emergency"));
    //     strategy.allocate(abi.encode(0), 100e18, bytes4(0x00000000), address(allocator));

    //     // Disable kill switch
    //     vm.prank(admin);
    //     strategy.setKillSwitch(false);

    //     // Vault should succeed
    //     vm.prank(address(vault));
    //     strategy.allocate(abi.encode(0), 100e18, bytes4(0x00000000), address(allocator));
    // }

    // Test that strategy parameters can be updated
    function test_strategyParametersCanBeUpdated() public {
        // Update risk class
        vm.prank(admin);
        strategy.setRiskClass(IMYTStrategy.RiskClass.HIGH);

        // Update incentives
        vm.prank(admin);
        strategy.setAdditionalIncentives(true);

        // Verify updates by reading from storage directly
        // Access strategy parameters directly from storage
        (
            address owner,
            string memory name,
            string memory protocol,
            IMYTStrategy.RiskClass riskClass,
            uint256 cap,
            uint256 globalCap,
            uint256 estimatedYield,
            bool additionalIncentives,
            uint256 slippageBPS
        ) = strategy.params();
        assertEq(uint8(riskClass), uint8(IMYTStrategy.RiskClass.HIGH));
        assertEq(additionalIncentives, true);
    }

    // Test that strategy can interact with Alchemist system properly
    function test_strategyIntegrationWithAlchemist() public {
        // User deposits into yield token vault first
        vm.prank(user);
        vault.deposit(100e18, user);

        // User approves yield token for Alchemist
        vm.prank(user);
        vault.approve(address(alchemist), 100e18);

        // User deposits into Alchemist
        vm.prank(user);
        alchemist.deposit(10e18, user, 0);

        // Verify that allocator was called to allocate
        console.log("Deposit completed - allocation should have been triggered");
    }

    // Test that strategy respects Alchemist pause states
    function test_strategyRespectsAlchemistPauseStates() public {
        // Pause Alchemist deposits
        vm.prank(alOwner);
        alchemist.pauseDeposits(true);

        // User should not be able to deposit
        vm.prank(user);
        vault.approve(address(alchemist), 100e18);
        vm.expectRevert(IllegalState.selector);
        alchemist.deposit(100e18, user, 0);

        // Unpause deposits
        vm.prank(alOwner);
        alchemist.pauseDeposits(false);

        // Now deposit should work
        vm.startPrank(user);
        vault.approve(address(alchemist), 100e18);
        alchemist.deposit(10e18, user, 0);
        vm.stopPrank();
    }

    function getVaultParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function getSwapParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.swap;
        params.swapParams = IMYTStrategy.SwapParams({
            txData: hex"1234",
            minIntermediateOut: 0
        });
        return abi.encode(params);
    }

    function getUnwrapAndSwapParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.unwrapAndSwap;
        params.swapParams = IMYTStrategy.SwapParams({
            txData: hex"1234",
            minIntermediateOut: 100e18
        });
        return abi.encode(params);
    }

    // Test that base strategy reverts for unsupported direct allocate
    function test_baseStrategy_allocateDirect_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        strategy.allocate(getVaultParams(), 100e18, bytes4(0x00000000), address(allocator));
    }

    // Test that base strategy reverts for unsupported swap allocate
    function test_baseStrategy_allocateSwap_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        strategy.allocate(getSwapParams(), 100e18, bytes4(0x00000000), address(allocator));
    }

    // Test that base strategy reverts for unsupported direct deallocate
    function test_baseStrategy_deallocateDirect_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        strategy.deallocate(getVaultParams(), 100e18, bytes4(0x00000000), address(allocator));
    }

    // Test that base strategy reverts for unsupported swap deallocate
    function test_baseStrategy_deallocateSwap_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        strategy.deallocate(getSwapParams(), 100e18, bytes4(0x00000000), address(allocator));
    }

    // Test that base strategy reverts for unsupported unwrapAndSwap deallocate
    function test_baseStrategy_deallocateUnwrapAndSwap_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        strategy.deallocate(getUnwrapAndSwapParams(), 100e18, bytes4(0x00000000), address(allocator));
    }

    // ─── dexSwap tests ───────────────────────────────────────────────────

    function _deployHarness() internal returns (DexSwapHarness) {
        return new DexSwapHarness(address(vault), strategyParams);
    }

    function test_dexSwap_reverts_on_amount_less_than_minAmountOut() public {
        DexSwapHarness harness = _deployHarness();

        // Mock allowance holder that succeeds but transfers nothing
        MockAllowanceHolderNoOp noOp = new MockAllowanceHolderNoOp();
        vm.prank(admin);
        harness.setAllowanceHolder(address(noOp));

        ERC20Mock fromToken = new ERC20Mock();
        ERC20Mock toToken = new ERC20Mock();

        // Give the harness enough `from` tokens for the approve inside dexSwap
        deal(address(fromToken), address(harness), 100e18);

        // minAmountOut > 0 but swap returns 0 → should revert
        uint256 minAmountOut = 50e18;
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minAmountOut, 0));
        harness.exposedDexSwap(address(toToken), address(fromToken), 100e18, minAmountOut, hex"01");
    }

    function test_dexSwap_strategy_receives_to_asset() public {
        DexSwapHarness harness = _deployHarness();

        ERC20Mock fromToken = new ERC20Mock();
        ERC20Mock toToken = new ERC20Mock();

        uint256 swapReturn = 75e18;
        MockAllowanceHolderSuccess mockSwap = new MockAllowanceHolderSuccess(address(toToken), swapReturn);
        deal(address(toToken), address(mockSwap), swapReturn);

        vm.prank(admin);
        harness.setAllowanceHolder(address(mockSwap));

        // Give the harness enough `from` tokens for the approve
        deal(address(fromToken), address(harness), 100e18);

        uint256 balanceBefore = toToken.balanceOf(address(harness));
        uint256 received = harness.exposedDexSwap(address(toToken), address(fromToken), 100e18, 0, hex"01");
        uint256 balanceAfter = toToken.balanceOf(address(harness));

        assertEq(received, swapReturn, "Received amount mismatch");
        assertEq(balanceAfter - balanceBefore, swapReturn, "Balance change mismatch");
    }

    function test_dexSwap_reverts_on_allowanceHolder_call_failure() public {
        DexSwapHarness harness = _deployHarness();

        MockAllowanceHolderFail mockFail = new MockAllowanceHolderFail();
        vm.prank(admin);
        harness.setAllowanceHolder(address(mockFail));

        ERC20Mock fromToken = new ERC20Mock();
        ERC20Mock toToken = new ERC20Mock();

        deal(address(fromToken), address(harness), 100e18);

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.CounterfeitSettler.selector, address(mockFail)));
        harness.exposedDexSwap(address(toToken), address(fromToken), 100e18, 0, hex"01");
    }

    function test_rescueTokens_rescues_arbitrary_token() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 100e18);

        uint256 balanceBefore = randomToken.balanceOf(admin);
        vm.prank(admin);
        strategy.rescueTokens(address(randomToken), admin, 100e18);
        uint256 balanceAfter = randomToken.balanceOf(admin);

        assertEq(balanceAfter - balanceBefore, 100e18, "Rescue failed");
        assertEq(randomToken.balanceOf(address(strategy)), 0, "Strategy still has tokens");
    }

    function test_rescueTokens_reverts_on_protected_token() public {
        // MYT.asset() is protected by default
        vm.expectRevert(bytes("Protected token"));
        vm.prank(admin);
        strategy.rescueTokens(address(fakeUnderlyingToken), admin, 10e18);
    }

    function test_rescueTokens_reverts_on_zero_recipient() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 100e18);

        vm.expectRevert(bytes("Invalid recipient"));
        vm.prank(admin);
        strategy.rescueTokens(address(randomToken), address(0), 100e18);
    }

    function test_rescueTokens_reverts_on_insufficient_balance() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 50e18);

        vm.expectRevert(bytes("Insufficient balance"));
        vm.prank(admin);
        strategy.rescueTokens(address(randomToken), admin, 100e18);
    }

    function test_rescueTokens_onlyOwner() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 100e18);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user));
        vm.prank(user);
        strategy.rescueTokens(address(randomToken), user, 100e18);
    }

    function test_rescueTokens_partial_amount() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 100e18);

        uint256 balanceBefore = randomToken.balanceOf(admin);
        vm.prank(admin);
        strategy.rescueTokens(address(randomToken), admin, 30e18);
        uint256 balanceAfter = randomToken.balanceOf(admin);

        assertEq(balanceAfter - balanceBefore, 30e18, "Partial rescue failed");
        assertEq(randomToken.balanceOf(address(strategy)), 70e18, "Remaining balance wrong");
    }

    function test_rescueTokens_emits_event() public {
        ERC20Mock randomToken = new ERC20Mock();
        deal(address(randomToken), address(strategy), 100e18);

        vm.expectEmit(true, true, false, true);
        emit IMYTStrategy.TokensRescued(address(randomToken), admin, 50e18);
        vm.prank(admin);
        strategy.rescueTokens(address(randomToken), admin, 50e18);
    }
}
