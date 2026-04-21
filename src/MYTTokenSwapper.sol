// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";

interface IFluidATokenSwap {
    function swapToWstETH(uint256 amountIn, uint256 amountOutMin) external returns (uint256 amountOut);
    function getWstETHAmountOut(uint256 amountIn) external view returns (uint256);
    function maxSwapToWstETH() external view returns (uint256);
    function paused() external view returns (bool);
}

interface IAavePool {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPoolAddressProvider {
    function getPool() external view returns (address);
}

/// @title MYTTokenSwapper
/// @notice Temporary helper that can be installed as a strategy's allowance holder to migrate
/// `aEthWETH` into raw `wstETH` via Fluid followed by an Aave withdrawal.
/// @dev The source strategy calls this helper through `adminDexSwap()`, so `msg.sender` is the
/// strategy currently holding the approved `aEthWETH`. The helper completes the full flow and
/// forwards the resulting `wstETH` directly into a destination strategy that can hold it.
contract MYTTokenSwapper is Ownable {
    address public immutable aEthWETH;
    address public immutable aEthwstETH;
    address public immutable wstETH;
    IFluidATokenSwap public immutable fluidATokenSwap;
    IPoolAddressProvider public immutable poolProvider;
    bool public paused;

    event SwappedToWstethStrategy(
        address indexed sourceStrategy,
        address indexed destinationStrategy,
        uint256 amountIn,
        uint256 aEthwstETHOut,
        uint256 wstETHOut
    );
    event HelperPauseUpdated(bool paused);

    error InvalidAddress();
    error InvalidAmount();
    error FluidPaused();
    error HelperPaused();
    error MaxSwapExceeded(uint256 maxSwap, uint256 requested);
    error QuotedAmountTooLow(uint256 quotedAmountOut, uint256 minAmountOut);
    error AaveWithdrawTooLow(uint256 amountOut, uint256 minAmountOut);
    error DestinationEqualsSource();

    constructor(
        address _owner,
        address _aEthWETH,
        address _aEthwstETH,
        address _wstETH,
        address _fluidATokenSwap,
        address _poolProvider
    ) Ownable(_owner) {
        if (
            _owner == address(0)
                || _aEthWETH == address(0)
                || _aEthwstETH == address(0)
                || _wstETH == address(0)
                || _fluidATokenSwap == address(0)
                || _poolProvider == address(0)
        ) {
            revert InvalidAddress();
        }

        aEthWETH = _aEthWETH;
        aEthwstETH = _aEthwstETH;
        wstETH = _wstETH;
        fluidATokenSwap = IFluidATokenSwap(_fluidATokenSwap);
        poolProvider = IPoolAddressProvider(_poolProvider);
    }

    /// @notice Pull `aEthWETH` from the calling strategy, route it through Fluid into
    /// `aEthwstETH`, withdraw raw `wstETH` from Aave, and forward that `wstETH` to the destination
    /// strategy.
    /// @param amountIn The `aEthWETH` amount to migrate.
    /// @param minAethwstETHOut The minimum acceptable `aEthwstETH` output from Fluid.
    /// @param destinationStrategy The strategy that should receive the withdrawn `wstETH`.
    function swapAaveWethToWstethViaFluid(
        uint256 amountIn,
        uint256 minAethwstETHOut,
        address destinationStrategy
    ) external returns (uint256 wstETHOut) {
        address sourceStrategy = msg.sender;
        if (paused) revert HelperPaused();
        if (amountIn == 0 || minAethwstETHOut == 0) revert InvalidAmount();
        if (destinationStrategy == address(0)) revert InvalidAddress();
        if (destinationStrategy == sourceStrategy) revert DestinationEqualsSource();
        if (fluidATokenSwap.paused()) revert FluidPaused();

        uint256 maxSwap = fluidATokenSwap.maxSwapToWstETH();
        if (amountIn > maxSwap) revert MaxSwapExceeded(maxSwap, amountIn);

        uint256 quotedAmountOut = fluidATokenSwap.getWstETHAmountOut(amountIn);
        if (quotedAmountOut < minAethwstETHOut) revert QuotedAmountTooLow(quotedAmountOut, minAethwstETHOut);

        // Pull the source aToken from the strategy that approved this helper via adminDexSwap.
        TokenUtils.safeTransferFrom(aEthWETH, sourceStrategy, address(this), amountIn);

        // Approve only the exact amount for Fluid and clear it immediately after the swap.
        TokenUtils.safeApprove(aEthWETH, address(fluidATokenSwap), 0);
        TokenUtils.safeApprove(aEthWETH, address(fluidATokenSwap), amountIn);
        uint256 aEthwstETHOut = fluidATokenSwap.swapToWstETH(amountIn, minAethwstETHOut);
        TokenUtils.safeApprove(aEthWETH, address(fluidATokenSwap), 0);

        if (aEthwstETHOut < minAethwstETHOut) revert AaveWithdrawTooLow(aEthwstETHOut, minAethwstETHOut);

        // Withdraw the newly received aEthwstETH into raw wstETH on this helper.
        IAavePool pool = IAavePool(poolProvider.getPool());
        uint256 wstETHBeforeWithdraw = TokenUtils.safeBalanceOf(wstETH, address(this));
        uint256 wstETHWithdrawn = pool.withdraw(wstETH, aEthwstETHOut, address(this));
        uint256 wstETHAfterWithdraw = TokenUtils.safeBalanceOf(wstETH, address(this));
        wstETHOut = wstETHAfterWithdraw - wstETHBeforeWithdraw;
        if (wstETHWithdrawn < aEthwstETHOut || wstETHOut < aEthwstETHOut) {
            revert AaveWithdrawTooLow(wstETHOut, aEthwstETHOut);
        }

        // Forward all withdrawn wstETH directly into the destination strategy.
        TokenUtils.safeTransfer(wstETH, destinationStrategy, wstETHOut);
        emit SwappedToWstethStrategy(sourceStrategy, destinationStrategy, amountIn, aEthwstETHOut, wstETHOut);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit HelperPauseUpdated(_paused);
    }

    /// @notice Rescue non-core tokens that end up on this helper.
    function rescueTokens(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        TokenUtils.safeTransfer(token, recipient, amount);
    }
}
