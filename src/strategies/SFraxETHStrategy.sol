// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IFraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256 shares);
}

interface ISfrxETH {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract SFraxETHStrategy is OraclePricedSwapStrategy {
    event MinFrxEthOutBpsUpdated(uint256 indexed newMinFrxEthOutBps);

    IFraxMinter public immutable minter;
    IERC20 public immutable frxETH;
    ISfrxETH public immutable sfrxETH;
    uint256 public minFrxEthOutBps;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _minter,
        address _frxETH,
        address _sfrxETH,
        address _pricedTokenOracle,
        uint256 _minFrxEthOutBps,
        uint256 _maxOracleStaleness
    ) OraclePricedSwapStrategy(_myt, _params, _pricedTokenOracle, _maxOracleStaleness) {
        require(_minter != address(0), "Zero minter address");
        require(_frxETH != address(0), "Zero frxETH address");
        require(_sfrxETH != address(0), "Zero sfrxETH address");
        require(_minFrxEthOutBps <= 10_000, "Invalid min frxETH out bps");

        minter = IFraxMinter(_minter);
        frxETH = IERC20(_frxETH);
        sfrxETH = ISfrxETH(_sfrxETH);
        minFrxEthOutBps = _minFrxEthOutBps;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        IWETH(_asset()).withdraw(amount);
        uint256 sharesReceived = minter.submitAndDeposit{value: amount}(address(this));
        require(sharesReceived > 0, "No sfrxETH received");
        return amount;
    }

    function _afterAllocationSwap(uint256 oracleTokenReceived) internal override {
        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), oracleTokenReceived);
        uint256 sharesReceived = sfrxETH.deposit(oracleTokenReceived, address(this));
        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), 0);
        require(sharesReceived > 0, "No sfrxETH received");
    }

    /// @notice Updates the minimum raw frxETH output floor enforced after swap-based allocations.
    /// @dev This is an oracle-independent downside guard against pathological quotes or severe frxETH depegs.
    function setMinFrxEthOutBps(uint256 newMinFrxEthOutBps) external onlyOwner {
        require(newMinFrxEthOutBps <= 10_000, "Invalid min frxETH out bps");
        minFrxEthOutBps = newMinFrxEthOutBps;
        emit MinFrxEthOutBpsUpdated(newMinFrxEthOutBps);
    }

    function _deallocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(sfrxETH) || token == address(frxETH);
    }

    function _oracleToken() internal view override returns (address) {
        return address(frxETH);
    }

    function _positionBalance() internal view override returns (uint256) {
        return frxETH.balanceOf(address(this)) + sfrxETH.convertToAssets(sfrxETH.balanceOf(address(this)));
    }

    function _allocationSwapGuard(uint256 assetAmountIn, uint256, uint256 oracleTokenReceived) internal view override {
        if (minFrxEthOutBps == 0) return;

        uint256 minFrxEthOut = (assetAmountIn * minFrxEthOutBps) / 10_000;
        if (oracleTokenReceived < minFrxEthOut) revert InvalidAmount(minFrxEthOut, oracleTokenReceived);
    }

    function _prepareOracleTokenForSwap(uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _prepareIntermediateForSwap(uint256 maxOracleTokenIn, uint256 minIntermediateOutAmount)
        internal
        override
        returns (address sellToken, uint256 sellAmount)
    {
        require(minIntermediateOutAmount > 0, "Invalid intermediate amount");

        uint256 sharesNeeded = sfrxETH.previewWithdraw(minIntermediateOutAmount);
        uint256 sharesBalance = sfrxETH.balanceOf(address(this));
        require(sharesNeeded > 0, "No sfrxETH to unwrap");
        require(sharesNeeded <= sharesBalance, "Insufficient sfrxETH balance");
        require(minIntermediateOutAmount <= maxOracleTokenIn, "Intermediate exceeds max oracle token in");

        uint256 frxETHBefore = frxETH.balanceOf(address(this));
        sfrxETH.withdraw(minIntermediateOutAmount, address(this), address(this));
        sellAmount = frxETH.balanceOf(address(this)) - frxETHBefore;
        require(sellAmount >= minIntermediateOutAmount, "Insufficient intermediate out");

        sellToken = address(frxETH);
    }

    receive() external payable {}
}
