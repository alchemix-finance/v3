// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlchemistV3} from "../../../src/AlchemistV3.sol";
import {AlchemistInitializationParams} from "../../../src/interfaces/IAlchemistV3.sol";
import {AlchemistV3Position} from "../../../src/AlchemistV3Position.sol";
import {AlchemistRouter} from "../../../src/router/AlchemistRouter.sol";

/// @dev Token model: exact transfers, no rebase or fees. Faucet is fixture-only.
contract CoreToken is ERC20 {
    uint8 private immutable units;
    address public callbackTarget; bytes public callbackData; bool public callbackAttempted; bytes4 public callbackError;
    function setCallback(address target, bytes calldata data) external { callbackTarget=target; callbackData=data; }
    function transferFrom(address from,address to,uint256 value) public override returns(bool) {
        bool ok=super.transferFrom(from,to,value);
        if(callbackTarget!=address(0)) { callbackAttempted=true; (bool success,bytes memory reason)=callbackTarget.call(callbackData); require(!success); if(reason.length>=4) callbackError=bytes4(reason); }
        return ok;
    }
    constructor(uint8 decimals_) ERC20("Fixture", "FIX") { units = decimals_; }
    function decimals() public view override returns (uint8) { return units; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
    function burnFrom(address from, uint256 amount) external { _spendAllowance(from, msg.sender, amount); _burn(from, amount); }
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external { _burn(msg.sender, amount); (bool ok,) = msg.sender.call{value:amount}(""); require(ok); }
    receive() external payable {}
}

/// @dev Unit fixture only. Fixed WAD price, floor conversions, no virtual offsets.
/// Real VaultV2 composition is checked separately in integration tests.
contract CoreVault is ERC20 {
    CoreToken public immutable underlying;
    uint256 public price = 1e18;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    constructor(CoreToken token) ERC20("Fixture shares", "FS") { underlying = token; }
    function asset() external view returns (address) { return address(underlying); }
    function setPrice(uint256 value) external { price = value; }
    function mintFixture(address to, uint256 value) external { _mint(to, value); }
    function convertToAssets(uint256 shares) public view returns (uint256) { return shares * price / 1e18; }
    function convertToShares(uint256 assets) public view returns (uint256) { return assets * 1e18 / price; }
    function setCallback(address target, bytes calldata data) external { callbackTarget = target; callbackData = data; }
    function _callback() internal {
        if (callbackTarget != address(0)) {
            callbackAttempted = true;
            (bool ok,bytes memory reason) = callbackTarget.call(callbackData); callbackSucceeded=ok; if(reason.length>=4) callbackError=bytes4(reason);
        }
    }
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(underlying.transferFrom(msg.sender, address(this), assets));
        _callback();
        _mint(receiver, shares);
    }
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (owner != msg.sender) _spendAllowance(owner, msg.sender, shares);
        assets = convertToAssets(shares);
        _burn(owner, shares);
        _callback();
        require(underlying.transfer(receiver, assets));
    }
}

/// @dev Unit graph/lock fixture; no claim is represented as a real Transmuter proof.
contract CoreTransmuter is ERC721 {
    uint256 public totalLocked;
    uint256 public scheduled;
    CoreVault public shares;
    CoreToken public synthetics;
    uint256 public claimShares;
    uint256 public claimRefund;
    constructor() ERC721("Fixture claims", "FC") {}
    function configure(uint256 locked_, uint256 scheduled_) external { totalLocked = locked_; scheduled = scheduled_; }
    function queryGraph(uint256, uint256) external view returns (uint256) { return scheduled; }
    function seedClaim(address owner, CoreVault vault, CoreToken debt, uint256 yield_, uint256 refund) external {
        shares = vault; synthetics = debt; claimShares = yield_; claimRefund = refund;
        _mint(owner, 1);
        vault.mintFixture(address(this), yield_); debt.mint(address(this), refund);
    }
    function claimRedemption(uint256 id) external returns (uint256,uint256,uint256,uint256) {
        require(ownerOf(id) == msg.sender); _burn(id);
        require(shares.transfer(msg.sender, claimShares)); require(synthetics.transfer(msg.sender, claimRefund));
        return (claimShares, 0, claimRefund, 0);
    }
}

