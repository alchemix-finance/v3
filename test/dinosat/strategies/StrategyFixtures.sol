// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import "./StrategyMocks.sol";
import "./StrategyHarnesses.sol";
import {MYTStrategy} from "../../../src/MYTStrategy.sol";
import {IMYTStrategy} from "../../../src/interfaces/IMYTStrategy.sol";
import {AaveStrategy} from "../../../src/strategies/AaveStrategy.sol";
import {MoonwellStrategy} from "../../../src/strategies/MoonwellStrategy.sol";
import {ERC4626Strategy} from "../../../src/strategies/ERC4626Strategy.sol";
import {YearnV3Strategy} from "../../../src/strategies/YearnV3Strategy.sol";
import {TokeAutoStrategy,TokeRedeemParams,TokeSwapRoute} from "../../../src/strategies/TokeAutoStrategy.sol";

abstract contract DinoFixture is Test {
    uint256 internal constant P=1e18;
    address internal constant ATTACKER=address(0xBEEF);
    DinoToken internal asset;
    DinoToken internal receipt;
    DinoToken internal reward;
    DinoMYT internal myt;
    DinoOracle internal oracle;
    DinoSwap internal swapper;
    MYTStrategy internal strategy;
    function _init() internal {
        asset=new DinoToken();receipt=new DinoToken();reward=new DinoToken();myt=new DinoMYT(address(asset));oracle=new DinoOracle();swapper=new DinoSwap();
        vm.warp(10000);oracle.set(1e18,10000);vm.deal(address(asset),1e30);
    }
    function _params() internal view returns(IMYTStrategy.StrategyParams memory){return IMYTStrategy.StrategyParams(address(this),"Dino","model",IMYTStrategy.RiskClass.LOW,123,456,789,false,25);}
    function _wire() internal {strategy.setAllowanceHolder(address(swapper));}
    function _data(IMYTStrategy.ActionType a,bytes memory d,uint256 n) internal pure returns(bytes memory){return abi.encode(IMYTStrategy.VaultAdapterParams(a,IMYTStrategy.SwapParams(d,n)));}
    function _route(address from,address to,uint256 n,uint256 out) internal pure returns(bytes memory){return abi.encodeCall(DinoSwap.swap,(from,to,n,out));}
    function _allocate(IMYTStrategy.ActionType a,uint256 n,bytes memory d) internal returns(int256 change){vm.prank(address(myt));(bytes32[] memory ids,int256 c)=strategy.allocate(_data(a,d,0),n,bytes4(0),address(this));assert(ids.length==1&&ids[0]==strategy.adapterId());return c;}
    function _exit(IMYTStrategy.ActionType a,uint256 n,bytes memory d,uint256 minIntermediate) internal returns(int256 change){
        vm.prank(address(myt));(bytes32[] memory ids,int256 c)=strategy.deallocate(_data(a,d,minIntermediate),n,bytes4(0),address(this));
        assert(ids.length==1&&ids[0]==strategy.adapterId());assert(asset.allowance(address(strategy),address(myt))==n);
        uint256 before=mytAssetBalance();myt.pull(address(strategy),n);assert(mytAssetBalance()==before+n);return c;
    }
    function mytAssetBalance() internal view returns(uint256){return asset.balanceOf(address(myt));}
    function _bad(address target,bytes memory data,bytes memory reason) internal {
        (bool ok,bytes memory got)=target.call(data);assert(!ok);assert(keccak256(got)==keccak256(reason));
    }
    function _ownerOnlyAs(address caller,bytes memory data) internal {
        address ownerBefore=strategy.owner();bool paused=strategy.killSwitch();address spender=strategy.allowanceHolder();
        vm.prank(caller);(bool ok,bytes memory reason)=address(strategy).call(data);
        assert(!ok);assert(keccak256(reason)==keccak256(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)",caller)));
        assert(strategy.owner()==ownerBefore&&strategy.killSwitch()==paused&&strategy.allowanceHolder()==spender);
    }
    function _revertString(string memory s) internal pure returns(bytes memory){return abi.encodeWithSignature("Error(string)",s);}
    function _panic(uint256 n) internal pure returns(bytes memory){return abi.encodeWithSignature("Panic(uint256)",n);}
    function _slip() internal view returns(uint256 n){(,,,,,,,,n)=strategy.params();}
}
abstract contract DinoBaseFixture is DinoFixture {
    DinoBaseHarness internal h;
    function setUp() public virtual {_init();h=new DinoBaseHarness(address(myt),_params());strategy=h;_wire();}
}
abstract contract DinoOracleFixture is DinoFixture {
    DinoOracleHarness internal h;
    function setUp() public virtual {_init();h=new DinoOracleHarness(address(myt),_params(),address(oracle),address(receipt));strategy=h;_wire();}
}
abstract contract Dino4626Fixture is DinoFixture {
    Dino4626 internal vault;
    function setUp() public virtual {_init();vault=new Dino4626(address(asset));strategy=new ERC4626Strategy(address(myt),_params(),address(vault));_wire();}
}
abstract contract DinoYearnFixture is DinoFixture {
    Dino4626 internal vault;
    function setUp() public virtual {_init();vault=new Dino4626(address(asset));strategy=new YearnV3Strategy(address(myt),_params(),address(vault));_wire();}
}
abstract contract DinoAaveFixture is DinoFixture {
    DinoAave internal pool;DinoRewarder internal rewards;
    function setUp() public virtual {_init();pool=new DinoAave(receipt);rewards=new DinoRewarder(address(receipt),address(reward));strategy=new AaveStrategy(address(myt),_params(),address(asset),address(receipt),address(pool),address(rewards),address(reward));_wire();}
}
abstract contract DinoMoonFixture is DinoFixture {
    DinoMoon internal moon;DinoRewarder internal rewards;
    function setUp() public virtual {_init();moon=new DinoMoon(address(asset));rewards=new DinoRewarder(address(moon),address(reward));strategy=new MoonwellStrategy(address(myt),_params(),address(asset),address(moon),address(rewards),address(reward),true);_wire();vm.deal(address(moon),1e30);}
}
abstract contract DinoWstFixture is DinoFixture {
    DinoWrappedToken internal wrapped;DinoWstHarness internal h;
    function setUp() public virtual {_init();wrapped=new DinoWrappedToken();h=new DinoWstHarness(address(myt),_params(),address(wrapped),address(oracle));strategy=h;_wire();}
}
abstract contract DinoWstL2Fixture is DinoFixture {
    DinoWrappedToken internal wrapped;DinoWstL2Harness internal h;
    function setUp() public virtual {_init();wrapped=new DinoWrappedToken();h=new DinoWstL2Harness(address(myt),_params(),address(wrapped),address(oracle));strategy=h;_wire();}
}
abstract contract DinoFraxFixture is DinoFixture {
    Dino4626 internal shares;DinoFraxMinter internal minter;DinoFraxHarness internal h;
    function setUp() public virtual {_init();shares=new Dino4626(address(receipt));minter=new DinoFraxMinter(shares);h=new DinoFraxHarness(address(myt),_params(),address(minter),address(receipt),address(shares),address(oracle));strategy=h;_wire();}
}
abstract contract DinoEtherFixture is DinoFixture {
    DinoToken internal we;DinoEther internal manager;DinoEtherHarness internal h;
    function setUp() public virtual {_init();we=new DinoToken();manager=new DinoEther(asset,we);h=new DinoEtherHarness(address(myt),_params(),address(receipt),address(we),address(manager),address(oracle));strategy=h;_wire();vm.deal(address(manager),1e30);}
}
abstract contract DinoSiFixture is DinoFixture {
    Dino4626 internal shares;DinoSi internal gateway;DinoSiHarness internal h;
    function setUp() public virtual {_init();shares=new Dino4626(address(receipt));gateway=new DinoSi(asset,receipt,shares);h=new DinoSiHarness(address(myt),_params(),address(asset),address(receipt),address(shares),address(gateway),address(oracle));strategy=h;_wire();}
}
abstract contract DinoDAOFixture is DinoFixture {
    DinoCurve internal curve;DinoAccountant internal accountant;DinoStakeVault internal vault;DinoDAOHarness internal h;
    function setUp() public virtual {_init();curve=new DinoCurve(address(asset));accountant=new DinoAccountant(address(reward));vault=new DinoStakeVault(address(curve),address(accountant));h=new DinoDAOHarness(address(myt),_params(),address(vault),address(curve),address(swapper));strategy=h;_wire();}
}
abstract contract DinoTokeFixture is DinoFixture {
    Dino4626 internal vault;DinoRewarder internal rewards;DinoTokeRouter internal router;
    function setUp() public virtual {_init();vault=new Dino4626(address(asset));rewards=new DinoRewarder(address(vault),address(reward));router=new DinoTokeRouter();strategy=new TokeAutoStrategy(address(myt),_params(),address(asset),address(vault),address(rewards),address(reward),address(router),25);_wire();}
}
