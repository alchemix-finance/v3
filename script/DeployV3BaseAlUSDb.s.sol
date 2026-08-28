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
    address deployerAddr = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // FIXME anvil #0

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
        alAssetProxy.transferOwnership(newOwner);
        return address(alAssetProxy);
    }

    function run() public {
        vm.startBroadcast(deployerAddr);

        // Deploy alAsset
        alUSDb = deployAlAsset("Alchemic USD Base", "alUSDb");

        vm.stopBroadcast();

        // Output deployment addresses
        console.log("alUSDb deployed at:", alUSDb);

        console.log("----------- IMPORTANT -----------");
        console.log("- Run DeployV3Base with ALUSDB_ADDRESS set to the address above!");
        console.log("- Deployer intentionally keeps ADMIN_ROLE and mint whitelist for the handoff in DeployV3Base!");

        require(Ownable(alUSDb).owner() == newOwner);
        require(IERC20(alUSDb).balanceOf(newOwner) == 10 * 1e18);
        require(AlAsset(alUSDb).whitelisted(deployerAddr));
        require(AlAsset(alUSDb).whitelisted(newOwner));
    }
}
