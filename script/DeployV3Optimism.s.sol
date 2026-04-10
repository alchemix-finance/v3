// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "..//src/interfaces/IAlchemistV3.sol";
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
import {WstethStrategy} from "../src/strategies/WStethStrategy.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../src/AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../src/AlchemistTokenVault.sol";

// AlAsset
//import {CrossChainCanonicalAlchemicTokenV2} from "../lib/v2-foundry/src/CrossChainCanonicalAlchemicTokenV2.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

interface AlAsset {
    function setWhitelist(address a, bool v) external;
}

contract DeployV3OptimismScript is Script {
    address self = address(this);
    address deployerAddr = 0x1c9387747baA55C26197732Bda132955E1F56b80;
    // Asset addresses
    address public aUSDC = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address public wethOP = 0x4200000000000000000000000000000000000006;
    address public alUSD = 0xb2c22A9fb4FC02eb9D1d337655Ce079a04a526C7;
    address public alETH = 0x3E29D3A9316dAB217754d13b28646B76607c5f04;
    address public USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Price feed addresses
    address public ETH_USD_PRICE_FEED_MAINNET = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    uint256 public ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    address public receiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public protocolFeeReceiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;

    // Contract addresses
    address public vaultAdmin = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public newOwner = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    //address public vaultAdmin = deployerAddr; // FIXME
    //address public newOwner = deployerAddr; // FIXME
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
    // Aave V3
    address public aavePoolProvider = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb; 
    address public aaveRewardsController_OP = 0x929EC64c34a17401F460460D4B9390518E5B473e; // Aave RewardsController on Optimism
    address public aaveRewardToken_OP = 0x4200000000000000000000000000000000000042; // OP token on Optimism

    // wstETH
    address public wstETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address public wstEthEthOracle = 0x524299Ab0987a7c4B3c8022a35669DdcdC715a10;

    // Strategy parameters
    IMYTStrategy.StrategyParams public aaveUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "AaveV3 OP USDC",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000 * 1e6,
        globalCap: 1e18,
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public wstEthParams = IMYTStrategy.StrategyParams({
        owner: deployerAddr,
        name: "WstETH Optimism",
        protocol: "WstETH",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0.7 * 1e18,
        globalCap: 1e18,
        estimatedYield: 350,
        additionalIncentives: false,
        slippageBPS: 50
    });

    function setUp() public {}

    function deployAaveV3OPUSDCStrategy(address myt) internal returns (AaveStrategy) {
        AaveStrategy aaveUSDCStrategy = new AaveStrategy(
            myt,
            aaveUSDCParams,
            USDC,
            aUSDC,
            aavePoolProvider,
            aaveRewardsController_OP,
            aaveRewardToken_OP
        );
        aaveUSDCStrategy.setKillSwitch(true);
        curator.submitSetStrategy(address(aaveUSDCStrategy), address(myt));
        curator.setStrategy(address(aaveUSDCStrategy), address(myt));
        bytes memory idData = aaveUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.increaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);
        curator.increaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);

        aaveUSDCStrategy.transferOwnership(newOwner);
        return aaveUSDCStrategy;
    }

    function deployWstEthStrategy(address myt) internal returns (WstethStrategy) {
        WstethStrategy strategy = new WstethStrategy(
            myt,
            wstEthParams,
            wstETH,
            wstEthEthOracle,
            false,
            7000
        );

        strategy.setKillSwitch(true);
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), wstEthParams.cap);
        curator.increaseAbsoluteCap(address(strategy), wstEthParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), wstEthParams.globalCap);
        curator.increaseRelativeCap(address(strategy), wstEthParams.globalCap);

        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function deployUSDCStrategies(address myt) public {
        AaveStrategy aaveUSDCStrategy = deployAaveV3OPUSDCStrategy(myt);
        usdcStrategies.push(address(aaveUSDCStrategy));

        console.log("AaveV3 OP USDC Strategy deployed at:", address(aaveUSDCStrategy));
    }

    function deployETHStrategies(address myt) public {
        WstethStrategy wstEthStrategy = deployWstEthStrategy(myt);
        ethStrategies.push(address(wstEthStrategy));

        console.log("WstETH Optimism Strategy deployed at:", address(wstEthStrategy));
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
            timeToTransmute: 3_628_800,
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
            depositCap: cap,
            minimumCollateralization: 1_111_111_111_111_111_111, // 1.1x collateralization
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            liquidationTargetCollateralization: 1_111_111_111_111_111_111, // 1.1
            globalMinimumCollateralization: 1_052_631_578_950_000_000, // 20/19
            transmuter: transmuter,
            protocolFee: 25, // 10000 bps -> 0.25%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300, // 3% = 300 BPS
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
        // ====== MOCK ONLY ======
        // Deploy alAssets
        //alUSD = deployAlAsset("thatsmy", "kungfu");
        //alETH = deployAlAsset("ethkungfu", "ekungfu");
        // ========= END MOCK ==============
        // Deploy Morpho Vault
        vaultFactory = new VaultV2Factory();
        usdcVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, USDC, bytes32(0)));
        ethVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, wethOP, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(deployerAddr, deployerAddr);

        // Deploy AlchemistStrategyClassifier
        classifier = new AlchemistStrategyClassifier(newOwner);

        // Set vault curator immediately so submit calls work
        usdcVault.setCurator(address(curator));
        ethVault.setCurator(address(curator));

        // Deploy AlchemistAllocator
        usdcAllocator = new AlchemistAllocator(address(usdcVault), deployerAddr, deployerAddr, address(classifier));
        ethAllocator = new AlchemistAllocator(address(ethVault), deployerAddr, deployerAddr, address(classifier));

        usdcTransmuter = deployTransmuter(alUSD);
        ethTransmuter = deployTransmuter(alETH);

        usdcAlchemist = deployAlchemist(alUSD, USDC, address(usdcVault), address(usdcTransmuter), 0);
        ethAlchemist = deployAlchemist(alETH, wethOP, address(ethVault), address(ethTransmuter), 0);

        // Whitelist alchemist proxy for minting tokens
        // TODO we dont have admin access
        // AlAsset(alUSD).setWhitelist(address(alchemist), true);

        // Deploy and link strategies (now that curator is set)
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
        console.log("mock alUSD deployed at", address(alUSD));
        console.log("mock alETH deployed at", address(alETH));

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
        console.log("- Run $vault.setIsAllocator(allocator,true) on each MYT vault now!");
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
            require(Ownable(usdcStrategies[i]).owner() == newOwner);
            require(usdcVault.forceDeallocatePenalty(usdcStrategies[i]) == 2e16);
        }
        for (uint256 i = 0; i < ethStrategies.length; i++) {
            require(Ownable(ethStrategies[i]).owner() == newOwner);
            require(ethVault.forceDeallocatePenalty(ethStrategies[i]) == 2e16);
        }
    }
}
