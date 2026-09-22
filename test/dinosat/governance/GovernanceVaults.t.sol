// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceTestBase, GovernanceAsset, GovernanceWETH} from "./GovernanceFixtures.sol";
import {AlchemistETHVault} from "src/AlchemistETHVault.sol";
import {AlchemistTokenVault} from "src/AlchemistTokenVault.sol";

contract GovernanceETHReceiver {
    AlchemistETHVault public vault;
    uint8 public action;
    bytes public reason;
    bool public nestedSucceeded;
    bool public rejectPayment;
    constructor(AlchemistETHVault target) { vault = target; }
    function configure(uint8 mode, bool reject) external { action = mode; rejectPayment = reject; }
    receive() external payable {
        require(!rejectPayment, "receiver failed");
        bytes memory payload = action == 0 ? abi.encodeCall(vault.deposit, ()) : action == 1 ? abi.encodeCall(vault.depositWETH, (uint256(1))) : abi.encodeCall(vault.withdraw, (address(this), uint256(1)));
        (nestedSucceeded, reason) = address(vault).call(payload);
    }
}

contract GovernanceCallbackWETH is GovernanceWETH {
    AlchemistETHVault public vault;
    uint8 public mode;
    bool public nestedSuccess;
    bytes public nestedReason;
    function configure(AlchemistETHVault target,uint8 value) external { vault=target; mode=value; }
    function withdraw(uint256 amount) public override {
        bytes memory payload=mode==0 ? abi.encodeCall(vault.deposit,()) : mode==1 ? abi.encodeCall(vault.depositWETH,(uint256(1))) : abi.encodeCall(vault.withdraw,(address(this),uint256(1)));
        (nestedSuccess,nestedReason)=address(vault).call(payload);
        super.withdraw(amount);
    }
}

contract GovernanceBehaviorAsset is GovernanceAsset {
    uint8 public mode;
    AlchemistTokenVault public callbackVault;
    bool private entered;
    bool public callbackSuccess;
    bytes public callbackReason;
    function configure(uint8 value, AlchemistTokenVault target) external { mode=value; callbackVault=target; }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _behavior(); return ok;
    }
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _behavior(); return ok;
    }
    function _behavior() internal {
        if (mode == 1) { assembly { mstore(0, 0) return(0, 32) } }
        if (mode == 2) { assembly { return(0, 0) } }
        if (mode == 3) revert("token failed");
        if (mode == 4 && !entered) {
            entered = true;
            (callbackSuccess, callbackReason) = address(callbackVault).call(abi.encodeCall(callbackVault.withdraw, (address(0x1004), uint256(1))));
            entered = false;
        }
    }
}

