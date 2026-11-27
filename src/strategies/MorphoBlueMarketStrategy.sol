// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IMorphoBlue, IMorphoIrm, Market, MarketParams, Position} from "./interfaces/IMorphoBlue.sol";

/**
 * @title MorphoBlueMarketStrategy
 * @notice Generic deployable strategy that lends the MYT asset directly into one Morpho Blue market.
 * @dev No receipt token is held; the position lives in Morpho's `position[id][strategy].supplyShares`.
 */
contract MorphoBlueMarketStrategy is MYTStrategy {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable mytAsset;
    IMorphoBlue public immutable morpho;
    bytes32 public immutable marketId;
    address public immutable collateralToken;
    address public immutable oracle;
    address public immutable irm;
    uint256 public immutable lltv;
    bool public canForceDeallocate;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);

    error MarketNotCreated(bytes32 id);
    error LoanTokenMismatch(address loanToken, address mytAsset);

    constructor(address _myt, StrategyParams memory _params, address _morpho, MarketParams memory _marketParams) MYTStrategy(_myt, _params) {
        require(_morpho != address(0), "Invalid morpho");
        mytAsset = IERC20(MYT.asset());
        if (_marketParams.loanToken != address(mytAsset)) revert LoanTokenMismatch(_marketParams.loanToken, address(mytAsset));

        morpho = IMorphoBlue(_morpho);
        collateralToken = _marketParams.collateralToken;
        oracle = _marketParams.oracle;
        irm = _marketParams.irm;
        lltv = _marketParams.lltv;
        marketId = keccak256(abi.encode(_marketParams));

        if (morpho.market(marketId).lastUpdate == 0) revert MarketNotCreated(marketId);
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    /// @notice Market params reconstructed from immutables, as expected by Morpho entrypoints.
    function marketParams() public view returns (MarketParams memory) {
        return MarketParams({loanToken: address(mytAsset), collateralToken: collateralToken, oracle: oracle, irm: irm, lltv: lltv});
    }

    /// @notice Loan asset currently supplied by this strategy, including interest accrued since the last market update.
    function expectedSupplyAssets() public view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = _expectedMarketBalances();
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;
        return _toAssetsDown(shares, totalSupplyAssets, totalSupplyShares);
    }

    /// @notice Loan asset not yet borrowed, i.e. the most Morpho can return synchronously right now.
    function availableLiquidity() public view returns (uint256) {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = _expectedMarketBalances();
        return totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        _ensureIdleBalance(address(mytAsset), amount);

        TokenUtils.safeApprove(address(mytAsset), address(morpho), amount);
        morpho.supply(marketParams(), amount, 0, address(this), "");
        return amount;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            morpho.withdraw(marketParams(), shortfall, 0, address(this), address(this));
        }

        _ensureIdleBalance(address(mytAsset), amount);
        TokenUtils.safeApprove(address(mytAsset), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        return expectedSupplyAssets() + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(mytAsset), address(this));
    }

    /// @dev Withdrawals are capped by idle balance plus what Morpho can release; the rest is slippage buffer only.
    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 position = expectedSupplyAssets();
        uint256 liquidity = availableLiquidity();
        uint256 withdrawable = _idleAssets() + (position < liquidity ? position : liquidity);
        uint256 capped = amount < withdrawable ? amount : withdrawable;
        return capped * (10_000 - params.slippageBPS) / 10_000;
    }

    /// @dev Reward tokens are delivered to this address off-chain (e.g. Merkl); sell them and forward to the vault.
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual override returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return 0;

        emit RewardsClaimed(token, balance);

        uint256 assetsReceived;
        if (token == address(mytAsset)) {
            assetsReceived = balance;
        } else {
            assetsReceived = dexSwap(address(mytAsset), token, balance, minAmountOut, quote);
        }
        TokenUtils.safeTransfer(address(mytAsset), address(MYT), assetsReceived);
        return assetsReceived;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == address(mytAsset);
    }

    function _canForceDeallocate() internal view virtual override returns (bool) {
        return canForceDeallocate;
    }

    /// @dev Mirrors MorphoBalancesLib.expectedMarketBalances: project interest and fee shares since `lastUpdate`.
    function _expectedMarketBalances() internal view returns (uint256, uint256, uint256, uint256) {
        Market memory m = morpho.market(marketId);
        uint256 elapsed = block.timestamp - m.lastUpdate;

        if (elapsed != 0 && m.totalBorrowAssets != 0 && irm != address(0)) {
            uint256 borrowRate = IMorphoIrm(irm).borrowRateView(marketParams(), m);
            uint256 interest = _wMulDown(m.totalBorrowAssets, _wTaylorCompounded(borrowRate, elapsed));
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);

            if (m.fee != 0) {
                uint256 feeAmount = _wMulDown(interest, m.fee);
                uint256 feeShares = _toSharesDown(feeAmount, m.totalSupplyAssets - feeAmount, m.totalSupplyShares);
                m.totalSupplyShares += uint128(feeShares);
            }
        }

        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES);
    }

    function _toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS);
    }

    function _wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * y / WAD;
    }

    /// @dev Third order Taylor expansion of e^(x*n) - 1, matching Morpho Blue's MathLib.
    function _wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = firstTerm * firstTerm / (2 * WAD);
        uint256 thirdTerm = secondTerm * firstTerm / (3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }
}
