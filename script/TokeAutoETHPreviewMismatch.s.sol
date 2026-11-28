// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

import {MockMYTVault} from "../src/test/mocks/MockMYTVault.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";

interface IRootOraclePoc {
    function getPriceInEth(address token) external returns (uint256);
    function getCeilingPrice(address token, address pool, address quoteToken) external returns (uint256);
    function getFloorPrice(address token, address pool, address quoteToken) external returns (uint256);
}

contract TokeAutoETHPreviewMismatchScript is Script, Test {
    address internal constant TOKE_AUTO_ETH_VAULT = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address internal constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC;
    address internal constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;

    address internal constant ADMIN = address(1);
    address internal constant CURATOR = address(2);
    address internal constant OPERATOR = address(3);
    address internal constant VAULT_DEPOSITOR = address(4);

    uint256 internal constant FORK_BLOCK = 24_667_747;
    uint256 internal constant ABSOLUTE_CAP = 10_000e18;
    uint256 internal constant RELATIVE_CAP = 1e18;
    uint256 internal constant INITIAL_VAULT_DEPOSIT = 1_000e18;

    struct Env {
        MockMYTVault vault;
        TokeAutoStrategy strategy;
        AlchemistAllocator allocator;
    }

    function run() external {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, FORK_BLOCK);
        vm.selectFork(forkId);

        console.log("Forked Ethereum mainnet at block", block.number);
        console.log("Reproducing Tokemak ETH previewAdjustedWithdraw mismatch...");

        Env memory liveEnv = _deployEnvironment();
        _runLiveUnwindMismatch(liveEnv);

        Env memory idleEnv = _deployEnvironment();
        _runIdleOnlyMismatch(idleEnv);

        console.log("PoC completed successfully.");
    }

    function _deployEnvironment() internal returns (Env memory env) {
        vm.startPrank(ADMIN);
        env.vault = new MockMYTVault(ADMIN, WETH);
        env.vault.setCurator(CURATOR);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: ADMIN,
            name: "TokeAutoEth PoC",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: ABSOLUTE_CAP,
            globalCap: RELATIVE_CAP,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 30
        });

        env.strategy = new TokeAutoStrategy(address(env.vault), params, WETH, TOKE_AUTO_ETH_VAULT, REWARDER, TOKE);

        AlchemistStrategyClassifier classifier = new AlchemistStrategyClassifier(ADMIN);
        classifier.setRiskClass(0, type(uint256).max, type(uint256).max);
        classifier.setRiskClass(1, type(uint256).max, type(uint256).max);
        classifier.setRiskClass(2, type(uint256).max, type(uint256).max);
        classifier.assignStrategyRiskLevel(uint256(env.strategy.adapterId()), uint8(IMYTStrategy.RiskClass.MEDIUM));

        env.allocator = new AlchemistAllocator(address(env.vault), ADMIN, OPERATOR, address(classifier));
        vm.stopPrank();

        vm.startPrank(CURATOR);
        _vaultSubmitAndFastForward(env.vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(env.allocator), true)));
        env.vault.setIsAllocator(address(env.allocator), true);

        _vaultSubmitAndFastForward(env.vault, abi.encodeCall(IVaultV2.addAdapter, (address(env.strategy))));
        env.vault.addAdapter(address(env.strategy));

        bytes memory idData = env.strategy.getIdData();
        _vaultSubmitAndFastForward(env.vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, ABSOLUTE_CAP)));
        env.vault.increaseAbsoluteCap(idData, ABSOLUTE_CAP);

        _vaultSubmitAndFastForward(env.vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        env.vault.increaseRelativeCap(idData, RELATIVE_CAP);
        vm.stopPrank();

        deal(WETH, VAULT_DEPOSITOR, INITIAL_VAULT_DEPOSIT);
        vm.startPrank(VAULT_DEPOSITOR);
        IERC20(WETH).approve(address(env.vault), INITIAL_VAULT_DEPOSIT);
        env.vault.deposit(INITIAL_VAULT_DEPOSIT, VAULT_DEPOSITOR);
        vm.stopPrank();
    }

    function _runLiveUnwindMismatch(Env memory env) internal {
        console.log("");
        console.log("[1/2] Live unwind mismatch");

        vm.prank(ADMIN);
        env.allocator.allocate(address(env.strategy), 2e18);
        _warpWithOracle(7 days);

        vm.prank(ADMIN);
        env.allocator.allocate(address(env.strategy), 1e18);
        _warpWithOracle(14 days);

        uint256 smallPreview = env.strategy.previewAdjustedWithdraw(0.05e18);
        vm.prank(ADMIN);
        env.allocator.deallocate(address(env.strategy), smallPreview);
        _warpWithOracle(30 days);

        uint256 realAssetsBefore = env.strategy.realAssets();
        uint256 idleAssetsBefore = IERC20(WETH).balanceOf(address(env.strategy));
        uint256 previewAmount = env.strategy.previewAdjustedWithdraw(realAssetsBefore);

        console.log("realAssets before final unwind:", realAssetsBefore);
        console.log("idle WETH before final unwind:", idleAssetsBefore);
        console.log("strategy previewAdjustedWithdraw(realAssets):", previewAmount);

        vm.prank(ADMIN);
        (bool ok, bytes memory err) =
            address(env.allocator).call(abi.encodeWithSelector(IAllocator.deallocate.selector, address(env.strategy), previewAmount));

        require(!ok, "allocator.deallocate unexpectedly succeeded for previewed amount");

        string memory reason = _decodeRevertReason(err);
        console.log("allocator.deallocate reverted with reason:");
        console.log(reason);
        require(
            keccak256(bytes(reason)) == keccak256(bytes("Withdraw amount insufficient")),
            "unexpected revert reason"
        );
    }

    function _runIdleOnlyMismatch(Env memory env) internal {
        console.log("");
        console.log("[2/2] Idle-only preview blind spot");

        deal(WETH, address(env.strategy), 1e18);
        uint256 preview = env.strategy.previewAdjustedWithdraw(1e18);
        console.log("previewAdjustedWithdraw(1 ether) with only idle WETH:", preview);
        require(preview == 0, "expected zero preview for idle-only funds");

        vm.prank(address(env.vault));
        (bool ok,) = address(env.strategy).call(
            abi.encodeWithSelector(IMYTStrategy.deallocate.selector, _directParams(), 1e18, bytes4(0), address(env.vault))
        );
        require(ok, "direct strategy deallocate from idle funds should succeed");

        uint256 allowance = IERC20(WETH).allowance(address(env.strategy), address(env.vault));
        console.log("post-deallocate allowance granted to vault:", allowance);
        require(allowance == 1e18, "expected deallocate approval for the idle WETH");
    }

    function _vaultSubmitAndFastForward(MockMYTVault vault, bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function _warpWithOracle(uint256 timeDelta) internal {
        uint256 mockedEthPrice = 1_108_368_970_000_000_000;
        uint256 mockedCeilingPrice = 1_006_112_990_447_894_840;
        uint256 mockedFloorPrice = 1_001_260_889_888_317_396;

        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOraclePoc.getPriceInEth.selector),
            abi.encode(mockedEthPrice)
        );
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOraclePoc.getCeilingPrice.selector),
            abi.encode(mockedCeilingPrice)
        );
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IRootOraclePoc.getFloorPrice.selector),
            abi.encode(mockedFloorPrice)
        );

        vm.warp(block.timestamp + timeDelta);
    }

    function _directParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function _decodeRevertReason(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            return "non-standard revert";
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }

        if (selector != 0x08c379a0 || revertData.length < 68) {
            return "non-Error(string) revert";
        }

        bytes memory payload = new bytes(revertData.length - 4);
        for (uint256 i = 4; i < revertData.length; ++i) {
            payload[i - 4] = revertData[i];
        }

        return abi.decode(payload, (string));
    }
}