contract GovernanceETHVault is GovernanceTestBase {
    GovernanceAsset internal asset;
    AlchemistETHVault internal subject;
    function setUp() public { asset = new GovernanceWETH(); subject = new AlchemistETHVault(address(asset), OPERATOR, ADMIN); }
    /// @custom:property AlchemistETHVault-AC-01 AlchemistETHVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification DIRECT: uint96 custody values prevent fixture funding overflow.
    function test_check_withdraw(uint96 raw) public {
        uint256 amount = uint256(raw) + 1;
        vm.deal(address(subject), amount);
        uint256 beforeRecipient = BOB.balance;
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.withdraw, (BOB, amount)), abi.encodeWithSignature("Unauthorized()"));
        assert(subject.totalDeposits() == amount && BOB.balance == beforeRecipient);
        vm.prank(OPERATOR); subject.withdraw(BOB, amount);
        assert(subject.totalDeposits() == 0 && BOB.balance == beforeRecipient + amount);
        assert(subject.totalDeposits() == address(subject).balance);
    }
    /// @custom:property AlchemistETHVault-AC-02 AlchemistETHVault-AUTH
    /// @custom:classification DIRECT: exact owner guard with authorized success control.
    function test_check_authorization(bool value) public {
        assert(subject.authorized(ADMIN) && subject.authorized(OPERATOR));
        assert(subject.owner() == ADMIN && subject.token() == address(asset));
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.setAuthorization, (ALICE, value)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(!subject.authorized(ALICE));
        vm.prank(ADMIN); subject.setAuthorization(ALICE, value);
        assert(subject.authorized(ALICE) == value && subject.token() == address(asset));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setAuthorization, (address(0), true)), abi.encodeWithSignature("ZeroAddress()"));
    }
    /// @custom:property AlchemistETHVault-AC-03 AlchemistETHVault-AC-04 AlchemistETHVault-OWNER
    /// @custom:classification DIRECT: independent owner and withdrawal authorization after transfer and renounce.
    function test_check_ownership() public {
        uint256 amount = 2;
        vm.deal(address(subject), amount);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.renounceOwnership, ()), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.transferOwnership, (ALICE)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(subject.owner() == ADMIN);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.transferOwnership, (address(0))), abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        vm.prank(ADMIN); subject.transferOwnership(ALICE);
        assert(subject.owner() == ALICE && subject.authorized(ADMIN) && !subject.authorized(ALICE));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setAuthorization, (BOB, true)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ADMIN));
        vm.prank(ADMIN); subject.withdraw(BOB, 1);
        vm.prank(ALICE); subject.setAuthorization(BOB, true);
        vm.prank(ALICE); subject.renounceOwnership();
        assert(subject.owner() == address(0) && subject.authorized(BOB));
        vm.prank(BOB); subject.withdraw(BOB, 1);
        assert(subject.totalDeposits() == 0);
    }
    /// @custom:property AlchemistETHVault-AUTH
    /// @custom:classification ENUMERATE: all three invalid construction inputs.
    function test_check_constructor() public {
        try new AlchemistETHVault(address(0), OPERATOR, ADMIN) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("ZeroAddress()"))); }
        try new AlchemistETHVault(address(asset), address(0), ADMIN) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("ZeroAddress()"))); }
        try new AlchemistETHVault(address(asset), OPERATOR, address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)))); }
    }
    /// @custom:property AlchemistETHVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW
    /// @custom:classification ENUMERATE: zero and self-recipient branches.
    function test_check_withdrawInvalidAndSelf() public {
        uint256 amount = 3; vm.deal(address(subject), amount);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.withdraw, (address(0), uint256(1))), abi.encodeWithSignature("ZeroAddress()"));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.withdraw, (BOB, uint256(0))), abi.encodeWithSignature("ZeroAmount()"));
        vm.prank(ADMIN); subject.withdraw(address(subject), 2);
        assert(subject.totalDeposits() == amount);
    }

    /// @custom:property AlchemistETHVault-AC-01 AlchemistETHVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_withdraw(uint96 raw) public { test_check_withdraw(raw); }
    /// @custom:property AlchemistETHVault-AC-02 AlchemistETHVault-AUTH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_authorization(bool value) public { test_check_authorization(value); }
    /// @custom:property AlchemistETHVault-AC-03 AlchemistETHVault-AC-04 AlchemistETHVault-OWNER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_ownership() public { test_check_ownership(); }
    /// @custom:property AlchemistETHVault-AUTH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_constructor() public { test_check_constructor(); }
    /// @custom:property AlchemistETHVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_withdrawInvalidAndSelf() public { test_check_withdrawInvalidAndSelf(); }
}

