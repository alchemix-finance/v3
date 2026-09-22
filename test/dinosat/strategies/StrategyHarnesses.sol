// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {MYTStrategy} from "../../../src/MYTStrategy.sol";
import {IMYTStrategy} from "../../../src/interfaces/IMYTStrategy.sol";
import {OraclePricedSwapStrategy} from "../../../src/strategies/OraclePricedSwapStrategy.sol";
import {ERC4626Strategy} from "../../../src/strategies/ERC4626Strategy.sol";
import {AaveStrategy} from "../../../src/strategies/AaveStrategy.sol";
import {MoonwellStrategy} from "../../../src/strategies/MoonwellStrategy.sol";
import {YearnV3Strategy} from "../../../src/strategies/YearnV3Strategy.sol";
import {WstETHEthereumStrategy} from "../../../src/strategies/WstETHEthereumStrategy.sol";
import {WstETHL2Strategy} from "../../../src/strategies/WstETHL2Strategy.sol";
import {SFraxETHStrategy} from "../../../src/strategies/SFraxETHStrategy.sol";
import {SiUSDStrategy} from "../../../src/strategies/SiUSDStrategy.sol";
import {EtherfiEETHMYTStrategy} from "../../../src/strategies/EtherfiEETHStrategy.sol";
import {StakeDAOWETHStrategy} from "../../../src/strategies/StakeDAOWETHStrategy.sol";
import {TokeAutoStrategy} from "../../../src/strategies/TokeAutoStrategy.sol";
import {AbstractFeeVault} from "../../../src/adapters/AbstractFeeVault.sol";
import {DinoToken} from "./StrategyMocks.sol";

