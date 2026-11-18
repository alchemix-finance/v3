// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StrategyLaunchBase} from "./StrategyLaunchBase.s.sol";

/// @notice Launch batches for SiUSD on the mainnet USDC MYT. Deploy the strategy first
///         with script/DeploySiUSDStrategies.s.sol, then run with STRATEGY set.
contract LaunchSiUSDStrategyScript is StrategyLaunchBase {
    function configPath() public pure override returns (string memory) {
        return "script/launch/siusd-mainnet-usdc.json";
    }
}
