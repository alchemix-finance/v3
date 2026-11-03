// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {YieldBouncer} from "../src/utils/YieldBouncer.sol";
import {AaveV3RateSource} from "../src/utils/rates/AaveV3RateSource.sol";
import {EulerEVaultRateSource} from "../src/utils/rates/EulerEVaultRateSource.sol";
import {FluidFTokenRateSource} from "../src/utils/rates/FluidFTokenRateSource.sol";
import {MorphoVaultV2RateSource} from "../src/utils/rates/MorphoVaultV2RateSource.sol";
import {YearnV3RateSource} from "../src/utils/rates/YearnV3RateSource.sol";
import {TokemakAutopoolRateSource} from "../src/utils/rates/TokemakAutopoolRateSource.sol";

/// @notice Deploys a YieldBouncer against any mix's AlchemistAllocator, plus the rate
///         sources named in YB_SOURCES (one per protocol type per chain; skip any the
///         chain already has). The deployer stays owner and starts the two-step
///         handover to YB_NEW_OWNER, by default the allocator's admin (slot 0, read
///         live). The admin then calls `setOperator(bouncer, true)`, `acceptOwnership()`,
///         `setRateSource` per strategy and `grantPair`.
///
///   YB_ALLOCATOR   required: the mix's AlchemistAllocator
///   YB_NEW_OWNER   optional: defaults to the allocator admin
///   YB_SOURCES     optional: comma list of aave,euler,fluid,morpho,tokemak,yearn
///   YB_DEPLOYER    optional: broadcast from this address (else forge's sender)
contract DeployYieldBouncerScript is Script {
    struct Deployed {
        address bouncer;
        address aave;
        address euler;
        address fluid;
        address morpho;
        address yearn;
        address tokemak;
    }

    function deploy(address allocator, address newOwner, string[] memory sources) public returns (Deployed memory d) {
        YieldBouncer bouncer = new YieldBouncer(allocator);
        bouncer.transferOwnership(newOwner);
        d.bouncer = address(bouncer);
        for (uint256 i = 0; i < sources.length; i++) {
            bytes32 s = keccak256(bytes(sources[i]));
            if (s == keccak256("aave")) d.aave = address(new AaveV3RateSource());
            else if (s == keccak256("euler")) d.euler = address(new EulerEVaultRateSource());
            else if (s == keccak256("fluid")) d.fluid = address(new FluidFTokenRateSource());
            else if (s == keccak256("morpho")) d.morpho = address(new MorphoVaultV2RateSource());
            else if (s == keccak256("yearn")) d.yearn = address(new YearnV3RateSource());
            else if (s == keccak256("tokemak")) d.tokemak = address(new TokemakAutopoolRateSource());
            else revert(string.concat("unknown rate source: ", sources[i]));
        }
    }

    function allocatorAdmin(address allocator) public view returns (address) {
        return address(uint160(uint256(vm.load(allocator, bytes32(0)))));
    }

    function run() public returns (Deployed memory d) {
        address allocator = vm.envAddress("YB_ALLOCATOR");
        address newOwner = vm.envOr("YB_NEW_OWNER", allocatorAdmin(allocator));
        string[] memory sources = vm.envOr("YB_SOURCES", ",", new string[](0));
        address deployer = vm.envOr("YB_DEPLOYER", address(0));

        if (deployer == address(0)) vm.startBroadcast();
        else vm.startBroadcast(deployer);
        d = deploy(allocator, newOwner, sources);
        vm.stopBroadcast();

        console.log("YieldBouncer:", d.bouncer);
        console.log("pending owner:", newOwner);
        if (d.aave != address(0)) console.log("AaveV3RateSource:", d.aave);
        if (d.euler != address(0)) console.log("EulerEVaultRateSource:", d.euler);
        if (d.fluid != address(0)) console.log("FluidFTokenRateSource:", d.fluid);
        if (d.morpho != address(0)) console.log("MorphoVaultV2RateSource:", d.morpho);
        if (d.yearn != address(0)) console.log("YearnV3RateSource:", d.yearn);
        if (d.tokemak != address(0)) console.log("TokemakAutopoolRateSource:", d.tokemak);
    }
}
