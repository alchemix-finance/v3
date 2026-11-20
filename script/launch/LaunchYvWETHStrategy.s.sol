// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StrategyLaunchBase} from "./StrategyLaunchBase.s.sol";

/// @notice Launch batches for Yearn WETH-1 on the mainnet ETH MYT, on the direct paths. Deploy the
///         strategy first with script/DeployYvWETHStrategy.s.sol, then run with STRATEGY set.
contract LaunchYvWETHStrategyScript is StrategyLaunchBase {
    function configPath() public pure override returns (string memory) {
        return "script/launch/yvweth-mainnet-weth.json";
    }
}
