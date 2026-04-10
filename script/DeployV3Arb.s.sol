// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";
import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {VaultV2Factory} from "../lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2, IVaultV2} from "../lib/vault-v2/src/VaultV2.sol";

import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../src/AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../src/AlchemistTokenVault.sol";

// AlAsset
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

contract DeployV3ArbScript is Script {
    address self = address(this);
    address deployerAddr = 0x1c9387747baA55C26197732Bda132955E1F56b80;
    // Token addresses
    address public wethARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH on Arbitrum
    address public usdcARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum
    address public alUSD = 0xCB8FA9a76b8e203D8C3797bF438d8FB81Ea3326A;
    address public alETH = 0x17573150d67d820542EFb24210371545a4868B03;

    // Fee and receiver addresses
    address public receiver = 0x7e108711771DfdB10743F016D46d75A9379cA043;
    address public protocolFeeReceiver = 0x7e108711771DfdB10743F016D46d75A9379cA043;

    // Contract addresses
    address public vaultAdmin = 0x7e108711771DfdB10743F016D46d75A9379cA043; // FIXME
    address public newOwner = 0x7e108711771DfdB10743F016D46d75A9379cA043; // FIXME
    // Vault and factory
    VaultV2Factory public vaultFactory;
    VaultV2 public usdcVault;
    VaultV2 public ethVault;
    AlchemistV3 public usdcAlchemist;
    AlchemistV3 public ethAlchemist;
    Transmuter public usdcTransmuter;
    Transmuter public ethTransmuter;
    AlchemistCurator public curator;
    AlchemistStrategyClassifier public classifier;
    AlchemistAllocator public usdcAllocator;
    AlchemistAllocator public ethAllocator;

    address[] public usdcStrategies;
    address[] public ethStrategies;

    // Strategy-specific addresses
    // Aave V3 addresses
    address public aavePoolARB = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb; // Aave V3 PoolAddressProvider on Arbitrum
    address public aWETH_ARB = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8; // aWETH on Arbitrum
    address public aUSDC_ARB = 0x724dc807b04555b71ed48a6896b6F41593b8C637; // aUSDCn on Arbitrum
    address public aaveRewardsController_ARB = 0x929EC64c34a17401F460460D4B9390518E5B473e; // Aave RewardsController on Arbitrum
    address public aaveRewardToken_ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548; // ARB token on Arbitrum

    // Euler addresses
    address public eulerVaultWETH_ARB = 0x78E3E051D32157AACD550fBB78458762d8f7edFF; // Euler WETH vault on Arbitrum
    address public eulerVaultUSDC_ARB = 0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899; // Euler USDC vault on Arbitrum

    // Fluid addresses
    address public fluidVaultUSDC_ARB = 0x1A996cb54bb95462040408C06122D45D6Cdb6096; // Fluid USDC vault on Arbitrum

    // Strategy parameters
    IMYTStrategy.StrategyParams public aaveWETHParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "Aave V3 WETH Arbitrum",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0.7 * 1e18,
        globalCap: 1e18,
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public aaveUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "Aave V3 USDC Arbitrum",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000 * 1e6,
        globalCap: 1e18,
        estimatedYield: 450, // 4.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public eulerWETHParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "Euler WETH Arbitrum",
        protocol: "Euler",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0.7 * 1e18,
        globalCap: 1e18,
        estimatedYield: 600, // 6% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public eulerUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "Euler USDC Arbitrum",
        protocol: "Euler",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000 * 1e6,
        globalCap: 1e18,
        estimatedYield: 550, // 5.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public fluidUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "Fluid USDC Arbitrum",
        protocol: "Fluid",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 1000 * 1e6,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 525, // 5.25% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    function setUp() public {}

    function deployAaveWETHStrategy(address myt) internal returns (AaveStrategy) {
        AaveStrategy strategy = new AaveStrategy(
            myt,
            aaveWETHParams,
            wethARB,
            aWETH_ARB,
            aavePoolARB,
            aaveRewardsController_ARB,
            aaveRewardToken_ARB
        );
        
        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), aaveWETHParams.cap);
        curator.increaseAbsoluteCap(address(strategy), aaveWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), aaveWETHParams.globalCap);
        curator.increaseRelativeCap(address(strategy), aaveWETHParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployAaveUSDCStrategy(address myt) internal returns (AaveStrategy) {
        AaveStrategy strategy = new AaveStrategy(
            myt,
            aaveUSDCParams,
            usdcARB,
            aUSDC_ARB,
            aavePoolARB,
            aaveRewardsController_ARB,
            aaveRewardToken_ARB
        );
        
        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), aaveUSDCParams.cap);
        curator.increaseAbsoluteCap(address(strategy), aaveUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), aaveUSDCParams.globalCap);
        curator.increaseRelativeCap(address(strategy), aaveUSDCParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployEulerWETHStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            eulerWETHParams,
            eulerVaultWETH_ARB
        );
        
        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), eulerWETHParams.cap);
        curator.increaseAbsoluteCap(address(strategy), eulerWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), eulerWETHParams.globalCap);
        curator.increaseRelativeCap(address(strategy), eulerWETHParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployEulerUSDCStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            eulerUSDCParams,
            eulerVaultUSDC_ARB
        );
        
        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), eulerUSDCParams.cap);
        curator.increaseAbsoluteCap(address(strategy), eulerUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), eulerUSDCParams.globalCap);
        curator.increaseRelativeCap(address(strategy), eulerUSDCParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployFluidUSDCStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            fluidUSDCParams,
            fluidVaultUSDC_ARB
        );
        
        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), fluidUSDCParams.cap);
        curator.increaseAbsoluteCap(address(strategy), fluidUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), fluidUSDCParams.globalCap);
        curator.increaseRelativeCap(address(strategy), fluidUSDCParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployUSDCStrategies(address myt) public {
        AaveStrategy aaveUSDCStrategy = deployAaveUSDCStrategy(myt);
        ERC4626Strategy eulerUSDCStrategy = deployEulerUSDCStrategy(myt);
        ERC4626Strategy fluidUSDCStrategy = deployFluidUSDCStrategy(myt);
        usdcStrategies.push(address(aaveUSDCStrategy));
        usdcStrategies.push(address(eulerUSDCStrategy));
        usdcStrategies.push(address(fluidUSDCStrategy));

        console.log("Aave V3 USDC Strategy deployed at:", address(aaveUSDCStrategy));
        console.log("Euler USDC Strategy deployed at:", address(eulerUSDCStrategy));
        console.log("Fluid USDC Strategy deployed at:", address(fluidUSDCStrategy));
    }

    function deployETHStrategies(address myt) public {
        AaveStrategy aaveWETHStrategy = deployAaveWETHStrategy(myt);
        ERC4626Strategy eulerWETHStrategy = deployEulerWETHStrategy(myt);
        ethStrategies.push(address(aaveWETHStrategy));
        ethStrategies.push(address(eulerWETHStrategy));

        console.log("Aave V3 WETH Strategy deployed at:", address(aaveWETHStrategy));
        console.log("Euler WETH Strategy deployed at:", address(eulerWETHStrategy));
    }

    function deployAlAsset(string memory name, string memory ticker) public returns (address) {
        CrossChainCanonicalAlchemicTokenV3 alAssetImpl = new CrossChainCanonicalAlchemicTokenV3();
        bytes memory alAssetParams = abi.encodeWithSelector(CrossChainCanonicalAlchemicTokenV3.initialize.selector, name, ticker);
        CrossChainCanonicalAlchemicTokenV3 alAssetProxy = CrossChainCanonicalAlchemicTokenV3(address(new TransparentUpgradeableProxy(
            address(alAssetImpl),
            newOwner,
            alAssetParams
        )));
        alAssetProxy.transferOwnership(newOwner);
        alAssetProxy.setWhitelist(self, true);
        alAssetProxy.setWhitelist(newOwner, true);
        alAssetProxy.mint(newOwner, 1e9 * 1e18);
        return address(alAssetProxy);
    }

    function deployTransmuter(address alAsset) public returns (Transmuter) {
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alAsset,
            feeReceiver: protocolFeeReceiver,
            timeToTransmute: 29_030_400,
            transmutationFee: 0,
            exitFee: 100,
            graphSize: 365 days
        });

        Transmuter deployedTransmuter = new Transmuter(transmuterParams);
        deployedTransmuter.setDepositCap(0);

        require(deployedTransmuter.transmutationFee() == 0);
        require(deployedTransmuter.exitFee() == 100);
        return deployedTransmuter;
    }

    function deployAlchemist(address alAsset, address underlying, address vault, address transmuter, uint256 cap) public returns (AlchemistV3) {
        AlchemistV3 alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployerAddr,
            debtToken: alAsset,
            underlyingToken: underlying,
            depositCap: cap, // FIXME 1.5 * migratedDeposits
            minimumCollateralization: 1_111_111_111_111_111_111,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 20/19
            liquidationTargetCollateralization: 1_111_111_111_111_111_111,
            globalMinimumCollateralization: 1_052_631_578_950_000_000, // 20/19
            transmuter: transmuter,
            protocolFee: 25, // 10000 bps -> 0.25%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300,
            repaymentFee: 0,
            myt: vault
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        AlchemistV3 deployedAlchemist = AlchemistV3(address(new TransparentUpgradeableProxy(
            address(alchemistLogic),
            newOwner,
            alchemParams
        )));

        require(deployedAlchemist.protocolFee() == 25);
        require(deployedAlchemist.liquidatorFee() == 300);
        require(deployedAlchemist.repaymentFee() == 0);

        AlchemistV3Position alchemistNFT = new AlchemistV3Position(address(deployedAlchemist), deployerAddr);
        alchemistNFT.setMetadataRenderer(address(new AlchemistV3PositionRenderer()));
        deployedAlchemist.setAlchemistPositionNFT(address(alchemistNFT));
        alchemistNFT.setAdmin(newOwner);

        AlchemistTokenVault alchemistFeeVault = new AlchemistTokenVault(underlying, address(deployedAlchemist), deployerAddr);
        alchemistFeeVault.setAuthorization(address(deployedAlchemist), true);
        alchemistFeeVault.transferOwnership(newOwner);
        deployedAlchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        deployedAlchemist.setPendingAdmin(newOwner);
        
        return deployedAlchemist;
    }

    function run() public {
        deployerAddr = 0x1c9387747baA55C26197732Bda132955E1F56b80;
        vm.startBroadcast(deployerAddr);
        
        // Deploy alAssets
        //alUSD = deployAlAsset("Alchemic USD", "alUSD");
        //alETH = deployAlAsset("Alchemic ETH", "alETH");

        // Deploy Vault Factory and Vaults
        vaultFactory = new VaultV2Factory();
        usdcVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, usdcARB, bytes32(0)));
        ethVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, wethARB, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(deployerAddr, deployerAddr);

        // Deploy AlchemistStrategyClassifier
        classifier = new AlchemistStrategyClassifier(newOwner);

        // Set vault curator immediately
        usdcVault.setCurator(address(curator));
        ethVault.setCurator(address(curator));

        // Deploy AlchemistAllocator
        usdcAllocator = new AlchemistAllocator(address(usdcVault), deployerAddr, deployerAddr, address(classifier));
        ethAllocator = new AlchemistAllocator(address(ethVault), deployerAddr, deployerAddr, address(classifier));

        // Deploy Transmuters
        usdcTransmuter = deployTransmuter(alUSD);
        ethTransmuter = deployTransmuter(alETH);

        // Deploy Alchemists
        usdcAlchemist = deployAlchemist(alUSD, usdcARB, address(usdcVault), address(usdcTransmuter), 0);
        ethAlchemist = deployAlchemist(alETH, wethARB, address(ethVault), address(ethTransmuter), 0);

        // Deploy and link strategies
        deployUSDCStrategies(address(usdcVault));
        deployETHStrategies(address(ethVault));

        // Set allocator on vault
        curator.submitSetAllocator(address(usdcVault), address(usdcAllocator), true);
        usdcVault.setIsAllocator(address(usdcAllocator), true);

        curator.submitSetAllocator(address(ethVault), address(ethAllocator), true);
        ethVault.setIsAllocator(address(ethAllocator), true);

        // set max rate
        usdcAllocator.setMaxRate(3170979198); // 1e17 / 365 days = 10%
        ethAllocator.setMaxRate(3170979198); // 1e17 / 365 days = 10%

        // set force deallocate penalty
        usdcAllocator.setPermissionedCall(IVaultV2.setForceDeallocatePenalty.selector, true);
        ethAllocator.setPermissionedCall(IVaultV2.setForceDeallocatePenalty.selector, true);
        for (uint256 i = 0; i < usdcStrategies.length; i++) {
            address adapter = usdcStrategies[i];
            curator.submitSetForceDeallocatePenalty(adapter, address(usdcVault), 2e16);
            usdcAllocator.proxy(address(usdcVault), abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (adapter, 2e16)));
        }
        for (uint256 i = 0; i < ethStrategies.length; i++) {
            address adapter = ethStrategies[i];
            curator.submitSetForceDeallocatePenalty(adapter, address(ethVault), 2e16);
            ethAllocator.proxy(address(ethVault), abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (adapter, 2e16)));
        }
        
        usdcVault.setOwner(newOwner);
        ethVault.setOwner(newOwner);

        // Transfer curator ownership
        curator.transferAdminOwnerShip(newOwner);

        // transfer allocator ownership
        usdcAllocator.transferAdminOwnerShip(newOwner);
        ethAllocator.transferAdminOwnerShip(newOwner);

        usdcTransmuter.setAlchemist(address(usdcAlchemist));
        ethTransmuter.setAlchemist(address(ethAlchemist));
        usdcTransmuter.setPendingAdmin(newOwner);
        ethTransmuter.setPendingAdmin(newOwner);

    
        vm.stopBroadcast();

        // Output deployment addresses
        console.log("alUSD deployed at:", address(alUSD));
        console.log("alETH deployed at:", address(alETH));
        console.log("VaultFactory deployed at:", address(vaultFactory));
        console.log("alUSD Transmuter deployed at:", address(usdcTransmuter));
        console.log("alUSD Alchemist deployed at:", address(usdcAlchemist));
        console.log("USDC MYT Vault deployed at:", address(usdcVault));
        console.log("alETH Transmuter deployed at:", address(ethTransmuter));
        console.log("alETH Alchemist deployed at:", address(ethAlchemist));
        console.log("WETH MYT Vault deployed at:", address(ethVault));

        console.log("Curator deployed at:", address(curator));
        console.log("USDC Allocator deployed at:", address(usdcAllocator));
        console.log("ETH Allocator deployed at:", address(ethAllocator));

        console.log("----------- IMPORTANT -----------");
        console.log("- Add the new alchemists to the alAsset whitelist!");

        require(usdcAlchemist.pendingAdmin() == newOwner);
        require(usdcTransmuter.pendingAdmin() == newOwner);
        require(ethAlchemist.pendingAdmin() == newOwner);
        require(ethTransmuter.pendingAdmin() == newOwner);
        require(curator.pendingAdmin() == newOwner);
        require(usdcAllocator.pendingAdmin() == newOwner);
        require(ethAllocator.pendingAdmin() == newOwner);
        require(usdcVault.maxRate() == 3170979198);
        require(ethVault.maxRate() == 3170979198);
        for (uint256 i = 0; i < usdcStrategies.length; i++) {
            require(usdcVault.forceDeallocatePenalty(usdcStrategies[i]) == 2e16);
            require(Ownable(usdcStrategies[i]).owner() == newOwner);
        }
        for (uint256 i = 0; i < ethStrategies.length; i++) {
            require(ethVault.forceDeallocatePenalty(ethStrategies[i]) == 2e16);
            require(Ownable(ethStrategies[i]).owner() == newOwner);
        }
    }
}
