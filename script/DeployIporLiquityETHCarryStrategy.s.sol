// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {IporFusionStrategy} from "../src/strategies/IporFusionStrategy.sol";

/// @notice Deploys the IPOR Fusion "rETH Liquity LP Carry" PlasmaVault strategy on Ethereum mainnet.
/// @dev Synchronous deposit/redeem only. Exits are bounded by the PlasmaVault's idle WETH; larger
///      unwinds require the async WithdrawManager flow, which this strategy version does not implement.
contract DeployIporLiquityETHCarryStrategyScript is Script {
    address public deployerAddr = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address public newOwner = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address public ethMYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    address public constant IPOR_PLASMA_VAULT = 0xB9E806e8f2d94c015ffefa90cD24Ecce18f1663C;
    address public constant IPOR_WITHDRAW_MANAGER = 0xe99b6ef767A42131263bDd3d4a0A7c16B32F0543;

    /// @dev Live withdraw fee is 0.2%; refuse to exit synchronously if governance raises it past 0.5%.
    uint256 public constant MAX_WITHDRAW_FEE = 5e15;
    /// @dev Extra shares redeemed to cover rounding and pre-redeem management fee realization.
    uint256 public constant REDEEM_BUFFER_BPS = 10;
    /// @dev Share-price deadband. About 3x the 6% carry, with a 50 bp catch-up cap.
    uint256 public constant BASE_BPS = 5;
    uint256 public constant UP_BPS_PER_DAY = 5;
    uint256 public constant DOWN_BPS_PER_DAY = 5;
    uint256 public constant MAX_UP_BPS = 50;
    uint256 public constant MAX_DOWN_BPS = 50;

    struct IporDeployConfig {
        address myt;
        address plasmaVault;
        address withdrawManager;
        uint256 maxWithdrawFee;
        uint256 redeemBufferBps;
        IporFusionStrategy.PriceGuardParams guard;
        IMYTStrategy.StrategyParams params;
    }

    function defaultParams() public view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: deployerAddr,
            name: "IPOR Fusion Liquity ETH Carry",
            protocol: "IPOR Fusion",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 100e18,
            globalCap: 0.1e18,
            estimatedYield: 300,
            additionalIncentives: false,
            slippageBPS: 20
        });
    }

    function defaultConfig() public view returns (IporDeployConfig memory) {
        return IporDeployConfig({
            myt: ethMYT,
            plasmaVault: IPOR_PLASMA_VAULT,
            withdrawManager: IPOR_WITHDRAW_MANAGER,
            maxWithdrawFee: MAX_WITHDRAW_FEE,
            redeemBufferBps: REDEEM_BUFFER_BPS,
            guard: IporFusionStrategy.PriceGuardParams({
                baseBps: BASE_BPS,
                upBpsPerDay: UP_BPS_PER_DAY,
                downBpsPerDay: DOWN_BPS_PER_DAY,
                maxUpBps: MAX_UP_BPS,
                maxDownBps: MAX_DOWN_BPS
            }),
            params: defaultParams()
        });
    }

    function deployIporStrategy(address targetOwner, IporDeployConfig memory config) public returns (address strategyAddr) {
        IporFusionStrategy strategy = new IporFusionStrategy(
            config.myt,
            config.params,
            config.plasmaVault,
            config.withdrawManager,
            config.maxWithdrawFee,
            config.redeemBufferBps,
            config.guard
        );
        strategyAddr = address(strategy);
        strategy.setKillSwitch(true);
        strategy.transferOwnership(targetOwner);
    }

    function run() public returns (address strategyAddr) {
        vm.startBroadcast(deployerAddr);
        strategyAddr = deployIporStrategy(newOwner, defaultConfig());
        vm.stopBroadcast();

        console.log("IPOR Fusion Liquity ETH Carry strategy deployed at:", strategyAddr);
    }
}
