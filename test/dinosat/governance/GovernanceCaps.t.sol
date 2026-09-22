// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {PermissionFixture} from "./GovernancePermissions.t.sol";
import {GovernanceTestBase, GovernanceAsset, GovernanceAdapter, GovernanceRecordingVault} from "./GovernanceFixtures.sol";
import {AlchemistAllocator} from "src/AlchemistAllocator.sol";
import {AlchemistCurator} from "src/AlchemistCurator.sol";
import {AlchemistStrategyClassifier} from "src/AlchemistStrategyClassifier.sol";
import {AlchemistGate} from "src/AlchemistGate.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";
import {ERC4626Strategy} from "src/strategies/ERC4626Strategy.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GovernanceAllocatorCaps is PermissionFixture {
    AlchemistAllocator internal subject;
    function setUp() public { _fixture(); subject = new AlchemistAllocator(address(vault), ADMIN, OPERATOR, address(classifier)); }
    /// @custom:property ALLOC-CAPS ALLOC-ARITH
    /// @custom:classification DECOMPOSE: exact two-adapter history; uint64 inputs keep products below 2**128.
    /// @custom:limitations Bounded numeric domain and adapter count, not all reachable Morpho states.
    function test_check_caps(uint64 assets, uint64 absolute, uint64 relative, uint64 global, uint64 local, uint64 existing, uint64 other, uint64 amount, bool asAdmin, bool sameRisk) public {
        GovernanceAdapter second = new GovernanceAdapter(2);
        vault.addFixtureAdapter(address(adapter)); vault.addFixtureAdapter(address(second));
        vault.setTotalAssets(assets);
        vault.configure(adapter.adapterId(), absolute, relative, existing);
        vault.configure(second.adapterId(), type(uint128).max, 1e18, other);
        vm.prank(ADMIN); classifier.setRiskClass(0, global, local);
        vm.prank(ADMIN); classifier.assignStrategyRiskLevel(2, sameRisk ? 0 : 1);
        uint256 aggregate = uint256(existing) + (sameRisk ? uint256(other) : 0);
        uint256 riskCap = uint256(assets) * global / 1e18;
        uint256 relativeAmount = uint256(assets) * relative / 1e18;
        uint256 localAmount = uint256(assets) * local / 1e18;
        bool expected = amount <= (aggregate < riskCap ? riskCap - aggregate : 0)
            && uint256(existing) + amount <= absolute
            && uint256(existing) + amount <= relativeAmount
            && (asAdmin || uint256(existing) + amount <= localAmount);
        vm.prank(asAdmin ? ADMIN : OPERATOR);
        (bool ok, bytes memory reason) = address(subject).call(abi.encodeCall(subject.allocate, (address(adapter), amount)));
        assert(ok == expected);
        assert(vault.calls() == (expected ? 1 : 0));
        if (!ok) { assert(bytes4(reason) == bytes4(keccak256("EffectiveCap(uint256,uint256)"))); }
    }
    /// @custom:property ALLOC-CAPS
    /// @custom:classification DECOMPOSE: admin bypasses local cap only, while global and vault caps remain enforced.
    function test_check_adminLocalException(uint64 raw) public {
        uint256 amount = uint256(raw) + 1;
        vault.setTotalAssets(amount); vault.configure(adapter.adapterId(), amount, 1e18, 0);
        vm.prank(ADMIN); classifier.setRiskClass(0, 1e18, 0);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.allocate, (address(adapter), amount)), abi.encodeWithSignature("EffectiveCap(uint256,uint256)", amount, uint256(0)));
        vm.prank(ADMIN); subject.allocate(address(adapter), amount);
        assert(vault.calls() == 1);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.allocate, (address(adapter), amount + 1)), abi.encodeWithSignature("EffectiveCap(uint256,uint256)", amount + 1, amount));
    }
    /// @custom:property ALLOC-ARITH
    /// @custom:classification ENUMERATE: explicit checked product overflow witness.
    function test_check_productOverflow() public {
        vault.setTotalAssets(type(uint256).max);
        vault.configure(adapter.adapterId(), type(uint256).max, 2, 0);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.allocate, (address(adapter), uint256(0))), abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        assert(vault.calls() == 0);
    }
    /// @custom:property ALLOC-ARITH
    /// @custom:classification ENUMERATE: checked sum across two adapter allocations overflows before forwarding.
    function test_check_allocationOverflow() public {
        GovernanceAdapter second=new GovernanceAdapter(2);
        vault.addFixtureAdapter(address(adapter)); vault.addFixtureAdapter(address(second));
        vault.configure(adapter.adapterId(),type(uint256).max,1e18,type(uint256).max);
        vault.configure(second.adapterId(),1,1e18,1);
        _reject(address(subject),ADMIN,abi.encodeCall(subject.allocate,(address(adapter),uint256(0))),abi.encodeWithSignature("Panic(uint256)",uint256(0x11)));
        assert(vault.calls()==0);
    }
    /// @custom:property ALLOC-FORWARD
    /// @custom:classification ENUMERATE: fixed swap payload; all three action encodings and downstream rollback.
    function test_check_actionEncoding(uint96 amount, uint96 minOut, bytes32 payload) public {
        bytes memory data = abi.encode(payload);
        vm.prank(OPERATOR); subject.deallocateWithUnwrapAndSwap(address(adapter), amount, data, minOut);
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(IMYTStrategy.ActionType.unwrapAndSwap, IMYTStrategy.SwapParams(data, minOut));
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.deallocate, (address(adapter), abi.encode(params), amount))));
        vm.prank(OPERATOR); subject.deallocateWithSwap(address(adapter), amount, data);
        params.action = IMYTStrategy.ActionType.swap; params.swapParams.minIntermediateOut = 0;
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.deallocate, (address(adapter), abi.encode(params), amount))));
        vm.prank(OPERATOR); subject.deallocate(address(adapter), amount);
        params.action = IMYTStrategy.ActionType.direct; params.swapParams.txData = new bytes(0);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.deallocate, (address(adapter), abi.encode(params), amount))));
        vault.setFail(true);
        _reject(address(subject), ADMIN, abi.encodeCall(subject.setMaxRate, (uint256(amount))), _error("target failed"));
        assert(vault.calls() == 3);
    }
    /// @custom:property ALLOC-FORWARD
    /// @custom:classification ENUMERATE: exact allocate/swap/liquidity/rate forwarding, amount in uint64 keeps configured caps ample.
    function test_check_allocateAndConfigEncoding(uint64 amount,bytes32 payload) public {
        bytes memory data=abi.encode(payload);
        IMYTStrategy.VaultAdapterParams memory params;
        params.action=IMYTStrategy.ActionType.direct;
        vm.prank(OPERATOR); subject.allocate(address(adapter),amount);
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.allocate,(address(adapter),abi.encode(params),uint256(amount)))));
        params.action=IMYTStrategy.ActionType.swap; params.swapParams.txData=data;
        vm.prank(OPERATOR); subject.allocateWithSwap(address(adapter),amount,data);
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.allocate,(address(adapter),abi.encode(params),uint256(amount)))));
        vm.prank(OPERATOR); subject.setLiquidityAdapter(address(adapter),data);
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.setLiquidityAdapterAndData,(address(adapter),data))));
        vm.prank(ADMIN); subject.setMaxRate(amount);
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.setMaxRate,(uint256(amount)))));
    }
    /// @custom:property AlchemistAllocator-SETUP AlchemistCurator-SETUP
    /// @custom:classification ENUMERATE: constructor rejection branches.
    function test_check_constructorRejections() public {
        try new AlchemistAllocator(address(vault), address(0), OPERATOR, address(classifier)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("zero"))); }
        try new AlchemistAllocator(address(vault), ADMIN, address(0), address(classifier)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("zero"))); }
        try new AlchemistAllocator(address(vault), ADMIN, OPERATOR, address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("IC"))); }
        vault.setAsset(address(0));
        try new AlchemistAllocator(address(vault), ADMIN, OPERATOR, address(classifier)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("IV"))); }
        try new AlchemistCurator(address(0), OPERATOR) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("zero"))); }
        try new AlchemistCurator(ADMIN, address(0)) { assert(false); } catch (bytes memory reason) { assert(keccak256(reason) == keccak256(_error("zero"))); }
    }

    /// @custom:property ALLOC-CAPS ALLOC-ARITH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_caps(uint64 assets, uint64 absolute, uint64 relative, uint64 global, uint64 local, uint64 existing, uint64 other, uint64 amount, bool asAdmin, bool sameRisk) public { test_check_caps(assets, absolute, relative, global, local, existing, other, amount, asAdmin, sameRisk); }
    /// @custom:property ALLOC-CAPS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_adminLocalException(uint64 raw) public { test_check_adminLocalException(raw); }
    /// @custom:property ALLOC-ARITH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_productOverflow() public { test_check_productOverflow(); }
    /// @custom:property ALLOC-ARITH
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_allocationOverflow() public { test_check_allocationOverflow(); }
    /// @custom:property ALLOC-FORWARD
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_actionEncoding(uint96 amount, uint96 minOut, bytes32 payload) public { test_check_actionEncoding(amount, minOut, payload); }
    /// @custom:property ALLOC-FORWARD
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_allocateAndConfigEncoding(uint64 amount,bytes32 payload) public { test_check_allocateAndConfigEncoding(amount, payload); }
    /// @custom:property AlchemistAllocator-SETUP AlchemistCurator-SETUP
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_constructorRejections() public { test_check_constructorRejections(); }
}

