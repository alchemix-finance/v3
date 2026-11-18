// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlchemistCurator} from "../../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../src/AlchemistStrategyClassifier.sol";
import {MYTStrategy} from "../../src/MYTStrategy.sol";
import {IMYTStrategy} from "../../src/interfaces/IMYTStrategy.sol";
import {ClipAllocator} from "../../src/utils/ClipAllocator.sol";
import {StrategyLauncher} from "../../src/utils/StrategyLauncher.sol";

/// @notice Reads one launch JSON and builds the two Safe batches for an already deployed
///         strategy. Each launch script names its JSON. `run` writes Transaction Builder files.
abstract contract StrategyLaunchBase is Script {
    using stdJson for string;

    struct Call {
        address to;
        bytes data;
        string label;
    }

    struct Contracts {
        address safe;
        address myt;
        address curator;
        address classifier;
        address allocator;
        address probe;
        address clip;
        address launcher;
        address liquidityAdapter;
    }

    struct Grant {
        uint256 amount;
        uint256 maxClip;
        uint32 minIntervalBlocks;
        address priceToken;
        uint256 limitRate;
        uint16 maxLossBps;
    }

    struct Config {
        string name;
        uint256 chainId;
        Contracts c;
        address strategy;
        uint8 riskClass;
        uint256 absoluteCap;
        uint256 relativeCap;
        uint256 forceDeallocatePenalty;
        uint256 probeToleranceBps;
        StrategyLauncher.Plan plan;
        Grant pilot;
        Grant liquidity;
        bool liquidityTopUp;
        uint256 scaleAbsoluteCap;
        uint256 scaleManualAllocate;
    }

    function configPath() public view virtual returns (string memory);

    function loadConfig() public view returns (Config memory cfg) {
        string memory json = vm.readFile(configPath());
        cfg.name = json.readString(".name");
        cfg.chainId = json.readUint(".chainId");
        cfg.c = Contracts({
            safe: json.readAddress(".contracts.safe"),
            myt: json.readAddress(".contracts.myt"),
            curator: json.readAddress(".contracts.curator"),
            classifier: json.readAddress(".contracts.classifier"),
            allocator: json.readAddress(".contracts.allocator"),
            probe: json.readAddress(".contracts.probe"),
            clip: json.readAddress(".contracts.clip"),
            launcher: json.readAddress(".contracts.launcher"),
            liquidityAdapter: json.readAddress(".contracts.liquidityAdapter")
        });
        cfg.strategy = json.readAddress(".strategy.address");
        cfg.riskClass = uint8(json.readUint(".strategy.riskClass"));
        cfg.absoluteCap = _uint(json, ".caps.absoluteCap");
        cfg.relativeCap = _uint(json, ".caps.relativeCap");
        cfg.forceDeallocatePenalty = _uint(json, ".caps.forceDeallocatePenalty");
        cfg.probeToleranceBps = _uint(json, ".probe.toleranceBps");
        cfg.plan = _plan(json, cfg.c.myt);
        cfg.pilot = _grant(json, ".pilot", ".maxAllocate");
        cfg.liquidity = _grant(json, ".liquidityGrant", ".amount");
        cfg.liquidityTopUp = keccak256(bytes(json.readString(".liquidityGrant.mode"))) == keccak256("topUp");
        cfg.scaleAbsoluteCap = _uint(json, ".scale.absoluteCap");
        cfg.scaleManualAllocate = _uint(json, ".scale.manualAllocate");
    }

    /// @notice Register, cap at the pilot level, turn allocation on, grant the launcher, open the launch.
    function batch1(Config memory cfg, address strategy) public view returns (Call[] memory calls) {
        bool swapLadder = !cfg.plan.useProbe;
        calls = new Call[](swapLadder ? 13 : 12);
        AlchemistCurator curator = AlchemistCurator(cfg.c.curator);
        uint256 i;
        calls[i++] = Call(address(curator), abi.encodeCall(curator.submitSetStrategy, (strategy, cfg.c.myt)), "submitSetStrategy");
        calls[i++] = Call(address(curator), abi.encodeCall(curator.setStrategy, (strategy, cfg.c.myt)), "setStrategy");
        calls[i++] = Call(
            address(curator), abi.encodeCall(curator.submitIncreaseAbsoluteCap, (strategy, cfg.absoluteCap)), "submitIncreaseAbsoluteCap"
        );
        calls[i++] = Call(address(curator), abi.encodeCall(curator.increaseAbsoluteCap, (strategy, cfg.absoluteCap)), "increaseAbsoluteCap");
        calls[i++] = Call(
            address(curator), abi.encodeCall(curator.submitIncreaseRelativeCap, (strategy, cfg.relativeCap)), "submitIncreaseRelativeCap"
        );
        calls[i++] = Call(address(curator), abi.encodeCall(curator.increaseRelativeCap, (strategy, cfg.relativeCap)), "increaseRelativeCap");
        calls[i++] = Call(
            address(curator),
            abi.encodeCall(curator.submitSetForceDeallocatePenalty, (strategy, cfg.c.myt, cfg.forceDeallocatePenalty)),
            "submitSetForceDeallocatePenalty"
        );
        calls[i++] = Call(
            cfg.c.classifier,
            abi.encodeCall(
                AlchemistStrategyClassifier.assignStrategyRiskLevel, (uint256(IMYTStrategy(strategy).adapterId()), cfg.riskClass)
            ),
            "assignStrategyRiskLevel"
        );
        calls[i++] = Call(strategy, abi.encodeCall(MYTStrategy.setKillSwitch, (false)), "setKillSwitch(false)");

        Grant memory p = cfg.pilot;
        uint256 allocateBudget = p.amount + (swapLadder ? uint256(cfg.plan.smallLeg) + cfg.plan.largeLeg : 0);
        calls[i++] = Call(
            cfg.c.clip,
            abi.encodeCall(
                ClipAllocator.grantAllocate,
                (cfg.c.launcher, strategy, allocateBudget, p.maxClip, p.minIntervalBlocks, p.priceToken, p.limitRate, p.maxLossBps)
            ),
            "grantAllocate(launcher, strategy)"
        );
        if (swapLadder) {
            uint256 legs = uint256(cfg.plan.smallLeg) + cfg.plan.largeLeg;
            calls[i++] = Call(
                cfg.c.clip,
                abi.encodeCall(
                    ClipAllocator.grantDeallocate,
                    (cfg.c.launcher, strategy, legs, cfg.plan.largeLeg, 0, p.priceToken, p.limitRate, p.maxLossBps)
                ),
                "grantDeallocate(launcher, strategy)"
            );
        }
        calls[i++] = _liquidityGrant(cfg);
        calls[i++] =
            Call(cfg.c.launcher, abi.encodeCall(StrategyLauncher.registerLaunch, (strategy, cfg.plan)), "registerLaunch");
    }

    /// @notice After the pilot review: raise the cap, close the launcher's budget, allocate, graduate.
    ///         The manual allocation is direct, so swap strategies drop the last two allocator calls.
    function batch2(Config memory cfg, address strategy) public view returns (Call[] memory calls) {
        bool direct = cfg.plan.allocMode == StrategyLauncher.Mode.Direct;
        calls = new Call[](direct ? 6 : 4);
        AlchemistCurator curator = AlchemistCurator(cfg.c.curator);
        uint256 i;
        calls[i++] = Call(
            address(curator),
            abi.encodeCall(curator.submitIncreaseAbsoluteCap, (strategy, cfg.scaleAbsoluteCap)),
            "submitIncreaseAbsoluteCap"
        );
        calls[i++] =
            Call(address(curator), abi.encodeCall(curator.increaseAbsoluteCap, (strategy, cfg.scaleAbsoluteCap)), "increaseAbsoluteCap");
        calls[i++] = Call(cfg.c.clip, abi.encodeCall(ClipAllocator.revokeAllocate, (cfg.c.launcher, strategy)), "revokeAllocate");
        if (direct) {
            calls[i++] = Call(
                cfg.c.allocator,
                abi.encodeCall(AlchemistAllocator.deallocate, (cfg.c.liquidityAdapter, cfg.scaleManualAllocate)),
                "deallocate(liquidityAdapter)"
            );
            calls[i++] = Call(
                cfg.c.allocator, abi.encodeCall(AlchemistAllocator.allocate, (strategy, cfg.scaleManualAllocate)), "allocate(strategy)"
            );
        }
        calls[i++] = Call(cfg.c.launcher, abi.encodeCall(StrategyLauncher.graduate, (strategy)), "graduate");
    }

    /// @notice Write both batches for STRATEGY (or the JSON's strategy.address) next to the JSON.
    function run() public virtual {
        Config memory cfg = loadConfig();
        address strategy = vm.envOr("STRATEGY", cfg.strategy);
        require(strategy != address(0), "set STRATEGY or strategy.address");
        require(cfg.c.probe != address(0) && cfg.c.clip != address(0) && cfg.c.launcher != address(0), "fill probe, clip, launcher");

        console.log("plan hash");
        console.logBytes32(keccak256(abi.encode(cfg.plan)));
        _writeSafeBatch(cfg, batch1(cfg, strategy), "batch1");
        _writeSafeBatch(cfg, batch2(cfg, strategy), "batch2");
    }

    function _liquidityGrant(Config memory cfg) internal pure returns (Call memory) {
        Grant memory g = cfg.liquidity;
        if (cfg.liquidityTopUp) {
            return Call(
                cfg.c.clip,
                abi.encodeCall(ClipAllocator.topUpDeallocate, (cfg.c.launcher, cfg.c.liquidityAdapter, g.amount)),
                "topUpDeallocate(launcher, liquidityAdapter)"
            );
        }
        return Call(
            cfg.c.clip,
            abi.encodeCall(
                ClipAllocator.grantDeallocate,
                (cfg.c.launcher, cfg.c.liquidityAdapter, g.amount, g.maxClip, g.minIntervalBlocks, g.priceToken, g.limitRate, g.maxLossBps)
            ),
            "grantDeallocate(launcher, liquidityAdapter)"
        );
    }

    /// @dev Safe Transaction Builder format, written to script/launch/out/<name>.<suffix>.json.
    function _writeSafeBatch(Config memory cfg, Call[] memory calls, string memory suffix) internal {
        string memory txs = "[";
        for (uint256 i; i < calls.length; i++) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '"}'
            );
            console.log(i + 1, calls[i].label, calls[i].to);
        }
        string memory body = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(cfg.chainId),
            '","meta":{"name":"',
            cfg.name,
            " ",
            suffix,
            '"},"transactions":',
            txs,
            "]}"
        );
        string memory path = string.concat("script/launch/out/", cfg.name, ".", suffix, ".json");
        vm.createDir("script/launch/out", true);
        vm.writeFile(path, body);
        console.log("wrote", path);
    }

    function _plan(string memory json, address myt) internal pure returns (StrategyLauncher.Plan memory plan) {
        bool useProbe = json.readBool(".strategy.useProbe");
        string memory legs = useProbe ? ".probe" : ".swapLadder";
        plan = StrategyLauncher.Plan({
            myt: myt,
            useProbe: useProbe,
            allocMode: _mode(json.readString(".strategy.allocate")),
            deallocMode: _mode(json.readString(".strategy.deallocate")),
            smallLeg: uint128(_uint(json, string.concat(legs, ".smallLeg"))),
            largeLeg: uint128(_uint(json, string.concat(legs, ".largeLeg"))),
            exitBufferBps: uint16(_uint(json, string.concat(legs, ".exitBufferBps"))),
            pilotMax: _uint(json, ".pilot.maxAllocate")
        });
    }

    function _grant(string memory json, string memory key, string memory amountKey) internal pure returns (Grant memory g) {
        g.amount = _uint(json, string.concat(key, amountKey));
        g.maxClip = _uint(json, string.concat(key, ".maxClip"));
        g.minIntervalBlocks = uint32(json.readUint(string.concat(key, ".minIntervalBlocks")));
        g.priceToken = json.readAddress(string.concat(key, ".priceToken"));
        g.limitRate = _uint(json, string.concat(key, ".limitRate"));
        g.maxLossBps = uint16(json.readUint(string.concat(key, ".maxLossBps")));
    }

    function _uint(string memory json, string memory key) internal pure returns (uint256) {
        return vm.parseUint(json.readString(key));
    }

    function _mode(string memory name) internal pure returns (StrategyLauncher.Mode) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("direct")) return StrategyLauncher.Mode.Direct;
        if (h == keccak256("swap")) return StrategyLauncher.Mode.Swap;
        if (h == keccak256("unwrapAndSwap")) return StrategyLauncher.Mode.UnwrapAndSwap;
        revert("unknown mode");
    }
}
