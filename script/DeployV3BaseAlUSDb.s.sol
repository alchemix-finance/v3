// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// AlAsset
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

interface AlAsset {
    function whitelisted(address a) external view returns (bool);
}

contract DeployV3BaseAlUSDbScript is Script {
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0x24E9cbB9DdDa1247ae4b4eEEE3C569A2190ac401;

    address public alUSDb;

    function setUp() public {}

    function deployAlAsset(string memory name, string memory ticker) public returns (address) {
        CrossChainCanonicalAlchemicTokenV3 alAssetImpl = new CrossChainCanonicalAlchemicTokenV3();
        bytes memory alAssetParams = abi.encodeWithSelector(CrossChainCanonicalAlchemicTokenV3.initialize.selector, name, ticker);
        CrossChainCanonicalAlchemicTokenV3 alAssetProxy = CrossChainCanonicalAlchemicTokenV3(address(new TransparentUpgradeableProxy(
            address(alAssetImpl),
            newOwner,
            alAssetParams
        )));
        alAssetProxy.setWhitelist(deployerAddr, true);
        alAssetProxy.setWhitelist(newOwner, true);
        alAssetProxy.grantRole(alAssetProxy.ADMIN_ROLE(), newOwner);
        alAssetProxy.grantRole(alAssetProxy.SENTINEL_ROLE(), newOwner);
        alAssetProxy.mint(newOwner, 10 * 1e18);
        alAssetProxy.setWhitelist(deployerAddr, false);
        alAssetProxy.transferOwnership(newOwner);
        return address(alAssetProxy);
    }

    function run() public {
        vm.startBroadcast(deployerAddr);

        // Deploy alAsset
        alUSDb = deployAlAsset("Alchemic USD Base", "alUSDb");

        CrossChainCanonicalAlchemicTokenV3 token = CrossChainCanonicalAlchemicTokenV3(alUSDb);
        require(token.hasRole(token.ADMIN_ROLE(), newOwner));
        require(token.hasRole(token.SENTINEL_ROLE(), newOwner));
        token.renounceRole(token.ADMIN_ROLE(), deployerAddr);
        token.renounceRole(token.SENTINEL_ROLE(), deployerAddr);

        vm.stopBroadcast();

        // Output deployment addresses
        console.log("alUSDb deployed at:", alUSDb);

        console.log("----------- IMPORTANT -----------");
        console.log("- Run DeployV3Base with ALUSDB_ADDRESS set to the address above!");
        console.log("- Multisig must grantRole(ADMIN_ROLE, deployer) on alUSDb before running DeployV3Base!");
        console.log("- Multisig must accept pending admin on alchemist, transmuter, curator and allocator after DeployV3Base!");

        require(keccak256(abi.encodePacked(token.name())) == keccak256("Alchemic USD Base"));
        require(keccak256(abi.encodePacked(token.symbol())) == keccak256("alUSDb"));
        require(Ownable(alUSDb).owner() == newOwner);
        require(IERC20(alUSDb).balanceOf(newOwner) == 10 * 1e18); // must match mint amount
        require(token.hasRole(token.ADMIN_ROLE(), newOwner));
        require(token.hasRole(token.SENTINEL_ROLE(), newOwner));
        require(AlAsset(alUSDb).whitelisted(newOwner));
        require(!AlAsset(alUSDb).whitelisted(deployerAddr));
        require(!token.hasRole(token.ADMIN_ROLE(), deployerAddr));
        require(!token.hasRole(token.SENTINEL_ROLE(), deployerAddr));
    }
}
