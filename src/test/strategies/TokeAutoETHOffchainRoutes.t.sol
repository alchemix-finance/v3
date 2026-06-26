// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    IERC4626Like,
    TokeAutoStrategy,
    TokeRedeemParams,
    TokeSwapRoute
} from "../../strategies/TokeAutoStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract TokeAutoETHOffchainRoutesTest is Test {
    string internal constant FIXTURE_PATH =
        "src/test/strategies/utils/offchain/quotes/tokeAutoEthRedeem1500EthWithRoutes.json";

    address internal constant TOKE_AUTO_ETH_VAULT = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address internal constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address internal constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;

    address internal admin = address(1);
    MockMYTVault internal vault;
    TokeAutoStrategy internal strategy;
    IERC4626Like internal autoVault;
    string internal fixture;
    address internal curator = address(2);
    address internal operator = address(3);
    address internal vaultDepositor = address(4);
    address internal allocator;
    address internal classifier;

    function setUp() public {
        fixture = vm.readFile(FIXTURE_PATH);
        uint256 blockNumber = _readUint(".blockNumber");
        vm.createSelectFork(_readString(".rpcUrl"), blockNumber);

        vault = new MockMYTVault(admin, WETH);
        autoVault = IERC4626Like(TOKE_AUTO_ETH_VAULT);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "TokeAutoEth Offchain Routes",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 100
        });

        strategy = new TokeAutoStrategy(address(vault), params, WETH, TOKE_AUTO_ETH_VAULT, REWARDER, TOKE, AUTOPILOT_ROUTER, 25);
        _setUpAllocator();
    }

    function test_deallocateWithSwap_usesStaticOffchainRoutes() public {
        uint256 withdrawAmount = _readUint(".withdrawAmount");
        uint256 minAmountOut = _readUint(".minAmountOut");
        uint256 fixtureTotalAssetsForWithdraw = _readUint(".totalAssetsForWithdraw");
        uint256 fixtureTotalSupply = _readUint(".totalSupply");
        uint256 fixtureSharesNeeded = _readUint(".sharesNeeded");

        uint256 totalAssetsForWithdraw = autoVault.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw);
        uint256 totalSupply = autoVault.totalSupply();
        assertEq(totalAssetsForWithdraw, fixtureTotalAssetsForWithdraw, "fixture totalAssets mismatch");
        assertEq(totalSupply, fixtureTotalSupply, "fixture totalSupply mismatch");

        uint256 computedShares = autoVault.convertToShares(
            withdrawAmount,
            totalAssetsForWithdraw,
            totalSupply,
            IERC4626Like.Rounding.Up
        );
        assertEq(computedShares, fixtureSharesNeeded, "fixture shares mismatch");

        IMYTStrategy.VaultAdapterParams memory allocateParams = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.direct,
            swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
        });

        deal(WETH, address(strategy), 1600e18);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(abi.encode(allocateParams), 1600e18, "", address(vault));
        assertGe(IMYTStrategy(address(strategy)).realAssets(), withdrawAmount, "strategy underallocated");

        TokeSwapRoute[] memory routes = new TokeSwapRoute[](2);
        routes[0] = TokeSwapRoute({
            fromToken: vm.parseJsonAddress(fixture, ".routes[0].fromToken"),
            toToken: vm.parseJsonAddress(fixture, ".routes[0].toToken"),
            target: vm.parseJsonAddress(fixture, ".routes[0].target"),
            data: vm.parseJsonBytes(fixture, ".routes[0].data")
        });
        routes[1] = TokeSwapRoute({
            fromToken: vm.parseJsonAddress(fixture, ".routes[1].fromToken"),
            toToken: vm.parseJsonAddress(fixture, ".routes[1].toToken"),
            target: vm.parseJsonAddress(fixture, ".routes[1].target"),
            data: vm.parseJsonBytes(fixture, ".routes[1].data")
        });

        TokeRedeemParams memory redeemParams =
            TokeRedeemParams({minAmountOut: minAmountOut, customRoutes: routes});
        IMYTStrategy.SwapParams memory swapParams =
            IMYTStrategy.SwapParams({txData: abi.encode(redeemParams), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory adapterParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        uint256 wethBefore = IERC20(WETH).balanceOf(address(strategy));

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(abi.encode(adapterParams), withdrawAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(address(strategy)) - wethBefore, withdrawAmount, "insufficient WETH out");
    }

    function test_allocator_deallocateWithSwap_usesStaticOffchainRoutes() public {
        uint256 withdrawAmount = _readUint(".withdrawAmount");
        uint256 minAmountOut = _readUint(".minAmountOut");

        deal(WETH, vaultDepositor, 2000e18);
        vm.startPrank(vaultDepositor);
        IERC20(WETH).approve(address(vault), 2000e18);
        vault.deposit(2000e18, vaultDepositor);
        vm.stopPrank();

        vm.startPrank(admin);
        IAllocator(allocator).allocate(address(strategy), 1600e18);
        assertGe(IMYTStrategy(address(strategy)).realAssets(), withdrawAmount, "strategy underallocated");

        TokeRedeemParams memory redeemParams =
            TokeRedeemParams({minAmountOut: minAmountOut, customRoutes: _loadRoutes()});

        uint256 vaultBalanceBefore = IERC20(WETH).balanceOf(address(vault));
        IAllocator(allocator).deallocateWithSwap(address(strategy), withdrawAmount, abi.encode(redeemParams));
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(address(vault)) - vaultBalanceBefore, withdrawAmount, "vault should receive WETH");
    }

    function _readUint(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(fixture, key));
    }

    function _readString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(fixture, key);
    }

    function _loadRoutes() internal view returns (TokeSwapRoute[] memory routes) {
        routes = new TokeSwapRoute[](2);
        routes[0] = TokeSwapRoute({
            fromToken: vm.parseJsonAddress(fixture, ".routes[0].fromToken"),
            toToken: vm.parseJsonAddress(fixture, ".routes[0].toToken"),
            target: vm.parseJsonAddress(fixture, ".routes[0].target"),
            data: vm.parseJsonBytes(fixture, ".routes[0].data")
        });
        routes[1] = TokeSwapRoute({
            fromToken: vm.parseJsonAddress(fixture, ".routes[1].fromToken"),
            toToken: vm.parseJsonAddress(fixture, ".routes[1].toToken"),
            target: vm.parseJsonAddress(fixture, ".routes[1].target"),
            data: vm.parseJsonBytes(fixture, ".routes[1].data")
        });
    }

    function _setUpAllocator() internal {
        vm.prank(admin);
        vault.setCurator(curator);

        vm.startPrank(admin);
        classifier = address(new AlchemistStrategyClassifier(admin));
        AlchemistStrategyClassifier(classifier).setRiskClass(uint8(IMYTStrategy.RiskClass.MEDIUM), 1e18, 1e18);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(
            uint256(strategy.adapterId()),
            uint8(IMYTStrategy.RiskClass.MEDIUM)
        );
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);
        _submitAndExecute(abi.encodeCall(IVaultV2.addAdapter, (address(strategy))));
        vault.addAdapter(address(strategy));
        bytes memory idData = strategy.getIdData();
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 2000e18)));
        vault.increaseAbsoluteCap(idData, 2000e18);
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();
    }

    function _submitAndExecute(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }
}
