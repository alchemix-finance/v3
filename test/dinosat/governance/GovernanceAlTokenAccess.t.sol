// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceTestBase} from "./GovernanceFixtures.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "src/AlTokenV3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

abstract contract GovernanceAlTokenFixture is GovernanceTestBase {
    CrossChainCanonicalAlchemicTokenV3 internal token;
    CrossChainCanonicalAlchemicTokenV3 internal implementation;
    function setUp() public virtual {
        vm.warp(100);
        implementation=new CrossChainCanonicalAlchemicTokenV3();
        vm.prank(ADMIN);
        token=CrossChainCanonicalAlchemicTokenV3(address(new ERC1967Proxy(address(implementation),abi.encodeCall(implementation.initialize,("Alchemic", "AL")))));
        vm.prank(ADMIN); token.setWhitelist(OPERATOR,true);
    }
    function _mint(address to,uint256 amount) internal { vm.prank(OPERATOR); token.mint(to,amount); }
    function _missingRole(address who,bytes32 role) internal pure returns(bytes memory) {
        return _error(string.concat("AccessControl: account ",Strings.toHexString(uint160(who),20)," is missing role ",Strings.toHexString(uint256(role),32)));
    }
}
contract GovernanceAlTokenAccess is GovernanceAlTokenFixture {
    /// @custom:property AlTokenV3-AC-02
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_setFlashFeeGuard() public {
        bytes memory data=abi.encodeWithSignature("setFlashFee(uint256)",uint256(7));
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(token.flashMintFee()==0);
        _success(address(token),ADMIN,data); assert(token.flashMintFee()==7);
    }
    /// @custom:property AlTokenV3-AC-03
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_mintGuard() public {
        bytes memory data=abi.encodeWithSignature("mint(address,uint256)",ALICE, uint256(7));
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(token.totalSupply()==0);
        _success(address(token),OPERATOR,data); assert(token.totalSupply()==7 && token.balanceOf(ALICE)==7);
    }
    /// @custom:property AlTokenV3-AC-04
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_setWhitelistGuard() public {
        bytes memory data=abi.encodeWithSignature("setWhitelist(address,bool)",ALICE, true);
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(!token.whitelisted(ALICE));
        _success(address(token),ADMIN,data); assert(token.whitelisted(ALICE));
    }
    /// @custom:property AlTokenV3-AC-05
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_setSentinelGuard() public {
        bytes memory data=abi.encodeWithSignature("setSentinel(address)",ALICE);
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(!token.hasRole(token.SENTINEL_ROLE(),ALICE));
        _success(address(token),ADMIN,data); assert(token.hasRole(token.SENTINEL_ROLE(),ALICE));
    }
    /// @custom:property AlTokenV3-AC-06
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_pauseMinterGuard() public {
        bytes memory data=abi.encodeWithSignature("pauseMinter(address,bool)",OPERATOR, true);
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(!token.paused(OPERATOR));
        _success(address(token),ADMIN,data); assert(token.paused(OPERATOR));
    }
    /// @custom:property AlTokenV3-AC-08
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_setMaxFlashLoanGuard() public {
        bytes memory data=abi.encodeWithSignature("setMaxFlashLoan(uint256)",uint256(7));
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(token.maxFlashLoanAmount()==0);
        _success(address(token),ADMIN,data); assert(token.maxFlashLoanAmount()==7);
    }
    /// @custom:property AlTokenV3-AC-09
    /// @custom:classification DIRECT: proxy implementation guard and authorized state transition.
    function test_check_setLimitsGuard() public {
        bytes memory data=abi.encodeWithSignature("setLimits(address,uint256,uint256)",OPERATOR, uint256(7), uint256(9));
        _reject(address(token),OUTSIDER,data,abi.encodeWithSignature("Unauthorized()")); assert(token.mintingMaxLimitOf(OPERATOR)==0 && token.burningMaxLimitOf(OPERATOR)==0);
        _success(address(token),ADMIN,data); assert(token.mintingMaxLimitOf(OPERATOR)==7 && token.burningMaxLimitOf(OPERATOR)==9);
    }
    /// @custom:property ALT-INITIALIZE
    /// @custom:classification ENUMERATE: real implementation constructor and atomic ERC1967 proxy initialization.
    function test_check_initialization() public {
        _reject(address(implementation),ADMIN,abi.encodeCall(implementation.initialize,("X","X")),_error("Initializable: contract is already initialized"));
        _reject(address(token),ADMIN,abi.encodeCall(token.initialize,("X","X")),_error("Initializable: contract is already initialized"));
        assert(keccak256(bytes(token.name()))==keccak256("Alchemic") && keccak256(bytes(token.symbol()))==keccak256("AL"));
        assert(token.decimals()==18 && token.owner()==ADMIN && token.totalSupply()==0);
        assert(token.hasRole(token.ADMIN_ROLE(),ADMIN) && token.hasRole(token.SENTINEL_ROLE(),ADMIN));
        assert(token.getRoleAdmin(token.ADMIN_ROLE())==token.ADMIN_ROLE() && token.getRoleAdmin(token.SENTINEL_ROLE())==token.ADMIN_ROLE());
        assert(!token.hasRole(token.DEFAULT_ADMIN_ROLE(),ADMIN));
        assert(token.BPS()==10000 && token.CALLBACK_SUCCESS()==keccak256("ERC3156FlashBorrower.onFlashLoan"));
    }
    /// @custom:property AlTokenV3-AC-10 AlTokenV3-AC-11 ALT-OWNER ALT-ROLES
    /// @custom:classification DIRECT: inherited owner guards, distinct role state.
    function test_check_owner() public {
        _reject(address(token),OUTSIDER,abi.encodeCall(token.transferOwnership,(ALICE)),_error("Ownable: caller is not the owner"));
        _reject(address(token),OUTSIDER,abi.encodeCall(token.renounceOwnership,()),_error("Ownable: caller is not the owner"));
        assert(token.owner()==ADMIN);
        _reject(address(token),ADMIN,abi.encodeCall(token.transferOwnership,(address(0))),_error("Ownable: new owner is the zero address"));
        vm.prank(ADMIN); token.transferOwnership(ALICE);
        assert(token.owner()==ALICE && token.hasRole(token.ADMIN_ROLE(),ADMIN) && !token.hasRole(token.ADMIN_ROLE(),ALICE));
        _reject(address(token),ADMIN,abi.encodeCall(token.renounceOwnership,()),_error("Ownable: caller is not the owner"));
        vm.prank(ALICE); token.renounceOwnership();
        assert(token.owner()==address(0) && token.hasRole(token.SENTINEL_ROLE(),ADMIN));
    }
    /// @custom:property AlTokenV3-AC-12 AlTokenV3-AC-13 AlTokenV3-AC-14 ALT-ROLES
    /// @custom:classification ENUMERATE: fixed role/address values bound inherited hexadecimal error loops.
    function test_check_roles() public {
        bytes32 role=token.SENTINEL_ROLE(); bytes32 adminRole=token.ADMIN_ROLE();
        _reject(address(token),OUTSIDER,abi.encodeCall(token.grantRole,(role,ALICE)),_missingRole(OUTSIDER,adminRole));
        assert(!token.hasRole(role,ALICE));
        vm.prank(ADMIN); token.grantRole(role,ALICE); assert(token.hasRole(role,ALICE));
        _reject(address(token),OUTSIDER,abi.encodeCall(token.revokeRole,(role,ALICE)),_missingRole(OUTSIDER,adminRole));
        assert(token.hasRole(role,ALICE));
        vm.prank(ADMIN); token.revokeRole(role,ALICE); assert(!token.hasRole(role,ALICE));
        vm.prank(ADMIN); token.grantRole(role,ALICE);
        _reject(address(token),OUTSIDER,abi.encodeCall(token.renounceRole,(role,ALICE)),_error("AccessControl: can only renounce roles for self"));
        assert(token.hasRole(role,ALICE));
        vm.prank(ALICE); token.renounceRole(role,ALICE); assert(!token.hasRole(role,ALICE));
        vm.prank(ADMIN); token.setSentinel(ALICE);
        vm.prank(ALICE); token.pauseMinter(OPERATOR,true); assert(token.paused(OPERATOR));
        _reject(address(token),ALICE,abi.encodeCall(token.setWhitelist,(BOB,true)),abi.encodeWithSignature("Unauthorized()"));
        vm.prank(ADMIN); token.grantRole(adminRole,BOB);
        vm.prank(BOB); token.revokeRole(adminRole,ADMIN); assert(!token.hasRole(adminRole,ADMIN));
        assert(token.supportsInterface(0x01ffc9a7) && token.supportsInterface(0x7965db0b) && !token.supportsInterface(0xffffffff));
    }

    /// @custom:property AlTokenV3-AC-02
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setFlashFeeGuard() public { test_check_setFlashFeeGuard(); }
    /// @custom:property AlTokenV3-AC-03
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_mintGuard() public { test_check_mintGuard(); }
    /// @custom:property AlTokenV3-AC-04
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setWhitelistGuard() public { test_check_setWhitelistGuard(); }
    /// @custom:property AlTokenV3-AC-05
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setSentinelGuard() public { test_check_setSentinelGuard(); }
    /// @custom:property AlTokenV3-AC-06
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_pauseMinterGuard() public { test_check_pauseMinterGuard(); }
    /// @custom:property AlTokenV3-AC-08
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setMaxFlashLoanGuard() public { test_check_setMaxFlashLoanGuard(); }
    /// @custom:property AlTokenV3-AC-09
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_setLimitsGuard() public { test_check_setLimitsGuard(); }
    /// @custom:property ALT-INITIALIZE
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_initialization() public { test_check_initialization(); }
    /// @custom:property AlTokenV3-AC-10 AlTokenV3-AC-11 ALT-OWNER ALT-ROLES
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_owner() public { test_check_owner(); }
    /// @custom:property AlTokenV3-AC-12 AlTokenV3-AC-13 AlTokenV3-AC-14 ALT-ROLES
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_roles() public { test_check_roles(); }
}
