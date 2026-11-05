// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {YieldBouncer} from "../src/utils/YieldBouncer.sol";
import {YieldBouncerUSD} from "../src/utils/YieldBouncerUSD.sol";
import {YieldBouncerETH} from "../src/utils/YieldBouncerETH.sol";
import {AaveV3RateSource} from "../src/utils/rates/AaveV3RateSource.sol";
import {EulerEVaultRateSource} from "../src/utils/rates/EulerEVaultRateSource.sol";
import {FluidFTokenRateSource} from "../src/utils/rates/FluidFTokenRateSource.sol";
import {MorphoVaultV2RateSource} from "../src/utils/rates/MorphoVaultV2RateSource.sol";
import {YearnV3RateSource} from "../src/utils/rates/YearnV3RateSource.sol";
import {TokemakAutopoolRateSource} from "../src/utils/rates/TokemakAutopoolRateSource.sol";
import {FluidLiteRateSource} from "../src/utils/rates/FluidLiteRateSource.sol";

/// @notice Deploys a YieldBouncerUSD (`--sig "runUSD()"`) or YieldBouncerETH (`--sig "runETH()"`)
///         against one mix's AlchemistAllocator, plus the rate sources named in YB_SOURCES
///         (one per protocol type per chain; skip any the chain already has). The deployer
///         stays owner and starts the two step handover to YB_NEW_OWNER, by default the
///         allocator's admin (slot 0, read live). The admin then calls
///         `setOperator(bouncer, true)`, `acceptOwnership()`, `setRateSource` per strategy
///         and `grantPair`.
///
///   YB_ALLOCATOR   required: the mix's AlchemistAllocator
///   YB_NEW_OWNER   optional: defaults to the allocator admin
///   YB_SOURCES     optional: comma list of aave,euler,fluid,fluidlite,morpho,tokemak,yearn
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
        address fluidlite;
    }

    function runUSD() external returns (Deployed memory deployed) {
        return _run(true);
    }

    function runETH() external returns (Deployed memory deployed) {
        return _run(false);
    }

    function deployUSD(address allocator, address newOwner, string[] memory sources)
        public
        returns (Deployed memory deployed)
    {
        return _deploy(new YieldBouncerUSD(allocator), newOwner, sources);
    }

    function deployETH(address allocator, address newOwner, string[] memory sources)
        public
        returns (Deployed memory deployed)
    {
        return _deploy(new YieldBouncerETH(allocator), newOwner, sources);
    }

    function allocatorAdmin(address allocator) public view returns (address) {
        return address(uint160(uint256(vm.load(allocator, bytes32(0)))));
    }

    function _run(bool usd) internal returns (Deployed memory deployed) {
        address allocator = vm.envAddress("YB_ALLOCATOR");
        address newOwner = vm.envOr("YB_NEW_OWNER", allocatorAdmin(allocator));
        string[] memory sources = vm.envOr("YB_SOURCES", ",", new string[](0));
        address deployer = vm.envOr("YB_DEPLOYER", address(0));

        if (deployer == address(0)) vm.startBroadcast();
        else vm.startBroadcast(deployer);
        deployed = usd ? deployUSD(allocator, newOwner, sources) : deployETH(allocator, newOwner, sources);
        vm.stopBroadcast();

        console.log(usd ? "YieldBouncerUSD:" : "YieldBouncerETH:", deployed.bouncer);
        console.log("pending owner:", newOwner);
        if (deployed.aave != address(0)) console.log("AaveV3RateSource:", deployed.aave);
        if (deployed.euler != address(0)) console.log("EulerEVaultRateSource:", deployed.euler);
        if (deployed.fluid != address(0)) console.log("FluidFTokenRateSource:", deployed.fluid);
        if (deployed.morpho != address(0)) console.log("MorphoVaultV2RateSource:", deployed.morpho);
        if (deployed.yearn != address(0)) console.log("YearnV3RateSource:", deployed.yearn);
        if (deployed.tokemak != address(0)) console.log("TokemakAutopoolRateSource:", deployed.tokemak);
        if (deployed.fluidlite != address(0)) console.log("FluidLiteRateSource:", deployed.fluidlite);
    }

    function _deploy(YieldBouncer bouncer, address newOwner, string[] memory sources)
        internal
        returns (Deployed memory deployed)
    {
        bouncer.transferOwnership(newOwner);
        deployed.bouncer = address(bouncer);
        for (uint256 index = 0; index < sources.length; index++) {
            bytes32 source = keccak256(bytes(sources[index]));
            if (source == keccak256("aave")) deployed.aave = address(new AaveV3RateSource());
            else if (source == keccak256("euler")) deployed.euler = address(new EulerEVaultRateSource());
            else if (source == keccak256("fluid")) deployed.fluid = address(new FluidFTokenRateSource());
            else if (source == keccak256("morpho")) deployed.morpho = address(new MorphoVaultV2RateSource());
            else if (source == keccak256("yearn")) deployed.yearn = address(new YearnV3RateSource());
            else if (source == keccak256("tokemak")) deployed.tokemak = address(new TokemakAutopoolRateSource());
            else if (source == keccak256("fluidlite")) deployed.fluidlite = address(new FluidLiteRateSource());
            else revert(string.concat("unknown rate source: ", sources[index]));
        }
    }
}
