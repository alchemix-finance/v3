// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @dev Minimal surface of the Fluid Lite iETHv2 vault.
interface IFluidLiteETHVault {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    /// @notice Percentage withdraw fee, scaled to 1e6 (1% == 10_000).
    function withdrawalFeePercentage() external view returns (uint256);
    /// @notice Absolute minimum withdraw fee in stETH.
    function withdrawFeeAbsoluteMin() external view returns (uint256);
    /// @notice max(percentage fee, absolute minimum) for a given stETH withdrawal.
    function getWithdrawFee(uint256 stETHAmount) external view returns (uint256);
}

/**
 * @title FluidLiteETHStrategy
 * @notice Allocates WETH into the Fluid Lite iETHv2 vault (leveraged stETH/weETH loop) via stETH.
 *
 * Allocation (swap only):
 *  - WETH -> stETH on a dex (oracle-bounded), deposit stETH into iETHv2.
 *
 * Deallocation (unwrapAndSwap only):
 *  - withdraw stETH from iETHv2 (grossed up for the vault's withdraw fee), then stETH -> WETH on a dex.
 */
contract FluidLiteETHStrategy is OraclePricedSwapStrategy {
    uint256 internal constant FEE_SCALE = 1e6;
    /// @dev Lido stETH transfers can under deliver by 1-2 wei. request slightly more to still clear `minStETHOut`.
    uint256 internal constant STETH_ROUNDING_BUFFER = 2;

    IFluidLiteETHVault public immutable iETH;
    IERC20 public immutable stETH;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _iETH,
        address _stETH,
        address _stEthEthOracle,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _stEthEthOracle, _maxOracleStaleness) {
        require(_iETH != address(0), "Zero iETH address");
        require(_stETH != address(0), "Zero stETH address");
        require(IFluidLiteETHVault(_iETH).asset() == _stETH, "iETH asset != stETH");

        iETH = IFluidLiteETHVault(_iETH);
        stETH = IERC20(_stETH);
    }

    /// @dev Direct allocation is intentionally unsupported: the base `_allocate(uint256)` reverts
    ///      `ActionNotSupported`, so WETH only enters through the oracle bounded swap path.
    function _afterAllocationSwap(uint256 oracleTokenReceived) internal override {
        _depositIntoVault(oracleTokenReceived);
    }

    function _depositIntoVault(uint256 stETHAmount) internal {
        TokenUtils.safeApprove(address(stETH), address(iETH), stETHAmount);
        uint256 sharesReceived = iETH.deposit(stETHAmount, address(this));
        TokenUtils.safeApprove(address(stETH), address(iETH), 0);
        require(sharesReceived > 0, "No iETHv2 received");
    }

    /// @dev One-hop swap path is disabled: it cannot account for the vault's withdraw fee or idle liquidity.
    function _deallocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _prepareOracleTokenForSwap(uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _prepareIntermediateForSwap(uint256 maxOracleTokenIn, uint256 minStETHOut)
        internal
        override
        returns (address sellToken, uint256 sellAmount)
    {
        require(minStETHOut > 0, "Invalid intermediate amount");
        require(minStETHOut <= maxOracleTokenIn, "Intermediate exceeds max oracle token in");

        uint256 stETHBefore = stETH.balanceOf(address(this));

        // Any raw stETH already held is sold first. only the remainder is pulled from the vault.
        if (stETHBefore < minStETHOut) {
            uint256 needed = minStETHOut - stETHBefore;
            uint256 grossRequest = _grossUpForWithdrawFee(needed) + STETH_ROUNDING_BUFFER;

            require(grossRequest <= maxOracleTokenIn, "Fee pushes request over max");
            require(grossRequest <= iETH.maxWithdraw(address(this)), "Insufficient iETHv2 balance");
            require(grossRequest <= stETH.balanceOf(address(iETH)), "Vault idle stETH too low");

            iETH.withdraw(grossRequest, address(this), address(this));
        }

        sellAmount = stETH.balanceOf(address(this));
        require(sellAmount >= minStETHOut, "Insufficient intermediate out");
        sellToken = address(stETH);
    }

    /// @dev Smallest `gross` such that `gross - getWithdrawFee(gross) >= net`.
    function _grossUpForWithdrawFee(uint256 net) internal view returns (uint256 gross) {
        uint256 feePct = iETH.withdrawalFeePercentage();
        require(feePct < FEE_SCALE, "Invalid withdraw fee");

        gross = (net * FEE_SCALE + (FEE_SCALE - feePct) - 1) / (FEE_SCALE - feePct);

        uint256 withAbsoluteMin = net + iETH.withdrawFeeAbsoluteMin();
        if (withAbsoluteMin > gross) gross = withAbsoluteMin;

        require(gross - iETH.getWithdrawFee(gross) >= net, "Withdraw fee gross-up failed");
    }

    function _oracleToken() internal view override returns (address) {
        return address(stETH);
    }

    function _positionBalance() internal view override returns (uint256) {
        return stETH.balanceOf(address(this)) + iETH.previewRedeem(iETH.balanceOf(address(this)));
    }

    /// @dev Like the base, but also deducts the vault withdraw fee and clamps to the vault's idle stETH,
    ///      since withdrawals beyond that buffer revert inside iETHv2.
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (amount <= idleBalance) return amount;

        uint256 remaining = amount - idleBalance;

        uint256 rawStETH = stETH.balanceOf(address(this));
        uint256 vaultValue = iETH.previewRedeem(iETH.balanceOf(address(this)));
        uint256 vaultLiquidity = stETH.balanceOf(address(iETH));
        uint256 fromVault = vaultValue < vaultLiquidity ? vaultValue : vaultLiquidity;
        uint256 netFromVault = fromVault - iETH.getWithdrawFee(fromVault);

        uint256 maxAsset = _oracleTokenToAsset(rawStETH + netFromVault);
        uint256 fundableFromPosition = remaining <= maxAsset ? remaining : maxAsset;
        return idleBalance + (fundableFromPosition * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == _asset() || token == address(stETH) || token == address(iETH);
    }
}
