// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokeSwapRoute} from "../../../src/strategies/TokeAutoStrategy.sol";

/// @notice Explicit test boundary: exact-transfer tokens and configurable external responses.
/// @dev Mint/burn setters are test controls. They do not model public production permissions.
contract DinoToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint8 public decimals = 18;
    uint256 public rate = 1e18;
    bool public falseTransfer;
    function setDecimals(uint8 v) external { decimals = v; }
    function setRate(uint256 v) external { rate = v; }
    function setFalseTransfer(bool v) external { falseTransfer = v; }
    function mint(address a, uint256 n) public { balanceOf[a] += n; totalSupply += n; }
    function burn(address a, uint256 n) public { balanceOf[a] -= n; totalSupply -= n; }
    function approve(address s, uint256 n) external returns (bool) { allowance[msg.sender][s] = n; return true; }
    function transfer(address to, uint256 n) external returns (bool) {
        if (falseTransfer) return false;
        balanceOf[msg.sender] -= n; balanceOf[to] += n; return true;
    }
    function transferFrom(address a, address b, uint256 n) external returns (bool) {
        allowance[a][msg.sender] -= n; balanceOf[a] -= n; balanceOf[b] += n; return true;
    }
    function deposit() external payable { mint(msg.sender, msg.value); }
    function withdraw(uint256 n) external { burn(msg.sender,n); (bool ok,) = msg.sender.call{value:n}(""); require(ok); }
    function getStETHByWstETH(uint256 n) external view returns (uint256) { return n*rate/1e18; }
    function getWstETHByStETH(uint256 n) external view returns (uint256) { return n*1e18/rate; }
    function getEETHByWeETH(uint256 n) external view returns (uint256) { return n*rate/1e18; }
    function getWeETHByeETH(uint256 n) external view returns (uint256) { return n*1e18/rate; }

}
contract DinoWrappedToken is DinoToken {
    receive() external payable { mint(msg.sender,msg.value*1e18/rate); }
}
contract DinoMYT {
    address public asset;
    mapping(bytes32 => uint256) public allocation;
    constructor(address a) { asset=a; }
    function setAllocation(bytes32 id,uint256 n) external { allocation[id]=n; }
    function pull(address from,uint256 n) external { DinoToken(asset).transferFrom(from,address(this),n); }
}
contract DinoOracle {
    uint8 public decimals=18;
    int256 public answer=1e18;
    uint256 public updatedAt=1;
    bool public bad;
    uint256 public low=1e18;
    uint256 public high=1e18;
    function set(int256 p,uint256 t) external { answer=p; updatedAt=t; }
    function setDecimals(uint8 d) external { decimals=d; }
    function setDual(bool b,uint256 l,uint256 h) external {bad=b;low=l;high=h;}
    function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80){return(1,answer,updatedAt,updatedAt,1);}
    function getPrices() external view returns(bool,uint256,uint256){return(bad,low,high);}
}
contract DinoSwap {
    error RouteFailed();
    bool public reentrySucceeded;
    bytes32 public reentryReason;
    function reenter(address target,bytes calldata payload,address to,uint256 buy) external {(bool ok,bytes memory reason)=target.call(payload);reentrySucceeded=ok;reentryReason=keccak256(reason);DinoToken(to).mint(msg.sender,buy);}
    function swap(address from,address to,uint256 sell,uint256 buy) external {
        DinoToken(from).transferFrom(msg.sender,address(this),sell);
        DinoToken(to).mint(msg.sender,buy);
    }
    function fail() external pure { revert RouteFailed(); }
    function noOp() external pure {}
    function drain(address token,uint256 n) external {DinoToken(token).burn(msg.sender,n);}
}
/// @dev Exact asset/share arithmetic. Fee shares, loss and quote rate are explicit test inputs.
contract Dino4626 is DinoToken {
    address public asset;
    uint256 public feeShares;
    uint256 public loss;
    uint256 public lastLoss;
    uint256 public withdrawCalls;
    uint256 public redeemCalls;
    constructor(address a){asset=a;}
    function setFee(uint256 n) external {feeShares=n;}
    function setLoss(uint256 n) external {loss=n;}
    function convertToAssets(uint256 n) public view returns(uint256){return n*rate/1e18;}
    function convertToShares(uint256 n) public view returns(uint256){return n*1e18/rate;}
    function previewDeposit(uint256 n) external view returns(uint256){return convertToShares(n);}
    function previewRedeem(uint256 n) external view returns(uint256){return convertToAssets(n);}
    function previewWithdraw(uint256 n) public view returns(uint256){return (n*1e18+rate-1)/rate+feeShares;}
    function deposit(uint256 n,address to) public returns(uint256 s){DinoToken(asset).transferFrom(msg.sender,address(this),n);s=convertToShares(n);mint(to,s);}
    function withdraw(uint256 n,address to,address owner) public returns(uint256 s){++withdrawCalls;s=previewWithdraw(n);burn(owner,s);DinoToken(asset).mint(to,n>loss?n-loss:0);}
    function redeem(uint256 s,address to,address owner) public returns(uint256 n){++redeemCalls;burn(owner,s);n=convertToAssets(s);DinoToken(asset).mint(to,n);}
    function withdraw(uint256 n,address to,address owner,uint256 maxLoss) external returns(uint256){lastLoss=maxLoss;return withdraw(n,to,owner);}
    function redeem(uint256 s,address to,address owner,uint256 maxLoss) external returns(uint256){lastLoss=maxLoss;return redeem(s,to,owner);}
    function totalAssets(uint8 purpose) external view returns(uint256){require(purpose==2,"withdraw NAV required");return totalSupply*rate/1e18;}
    function convertToAssets(uint256 s,uint256 nav,uint256 supply,uint8 rounding) external view returns(uint256){require(rounding==0,"floor required");require(nav==totalSupply*rate/1e18&&supply==totalSupply,"NAV arguments");return convertToAssets(s);}
    function convertToShares(uint256 n,uint256 nav,uint256 supply,uint8 rounding) external view returns(uint256){require(rounding==1,"ceiling required");require(nav==totalSupply*rate/1e18&&supply==totalSupply,"NAV arguments");return (n*1e18+rate-1)/rate;}
}
contract DinoAave {
    DinoToken public aToken;
    bool public zeroMint;
    function setZeroMint(bool v) external {zeroMint=v;}
    uint256 public reportCut;
    uint256 public transferCut;
    constructor(DinoToken t){aToken=t;}
    function setCuts(uint256 r,uint256 t) external {reportCut=r;transferCut=t;}
    function getPool() external view returns(address){return address(this);}
    function supply(address asset,uint256 n,address owner,uint16) external {DinoToken(asset).transferFrom(msg.sender,address(this),n);if(!zeroMint)aToken.mint(owner,n);}
    function withdraw(address asset,uint256 n,address to) external returns(uint256){aToken.burn(msg.sender,n);DinoToken(asset).mint(to,n-transferCut);return n-reportCut;}
}
contract DinoMoon is DinoToken {
    address public underlying;
    uint256 public mintError;
    uint256 public redeemError;
    uint256 public interestError;
    bool public nativeOutput;
    constructor(address a){underlying=a;}
    function setErrors(uint256 a,uint256 b,uint256 c) external {mintError=a;redeemError=b;interestError=c;}
    function setNative(bool n) external {nativeOutput=n;}
    function exchangeRateStored() external view returns(uint256){return rate;}
    function accrueInterest() external view returns(uint256){return interestError;}
    function mint(uint256 n) external returns(uint256){if(mintError!=0)return mintError;DinoToken(underlying).transferFrom(msg.sender,address(this),n);mint(msg.sender,n*1e18/rate);return 0;}
    function redeem(uint256 s) external returns(uint256){if(redeemError!=0)return redeemError;burn(msg.sender,s);uint256 n=s*rate/1e18;if(nativeOutput){(bool ok,)=msg.sender.call{value:n}("");require(ok);}else DinoToken(underlying).mint(msg.sender,n);return 0;}
}
contract DinoRewarder {
    mapping(address=>uint256) public balanceOf;
    address public shareToken;
    address public rewardToken;
    uint256 public rewardAmount;
    uint256 public tokeLockDuration;
    bool public allowExtraRewards;
    address public lastClaimAsset;
    constructor(address s,address r){shareToken=s;rewardToken=r;}
    function setReward(uint256 n,uint256 lockTime,bool extra) external {rewardAmount=n;tokeLockDuration=lockTime;allowExtraRewards=extra;}
    function seed(address a,uint256 n) external {balanceOf[a]=n;DinoToken(shareToken).mint(address(this),n);}
    function stake(address a,uint256 n) external {DinoToken(shareToken).transferFrom(msg.sender,address(this),n);balanceOf[a]+=n;}
    function withdraw(address a,uint256 n,bool) external {balanceOf[a]-=n;DinoToken(shareToken).transfer(a,n);}
    function getReward(address,address to,bool) external {DinoToken(rewardToken).mint(to,rewardAmount);}
    function claimReward() external {DinoToken(rewardToken).mint(msg.sender,rewardAmount);}
    function claimAllRewardsToSelf(address[] calldata requested) external returns(address[] memory a,uint256[] memory n){lastClaimAsset=requested[0];a=new address[](1);n=new uint256[](1);a[0]=rewardToken;n[0]=rewardAmount;DinoToken(rewardToken).mint(msg.sender,rewardAmount);}
}
contract DinoTokeRouter {
    bool public ignoreMinimum;
    uint256 public cut;
    uint256 public lastMinimum;
    function set(bool ignore,uint256 n) external {ignoreMinimum=ignore;cut=n;}
    function redeem(Dino4626 vault,address to,uint256 s,uint256 minimum) public payable returns(uint256 n){
        lastMinimum=minimum;vault.transferFrom(msg.sender,address(this),s);n=vault.convertToAssets(s);vault.burn(address(this),s);n=n>cut?n-cut:0;
        if(!ignoreMinimum)require(n>=minimum,"router minimum");DinoToken(vault.asset()).mint(to,n);
    }
    function redeemWithRoutes(Dino4626 vault,address to,uint256 s,uint256 minimum,TokeSwapRoute[] calldata) external payable returns(uint256){return redeem(vault,to,s,minimum);}
}
contract DinoCurve is DinoToken {
    address public weth;
    uint256 public virtualPrice=1e18;
    bool public lieOutput;
    function setLie(bool v) external {lieOutput=v;}
    constructor(address a){weth=a;}
    function setVP(uint256 p) external {virtualPrice=p;}
    function get_virtual_price() external view returns(uint256){return virtualPrice;}
    function calc_token_amount(uint256[] calldata a,bool) external view returns(uint256){return a[1]*1e18/rate;}
    function calc_withdraw_one_coin(uint256 n,int128) external view returns(uint256){return n*rate/1e18;}
    function add_liquidity(uint256[] calldata a,uint256 minimum,address to) external returns(uint256 n){n=a[1]*1e18/rate;require(n>=minimum);DinoToken(weth).transferFrom(msg.sender,address(this),a[1]);if(!lieOutput)mint(to,n);}
    function remove_liquidity_one_coin(uint256 s,int128,uint256 minimum,address to) external returns(uint256 n){burn(msg.sender,s);n=s*rate/1e18;require(n>=minimum);if(!lieOutput)DinoToken(weth).mint(to,n);}
}
contract DinoAccountant {
    error NoPendingRewards();
    error OtherFailure();
    address public REWARD_TOKEN;
    uint256 public reward;
    uint8 public mode;
    constructor(address r){REWARD_TOKEN=r;}
    function set(uint256 n,uint8 m) external {reward=n;mode=m;}
    function claim(address[] calldata,bytes[] calldata,address to) external {if(mode==1)revert NoPendingRewards();if(mode==2)revert OtherFailure();if(mode>=3){bytes memory data=new bytes(mode==3?0:mode==4?32:64);if(data.length>0)data[0]=0xa1;assembly{revert(add(data,32),mload(data))}}DinoToken(REWARD_TOKEN).mint(to,reward);}
}
contract DinoStakeVault is Dino4626 {
    address public ACCOUNTANT;
    address public gauge=address(0x600D);
    uint128 public earnedAmount;
    constructor(address a,address accountant) Dino4626(a){ACCOUNTANT=accountant;}
    function deposit(uint256 n,address to,address) external returns(uint256){return deposit(n,to);}
    function setEarned(uint128 n) external {earnedAmount=n;}
    function earned(address,address) external view returns(uint128){return earnedAmount;}
    function claim(address[] calldata t,address to) external returns(uint256[] memory a){a=new uint256[](t.length);for(uint256 i;i<t.length;++i){a[i]=earnedAmount;DinoToken(t[i]).mint(to,earnedAmount);}}
}
contract DinoFraxMinter {
    bool public zeroMint;
    function setZeroMint(bool v) external {zeroMint=v;}
    Dino4626 public shares;
    constructor(Dino4626 s){shares=s;}
    function submitAndDeposit(address to) external payable returns(uint256){if(zeroMint)return 0;shares.mint(to,msg.value);return msg.value;}
}
contract DinoEther {
    struct RedemptionLimit {uint64 capacity;uint64 remaining;uint64 lastRefill;uint64 refillRate;}
    DinoToken public weth;
    DinoToken public we;
    uint16 public fee;
    bool public available=true;
    uint256 public cut;
    bool public zeroMint;
    function setZeroMint(bool v) external {zeroMint=v;}
    uint256 public shareRate=1e18;
    function setShareRate(uint256 n) external {shareRate=n;}
    constructor(DinoToken a,DinoToken b){weth=a;we=b;}
    function set(uint16 f,bool a,uint256 c) external {fee=f;available=a;cut=c;}
    function depositWETHForWeETH(uint256 n,address) external returns(uint256){weth.transferFrom(msg.sender,address(this),n);if(zeroMint)return 0;we.mint(msg.sender,n);return n;}
    function tokenToRedemptionInfo(address) external view returns(RedemptionLimit memory,uint16,uint16,uint16){return(RedemptionLimit(0,0,0,0),0,fee,0);}
    function liquidityPool() external view returns(address){return address(this);}
    function amountForShare(uint256 n) external view returns(uint256){return n*shareRate/1e18;}
    function sharesForAmount(uint256 n) external view returns(uint256){return n*1e18/shareRate;}
    function sharesForWithdrawalAmount(uint256 n) external view returns(uint256){return (n*1e18+shareRate-1)/shareRate;}
    function previewRedeem(uint256 n,address) external view returns(uint256){return n*(10000-fee)/10000;}
    function canRedeem(uint256,address) external view returns(bool){return available;}
    function redeemWeEth(uint256 n,address to,address) external {we.transferFrom(msg.sender,address(this),n);uint256 out=n*(10000-fee)/10000;out=out>cut?out-cut:0;(bool ok,)=to.call{value:out}("");require(ok);}
    receive() external payable {}
}
contract DinoSi {
    bool public zeroMint;
    function setZeroMint(bool v) external {zeroMint=v;}
    DinoToken public assetToken;
    DinoToken public receipt;
    Dino4626 public shares;
    constructor(DinoToken a,DinoToken r,Dino4626 s){assetToken=a;receipt=r;shares=s;}
    function assetToReceipt(uint256 n) external pure returns(uint256){return n;}
    function receiptToAsset(uint256 n) external pure returns(uint256){return n;}
    function mintAndStake(address to,uint256 n) external returns(uint256){assetToken.transferFrom(msg.sender,address(this),n);if(zeroMint)return 0;shares.mint(to,n);return n;}
    function unstake(address to,uint256 n) external returns(uint256){shares.transferFrom(msg.sender,address(this),n);receipt.mint(to,n);return n;}
    function redeem(address to,uint256 n,uint256 minimum) external returns(uint256){require(n>=minimum);receipt.transferFrom(msg.sender,address(this),n);assetToken.mint(to,n);return n;}
}
/// @dev The adapter-price boundary echoes share units without multiplication overflow in the mock.
contract DinoPriceVault {
    uint8 public decimals=18;
    function setDecimals(uint8 d) external {decimals=d;}
    function convertToAssets(uint256 shares) external pure returns(uint256){return shares;}
}
