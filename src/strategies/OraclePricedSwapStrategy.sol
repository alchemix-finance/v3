// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

abstract contract OraclePricedSwapStrategy is MYTStrategy {
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;

    AggregatorV3Interface public immutable pricedTokenEthOracle;
    uint8 public immutable pricedTokenEthOracleDecimals;

    constructor(address _myt, StrategyParams memory _params, address _pricedTokenEthOracle) MYTStrategy(_myt, _params) {
        require(_pricedTokenEthOracle != address(0), "Zero oracle address");

        pricedTokenEthOracle = AggregatorV3Interface(_pricedTokenEthOracle);
        pricedTokenEthOracleDecimals = pricedTokenEthOracle.decimals();
    }

    function _allocate(uint256 amount, bytes memory callData) internal virtual override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 minOracleTokenOut = _assetToOracleTokenDown((amount * (10_000 - params.slippageBPS)) / 10_000);
        if (minOracleTokenOut == 0) minOracleTokenOut = 1;

        uint256 oracleTokenReceived = dexSwap(_oracleToken(), _asset(), amount, minOracleTokenOut, callData);
        _allocationSwapGuard(amount, minOracleTokenOut, oracleTokenReceived);
        _afterAllocationSwap(oracleTokenReceived);
        return amount;
    }

    function _deallocate(uint256 amount, bytes memory callData) internal virtual override returns (uint256) {
        return _deallocateViaOracleTokenSwap(amount, callData);
    }

    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount)
        internal
        virtual
        override
        returns (uint256)
    {
        return _deallocateViaUnwrapAndSwap(amount, callData, minIntermediateOutAmount);
    }

    function _deallocateViaOracleTokenSwap(uint256 amount, bytes memory callData) internal returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 maxAssetIn = _roundUpMulDiv(shortfall, 10_000, 10_000 - params.slippageBPS);
        uint256 maxOracleTokenIn = _assetToOracleTokenUp(maxAssetIn);
        if (maxOracleTokenIn == 0) maxOracleTokenIn = 1;

        uint256 oracleTokenToSwap = _prepareOracleTokenForSwap(maxOracleTokenIn);
        require(oracleTokenToSwap > 0, "No oracle token to swap");

        dexSwap(_asset(), _oracleToken(), oracleTokenToSwap, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _deallocateViaUnwrapAndSwap(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount)
        internal
        returns (uint256)
    {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 maxAssetIn = _roundUpMulDiv(shortfall, 10_000, 10_000 - params.slippageBPS);
        uint256 maxOracleTokenIn = _assetToOracleTokenUp(maxAssetIn);
        if (maxOracleTokenIn == 0) maxOracleTokenIn = 1;

        (address sellToken, uint256 sellAmount) = _prepareIntermediateForSwap(maxOracleTokenIn, minIntermediateOutAmount);
        require(sellToken != address(0), "No intermediate token");
        require(sellAmount > 0, "No intermediate amount");

        dexSwap(_asset(), sellToken, sellAmount, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        return _idleAssets() + _oracleTokenToAsset(_positionBalance());
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(_asset(), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        uint256 fromIdle = amount <= idleBalance ? amount : idleBalance;
        if (fromIdle == amount) {
            return amount;
        }

        uint256 remaining = amount - fromIdle;
        uint256 maxAsset = _oracleTokenToAsset(_positionBalance());
        uint256 fundableFromPosition = remaining <= maxAsset ? remaining : maxAsset;
        return fromIdle + (fundableFromPosition * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _oracleTokenToAsset(uint256 oracleTokenAmount) internal view returns (uint256) {
        return oracleTokenAmount * _oracleAnswer() / (10 ** pricedTokenEthOracleDecimals);
    }

    function _assetToOracleTokenDown(uint256 assetAmount) internal view returns (uint256) {
        return assetAmount * (10 ** pricedTokenEthOracleDecimals) / _oracleAnswer();
    }

    function _assetToOracleTokenUp(uint256 assetAmount) internal view returns (uint256) {
        uint256 scale = 10 ** pricedTokenEthOracleDecimals;
        uint256 answer = _oracleAnswer();
        return (assetAmount * scale + answer - 1) / answer;
    }

    function _oracleAnswer() internal view returns (uint256 answer) {
        (, int256 raw,, uint256 updatedAt,) = pricedTokenEthOracle.latestRoundData();
        require(raw > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        answer = uint256(raw);
    }

    function _roundUpMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }

    /// @notice Returns the vault asset managed by the parent MYT.
    function _asset() internal view returns (address) {
        return MYT.asset();
    }

    /// @notice Validates the result of an allocation swap before any post-swap processing occurs.
    /// @dev Override in child strategies to apply strategy-specific post-swap output guards.
    /// @param assetAmountIn The vault asset amount spent in the swap.
    /// @param minOracleTokenOut The oracle-priced minimum output passed to the swap executor.
    /// @param oracleTokenReceived The amount of oracle token received from the swap.
    function _allocationSwapGuard(uint256 assetAmountIn, uint256 minOracleTokenOut, uint256 oracleTokenReceived)
        internal
        view
        virtual
    {}

    /// @notice Optional hook for child strategies to transform or stake the received oracle token after allocation.
    /// @param oracleTokenReceived The oracle token amount returned by the allocation swap.
    function _afterAllocationSwap(uint256 oracleTokenReceived) internal virtual {}

    /// @notice Returns the token whose amount is priced by the oracle and used in swap sizing math.
    function _oracleToken() internal view virtual returns (address);

    /// @notice Returns the strategy's deployed position balance in units consumable by the oracle pricing math.
    /// @dev This may be the raw oracle token balance, or an oracle-token-equivalent amount derived from wrapped shares.
    function _positionBalance() internal view virtual returns (uint256);

    /// @notice Prepares the oracle token amount that will be sold in a one-hop swap deallocation.
    /// @param maxOracleTokenIn The maximum oracle token amount permitted by oracle and slippage math.
    function _prepareOracleTokenForSwap(uint256 maxOracleTokenIn) internal virtual returns (uint256);

    /// @notice Prepares an intermediate token for unwrap-and-swap deallocation flows.
    /// @dev Child strategies should unwrap or redeem into the sell token and return the token plus amount to swap.
    /// @param maxOracleTokenIn The maximum oracle-token-equivalent amount permitted by oracle and slippage math.
    /// @param minIntermediateOutAmount The minimum intermediate token amount the caller expects to produce before swapping.
    /// @return sellToken The intermediate token that should be sold into the vault asset.
    /// @return sellAmount The amount of the intermediate token available to sell.
    function _prepareIntermediateForSwap(uint256 maxOracleTokenIn, uint256 minIntermediateOutAmount)
        internal
        virtual
        returns (address sellToken, uint256 sellAmount)
    {
        revert ActionNotSupported();
    }
}
