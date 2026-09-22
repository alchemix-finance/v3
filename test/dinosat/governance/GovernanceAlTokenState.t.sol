// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernanceAlTokenFixture} from "./GovernanceAlTokenAccess.t.sol";
import {IXERC20} from "lib/v2-foundry/src/interfaces/external/connext/IXERC20.sol";

contract GovernanceAlTokenAccounting is GovernanceAlTokenFixture {
    /// @custom:property ALT-ERC20
    /// @custom:classification DECOMPOSE: distinct/self recipient and finite/infinite allowance; uint96 domain avoids fixture overflow.
    function test_check_transfers(uint96 raw, uint96 extra, bool self, bool infinite) public {
        uint256 amount=uint256(raw)+1; uint256 supply=amount+extra; _mint(ALICE,supply);
        address recipient=self ? ALICE : BOB;
        vm.prank(ALICE); token.approve(OUTSIDER,infinite ? type(uint256).max : supply);
        vm.prank(OUTSIDER); assert(token.transferFrom(ALICE,recipient,amount));
        assert(token.totalSupply()==supply && token.balanceOf(ALICE)==(self ? supply : uint256(extra)));
        assert(token.balanceOf(BOB)==(self ? 0 : amount));
        assert(token.allowance(ALICE,OUTSIDER)==(infinite ? type(uint256).max : uint256(extra)));
        vm.prank(recipient); assert(token.transfer(ALICE,amount));
        assert(token.balanceOf(ALICE)==supply && token.balanceOf(BOB)==0 && token.totalSupply()==supply);
    }
    /// @custom:property ALT-ERC20
    /// @custom:classification ENUMERATE: allowance adjustments and rejection rollback including checked overflow.
    function test_check_allowance(uint96 first, uint96 delta) public {
        vm.prank(ALICE); token.approve(BOB,first);
        vm.prank(ALICE); token.increaseAllowance(BOB,delta);
        assert(token.allowance(ALICE,BOB)==uint256(first)+delta && token.totalSupply()==0);
        vm.prank(ALICE); token.decreaseAllowance(BOB,delta); assert(token.allowance(ALICE,BOB)==first);
        _reject(address(token),ALICE,abi.encodeCall(token.decreaseAllowance,(BOB,uint256(first)+1)),_error("ERC20: decreased allowance below zero"));
        assert(token.allowance(ALICE,BOB)==first);
        vm.prank(ALICE); token.approve(BOB,type(uint256).max);
        _reject(address(token),ALICE,abi.encodeCall(token.increaseAllowance,(BOB,uint256(1))),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(token.allowance(ALICE,BOB)==type(uint256).max);
        _reject(address(token),ALICE,abi.encodeCall(token.approve,(address(0),uint256(1))),_error("ERC20: approve to the zero address"));
    }
    /// @custom:property ALT-ERC20 ALT-MINT
    /// @custom:classification ENUMERATE: insufficient balances/allowance, zero recipient and total supply overflow.
    function test_check_invalidMoves() public {
        _mint(ALICE,3);
        _reject(address(token),ALICE,abi.encodeCall(token.transfer,(BOB,uint256(4))),_error("ERC20: transfer amount exceeds balance"));
        _reject(address(token),ALICE,abi.encodeCall(token.transfer,(address(0),uint256(1))),_error("ERC20: transfer to the zero address"));
        _reject(address(token),BOB,abi.encodeCall(token.transferFrom,(ALICE,BOB,uint256(1))),_error("ERC20: insufficient allowance"));
        _reject(address(token),OPERATOR,abi.encodeCall(token.mint,(address(0),uint256(1))),_error("ERC20: mint to the zero address"));
        assert(token.totalSupply()==3 && token.balanceOf(ALICE)==3 && token.balanceOf(BOB)==0);
        _mint(BOB,type(uint256).max-3);
        _reject(address(token),OPERATOR,abi.encodeCall(token.mint,(ALICE,uint256(1))),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(token.totalSupply()==type(uint256).max && token.balanceOf(ALICE)==3);
    }
    /// @custom:property AlTokenV3-AC-01 AlTokenV3-AC-07 ALT-BURN
    /// @custom:classification ENUMERATE: both third-party burn overloads and exact allowance-underflow rejection.
    function test_check_burnAllowance(uint96 raw, bool legacy, bool infinite) public {
        uint256 amount=uint256(raw)+1; _mint(ALICE,amount);
        bytes memory data=legacy ? abi.encodeWithSignature("burn(address,uint256)",ALICE,amount) : abi.encodeWithSignature("burnFrom(address,uint256)",ALICE,amount);
        _reject(address(token),BOB,data,abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(token.balanceOf(ALICE)==amount && token.totalSupply()==amount && token.allowance(ALICE,BOB)==0);
        vm.prank(ALICE); token.approve(BOB,infinite ? type(uint256).max : amount);
        _success(address(token),BOB,data);
        assert(token.totalSupply()==0 && token.balanceOf(ALICE)==0);
        assert(token.allowance(ALICE,BOB)==(infinite ? type(uint256).max-amount : 0));
    }
    /// @custom:property ALT-BURN ALT-LIMITS
    /// @custom:classification DECOMPOSE: third-party registered burner restores allowance on limit rejection.
    function test_check_registeredBurnerAllowance(uint96 raw,bool legacy) public {
        uint256 amount=uint256(raw)+1; _mint(ALICE,amount+1);
        vm.prank(ALICE); token.approve(BOB,amount+1);
        vm.prank(ADMIN); token.setLimits(BOB,0,amount);
        bytes memory rejected=legacy ? abi.encodeWithSignature("burn(address,uint256)",ALICE,amount+1) : abi.encodeWithSignature("burnFrom(address,uint256)",ALICE,amount+1);
        _reject(address(token),BOB,rejected,abi.encodeWithSignature("IXERC20_NotHighEnoughLimits()"));
        assert(token.allowance(ALICE,BOB)==amount+1 && token.balanceOf(ALICE)==amount+1 && token.burningCurrentLimitOf(BOB)==amount);
        bytes memory valid=legacy ? abi.encodeWithSignature("burn(address,uint256)",ALICE,amount) : abi.encodeWithSignature("burnFrom(address,uint256)",ALICE,amount);
        _success(address(token),BOB,valid);
        assert(token.allowance(ALICE,BOB)==1 && token.balanceOf(ALICE)==1 && token.totalSupply()==1 && token.burningCurrentLimitOf(BOB)==0);
    }
    /// @custom:property ALT-BURN ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive registered-burner domain.
    function test_fuzz_generated_registeredBurnerAllowance(uint96 raw,bool legacy) public { test_check_registeredBurnerAllowance(raw,legacy); }
    /// @custom:property ALT-BURN
    /// @custom:classification ENUMERATE: all four actual burn entry points with self caller, failed balance preserves allowance.
    function test_check_selfBurn(uint96 raw, uint8 modeRaw) public {
        uint256 amount=uint256(raw)+1; _mint(ALICE,amount); uint8 mode=modeRaw % 4;
        vm.prank(ALICE); token.approve(ALICE,17);
        bytes memory bad=_burnData(mode,amount+1);
        _reject(address(token),ALICE,bad,_error("ERC20: burn amount exceeds balance"));
        assert(token.totalSupply()==amount && token.allowance(ALICE,ALICE)==17);
        _success(address(token),ALICE,_burnData(mode,amount));
        assert(token.totalSupply()==0 && token.balanceOf(ALICE)==0 && token.allowance(ALICE,ALICE)==17);
    }
    function _burnData(uint8 mode,uint256 amount) internal pure returns(bytes memory) {
        if(mode==0) return abi.encodeWithSignature("burn(uint256)",amount);
        if(mode==1) return abi.encodeWithSignature("burnSelf(uint256)",amount);
        if(mode==2) return abi.encodeWithSignature("burn(address,uint256)",ALICE,amount);
        return abi.encodeWithSignature("burnFrom(address,uint256)",ALICE,amount);
    }

    /// @custom:property ALT-ERC20
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_transfers(uint96 raw, uint96 extra, bool self, bool infinite) public { test_check_transfers(raw, extra, self, infinite); }
    /// @custom:property ALT-ERC20
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_allowance(uint96 first, uint96 delta) public { test_check_allowance(first, delta); }
    /// @custom:property ALT-ERC20 ALT-MINT
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_invalidMoves() public { test_check_invalidMoves(); }
    /// @custom:property AlTokenV3-AC-01 AlTokenV3-AC-07 ALT-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_burnAllowance(uint96 raw, bool legacy, bool infinite) public { test_check_burnAllowance(raw, legacy, infinite); }
    /// @custom:property ALT-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_selfBurn(uint96 raw, uint8 modeRaw) public { test_check_selfBurn(raw, modeRaw); }
}

contract GovernanceAlTokenLimits is GovernanceAlTokenFixture {
    /// @custom:property ALT-MINT ALT-LIMITS
    /// @custom:classification DECOMPOSE: uint96 cap/depletion, monotone elapsed time in [0,86400].
    function test_check_mintLimit(uint96 limitRaw,uint96 useRaw,uint32 elapsedRaw) public {
        uint256 limit=uint256(limitRaw)+1; uint256 used=uint256(useRaw) % (limit+1); uint256 elapsed=uint256(elapsedRaw)%86401;
        vm.prank(ADMIN); token.setLimits(OPERATOR,limit,0);
        assert(token.mintingCurrentLimitOf(OPERATOR)==limit && token.mintingMaxLimitOf(OPERATOR)==limit);
        _mint(ALICE,used); assert(token.mintingCurrentLimitOf(OPERATOR)==limit-used);
        vm.warp(100+elapsed);
        uint256 refill=elapsed==86400 ? used : elapsed*(limit/86400);
        uint256 expected=refill>=used ? limit : limit-used+refill;
        assert(token.mintingCurrentLimitOf(OPERATOR)==expected && expected<=limit);
        _reject(address(token),OPERATOR,abi.encodeCall(token.mint,(ALICE,expected+1)),abi.encodeWithSignature("IXERC20_NotHighEnoughLimits()"));
        assert(token.totalSupply()==used);
        _mint(ALICE,expected);
        assert(token.mintingCurrentLimitOf(OPERATOR)==0 && token.totalSupply()==used+expected);
    }
    /// @custom:property ALT-BURN ALT-LIMITS
    /// @custom:classification DECOMPOSE: all burn entry points, exact bridge depletion and day refill.
    function test_check_burnLimit(uint96 raw,uint8 modeRaw) public {
        uint256 limit=uint256(raw)+1; _mint(ALICE,limit+1);
        vm.prank(ADMIN); token.setLimits(ALICE,0,limit);
        uint8 mode=modeRaw%4;
        bytes memory tooMuch=_data(mode,limit+1);
        _reject(address(token),ALICE,tooMuch,abi.encodeWithSignature("IXERC20_NotHighEnoughLimits()"));
        assert(token.burningCurrentLimitOf(ALICE)==limit && token.totalSupply()==limit+1);
        _success(address(token),ALICE,_data(mode,limit));
        assert(token.burningCurrentLimitOf(ALICE)==0 && token.totalSupply()==1);
        vm.warp(100+1 days); assert(token.burningCurrentLimitOf(ALICE)==limit && token.burningMaxLimitOf(ALICE)==limit);
    }
    function _data(uint8 mode,uint256 amount) internal pure returns(bytes memory) {
        if(mode==0) return abi.encodeWithSignature("burn(uint256)",amount);
        if(mode==1) return abi.encodeWithSignature("burnSelf(uint256)",amount);
        if(mode==2) return abi.encodeWithSignature("burn(address,uint256)",ALICE,amount);
        return abi.encodeWithSignature("burnFrom(address,uint256)",ALICE,amount);
    }
    /// @custom:property ALT-LIMITS
    /// @custom:classification DECOMPOSE: bounded numeric current-cap adjustment after real mint and burn.
    function test_check_changeLimits(uint96 oldRaw,uint96 useRaw,uint96 newLimit) public {
        uint256 oldLimit=uint256(oldRaw)+1; uint256 used=uint256(useRaw)%(oldLimit+1);
        vm.prank(ADMIN); token.setLimits(OPERATOR,oldLimit,oldLimit);
        _mint(OPERATOR,used); vm.prank(OPERATOR); token.burnSelf(used);
        vm.prank(ADMIN); token.setLimits(OPERATOR,newLimit,newLimit);
        // Used capacity carries into the new window; reducing below used saturates remaining at zero.
        uint256 expected=newLimit>used ? uint256(newLimit)-used : 0;
        assert(token.mintingCurrentLimitOf(OPERATOR)==expected && token.burningCurrentLimitOf(OPERATOR)==expected);
        assert(token.mintingMaxLimitOf(OPERATOR)==newLimit && token.burningMaxLimitOf(OPERATOR)==newLimit);
        (IXERC20.BridgeParameters memory minter, IXERC20.BridgeParameters memory burner)=token.xBridges(OPERATOR);
        assert(minter.timestamp==100 && burner.timestamp==100 && minter.ratePerSecond==uint256(newLimit)/86400 && burner.ratePerSecond==uint256(newLimit)/86400);
        assert(minter.currentLimit==expected && burner.currentLimit==expected && minter.maxLimit==newLimit && burner.maxLimit==newLimit);
    }
    /// @custom:property ALT-MINT ALT-BURN
    /// @custom:classification ENUMERATE: pause/unpause and zero bridge cap intentionally skips limits.
    function test_check_pauseAndZeroLimit(uint96 raw) public {
        uint256 amount=uint256(raw)+1;
        vm.prank(ADMIN); token.pauseMinter(OPERATOR,true);
        _reject(address(token),OPERATOR,abi.encodeCall(token.mint,(ALICE,amount)),abi.encodeWithSignature("IllegalState()"));
        assert(token.totalSupply()==0);
        vm.prank(ADMIN); token.pauseMinter(OPERATOR,false);
        _mint(ALICE,amount);
        assert(token.mintingMaxLimitOf(OPERATOR)==0 && token.totalSupply()==amount);
        vm.prank(ALICE); token.burnSelf(amount);
        assert(token.totalSupply()==0 && token.burningMaxLimitOf(ALICE)==0);
    }
    /// @custom:property ALT-LIMITS
    /// @custom:classification ENUMERATE: exact panic witness for unrestricted administrative max cap.
    function test_check_nearMaxOverflowWitness() public {
        vm.prank(ADMIN); token.setLimits(OPERATOR,type(uint256).max,0);
        _mint(ALICE,1); vm.warp(101);
        _reject(address(token),ALICE,abi.encodeCall(token.mintingCurrentLimitOf,(OPERATOR)),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(token.totalSupply()==1 && token.mintingMaxLimitOf(OPERATOR)==type(uint256).max);
    }

    /// @custom:property ALT-MINT ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_mintLimit(uint96 limitRaw,uint96 useRaw,uint32 elapsedRaw) public { test_check_mintLimit(limitRaw, useRaw, elapsedRaw); }
    /// @custom:property ALT-BURN ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_burnLimit(uint96 raw,uint8 modeRaw) public { test_check_burnLimit(raw, modeRaw); }
    /// @custom:property ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_changeLimits(uint96 oldRaw,uint96 useRaw,uint96 newLimit) public { test_check_changeLimits(oldRaw, useRaw, newLimit); }
    /// @custom:property ALT-MINT ALT-BURN
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_pauseAndZeroLimit(uint96 raw) public { test_check_pauseAndZeroLimit(raw); }
    /// @custom:property ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_nearMaxOverflowWitness() public { test_check_nearMaxOverflowWitness(); }
}

/// @dev Keep failing intended property separate; an assertion failure is evidence, never a passing proof.
contract GovernanceAlTokenLimitCandidate is GovernanceAlTokenFixture {
    /// @custom:property ALT-LIMITS
    /// @custom:classification COUNTEREXAMPLE_CANDIDATE: reachable large cap, one minted unit and one second.
    function test_check_remainingCapacityMustRemainReadable() public {
        vm.prank(ADMIN); token.setLimits(OPERATOR,type(uint256).max,0);
        _mint(ALICE,1); vm.warp(101);
        (bool ok,)=address(token).call(abi.encodeCall(token.mintingCurrentLimitOf,(OPERATOR)));
        assert(ok);
    }

    /// @custom:property ALT-LIMITS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_remainingCapacityMustRemainReadable() public { test_check_remainingCapacityMustRemainReadable(); }
}
