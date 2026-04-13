// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAlchemistCurator {
    function increaseAbsoluteCap(address adapter, uint256 amount) external;
    function increaseRelativeCap(address adapter, uint256 amount) external;
    function submitIncreaseAbsoluteCap(address adapter, uint256 amount) external;
    function submitIncreaseRelativeCap(address adapter, uint256 amount) external;

    event IncreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitIncreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event IncreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitIncreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);

    function decreaseAbsoluteCap(address adapter, uint256 amount) external;

    event DecreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitDecreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);

    function decreaseRelativeCap(address adapter, uint256 amount) external;

    function submitSetAllocator(address myt, address allocator, bool v) external;
    event SubmitSetAllocator(address indexed allocator, bool indexed v);
    event DecreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitDecreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event StrategyAdded(address indexed strategy, address indexed myt);
    event StrategyRemoved(address indexed strategy, address indexed myt);
    event SubmitSetStrategy(address indexed strategy, address indexed myt);
    event SubmitRemoveStrategy(address indexed strategy, address indexed myt);

    function submitSetForceDeallocatePenalty(address adapter, address myt, uint256 penalty) external;
    event SubmitSetForceDeallocatePenalty(address indexed adapter, address indexed myt, uint256 penalty);

    function submitSetPerformanceFeeRecipient(address myt, address recipient) external;
    event SubmitSetPerformanceFeeRecipient(address indexed myt, address indexed recipient);

    function submitSetPerformanceFee(address myt, uint256 fee) external;
    event SubmitSetPerformanceFee(address indexed myt, uint256 fee);
}
