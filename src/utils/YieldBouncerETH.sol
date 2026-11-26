// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldBouncer} from "./YieldBouncer.sol";

/// @title YieldBouncerETH
/// @notice YieldBouncer for an ETH denominated MYT (WETH): at most 50 per day from its liquidity adapter.
contract YieldBouncerETH is YieldBouncer {
    uint256 public constant LIQ_ADAPTER_ETH_MAX = 50;

    constructor(address _allocator) YieldBouncer(_allocator, LIQ_ADAPTER_ETH_MAX) {}
}