contract GovernanceCuratorRouting is PermissionFixture {
    AlchemistCurator internal subject;
    function setUp() public { _fixture(); subject = new AlchemistCurator(ADMIN, OPERATOR); }
    /// @custom:property CURATOR-ROUTING
    /// @custom:classification ENUMERATE: mapping, exact target, zero-address and downstream-revert branches.
    function test_check_routing() public {
        vault.setFail(true);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.setStrategy, (address(adapter), address(vault))), _error("target failed"));
        assert(subject.adapterToMYT(address(adapter)) == address(0));
        vault.setFail(false);
        vm.prank(OPERATOR); subject.setStrategy(address(adapter), address(vault));
        assert(subject.adapterToMYT(address(adapter)) == address(vault));
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.addAdapter, (address(adapter)))));
        GovernanceRecordingVault other = new GovernanceRecordingVault();
        vm.prank(OPERATOR); subject.removeStrategy(address(adapter), address(other));
        assert(subject.adapterToMYT(address(adapter)) == address(0));
        assert(other.calls() == 0 && vault.calls() == 2);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.setStrategy, (address(0), address(vault))), _error("INVALID_ADDRESS"));
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.setStrategy, (address(adapter), address(0))), _error("INVALID_ADDRESS"));
        _reject(address(subject), ADMIN, abi.encodeCall(subject.decreaseAbsoluteCap, (address(adapter), uint256(0))), _error("INVALID_ADDRESS"));
    }
    /// @custom:property CURATOR-SUBMIT CURATOR-ROUTING
    /// @custom:classification ENUMERATE: strategy submit encodings do not change adapter mapping.
    function test_check_strategySubmissions() public {
        vm.prank(OPERATOR); subject.submitSetStrategy(address(adapter),address(vault));
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.submit,(abi.encodeCall(IVaultV2.addAdapter,(address(adapter)))))));
        assert(subject.adapterToMYT(address(adapter))==address(0));
        vm.prank(OPERATOR); subject.submitRemoveStrategy(address(adapter),address(vault));
        assert(keccak256(vault.lastCall())==keccak256(abi.encodeCall(IVaultV2.submit,(abi.encodeCall(IVaultV2.removeAdapter,(address(adapter)))))));
        assert(subject.adapterToMYT(address(adapter))==address(0));
    }
    /// @custom:property CURATOR-CAPS CURATOR-SUBMIT
    /// @custom:classification ENUMERATE: four cap selectors and six submit encodings on real curator.
    function test_check_capsAndSubmit(uint256 amount) public {
        vm.prank(OPERATOR); subject.setStrategy(address(adapter), address(vault));
        bytes memory id = adapter.getIdData();
        vm.prank(ADMIN); subject.decreaseAbsoluteCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.decreaseAbsoluteCap, (id, amount))));
        vm.prank(ADMIN); subject.decreaseRelativeCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.decreaseRelativeCap, (id, amount))));
        vm.prank(ADMIN); subject.increaseAbsoluteCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, amount))));
        vm.prank(ADMIN); subject.increaseRelativeCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.increaseRelativeCap, (id, amount))));
        vm.prank(ADMIN); subject.submitIncreaseAbsoluteCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, amount))))));
        vm.prank(ADMIN); subject.submitIncreaseRelativeCap(address(adapter), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.increaseRelativeCap, (id, amount))))));
        vm.prank(ADMIN); subject.submitSetAllocator(address(vault), ALICE, true);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.setIsAllocator, (ALICE, true))))));
        vm.prank(ADMIN); subject.submitSetForceDeallocatePenalty(address(adapter), address(vault), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), amount))))));
        vm.prank(ADMIN); subject.submitSetPerformanceFeeRecipient(address(vault), ALICE);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (ALICE))))));
        vm.prank(ADMIN); subject.submitSetPerformanceFee(address(vault), amount);
        assert(keccak256(vault.lastCall()) == keccak256(abi.encodeCall(IVaultV2.submit, (abi.encodeCall(IVaultV2.setPerformanceFee, (amount))))));
        assert(subject.adapterToMYT(address(adapter)) == address(vault));
    }
    /// @custom:property CURATOR-TIMELOCK CURATOR-ROUTING
    /// @custom:classification DECOMPOSE: real VaultV2, fixed adapter count, concrete one-day delay.
    function test_check_realTimelock() public {
        vm.warp(100);
        GovernanceAsset asset = new GovernanceAsset();
        VaultV2 realVault = new VaultV2(ADMIN, address(asset));
        vm.prank(ADMIN); realVault.setCurator(address(subject));
        bytes memory increase = abi.encodeCall(IVaultV2.increaseTimelock, (IVaultV2.addAdapter.selector, uint256(1 days)));
        vm.prank(address(subject)); realVault.submit(increase);
        realVault.increaseTimelock(IVaultV2.addAdapter.selector, 1 days);
        vm.prank(OPERATOR); subject.submitSetStrategy(address(adapter), address(realVault));
        bytes memory addition = abi.encodeCall(IVaultV2.addAdapter, (address(adapter)));
        assert(realVault.executableAt(addition) == 100 + 1 days);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.setStrategy, (address(adapter), address(realVault))), abi.encodeWithSignature("TimelockNotExpired()"));
        assert(subject.adapterToMYT(address(adapter)) == address(0) && !realVault.isAdapter(address(adapter)));
        vm.warp(100 + 1 days);
        vm.prank(OPERATOR); subject.setStrategy(address(adapter), address(realVault));
        assert(realVault.isAdapter(address(adapter)) && realVault.executableAt(addition) == 0);
        _reject(address(subject), OPERATOR, abi.encodeCall(subject.setStrategy, (address(adapter), address(realVault))), abi.encodeWithSignature("DataNotTimelocked()"));
        assert(subject.adapterToMYT(address(adapter)) == address(realVault));
    }

    /// @custom:property CURATOR-ROUTING
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_routing() public { test_check_routing(); }
    /// @custom:property CURATOR-SUBMIT CURATOR-ROUTING
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_strategySubmissions() public { test_check_strategySubmissions(); }
    /// @custom:property CURATOR-CAPS CURATOR-SUBMIT
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_capsAndSubmit(uint256 amount) public { test_check_capsAndSubmit(amount); }
    /// @custom:property CURATOR-TIMELOCK CURATOR-ROUTING
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_realTimelock() public { test_check_realTimelock(); }
}