contract GovernanceTokenVault is GovernanceTestBase {
    GovernanceAsset internal asset;
    AlchemistTokenVault internal subject;
    function setUp() public { asset = new GovernanceAsset(); subject = new AlchemistTokenVault(address(asset), OPERATOR, ADMIN); }
    /// @custom:property AlchemistTokenVault-AC-01 AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification DIRECT: uint96 custody values prevent fixture funding overflow.
    function test_check_withdraw(uint96 raw) public {
        uint256 amount = uint256(raw) + 1;
        asset.mint(address(subject), amount);
        uint256 beforeRecipient = asset.balanceOf(BOB);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.withdraw, (BOB, amount)), abi.encodeWithSignature("Unauthorized()"));
        assert(subject.totalDeposits() == amount && asset.balanceOf(BOB) == beforeRecipient);
        vm.prank(OPERATOR); subject.withdraw(BOB, amount);
        assert(subject.totalDeposits() == 0 && asset.balanceOf(BOB) == beforeRecipient + amount);
        assert(subject.totalDeposits() == asset.balanceOf(address(subject)));
    }
    /// @custom:property AlchemistTokenVault-AC-02 AlchemistTokenVault-AUTH
    /// @custom:classification DIRECT: exact owner guard with authorized success control.
    function test_check_authorization(bool value) public {
        assert(subject.authorized(ADMIN) && subject.authorized(OPERATOR));
        assert(subject.owner() == ADMIN && subject.token() == address(asset));
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.setAuthorization, (ALICE, value)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(!subject.authorized(ALICE));
        vm.prank(ADMIN); subject.setAuthorization(ALICE, value);
        assert(subject.authorized(ALICE) == value && subject.token() == address(asset));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setAuthorization, (address(0), true)), abi.encodeWithSignature("ZeroAddress()"));
    }
    /// @custom:property AlchemistTokenVault-AC-03 AlchemistTokenVault-AC-04 AlchemistTokenVault-OWNER
    /// @custom:classification DIRECT: independent owner and withdrawal authorization after transfer and renounce.
    function test_check_ownership() public {
        uint256 amount = 2;
        asset.mint(address(subject), amount);
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.renounceOwnership, ()), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        _reject(address(subject), OUTSIDER, abi.encodeCall(subject.transferOwnership, (ALICE)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OUTSIDER));
        assert(subject.owner() == ADMIN);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.transferOwnership, (address(0))), abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        vm.prank(ADMIN); subject.transferOwnership(ALICE);
        assert(subject.owner() == ALICE && subject.authorized(ADMIN) && !subject.authorized(ALICE));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setAuthorization, (BOB, true)), abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ADMIN));
        vm.prank(ADMIN); subject.withdraw(BOB, 1);
        vm.prank(ALICE); subject.setAuthorization(BOB, true);
        vm.prank(ALICE); subject.renounceOwnership();
        assert(subject.owner() == address(0) && subject.authorized(BOB));
        vm.prank(BOB); subject.withdraw(BOB, 1);
        assert(subject.totalDeposits() == 0);
    }
    /// @custom:property AlchemistTokenVault-AUTH
    /// @custom:classification ENUMERATE: all three invalid construction inputs.
    function test_check_constructor() public {
        try new AlchemistTokenVault(address(0), OPERATOR, ADMIN) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("ZeroAddress()"))); }
        try new AlchemistTokenVault(address(asset), address(0), ADMIN) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("ZeroAddress()"))); }
        try new AlchemistTokenVault(address(asset), OPERATOR, address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)))); }
    }
    /// @custom:property AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW
    /// @custom:classification ENUMERATE: zero and self-recipient branches.
    function test_check_withdrawInvalidAndSelf() public {
        uint256 amount = 3; asset.mint(address(subject), amount);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.withdraw, (address(0), uint256(1))), abi.encodeWithSignature("ZeroAddress()"));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.withdraw, (BOB, uint256(0))), abi.encodeWithSignature("ZeroAmount()"));
        vm.prank(ADMIN); subject.withdraw(address(subject), 2);
        assert(subject.totalDeposits() == amount);
    }

    /// @custom:property AlchemistTokenVault-AC-01 AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_withdraw(uint96 raw) public { test_check_withdraw(raw); }
    /// @custom:property AlchemistTokenVault-AC-02 AlchemistTokenVault-AUTH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_authorization(bool value) public { test_check_authorization(value); }
    /// @custom:property AlchemistTokenVault-AC-03 AlchemistTokenVault-AC-04 AlchemistTokenVault-OWNER
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_ownership() public { test_check_ownership(); }
    /// @custom:property AlchemistTokenVault-AUTH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_constructor() public { test_check_constructor(); }
    /// @custom:property AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-WITHDRAW
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_withdrawInvalidAndSelf() public { test_check_withdrawInvalidAndSelf(); }
}

