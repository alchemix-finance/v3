// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ClipAllocator} from "../src/utils/ClipAllocator.sol";

/// @notice Deploys ClipAllocator against the mainnet ETH AlchemistAllocator.
///         The deployer stays owner and starts the two-step handover to `newOwner`.
///         Making the clip an operator is a separate allocator-admin call:
///         `setOperator(clip, true)`.
contract DeployClipAllocatorScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public ethAllocator = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;

    function deployClipAllocator(address allocator) public returns (ClipAllocator clip) {
        clip = new ClipAllocator(allocator);
        clip.transferOwnership(newOwner);
    }

    function run() public returns (address clipAddr) {
        vm.startBroadcast(deployerAddr);
        clipAddr = address(deployClipAllocator(ethAllocator));
        vm.stopBroadcast();

        console.log("ClipAllocator deployed at:", clipAddr);
    }
}