/// @dev Standard custody adapter with one ID and exact signed asset deltas, an explicit integration assumption.
contract GovernanceExactAdapter {
    GovernanceAsset public immutable asset;
    address public immutable vault;
    bytes32 public immutable adapterId;
    constructor(GovernanceAsset token, address target) { asset=token; vault=target; adapterId=keccak256(abi.encode(address(this))); asset.approve(target,type(uint256).max); }
    function getIdData() external view returns(bytes memory) { return abi.encode(address(this)); }
    function realAssets() external view returns(uint256) { return asset.balanceOf(address(this)); }
    function allocate(bytes memory,uint256 amount,bytes4,address) external view returns(bytes32[] memory ids,int256 change) {
        require(msg.sender==vault,"only vault"); ids=new bytes32[](1); ids[0]=adapterId; change=int256(amount);
    }
    function deallocate(bytes memory,uint256 amount,bytes4,address) external view returns(bytes32[] memory ids,int256 change) {
        require(msg.sender==vault,"only vault"); ids=new bytes32[](1); ids[0]=adapterId; change=-int256(amount);
    }
}
contract GovernanceAllocatorMorpho is GovernanceTestBase {
    GovernanceAsset internal asset;
    VaultV2 internal vault;
    AlchemistAllocator internal allocator;
    AlchemistStrategyClassifier internal classifier;
    GovernanceExactAdapter internal adapter;
    function setUp() public {
        vm.warp(100);
        asset=new GovernanceAsset(); vault=new VaultV2(ADMIN,address(asset)); classifier=new AlchemistStrategyClassifier(ADMIN);
        allocator=new AlchemistAllocator(address(vault),ADMIN,OPERATOR,address(classifier)); adapter=new GovernanceExactAdapter(asset,address(vault));
        vm.prank(ADMIN); vault.setCurator(ADMIN);
        _submit(abi.encodeCall(IVaultV2.setIsAllocator,(address(allocator),true))); vault.setIsAllocator(address(allocator),true);
        _submit(abi.encodeCall(IVaultV2.addAdapter,(address(adapter)))); vault.addAdapter(address(adapter));
        bytes memory id=adapter.getIdData();
        _submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap,(id,uint256(1000)))); vault.increaseAbsoluteCap(id,1000);
        _submit(abi.encodeCall(IVaultV2.increaseRelativeCap,(id,uint256(1e18)))); vault.increaseRelativeCap(id,1e18);
        vm.prank(ADMIN); classifier.setRiskClass(0,5e17,25e16);
        asset.mint(ALICE,1000); vm.prank(ALICE); asset.approve(address(vault),1000); vm.prank(ALICE); vault.deposit(1000,ALICE);
    }
    function _submit(bytes memory data) internal { vm.prank(ADMIN); vault.submit(data); }
    /// @custom:property ALLOC-MORPHO INT-CAPS
    /// @custom:classification DECOMPOSE: real allocator/classifier/VaultV2, one exact-delta adapter, zero fee/rate.
    /// @custom:limitations Concrete assets=1000, amount in [1,250], fixed one-ID adapter; no arbitrary-strategy claim.
    function test_check_capComposition(uint8 raw) public {
        uint256 amount=uint256(raw)%250+1;
        vm.prank(OPERATOR); allocator.allocate(address(adapter),amount);
        assert(vault.allocation(adapter.adapterId())==amount && asset.balanceOf(address(adapter))==amount);
        assert(asset.balanceOf(address(vault))==1000-amount && vault.totalAssets()==1000);
        _reject(address(allocator),OPERATOR,abi.encodeCall(allocator.allocate,(address(adapter),uint256(251)-amount)),abi.encodeWithSignature("EffectiveCap(uint256,uint256)",uint256(251)-amount,uint256(250)));
        assert(vault.allocation(adapter.adapterId())==amount && asset.balanceOf(address(adapter))==amount);
        vm.prank(ADMIN); allocator.allocate(address(adapter),uint256(500)-amount);
        assert(vault.allocation(adapter.adapterId())==500 && asset.balanceOf(address(adapter))==500);
        _reject(address(allocator),ADMIN,abi.encodeCall(allocator.allocate,(address(adapter),uint256(1))),abi.encodeWithSignature("EffectiveCap(uint256,uint256)",uint256(1),uint256(0)));
        vm.prank(OPERATOR); allocator.deallocate(address(adapter),500);
        assert(vault.allocation(adapter.adapterId())==0 && asset.balanceOf(address(adapter))==0 && asset.balanceOf(address(vault))==1000);
    }

    /// @custom:property ALLOC-MORPHO INT-CAPS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_capComposition(uint8 raw) public { test_check_capComposition(raw); }
}