/// @dev Only virtual integration hooks are modeled. Dispatcher/authority/accounting bytecode is inherited unchanged.
contract DinoBaseHarness is MYTStrategy {
    uint256 public value;
    uint256 public called;
    bool public force=true;
    constructor(address v,StrategyParams memory p) MYTStrategy(v,p){}
    function setValue(uint256 n) external {value=n;}
    function setForce(bool v) external {force=v;}
    function _allocate(uint256 n) internal override returns(uint256){called=1;return n;}
    function _allocate(uint256 n,bytes memory) internal override returns(uint256){called=2;return n;}
    function _deallocate(uint256 n) internal override returns(uint256){called=3;return n;}
    function _deallocate(uint256 n,bytes memory) internal override returns(uint256){called=4;return n;}
    function _deallocate(uint256 n,bytes memory,uint256) internal override returns(uint256){called=5;return n;}
    function _totalValue() internal view override returns(uint256){return value;}
    function _previewAdjustedWithdraw(uint256 n) internal pure override returns(uint256){return n;}
    function _canForceDeallocate() internal view override returns(bool){return force;}
    function idle(address t,uint256 n) external view {_ensureIdleBalance(t,n);}
    function swap(address to,address from,uint256 n,uint256 minOut,bytes memory data) external returns(uint256){return dexSwap(to,from,n,minOut,data);}
    function validate(ActionType a,bytes4 s) external view {_validateDeallocateAction(a,s);}
}
contract DinoOracleHarness is OraclePricedSwapStrategy {
    DinoToken public receipt;
    bool public zeroIntermediate;
    function setZeroIntermediate(bool v) external {zeroIntermediate=v;}
    constructor(address v,StrategyParams memory p,address o,address t) OraclePricedSwapStrategy(v,p,o,1000){receipt=DinoToken(t);}
    function _oracleToken() internal view override returns(address){return address(receipt);}
    function _positionBalance() internal view override returns(uint256){return receipt.balanceOf(address(this));}
    function _prepareOracleTokenForSwap(uint256 n) internal view override returns(uint256){uint256 b=receipt.balanceOf(address(this));return n<b?n:b;}
    function _prepareIntermediateForSwap(uint256 maxIn,uint256 n) internal view override returns(address,uint256){require(n<=maxIn);return(zeroIntermediate?address(0):address(receipt),n);}
    function toAsset(uint256 n) external view returns(uint256){return _oracleTokenToAsset(n);}
    function down(uint256 n) external view returns(uint256){return _assetToOracleTokenDown(n);}
    function up(uint256 n) external view returns(uint256){return _assetToOracleTokenUp(n);}
    function answer() external view returns(uint256){return _oracleAnswer();}
    function ceil(uint256 x,uint256 y,uint256 d) external pure returns(uint256){return _roundUpMulDiv(x,y,d);}
}
contract DinoWstHarness is WstETHEthereumStrategy {
    constructor(address v,StrategyParams memory p,address w,address o) WstETHEthereumStrategy(v,p,w,o,1000){}
    function prep(uint256 n) external view returns(uint256){return _prepareOracleTokenForSwap(n);}
    function ceilWrapped(uint256 n) external view returns(uint256){return _wstEthFromStEthUp(n);}
}
contract DinoWstL2Harness is WstETHL2Strategy {
    constructor(address v,StrategyParams memory p,address w,address o) WstETHL2Strategy(v,p,w,o,1000){}
    function prep(uint256 n) external view returns(uint256){return _prepareOracleTokenForSwap(n);}
}
contract DinoSiHarness is SiUSDStrategy {
    constructor(address v,StrategyParams memory p,address a,address i,address s,address g,address o) SiUSDStrategy(v,p,a,i,s,g,g,g,o,1000){}
    function prep(uint256 cap,uint256 n) external returns(address,uint256){return _prepareIntermediateForSwap(cap,n);}
    function discount(uint256 n) external view returns(uint256){return _applyDirectPreviewDiscount(n);}
}
contract DinoFraxHarness is SFraxETHStrategy {
    constructor(address v,StrategyParams memory p,address m,address f,address s,address o) SFraxETHStrategy(v,p,m,f,s,o,9500,1000){}
    function prep(uint256 cap,uint256 n) external returns(address,uint256){return _prepareIntermediateForSwap(cap,n);}
    function guard(uint256 n,uint256 received) external view {_allocationSwapGuard(n,0,received);}
}
contract DinoEtherHarness is EtherfiEETHMYTStrategy {
    constructor(address v,StrategyParams memory p,address e,address w,address m,address o) EtherfiEETHMYTStrategy(v,p,e,w,m,m,o,1000){}
    function gross(uint256 n,uint256 balance) external view returns(uint256){return _weETHForGrossRedeem(n,balance);}
    function size(uint256 n,uint256 fee,uint256 balance) external view returns(uint256){return _weETHForNetShortfall(n,fee,balance);}
    function net(uint256 n) external view returns(uint256){return _previewNetEthFromWeETH(n);}
    function prep(uint256 n) external returns(uint256){return _prepareOracleTokenForSwap(n);}
}
contract DinoDAOHarness is StakeDAOWETHStrategy {
    constructor(address v,StrategyParams memory p,address r,address c,address e) StakeDAOWETHStrategy(v,p,r,c,e,25,1e18,95e16){}
    function minSlip(uint256 n) external view returns(uint256){return _minAmountAfterSlippage(n);}
    function minShares(uint256 n) external view returns(uint256){return _minSharesForWethIn(n);}
    function lpRequired(uint256 n,uint256 s) external view returns(uint256){return _lpRequiredForWeth(n,s);}
    function maxAbs(uint256 n) external view returns(uint256){return _maxLpForWeth(n);}
    function minAbs(uint256 n) external view returns(uint256){return _minLpForWeth(n);}
    function maxVP(uint256 n) external view returns(uint256){return _maxLpForWethVP(n);}
    function minVP(uint256 n) external view returns(uint256){return _minLpForWethVP(n);}
    function effectiveMin(uint256 n) external view returns(uint256){return _effectiveMinLpForWeth(n);}
    function effectiveMax(uint256 n) external view returns(uint256){return _effectiveMaxLpForWeth(n);}
    function route(address t,uint256 n,bytes memory d) external returns(uint256){return _ensoRoute(t,n,d);}
}
/// @dev Tests validators and base authorization only. Concrete fee vaults need their own integration tests.
contract DinoFeeHarness is AbstractFeeVault {
    constructor(address t,address a,address o) AbstractFeeVault(t,a,o){}
    function withdraw(address,uint256) external override onlyAuthorized {}
    function totalDeposits() external view override returns(uint256){return DinoToken(token).balanceOf(address(this));}
    function checkAddress(address a) external pure {_checkNonZeroAddress(a);}
    function checkAmount(uint256 a) external pure {_checkNonZeroAmount(a);}
}
