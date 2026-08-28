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

import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";
import {AlchemistV3PositionRenderer} from "../src/AlchemistV3PositionRenderer.sol";
import {AlchemistTokenVault} from "../src/AlchemistTokenVault.sol";
import {AlchemistRouter} from "../src/router/AlchemistRouter.sol";

// AlAsset
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

interface AlAsset {
    function whitelisted(address a) external view returns (bool);
}

contract DeployV3BaseScript is Script {
    address deployerAddr = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // FIXME

    address public USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // native USDC on Base
    address public alUSDb;

    // Fee and receiver addresses
    address public protocolFeeReceiver = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    // Contract addresses
    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    uint256 public expectedMint;

    // Vault and factory
    VaultV2Factory public vaultFactory;
    VaultV2 public usdcVault;
    AlchemistV3 public usdcAlchemist;
    Transmuter public usdcTransmuter;
    AlchemistCurator public curator;
    AlchemistStrategyClassifier public classifier;
    AlchemistAllocator public usdcAllocator;
    AlchemistRouter public usdcRouter;

    address[] public usdcStrategies;

    function setUp() public {}

    function handoffAlAsset(address alAsset, address alchemist) public {
        CrossChainCanonicalAlchemicTokenV3 token = CrossChainCanonicalAlchemicTokenV3(alAsset);
        token.setWhitelist(alchemist, true);
        token.setWhitelist(deployerAddr, false);
        token.renounceRole(token.ADMIN_ROLE(), deployerAddr);
        token.renounceRole(token.SENTINEL_ROLE(), deployerAddr);
    }

    function deployTransmuter(address alAsset) public returns (Transmuter) {
        // FIXME transmuter params
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alAsset,
            feeReceiver: protocolFeeReceiver,
            timeToTransmute: 604_800,
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
        // FIXME alchemist params
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployerAddr,
            debtToken: alAsset,
            underlyingToken: underlying,
            depositCap: cap,
            minimumCollateralization: 1_111_111_111_111_111_111,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 20/19
            liquidationTargetCollateralization: 1_111_111_111_111_111_111,
            globalMinimumCollateralization: 1_052_631_578_950_000_000, // 20/19
            transmuter: transmuter,
            protocolFee: 25, // 10000 bps -> 0.25%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 150,
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
        require(deployedAlchemist.liquidatorFee() == 150);
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

    function registerStrategy(address strategy, address myt, uint256 cap, uint256 globalCap) public {
        curator.submitSetStrategy(strategy, myt);
        curator.setStrategy(strategy, myt);
        curator.submitIncreaseAbsoluteCap(strategy, cap);
        curator.increaseAbsoluteCap(strategy, cap);
        curator.submitIncreaseRelativeCap(strategy, globalCap);
        curator.increaseRelativeCap(strategy, globalCap);
        // FIXME penalty
        curator.submitSetForceDeallocatePenalty(strategy, myt, 2e16);
        usdcAllocator.proxy(myt, abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (strategy, 2e16)));

        usdcStrategies.push(strategy);
    }

    function deployStrategy(address myt, IMYTStrategy.StrategyParams memory params, address targetVault) public returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(myt, params, targetVault);
        strategy.setKillSwitch(true);
        registerStrategy(address(strategy), myt, params.cap, params.globalCap);
        strategy.transferOwnership(newOwner);
        return strategy;
    }

    function run() public {
        // Requires the alUSDb deployed by DeployV3BaseAlUSDb and ADMIN_ROLE granted back to the deployer by the multisig
        alUSDb = vm.envAddress("ALUSDB_ADDRESS");
        require(alUSDb != address(0));
        require(alUSDb.code.length > 0);
        CrossChainCanonicalAlchemicTokenV3 token = CrossChainCanonicalAlchemicTokenV3(alUSDb);
        require(keccak256(abi.encodePacked(token.symbol())) == keccak256("alUSDb"));
        require(Ownable(alUSDb).owner() == newOwner);
        require(token.hasRole(token.ADMIN_ROLE(), deployerAddr));
        expectedMint = vm.envOr("ALUSDB_INITIAL_MINT", uint256(1e9 * 1e18)); // FIXME must match DeployV3BaseAlUSDb mint amount

        vm.startBroadcast(deployerAddr);

        // Deploy Vault Factory and Vault
        vaultFactory = new VaultV2Factory();
        usdcVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, USDC, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(deployerAddr, deployerAddr);

        // Deploy AlchemistStrategyClassifier
        classifier = new AlchemistStrategyClassifier(newOwner);

        // Set vault curator immediately
        usdcVault.setCurator(address(curator));

        // Deploy AlchemistAllocator
        usdcAllocator = new AlchemistAllocator(address(usdcVault), deployerAddr, deployerAddr, address(classifier));

        // Deploy Transmuter
        usdcTransmuter = deployTransmuter(alUSDb);

        // Deploy Alchemist
        usdcAlchemist = deployAlchemist(alUSDb, USDC, address(usdcVault), address(usdcTransmuter), 0);

        // Deploy Router
        usdcRouter = new AlchemistRouter(address(usdcAlchemist));

        // Set allocator on vault
        curator.submitSetAllocator(address(usdcVault), address(usdcAllocator), true);
        usdcVault.setIsAllocator(address(usdcAllocator), true);

        // No candidate strategies yet, use deployStrategy/registerStrategy helpers once selected

        // FIXME set max rate
        usdcAllocator.setMaxRate(3170979198); // 1e17 / 365 days = 10%

        // FIXME set force deallocate penalty
        usdcAllocator.setPermissionedCall(IVaultV2.setForceDeallocatePenalty.selector, true);

        usdcVault.setOwner(newOwner);

        // Transfer curator ownership
        curator.transferAdminOwnerShip(newOwner);

        // transfer allocator ownership
        usdcAllocator.transferAdminOwnerShip(newOwner);

        usdcTransmuter.setAlchemist(address(usdcAlchemist));
        usdcTransmuter.setPendingAdmin(newOwner);

        // Whitelist alchemist for minting on the alAsset and drop deployer roles
        handoffAlAsset(alUSDb, address(usdcAlchemist));

        vm.stopBroadcast();

        // Output deployment addresses
        console.log("alUSDb:", alUSDb);
        console.log("VaultFactory deployed at:", address(vaultFactory));
        console.log("alUSDb Transmuter deployed at:", address(usdcTransmuter));
        console.log("alUSDb Alchemist deployed at:", address(usdcAlchemist));
        console.log("USDC MYT Vault deployed at:", address(usdcVault));

        console.log("Curator deployed at:", address(curator));
        console.log("Classifier deployed at:", address(classifier));
        console.log("USDC Allocator deployed at:", address(usdcAllocator));
        console.log("USDC Router deployed at:", address(usdcRouter));

        console.log("USDC Alchemist NFT deployed at:", usdcAlchemist.alchemistPositionNFT());
        console.log("USDC Alchemist Fee Vault deployed at:", usdcAlchemist.alchemistFeeVault());

        console.log("----------- IMPORTANT -----------");
        console.log("- Multisig must accept pending admin on alchemist, transmuter, curator and allocator!");

        require(usdcAlchemist.pendingAdmin() == newOwner);
        require(usdcTransmuter.pendingAdmin() == newOwner);
        require(curator.pendingAdmin() == newOwner);
        require(usdcAllocator.pendingAdmin() == newOwner);
        require(usdcVault.maxRate() == 3170979198);
        require(usdcVault.owner() == newOwner);
        require(usdcVault.curator() == address(curator));
        require(usdcVault.isAllocator(address(usdcAllocator)));
        require(usdcAlchemist.debtToken() == alUSDb);
        require(usdcAlchemist.underlyingToken() == USDC);
        require(usdcAlchemist.myt() == address(usdcVault));
        require(usdcAlchemist.transmuter() == address(usdcTransmuter));
        require(usdcAlchemist.alchemistPositionNFT() != address(0));
        require(usdcAlchemist.alchemistFeeVault() != address(0));
        require(address(usdcTransmuter.alchemist()) == address(usdcAlchemist));
        require(usdcTransmuter.syntheticToken() == alUSDb);
        require(AlchemistV3Position(usdcAlchemist.alchemistPositionNFT()).admin() == newOwner);
        require(AlchemistTokenVault(usdcAlchemist.alchemistFeeVault()).authorized(address(usdcAlchemist)));
        require(Ownable(usdcAlchemist.alchemistFeeVault()).owner() == newOwner);
        require(usdcRouter.alchemist() == address(usdcAlchemist));
        require(Ownable(alUSDb).owner() == newOwner);
        require(IERC20(alUSDb).balanceOf(newOwner) == expectedMint);
        require(AlAsset(alUSDb).whitelisted(address(usdcAlchemist)));
        require(!AlAsset(alUSDb).whitelisted(deployerAddr));
        require(!token.hasRole(token.ADMIN_ROLE(), deployerAddr));
        require(!token.hasRole(token.SENTINEL_ROLE(), deployerAddr));
    }
}
