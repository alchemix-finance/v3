// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldBouncer} from "./YieldBouncer.sol";

/// @title YieldBouncerUSD
/// @notice YieldBouncer for a USD denominated MYT (USDC, DAI, ...): at most 200,000 per day from its liquidity adapter.
contract YieldBouncerUSD is YieldBouncer {
    uint256 public constant LIQ_ADAPTER_USD_MAX = 200_000;

    constructor(address _allocator) YieldBouncer(_allocator, LIQ_ADAPTER_USD_MAX) {}
}