contract GovernanceETHFlows is GovernanceTestBase {
    GovernanceWETH internal weth;
    AlchemistETHVault internal subject;
    function setUp() public { weth=new GovernanceWETH(); subject=new AlchemistETHVault(address(weth), OPERATOR, ADMIN); }
    /// @custom:property ETH-DEPOSIT STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification DIRECT: bounded native funding, deposit and receive are actual calls.
    function test_check_deposit(uint96 raw, uint96 donation) public {
        uint256 amount = uint256(raw) + 1;
        vm.deal(ALICE, amount + donation);
        vm.prank(ALICE); subject.deposit{value:amount}();
        vm.prank(ALICE); (bool ok,) = address(subject).call{value:donation}(""); assert(ok);
        assert(subject.totalDeposits() == amount + donation && address(subject).balance == amount + donation);
        _reject(address(subject), ALICE, abi.encodeCall(subject.deposit, ()), abi.encodeWithSignature("ZeroAmount()"));
    }
    /// @custom:property ETH-WETH
    /// @custom:classification ENUMERATE: exact one-to-one WETH counterparty and unwrap rollback.
    function test_check_weth(uint96 raw) public {
        uint256 amount = uint256(raw) + 1;
        vm.deal(ALICE, amount); vm.prank(ALICE); weth.deposit{value:amount}();
        vm.prank(ALICE); weth.approve(address(subject), amount);
        weth.setFailUnwrap(true);
        _reject(address(subject), ALICE, abi.encodeCall(subject.depositWETH, (amount)), _error("unwrap failed"));
        assert(weth.balanceOf(ALICE) == amount && weth.balanceOf(address(subject)) == 0 && subject.totalDeposits() == 0);
        weth.setFailUnwrap(false); vm.prank(ALICE); subject.depositWETH(amount);
        assert(weth.balanceOf(ALICE) == 0 && weth.balanceOf(address(subject)) == 0 && subject.totalDeposits() == amount);
        weth.mint(address(subject), 7); assert(subject.totalDeposits() == amount);
        _reject(address(subject), ALICE, abi.encodeCall(subject.depositWETH, (uint256(0))), abi.encodeWithSignature("ZeroAmount()"));
    }
    /// @custom:property ETH-WETH
    /// @custom:classification ENUMERATE: false/reverting token transfer preserves source balance before unwrap.
    function test_check_wethTransferFailure(bool falseReturn) public {
        GovernanceBehaviorAsset bad=new GovernanceBehaviorAsset();
        AlchemistETHVault other=new AlchemistETHVault(address(bad),OPERATOR,ADMIN);
        bad.mint(ALICE,1); vm.prank(ALICE); bad.approve(address(other),1);
        bad.configure(falseReturn ? 1 : 3,AlchemistTokenVault(address(0)));
        bytes memory expected=falseReturn ? abi.encodeWithSignature("SafeERC20FailedOperation(address)",address(bad)) : _error("token failed");
        _reject(address(other),ALICE,abi.encodeCall(other.depositWETH,(uint256(1))),expected);
        assert(bad.balanceOf(ALICE)==1 && bad.balanceOf(address(other))==0 && other.totalDeposits()==0);
    }
    /// @custom:property ETH-REENTRANCY ETH-WETH
    /// @custom:classification ENUMERATE: authorized WETH callback tests all guarded entry selectors during depositWETH.
    function test_check_wethReentry(uint8 raw) public {
        GovernanceCallbackWETH callbackWeth=new GovernanceCallbackWETH();
        AlchemistETHVault other=new AlchemistETHVault(address(callbackWeth),OPERATOR,ADMIN);
        callbackWeth.configure(other,raw%3); vm.prank(ADMIN); other.setAuthorization(address(callbackWeth),true);
        vm.deal(ALICE,1); vm.prank(ALICE); callbackWeth.deposit{value:1}();
        vm.prank(ALICE); callbackWeth.approve(address(other),1);
        vm.prank(ALICE); other.depositWETH(1);
        assert(!callbackWeth.nestedSuccess() && keccak256(callbackWeth.nestedReason())==keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()")));
        assert(other.totalDeposits()==1 && callbackWeth.balanceOf(address(other))==0);
    }
    /// @custom:property ETH-REENTRANCY AlchemistETHVault-WITHDRAW
    /// @custom:classification DECOMPOSE: one authorized receiver, three guarded entry selectors.
    function test_check_receiverReentry(uint8 raw) public {
        uint8 mode=raw % 3;
        GovernanceETHReceiver receiver = new GovernanceETHReceiver(subject);
        receiver.configure(mode, false);
        vm.prank(ADMIN); subject.setAuthorization(address(receiver), true);
        vm.deal(address(subject), 2);
        vm.prank(OPERATOR); subject.withdraw(address(receiver), 1);
        assert(!receiver.nestedSucceeded());
        assert(keccak256(receiver.reason()) == keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()")));
        assert(subject.totalDeposits() == 1 && address(receiver).balance == 1);
        receiver.configure(mode, true);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.withdraw, (address(receiver), uint256(1))), abi.encodeWithSignature("TransferFailed()"));
        assert(subject.totalDeposits() == 1 && address(receiver).balance == 1);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.withdraw, (BOB, uint256(2))), abi.encodeWithSignature("InsufficientBalance()"));
    }

    /// @custom:property ETH-DEPOSIT STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_deposit(uint96 raw, uint96 donation) public { test_check_deposit(raw, donation); }
    /// @custom:property ETH-WETH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_weth(uint96 raw) public { test_check_weth(raw); }
    /// @custom:property ETH-WETH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_wethTransferFailure(bool falseReturn) public { test_check_wethTransferFailure(falseReturn); }
    /// @custom:property ETH-REENTRANCY ETH-WETH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_wethReentry(uint8 raw) public { test_check_wethReentry(raw); }
    /// @custom:property ETH-REENTRANCY AlchemistETHVault-WITHDRAW
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_receiverReentry(uint8 raw) public { test_check_receiverReentry(raw); }
}

