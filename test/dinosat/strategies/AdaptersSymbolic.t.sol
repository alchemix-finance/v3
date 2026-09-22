// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./StrategyFixtures.sol";
import {EulerUSDCAdapter} from "../../../src/adapters/EulerUSDCAdapter.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../../../src/FrxEthEthDualOracleAggregatorAdapter.sol";
contract DinoAdapterTest is DinoFixture {
    function setUp() public {_init();}
    /// @notice STR-FEE-CONSTRUCT. fee constructor.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_fee_constructor() public {
        DinoFeeHarness f=new DinoFeeHarness(address(asset),address(myt),address(this));assert(f.token()==address(asset));assert(f.authorized(address(this)));assert(f.authorized(address(myt)));assert(!f.authorized(ATTACKER));
    }
    /// @notice STR-FEE-AUTH. fee authorization.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_fee_authorization() public {
        DinoFeeHarness f=new DinoFeeHarness(address(asset),address(myt),address(this));vm.prank(ATTACKER);_bad(address(f),abi.encodeCall(AbstractFeeVault.setAuthorization,(ATTACKER,true)),abi.encodeWithSignature("OwnableUnauthorizedAccount(address)",ATTACKER));assert(!f.authorized(ATTACKER));f.setAuthorization(ATTACKER,true);assert(f.authorized(ATTACKER));f.setAuthorization(ATTACKER,false);assert(!f.authorized(ATTACKER));_bad(address(f),abi.encodeCall(AbstractFeeVault.setAuthorization,(address(0),true)),abi.encodeWithSelector(AbstractFeeVault.ZeroAddress.selector));
    }
    /// @notice STR-FEE-VALIDATORS. fee validators.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_fee_validators(uint64 raw) public {
        DinoFeeHarness f=new DinoFeeHarness(address(asset),address(myt),address(this));f.checkAddress(ATTACKER);f.checkAmount(uint256(raw)+1);_bad(address(f),abi.encodeCall(DinoFeeHarness.checkAddress,(address(0))),abi.encodeWithSelector(AbstractFeeVault.ZeroAddress.selector));_bad(address(f),abi.encodeCall(DinoFeeHarness.checkAmount,(0)),abi.encodeWithSelector(AbstractFeeVault.ZeroAmount.selector));
    }
    /// @notice Same property and domain as test_check_fee_validators.
    function test_fuzz_fee_validators(uint64 raw) public { test_check_fee_validators(raw); }
    /// @notice STR-EULER-PRICE, STR-CONSTRUCT-EULERUSDCADAPTER. euler price 6.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_price_6() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(6);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));assert(a.price()==10**6);assert(a.token()==address(v)&&a.underlyingToken()==address(asset));
    }
    /// @notice STR-EULER-PRICE, STR-CONSTRUCT-EULERUSDCADAPTER. euler price 8.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_price_8() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(8);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));assert(a.price()==10**8);assert(a.token()==address(v)&&a.underlyingToken()==address(asset));
    }
    /// @notice STR-EULER-PRICE, STR-CONSTRUCT-EULERUSDCADAPTER. euler price 12.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_price_12() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(12);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));assert(a.price()==10**12);assert(a.token()==address(v)&&a.underlyingToken()==address(asset));
    }
    /// @notice STR-EULER-PRICE, STR-CONSTRUCT-EULERUSDCADAPTER. euler price 18.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_price_18() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(18);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));assert(a.price()==10**18);assert(a.token()==address(v)&&a.underlyingToken()==address(asset));
    }
    /// @notice STR-EULER-PRICE, STR-CONSTRUCT-EULERUSDCADAPTER. euler price 77.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_price_77() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(77);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));assert(a.price()==10**77);assert(a.token()==address(v)&&a.underlyingToken()==address(asset));
    }
    /// @notice STR-EULER-PRICE. euler overflow.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: ENUMERATE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_euler_overflow() public {
        DinoPriceVault v=new DinoPriceVault();v.setDecimals(78);EulerUSDCAdapter a=new EulerUSDCAdapter(address(v),address(asset));_bad(address(a),abi.encodeCall(EulerUSDCAdapter.price,()),_panic(0x11));v.setDecimals(255);_bad(address(a),abi.encodeCall(EulerUSDCAdapter.price,()),_panic(0x11));
    }
    /// @notice STR-FRX-DECIMALS, STR-CONSTRUCT-FRXETHETHDUALORACLEAGGREGATORADAPTER. frx decimals.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frx_decimals() public {
        FrxEthEthDualOracleAggregatorAdapter a=new FrxEthEthDualOracleAggregatorAdapter(address(oracle));assert(a.decimals()==18);assert(address(a.dualOracle())==address(oracle));
    }
    /// @notice STR-FRX-DATA. frx data.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frx_data(uint64 lowRaw,uint64 highRaw) public {
        uint256 low=uint256(lowRaw)+1;uint256 high=uint256(highRaw)+1;oracle.setDual(false,low,high);FrxEthEthDualOracleAggregatorAdapter a=new FrxEthEthDualOracleAggregatorAdapter(address(oracle));(uint80 round,int256 answer,uint256 start,uint256 updated,uint80 answered)=a.latestRoundData();uint256 p=uint256(answer);assert(p>0);assert(p>=(low<high?low:high)&&p<=(low>high?low:high));assert(p*2<=low+high&&(low+high)-p*2<2);assert(start==block.timestamp&&updated==block.timestamp);assert(round==uint80(block.number)&&answered==round);
    }
    /// @notice Same property and domain as test_check_frx_data.
    function test_fuzz_frx_data(uint64 lowRaw,uint64 highRaw) public { test_check_frx_data(lowRaw,highRaw); }
    /// @notice STR-FRX-DATA. frx bad zero overflow.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DECOMPOSE. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frx_bad_zero_overflow() public {
        FrxEthEthDualOracleAggregatorAdapter a=new FrxEthEthDualOracleAggregatorAdapter(address(oracle));oracle.setDual(true,1,1);_bad(address(a),abi.encodeCall(FrxEthEthDualOracleAggregatorAdapter.latestRoundData,()),_revertString("Bad dual oracle data"));oracle.setDual(false,0,1);_bad(address(a),abi.encodeCall(FrxEthEthDualOracleAggregatorAdapter.latestRoundData,()),_revertString("Invalid dual oracle price"));oracle.setDual(false,type(uint256).max,1);_bad(address(a),abi.encodeCall(FrxEthEthDualOracleAggregatorAdapter.latestRoundData,()),_panic(0x11));oracle.setDual(false,type(uint256).max,0);(,int256 p,,,)=a.latestRoundData();assert(p==type(int256).max);
    }
    function deployFee(address token,address alchemist,address owner) external returns(address){return address(new DinoFeeHarness(token,alchemist,owner));}
    function deployFrx(address feed) external returns(address){return address(new FrxEthEthDualOracleAggregatorAdapter(feed));}
    /// @notice STR-FEE-CONSTRUCT. fee constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_fee_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployFee,(address(0),address(myt),address(this))),abi.encodeWithSelector(AbstractFeeVault.ZeroAddress.selector));_bad(address(this),abi.encodeCall(this.deployFee,(address(asset),address(0),address(this))),abi.encodeWithSelector(AbstractFeeVault.ZeroAddress.selector));_bad(address(this),abi.encodeCall(this.deployFee,(address(asset),address(myt),address(0))),abi.encodeWithSignature("OwnableInvalidOwner(address)",address(0)));
    }
    /// @notice STR-CONSTRUCT-FRXETHETHDUALORACLEAGGREGATORADAPTER. frx constructor rejects.
    /// @dev Technique: actual bytecode with explicit boundary mocks.
    /// @dev Classification: DIRECT. uint64 amounts cover [0,2^64-1], an explicit domain below the default 1e27 bound.
    function test_check_frx_constructor_rejects() public {
        _bad(address(this),abi.encodeCall(this.deployFrx,(address(0))),_revertString("Zero dual oracle address"));
    }
}

