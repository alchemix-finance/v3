// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626Like, TokeAutoStrategy, TokeRedeemParams, TokeSwapRoute} from "../../strategies/TokeAutoStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract TokeAutoUSDOffchainRoutesTest is Test {
    string internal constant FIXTURE_PATH = "src/test/strategies/utils/offchain/quotes/tokeAutoUsdRedeem100kUsdWithRoutes.json";

    address internal constant TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
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

        vault = new MockMYTVault(admin, USDC);
        autoVault = IERC4626Like(TOKE_AUTO_USD_VAULT);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "TokeAutoUSD Offchain Routes",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 200_000e6,
            globalCap: 1e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });

        strategy = new TokeAutoStrategy(address(vault), params, USDC, TOKE_AUTO_USD_VAULT, REWARDER, TOKE, AUTOPILOT_ROUTER, 25);
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

        uint256 computedShares = autoVault.convertToShares(withdrawAmount, totalAssetsForWithdraw, totalSupply, IERC4626Like.Rounding.Up);
        assertEq(computedShares, fixtureSharesNeeded, "fixture shares mismatch");

        IMYTStrategy.VaultAdapterParams memory allocateParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.direct, swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})});

        deal(USDC, address(strategy), 120_000e6);
        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).allocate(abi.encode(allocateParams), 120_000e6, "", address(vault));
        assertGe(IMYTStrategy(address(strategy)).realAssets(), withdrawAmount, "strategy underallocated");

        TokeRedeemParams memory redeemParams = TokeRedeemParams({minAmountOut: minAmountOut, customRoutes: _loadRoutes()});
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: abi.encode(redeemParams), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory adapterParams = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(strategy));

        vm.prank(address(vault));
        IMYTStrategy(address(strategy)).deallocate(abi.encode(adapterParams), withdrawAmount, "", address(vault));
        assertGe(IERC20(USDC).balanceOf(address(strategy)) - usdcBefore, withdrawAmount, "insufficient USDC out");
    }

    function test_allocator_deallocateWithSwap_usesStaticOffchainRoutes() public {
        uint256 withdrawAmount = _readUint(".withdrawAmount");
        uint256 minAmountOut = _readUint(".minAmountOut");

        deal(USDC, vaultDepositor, 150_000e6);
        vm.startPrank(vaultDepositor);
        IERC20(USDC).approve(address(vault), 150_000e6);
        vault.deposit(150_000e6, vaultDepositor);
        vm.stopPrank();

        vm.startPrank(admin);
        IAllocator(allocator).allocate(address(strategy), 120_000e6);
        assertGe(IMYTStrategy(address(strategy)).realAssets(), withdrawAmount, "strategy underallocated");

        TokeRedeemParams memory redeemParams = TokeRedeemParams({minAmountOut: minAmountOut, customRoutes: _loadRoutes()});

        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(address(vault));
        IAllocator(allocator).deallocateWithSwap(address(strategy), withdrawAmount, abi.encode(redeemParams));
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(vault)) - vaultBalanceBefore, withdrawAmount, "vault should receive USDC");
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
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategy.adapterId()), uint8(IMYTStrategy.RiskClass.MEDIUM));
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);
        _submitAndExecute(abi.encodeCall(IVaultV2.addAdapter, (address(strategy))));
        vault.addAdapter(address(strategy));
        bytes memory idData = strategy.getIdData();
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 150_000e6)));
        vault.increaseAbsoluteCap(idData, 150_000e6);
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
