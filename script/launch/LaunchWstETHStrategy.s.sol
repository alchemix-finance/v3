// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StrategyLaunchBase} from "./StrategyLaunchBase.s.sol";

/// @notice Launch batches for wstETH on the mainnet ETH MYT: swap paths, no ladder, small pilot clips.
///         Deploy the strategy first with script/DeployWstETHEthereumStrategy.s.sol, then run with STRATEGY set.
contract LaunchWstETHStrategyScript is StrategyLaunchBase {
    function configPath() public pure override returns (string memory) {
        return "script/launch/wsteth-mainnet-weth.json";
    }
}
