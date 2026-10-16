// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {FluidLiteETHStrategy} from "../src/strategies/FluidLiteETHStrategy.sol";

/// @notice Reusable deploy helper for the Fluid Lite iETHv2 (leveraged stETH) strategy on Ethereum mainnet.
contract DeployFluidLiteETHStrategyScript is Script {
    address self = address(this);
    address deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;

    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public curatorAddr = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant FLUID_LITE_ETH_VAULT = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78; // iETHv2
    address public constant LIDO_WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    struct FluidLiteETHDeployConfig {
        address myt;
        address fluidLiteVault;
        address stETH;
        address withdrawalQueue;
        IMYTStrategy.StrategyParams params;
        FluidLiteETHStrategy.PriceGuardParams priceGuard;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "Fluid Lite Mainnet ETH",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 25e18,
            globalCap: 0.1e18,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    /// @dev Calibrated against iETHv2 `LogUpdateExchangePrice` history, blocks 23_561_624..26_154_825
    ///      (~360 days, 835 updates, +336 bp total). The PPS the guard reads (`previewRedeem`) is the
    ///      stored `exchangePrice`, which only the Instadapp rebalancer moves; user deposits/withdrawals
    ///      do not touch it, and it sits flat between updates (median gap 0.3 h, p95 24 h, max 30 d).
    ///      Realized moves:
    ///        up:   avg 1.2 bp/day, worst 1 d +4.2 bp, worst single update +4.8 bp,
    ///              worst 7 d +16.2 bp (2.3/day), worst 30 d +54 bp (1.8/day)
    ///        down: worst single update -1.9 bp, worst 1 d -0.6 bp, max peak-to-trough 2.2 bp,
    ///              no 3-day window ever negative
    ///      baseBps 50:       ~10x the worst up step, ~22x the worst drawdown, and covers a 30-day
    ///                        stale-mark catch-up at the advertised ~1.5 bp/day.
    ///      upBpsPerDay 10:   ~2x the worst observed day and ~8x the average, so the anchor tracks live
    ///                        without owner action up to ~36%/yr; a lagging anchor only clamps NAV down.
    ///      downBpsPerDay 2:  ~3x the worst observed down day; anything faster goes through `acceptPrice`.
    ///      maxUpBps 200:     ceiling on NAV over anchor; at realized drift it takes ~165 unpoked days
    ///                        to reach, and one `poke` then re-anchors (room = min(cap, 10/day * elapsed)).
    ///      maxDownBps 100:   floor can never sit more than 1% under the anchor regardless of staleness.
    function defaultPriceGuard() public pure returns (FluidLiteETHStrategy.PriceGuardParams memory) {
        return FluidLiteETHStrategy.PriceGuardParams({baseBps: 50, upBpsPerDay: 10, downBpsPerDay: 2, maxUpBps: 200, maxDownBps: 100});
    }

    function deployFluidLiteETHStrategy(
        AlchemistCurator curator,
        address targetOwner,
        FluidLiteETHDeployConfig memory config
    ) public returns (address strategyAddr) {
        curator;
        FluidLiteETHStrategy strategy = new FluidLiteETHStrategy(
            config.myt, config.params, config.fluidLiteVault, config.stETH, config.withdrawalQueue, config.priceGuard
        );
        strategyAddr = address(strategy);
        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        AlchemistCurator curator = AlchemistCurator(curatorAddr);

        FluidLiteETHDeployConfig memory config = FluidLiteETHDeployConfig({
            myt: ethMYT,
            fluidLiteVault: FLUID_LITE_ETH_VAULT,
            stETH: STETH,
            withdrawalQueue: LIDO_WITHDRAWAL_QUEUE,
            params: defaultParams(),
            priceGuard: defaultPriceGuard()
        });

        vm.startBroadcast(deployerAddr);
        strategyAddr = deployFluidLiteETHStrategy(curator, newOwner, config);
        vm.stopBroadcast();

        console.log("Fluid Lite ETH Strategy deployed at:", strategyAddr);
    }
}