/// @dev Exposes original internal logic; does not replace implementation code.
contract CoreAlchemistHarness is AlchemistV3 {
    function earmarkRatio(uint256 a, uint256 b) external pure returns (uint256) { return _earmarkSurvivalRatio(a,b); }
    function redemptionRatio(uint256 a, uint256 b) external pure returns (uint256) { return _redemptionSurvivalRatio(a,b); }
    function packedUpdate(uint256 a, uint256 b) external pure returns (uint256,uint256,uint256,uint256,bool) { return _simulateEarmarkPackedUpdate(a,b); }
    function internalLiquidate(uint256 id) external returns (uint256,uint256,uint256) { return _liquidate(id); }
    function feeLimit(uint256 id) external view returns (uint256) { return _maxRepaymentFeeInYield(id); }
    /// @dev Read-only access; slots checked against compiler storageLayout in Phase 3.
    function raw(uint256 slot) external view returns (uint256 value) { assembly { value := sload(slot) } }
    function stored(uint256 id, uint256 offset) external view returns (uint256 value) {
        bytes32 slot = keccak256(abi.encode(id, uint256(33)));
        assembly { value := sload(add(slot, offset)) }
    }
}

abstract contract CoreFixture is Test {
    CoreToken internal asset;
    CoreToken internal debt;
    CoreVault internal vault;
    CoreTransmuter internal trans;
    CoreAlchemistHarness internal alc;
    AlchemistV3Position internal nft;
    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);
    address internal constant FEES = address(0xfee);
    uint256 internal constant Q = uint256(1) << 128;
    function _params(address underlying_, address debt_, address vault_, address trans_) internal view returns (AlchemistInitializationParams memory p) {
        p = AlchemistInitializationParams({admin:address(this),debtToken:debt_,underlyingToken:underlying_,depositCap:1e36,
            minimumCollateralization:15e17,globalMinimumCollateralization:15e17,collateralizationLowerBound:11e17,
            liquidationTargetCollateralization:15e17,transmuter:trans_,protocolFee:0,protocolFeeReceiver:FEES,
            liquidatorFee:0,repaymentFee:0,myt:vault_});
    }
    function setUp() public virtual {
        vm.roll(100); vm.warp(1000);
        asset = new CoreToken(18); debt = new CoreToken(18); vault = new CoreVault(asset); trans = new CoreTransmuter();
        CoreAlchemistHarness logic = new CoreAlchemistHarness();
        alc = CoreAlchemistHarness(address(new ERC1967Proxy(address(logic), abi.encodeCall(AlchemistV3.initialize, (_params(address(asset),address(debt),address(vault),address(trans)))))));
        nft = new AlchemistV3Position(address(alc),address(this));
        _ok(address(alc), abi.encodeCall(AlchemistV3.setAlchemistPositionNFT,(address(nft))));
        vault.mintFixture(ALICE,1e30); vault.mintFixture(BOB,1e30); asset.mint(address(vault),1e30);
        vm.prank(ALICE); vault.approve(address(alc),type(uint256).max);
        vm.prank(BOB); vault.approve(address(alc),type(uint256).max);
        vm.prank(ALICE); debt.approve(address(alc),type(uint256).max);
    }
    function _ok(address target, bytes memory data) internal returns (bytes memory result) {
        bool success; (success,result) = target.call(data); assert(success);
    }
    function _as(address actor,address target,bytes memory data) internal returns (bytes memory result) { vm.prank(actor); return _ok(target,data); }
    function _fails(address actor,address target,bytes memory data) internal returns (bytes memory reason) {
        vm.prank(actor); (bool success,bytes memory result) = target.call(data); assert(!success); return result;
    }
    function _deposit(uint256 amount) internal returns (uint256 id) {
        (id,) = abi.decode(_as(ALICE,address(alc),abi.encodeCall(AlchemistV3.deposit,(amount,ALICE,0))),(uint256,uint256));
    }
    function _borrow(uint256 collateral,uint256 amount) internal returns (uint256 id) {
        id = _deposit(collateral);
        _as(ALICE,address(alc),abi.encodeCall(AlchemistV3.mint,(id,amount,ALICE)));
    }
    function _checkCDP(uint256 id,uint256 c,uint256 d,uint256 e) internal view { (uint256 ac,uint256 ad,uint256 ae)=alc.getCDP(id); assert(ac==c && ad==d && ae==e); }
}
