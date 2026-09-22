// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DinosatAssertions} from "./DinosatAssertions.sol";
import {Sets} from "../../../src/libraries/Sets.sol";
import {Whitelist} from "../../../src/utils/Whitelist.sol";
import {PermissionedProxy} from "../../../src/utils/PermissionedProxy.sol";
import {AlEth} from "../../../src/external/AlEth.sol";

contract DinosatSetHarness {
    using Sets for Sets.AddressSet;
    Sets.AddressSet internal s;
    function add(address x) external returns(bool){return s.add(x);}
    function remove(address x) external returns(bool){return s.remove(x);}
    function has(address x) external view returns(bool){return s.contains(x);}
    function values() external view returns(address[] memory){return s.values;}
    function index(address x) external view returns(uint256){return s.indexes[x];}
}
contract DinosatSetsSymbolicTest is DinosatAssertions {
    DinosatSetHarness h;
    function setUp() public {h=new DinosatSetHarness();}
    /// @notice SETS-ADD: insertion is idempotent and preserves the index bijection, including zero address.
    /// @dev Technique: real storage sequence. Classification: DIRECT.
    function test_check_add(address x) public {
        assert(!h.has(x));assert(h.add(x));assert(h.has(x));assert(h.index(x)==1);
        assert(!h.add(x));address[] memory v=h.values();assert(v.length==1);assert(v[0]==x);
    }
    /// @notice SETS-REMOVE: middle swap-pop preserves both surviving entries.
    /// @dev Technique: T9 concrete distinct address shape. Classification: ENUMERATE.
    function test_check_removeMiddle(uint160 raw) public {
        address a=address(raw);address b=address(raw^1);address c=address(raw^2);
        h.add(a);h.add(b);h.add(c);assert(h.remove(b));assert(!h.has(b));assert(h.index(b)==0);
        address[] memory v=h.values();assert(v.length==2);assert(v[0]==a);assert(v[1]==c);assert(h.index(c)==2);
        assert(!h.remove(b));assert(h.remove(c));assert(h.remove(a));assert(h.values().length==0);assert(!h.remove(a));
    }
    /// @notice SETS-REMOVE: removing first or last retains the other member.
    /// @dev Technique: T9 concrete two-element branches. Classification: ENUMERATE.
    function test_check_removeEnds(address a,bool first) public {
        address b=address(uint160(a)^1);h.add(a);h.add(b);address removed=first?a:b;address kept=first?b:a;
        assert(h.remove(removed));assert(h.has(kept));assert(h.index(kept)==1);assert(h.values()[0]==kept);
    }
    /// @notice SETS-ADD,SETS-REMOVE: longer action histories match independent membership bits.
    /// @dev Technique: T17 finite model. Classification: FUZZ. Four-address universe and 16 operations.
    function test_fuzz_history(uint256 actions) public {
        bool[4] memory members;
        for(uint256 i;i<16;i++){uint256 id=(actions>>(i*4))&3;address a=address(uint160(id));bool add=((actions>>(i*4+2))&1)==1;
            if(add){assert(h.add(a)==!members[id]);members[id]=true;}else{assert(h.remove(a)==members[id]);members[id]=false;}
            uint256 count;for(uint256 j;j<4;j++){assert(h.has(address(uint160(j)))==members[j]);if(members[j])count++;}
            address[] memory v=h.values();assert(v.length==count);for(uint256 k;k<v.length;k++){assert(h.index(v[k])==k+1);}
        }
    }
}
contract DinosatWhitelistSymbolicTest is DinosatAssertions {
    Whitelist h;address constant OTHER=address(0xBEEF);
    function setUp() public {h=new Whitelist();}
    /// @notice WL-CONSTRUCTOR,WL-SET: owner, empty state, and enabled membership are correct.
    /// @dev Technique: actual contract. Classification: DIRECT.
    function test_check_membership(address a) public {
        assert(h.owner()==address(this));assert(!h.disabled());assert(h.getAddresses().length==0);assert(!h.isWhitelisted(a));
        h.add(a);h.add(a);assert(h.getAddresses().length==1);assert(h.isWhitelisted(a));h.remove(a);assert(!h.isWhitelisted(a));assert(h.getAddresses().length==0);
    }
    /// @notice WL-ADMIN: unauthorized mutation fails with unchanged state.
    /// @dev Technique: guard isolation with valid arguments. Classification: DIRECT.
    function test_check_authorization() public {
        vm.prank(OTHER);_failsSelector(address(h),abi.encodeCall(h.add,(OTHER)),bytes4(keccak256("Unauthorized()")));
        vm.prank(OTHER);_failsSelector(address(h),abi.encodeCall(h.remove,(OTHER)),bytes4(keccak256("Unauthorized()")));
        vm.prank(OTHER);_failsSelector(address(h),abi.encodeCall(h.disable,()),bytes4(keccak256("Unauthorized()")));
        assert(h.getAddresses().length==0);assert(!h.disabled());assert(h.owner()==address(this));
        h.transferOwnership(OTHER);_failsSelector(address(h),abi.encodeCall(h.add,(OTHER)),bytes4(keccak256("Unauthorized()")));
        vm.prank(OTHER);h.add(OTHER);assert(h.isWhitelisted(OTHER));
    }
    /// @notice WL-DISABLE: disable permits every account and freezes mutation.
    /// @dev Technique: irreversible state sequence. Classification: DIRECT.
    function test_check_disable(address who) public {
        h.add(OTHER);h.disable();assert(h.disabled());assert(h.isWhitelisted(who));
        _failsSelector(address(h),abi.encodeCall(h.add,(who)),bytes4(keccak256("IllegalState()")));
        _failsSelector(address(h),abi.encodeCall(h.remove,(OTHER)),bytes4(keccak256("IllegalState()")));
        _fails(address(h),abi.encodeCall(h.disable,()),bytes(""));assert(h.disabled());assert(h.getAddresses().length==1);
    }
}
contract DinosatProxyRecorder {
    uint256 public value;address public caller;uint256 public eth;
    function record(uint256 x) external payable {value=x;caller=msg.sender;eth=msg.value;}
    function fail() external pure {revert("target");}
}
contract DinosatPermissionedProxySymbolicTest is DinosatAssertions {
    PermissionedProxy h;DinosatProxyRecorder target;address constant OP=address(0xA11);address constant NEXT=address(0xB11);
    function setUp() public {h=new PermissionedProxy(address(this),OP);target=new DinosatProxyRecorder();}
    /// @notice PP-CONSTRUCTOR,PP-ADMIN,PP-OPERATOR: authority gates preserve configuration.
    /// @dev Technique: real calls and exact errors. Classification: DIRECT.
    function test_check_admin() public {
        assert(h.operators(OP));assert(!h.operators(NEXT));
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.setOperator,(NEXT,true)),_err("PD"));
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.setPermissionedCall,(target.record.selector,true)),_err("PD"));
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.transferAdminOwnerShip,(NEXT)),_err("PD"));
        assert(!h.operators(NEXT));assert(!h.permissionedCalls(target.record.selector));assert(h.pendingAdmin()==address(0));
        _fails(address(h),abi.encodeCall(h.setOperator,(address(0),true)),_err("zero"));
        h.setOperator(NEXT,true);assert(h.operators(NEXT));h.setOperator(NEXT,false);assert(!h.operators(NEXT));
    }
    /// @notice PP-CONSTRUCTOR: zero constructor roles reject.
    /// @dev Technique: explicit rejected deployments. Classification: DIRECT.
    function test_check_constructorRejects() public {
        try new PermissionedProxy(address(0),OP){assert(false);}catch(bytes memory reason){assert(keccak256(reason)==keccak256(_err("zero")));}
        try new PermissionedProxy(address(this),address(0)){assert(false);}catch(bytes memory reason){assert(keccak256(reason)==keccak256(_err("zero")));}
    }
    /// @notice PP-HANDOFF: acceptance clears pending admin and removes prior authority.
    /// @dev Technique: real role sequence. Classification: DIRECT.
    function test_check_handoff() public {
        h.transferAdminOwnerShip(NEXT);assert(h.pendingAdmin()==NEXT);
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.acceptAdminOwnership,()),_err("PD"));assert(h.pendingAdmin()==NEXT);
        vm.prank(NEXT);h.acceptAdminOwnership();assert(h.pendingAdmin()==address(0));
        _fails(address(h),abi.encodeCall(h.setOperator,(OP,false)),_err("PD"));vm.prank(NEXT);h.setOperator(OP,false);assert(!h.operators(OP));
    }
    /// @notice PP-PROXY: permitted calldata and value reach the exact target.
    /// @dev Technique: T9 fixed ABI length with actual selector assembly. Classification: ENUMERATE.
    function test_check_forward(uint64 x,uint64 value) public {
        h.setPermissionedCall(target.record.selector,true);vm.deal(OP,value);vm.prank(OP);h.proxy{value:value}(address(target),abi.encodeCall(target.record,(x)));
        assert(target.value()==x);assert(target.caller()==address(h));assert(target.eth()==value);assert(address(h).balance==0);
        h.setOperator(OP,false);vm.prank(OP);_fails(address(h),abi.encodeCall(h.proxy,(address(target),abi.encodeCall(target.record,(2)))),_err("PD"));assert(target.value()==x);
    }
    /// @notice PP-PROXY: short input, forbidden selectors and failed targets reject.
    /// @dev Technique: T9 calldata partitions. Classification: ENUMERATE.
    function test_check_proxyRejects(uint8 length) public {
        bytes memory shortData=new bytes(uint256(length)%4);
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.proxy,(address(target),shortData)),_err("SEL"));
        vm.prank(OP);_fails(address(h),abi.encodeCall(h.proxy,(address(target),abi.encodeCall(target.record,(1)))),_err("PD"));
        h.setPermissionedCall(target.fail.selector,true);vm.prank(OP);_fails(address(h),abi.encodeCall(h.proxy,(address(target),abi.encodeCall(target.fail,()))),_err("failed"));assert(target.value()==0);
    }
}
contract DinosatAlEthSymbolicTest is DinosatAssertions {
    AlEth h;address constant USER=address(0xA1);address constant SPENDER=address(0xA2);
    function setUp() public {h=new AlEth();}
    /// @notice ALETH-CONSTRUCTOR,ALETH-CONTROLS: test-only token exposes its stated unrestricted controls.
    /// @dev Technique: actual fixture characterization. Classification: DIRECT. This is not a production access-control proof.
    function test_check_controls(uint64 ceiling) public {
        assert(h.totalSupply()==0);assert(!h.whiteList(USER));assert(keccak256(bytes(h.symbol()))==keccak256("alETH"));assert(keccak256(bytes(h.name()))==keccak256("Alchemix ETH"));
        vm.prank(USER);h.setWhitelist(USER,true);vm.prank(SPENDER);h.setCeiling(USER,ceiling);assert(h.ceiling(USER)==ceiling);
        vm.prank(USER);h.mint(USER,uint256(ceiling)+1);assert(h.totalSupply()==uint256(ceiling)+1);assert(h.hasMinted(USER)>h.ceiling(USER));
        vm.prank(SPENDER);h.pauseAlchemist(USER,true);assert(h.paused(USER));
    }
    /// @notice ALETH-MINT: unauthorized and paused mint reject without changing supply.
    /// @dev Technique: exact reverts plus positive transition. Classification: DIRECT.
    function test_check_mint(uint64 amount) public {
        vm.prank(USER);_fails(address(h),abi.encodeCall(h.mint,(USER,amount)),_err("AlETH: Alchemist is not whitelisted"));assert(h.totalSupply()==0);
        h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,amount);assert(h.totalSupply()==amount);assert(h.balanceOf(USER)==amount);assert(h.hasMinted(USER)==amount);
        h.pauseAlchemist(USER,true);vm.prank(USER);_fails(address(h),abi.encodeCall(h.mint,(USER,1)),_err("AlETH: Alchemist is currently paused."));assert(h.totalSupply()==amount);
    }
    /// @notice ALETH-BURN,ALETH-BURNFROM: burn consumes balances, supply and finite allowance.
    /// @dev Technique: real token state sequence. Classification: DIRECT.
    function test_check_burn(uint64 a,uint64 b) public {
        uint256 total=uint256(a)+b;h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,total);
        vm.prank(USER);h.burn(a);assert(h.totalSupply()==b);assert(h.balanceOf(USER)==b);assert(h.hasMinted(USER)==total);
        vm.prank(USER);h.approve(SPENDER,b);vm.prank(SPENDER);h.burnFrom(USER,b);assert(h.totalSupply()==0);assert(h.balanceOf(USER)==0);assert(h.allowance(USER,SPENDER)==0);
        vm.prank(SPENDER);_fails(address(h),abi.encodeCall(h.burnFrom,(USER,1)),_panicData(0x11));assert(h.totalSupply()==0);
    }
    /// @notice ALETH-BURN,ALETH-BURNFROM: balance failure restores the allowance and all token accounting.
    /// @dev Technique: exact custom error and real rollback. Classification: DIRECT.
    function test_check_insufficientBalance(uint64 amount) public {
        h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,amount);uint256 excessive=uint256(amount)+1;
        bytes memory expected=abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)",USER,uint256(amount),excessive);
        vm.prank(USER);_fails(address(h),abi.encodeCall(h.burn,(excessive)),expected);
        vm.prank(USER);h.approve(SPENDER,excessive);vm.prank(SPENDER);_fails(address(h),abi.encodeCall(h.burnFrom,(USER,excessive)),expected);
        assert(h.allowance(USER,SPENDER)==excessive);assert(h.totalSupply()==amount);assert(h.balanceOf(USER)==amount);assert(h.hasMinted(USER)==amount);
    }
    /// @notice ALETH-BURNFROM: burnFrom decreases even the maximum allowance by the exact amount.
    /// @dev Technique: characterize the production override, not the base ERC20 transferFrom convention. Classification: DIRECT.
    function test_check_maximumAllowance(uint64 raw) public {
        uint256 amount=uint256(raw)+1;h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,amount);vm.prank(USER);h.approve(SPENDER,type(uint256).max);vm.prank(SPENDER);h.burnFrom(USER,amount);
        assert(h.allowance(USER,SPENDER)==type(uint256).max-amount);assert(h.totalSupply()==0);assert(h.balanceOf(USER)==0);assert(h.hasMinted(USER)==amount);
    }
    /// @notice ALETH-MINT: mint counter overflow fails before supply and balance can change.
    /// @dev Technique: actual full-word boundary. Classification: DIRECT.
    function test_check_mintOverflow() public {
        h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,type(uint256).max);vm.prank(USER);_fails(address(h),abi.encodeCall(h.mint,(USER,1)),_panicData(0x11));
        assert(h.totalSupply()==type(uint256).max);assert(h.balanceOf(USER)==type(uint256).max);assert(h.hasMinted(USER)==type(uint256).max);
    }
    /// @notice ALETH-LOWER: hasMinted saturates at zero without changing balances or supply.
    /// @dev Technique: actual storage behavior. Classification: DIRECT.
    function test_check_lower(uint64 amount,uint64 reduction) public {
        h.setWhitelist(USER,true);vm.prank(USER);h.mint(USER,amount);vm.prank(USER);h.lowerHasMinted(reduction);
        assert(h.hasMinted(USER)==(reduction>=amount?0:uint256(amount)-reduction));assert(h.totalSupply()==amount);assert(h.balanceOf(USER)==amount);
        vm.prank(SPENDER);_fails(address(h),abi.encodeCall(h.lowerHasMinted,(1)),_err("AlETH: Alchemist is not whitelisted"));
    }
}
