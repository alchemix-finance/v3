// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StrategyLaunchBase} from "./StrategyLaunchBase.s.sol";

/// @notice Launch batches for Ether.fi weETH on the mainnet ETH MYT, on the swap paths. Deploy the
///         strategy first with script/DeployEtherfiEETHStrategy.s.sol, then run with STRATEGY set.
contract LaunchEtherfiEETHStrategyScript is StrategyLaunchBase {
    function configPath() public pure override returns (string memory) {
        return "script/launch/etherfi-mainnet-weth.json";
    }
}