contract GovernanceStandardERC4626 is ERC4626 {
    constructor(IERC20 asset) ERC4626(asset) ERC20("Standard vault", "SV") {}
}
contract GovernanceAllocatorProductionStrategy is GovernanceTestBase {
    GovernanceAsset internal asset;
    VaultV2 internal vault;
    AlchemistAllocator internal allocator;
    AlchemistStrategyClassifier internal classifier;
    ERC4626Strategy internal adapter;
    GovernanceStandardERC4626 internal externalVault;
    function setUp() public {
        vm.warp(100);
        asset=new GovernanceAsset(); vault=new VaultV2(ADMIN,address(asset)); classifier=new AlchemistStrategyClassifier(ADMIN);
        allocator=new AlchemistAllocator(address(vault),ADMIN,OPERATOR,address(classifier)); externalVault=new GovernanceStandardERC4626(IERC20(address(asset)));
        IMYTStrategy.StrategyParams memory parameters;
        parameters.owner=ADMIN; parameters.name="ERC4626"; parameters.protocol="Standard ERC4626";
        adapter=new ERC4626Strategy(address(vault),parameters,address(externalVault));
        vm.prank(ADMIN); vault.setCurator(ADMIN);
        _submit(abi.encodeCall(IVaultV2.setIsAllocator,(address(allocator),true))); vault.setIsAllocator(address(allocator),true);
        _submit(abi.encodeCall(IVaultV2.addAdapter,(address(adapter)))); vault.addAdapter(address(adapter));
        bytes memory id=adapter.getIdData();
        _submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap,(id,uint256(1000)))); vault.increaseAbsoluteCap(id,1000);
        _submit(abi.encodeCall(IVaultV2.increaseRelativeCap,(id,uint256(1e18)))); vault.increaseRelativeCap(id,1e18);
        vm.prank(ADMIN); classifier.setRiskClass(0,5e17,25e16);
        asset.mint(ALICE,1000); vm.prank(ALICE); asset.approve(address(vault),1000); vm.prank(ALICE); vault.deposit(1000,ALICE);
    }
    function _submit(bytes memory data) internal { vm.prank(ADMIN); vault.submit(data); }
    /// @custom:property ALLOC-MORPHO INT-CAPS
    /// @custom:classification DECOMPOSE: real allocator/classifier/VaultV2, production ERC4626Strategy and standard OpenZeppelin ERC4626 vault, zero fee/rate.
    /// @custom:limitations Concrete assets=1000, amount in [1,250], fixed one-strategy configuration, standard ERC20/ERC4626, no yield/fees; no arbitrary-strategy claim.
    function test_check_productionStrategyCapComposition(uint8 raw) public {
        uint256 amount=uint256(raw)%250+1;
        vm.prank(OPERATOR); allocator.allocate(address(adapter),amount);
        assert(vault.allocation(adapter.adapterId())==amount && externalVault.balanceOf(address(adapter))==amount);
        assert(asset.balanceOf(address(vault))==1000-amount && vault.totalAssets()==1000);
        _reject(address(allocator),OPERATOR,abi.encodeCall(allocator.allocate,(address(adapter),uint256(251)-amount)),abi.encodeWithSignature("EffectiveCap(uint256,uint256)",uint256(251)-amount,uint256(250)));
        assert(vault.allocation(adapter.adapterId())==amount && externalVault.balanceOf(address(adapter))==amount);
        vm.prank(ADMIN); allocator.allocate(address(adapter),uint256(500)-amount);
        assert(vault.allocation(adapter.adapterId())==500 && externalVault.balanceOf(address(adapter))==500);
        _reject(address(allocator),ADMIN,abi.encodeCall(allocator.allocate,(address(adapter),uint256(1))),abi.encodeWithSignature("EffectiveCap(uint256,uint256)",uint256(1),uint256(0)));
        vm.prank(OPERATOR); allocator.deallocate(address(adapter),500);
        assert(vault.allocation(adapter.adapterId())==0 && externalVault.balanceOf(address(adapter))==0 && asset.balanceOf(address(adapter))==0 && asset.balanceOf(address(vault))==1000);
    }

    /// @custom:property ALLOC-MORPHO INT-CAPS
    /// @custom:classification FUZZ companion: same constructive domain and implementation assertions.
    function test_fuzz_generated_productionStrategyCapComposition(uint8 raw) public { test_check_productionStrategyCapComposition(raw); }
}