contract GovernanceTokenFlows is GovernanceTestBase {
    GovernanceBehaviorAsset internal asset;
    AlchemistTokenVault internal subject;
    function setUp() public { asset=new GovernanceBehaviorAsset(); subject=new AlchemistTokenVault(address(asset), OPERATOR, ADMIN); }
    /// @custom:property TOKEN-DEPOSIT AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification ENUMERATE: standard true, false, empty and revert token responses.
    function test_check_tokenResponses(uint96 raw, uint8 modeRaw) public {
        uint256 amount=uint256(raw)+1; uint8 mode=modeRaw % 4;
        asset.mint(ALICE, amount); vm.prank(ALICE); asset.approve(address(subject), amount);
        asset.configure(mode, subject);
        vm.prank(ALICE); (bool ok, bytes memory reason)=address(subject).call(abi.encodeCall(subject.deposit, (amount)));
        assert(ok == (mode==0 || mode==2));
        if (ok) {
            assert(subject.totalDeposits()==amount && asset.balanceOf(ALICE)==0);
            vm.prank(OPERATOR); subject.withdraw(BOB, amount);
            assert(subject.totalDeposits()==0 && asset.balanceOf(BOB)==amount);
        } else {
            assert(subject.totalDeposits()==0 && asset.balanceOf(ALICE)==amount && asset.allowance(ALICE,address(subject))==amount);
            bytes memory expected=mode==1 ? abi.encodeWithSignature("SafeERC20FailedOperation(address)",address(asset)) : _error("token failed");
            assert(keccak256(reason)==keccak256(expected));
        }
        _reject(address(subject), ALICE, abi.encodeCall(subject.deposit, (uint256(0))), abi.encodeWithSignature("ZeroAmount()"));
    }
    /// @custom:property TOKEN-CALLBACK
    /// @custom:classification FUZZ: explicit authorized versus unauthorized callback counterparty.
    function test_fuzz_tokenCallback(bool authorize) public {
        asset.mint(ALICE, 2); vm.prank(ALICE); asset.approve(address(subject), 2);
        vm.prank(ADMIN); subject.setAuthorization(address(asset), authorize);
        asset.configure(4,subject); vm.prank(ALICE); subject.deposit(2);
        assert(asset.callbackSuccess()==authorize);
        assert(subject.totalDeposits()==(authorize ? 1 : 2));
        assert(asset.balanceOf(BOB)==(authorize ? 1 : 0));
        if (!authorize) assert(keccak256(asset.callbackReason())==keccak256(abi.encodeWithSignature("Unauthorized()")));
        assert(subject.authorized(address(asset))==authorize);
    }
    /// @custom:property AlchemistTokenVault-WITHDRAW
    /// @custom:classification ENUMERATE: failure after prior deposit restores custody and recipient.
    function test_check_failedWithdrawal(uint8 modeRaw) public {
        uint8 mode = modeRaw % 2 == 0 ? 1 : 3;
        asset.mint(address(subject), 5); asset.configure(mode, subject);
        bytes memory expected = mode==1 ? abi.encodeWithSignature("SafeERC20FailedOperation(address)",address(asset)) : _error("token failed");
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.withdraw,(BOB,uint256(2))), expected);
        assert(subject.totalDeposits()==5 && asset.balanceOf(BOB)==0);
        asset.configure(0,subject);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.withdraw,(BOB,uint256(6))), abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)",address(subject),uint256(5),uint256(6)));
        assert(subject.totalDeposits()==5);
    }

    /// @custom:property TOKEN-DEPOSIT AlchemistTokenVault-WITHDRAW STR-FEE-ABSTRACT-TOTAL
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_tokenResponses(uint96 raw, uint8 modeRaw) public { test_check_tokenResponses(raw, modeRaw); }
    /// @custom:property AlchemistTokenVault-WITHDRAW
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_failedWithdrawal(uint8 modeRaw) public { test_check_failedWithdrawal(modeRaw); }
}
