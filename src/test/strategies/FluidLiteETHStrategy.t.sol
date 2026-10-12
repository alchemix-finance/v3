// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {FluidLiteETHStrategy, IFluidLiteETHVault} from "../../strategies/FluidLiteETHStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";

contract MockSwapperForFluidLiteETH {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract FluidLiteETHStrategyTest is Test {
    uint256 internal constant ABSOLUTE_CAP = 1_000_000e18;
    uint256 internal constant RELATIVE_CAP = 1e18;
    uint256 internal constant MAX_ORACLE_STALENESS = 24 hours;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant FEE_SCALE = 1e6;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant IETH = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78;
    address public constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    // Curve stETH/ETH pool, used as a stETH source since `deal` cannot write rebasing balances.
    address public constant STETH_WHALE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    MockMYTVault internal vault;
    AlchemistAllocator internal allocator;
    AlchemistStrategyClassifier internal classifier;
    FluidLiteETHStrategy internal strategy;

    address internal admin = address(0xA11CE);
    address internal operator = address(0xB0B);
    uint256 private _forkId;

    function setUp() public {
        _forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"), getForkBlockNumber());
        vm.selectFork(_forkId);

        vault = new MockMYTVault(admin, WETH);
        classifier = new AlchemistStrategyClassifier(admin);

        vm.startPrank(admin);
        vault.setCurator(operator);
        classifier.setRiskClass(0, 1e18, 1e18);
        classifier.setRiskClass(1, 0.4e18, 0.25e18);
        classifier.setRiskClass(2, 1e18, 1e18); // HIGH widened so the test can exercise the full cap.
        allocator = new AlchemistAllocator(address(vault), admin, operator, address(classifier));
        vm.stopPrank();

        vm.startPrank(operator);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (admin)));
        vault.setPerformanceFeeRecipient(admin);
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (15e16)));
        vault.setPerformanceFee(15e16);
        vm.stopPrank();

        vm.startPrank(admin);
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "FluidLiteETH",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: SLIPPAGE_BPS
        });

        strategy = new FluidLiteETHStrategy(address(vault), params, IETH, STETH, STETH_ETH_ORACLE, MAX_ORACLE_STALENESS);
        classifier.assignStrategyRiskLevel(uint256(IMYTStrategy(address(strategy)).adapterId()), uint8(params.riskClass));
        vm.stopPrank();

        _setUpMYT();
        _mockFreshStEthEthOracle();
        _depositToVault(ABSOLUTE_CAP);
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_wires_vault_and_oracle() public view {
        assertEq(address(strategy.iETH()), IETH, "unexpected iETH");
        assertEq(address(strategy.stETH()), STETH, "unexpected stETH");
        assertEq(IFluidLiteETHVault(IETH).asset(), STETH, "iETHv2 asset should be stETH");
        assertEq(address(strategy.pricedTokenOracle()), STETH_ETH_ORACLE, "unexpected oracle");
        assertEq(strategy.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS, "unexpected staleness");
    }

    function test_constructor_reverts_on_asset_mismatch() public {
        IMYTStrategy.StrategyParams memory params = _params();
        vm.expectRevert(bytes("iETH asset != stETH"));
        new FluidLiteETHStrategy(address(vault), params, IETH, WETH, STETH_ETH_ORACLE, MAX_ORACLE_STALENESS);
    }

    /* ========== ALLOCATION ========== */

    function test_allocate_direct_reverts_noLidoStaking() public {
        _mockFreshStEthEthOracle();

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).allocate(address(strategy), 1e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), 0, "no shares should be minted");
        assertEq(IERC20(STETH).balanceOf(address(strategy)), 0, "no stETH should be held");
    }

    function test_allocateWithSwap_depositsReceivedStEthIntoIETH(uint256 amount) public {
        _mockFreshStEthEthOracle();
        amount = bound(amount, 1e18, 500e18);

        _allocateViaSwap(amount);

        uint256 shares = IERC20(IETH).balanceOf(address(strategy));
        assertGt(shares, 0, "strategy should hold iETHv2 shares after swap allocation");
        assertLe(IERC20(STETH).balanceOf(address(strategy)), 2, "stETH should be deposited, not retained");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "no idle WETH after swap allocation");

        // Mock swap is 1:1 and iETHv2 has no deposit fee, so position ~= amount in stETH terms.
        uint256 positionStETH = IFluidLiteETHVault(IETH).previewRedeem(shares);
        assertApproxEqRel(positionStETH, amount, 1e14, "position should track deposit 1:1");
        assertApproxEqRel(IMYTStrategy(address(strategy)).realAssets(), _stEthToWeth(positionStETH), 1e15);
    }

    function test_allocateWithSwap_reverts_below_oracle_minOut() public {
        _mockFreshStEthEthOracle();

        // Slippage allows 1% below oracle; return 2% below.
        uint256 amountIn = 10e18;
        uint256 shortOut = (amountIn * 9_800) / 10_000;

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), shortOut);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amountIn, shortOut));

        vm.expectRevert();
        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amountIn, txData);
    }

    function test_realAssets_includesRawStEthBalance() public {
        _mockFreshStEthEthOracle();
        _dealStETH(address(strategy), 3e18);

        uint256 raw = IERC20(STETH).balanceOf(address(strategy));
        assertApproxEqAbs(IMYTStrategy(address(strategy)).realAssets(), _stEthToWeth(raw), 2, "raw stETH should count");
    }

    /* ========== DEALLOCATION ========== */

    function test_deallocateWithUnwrapAndSwap_grossesUpVaultFee() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        uint256 minStETHOut = 4e18;
        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        uint256 positionBefore = IFluidLiteETHVault(IETH).previewRedeem(sharesBefore);
        uint256 allocationBefore = IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId());

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, minStETHOut, 4e18));

        _mockFreshStEthEthOracle();
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, minStETHOut);

        uint256 sharesAfter = IERC20(IETH).balanceOf(address(strategy));
        uint256 positionAfter = IFluidLiteETHVault(IETH).previewRedeem(sharesAfter);
        uint256 withdrawnFromVault = positionBefore - positionAfter;

        assertEq(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore + 4e18, "vault should receive WETH");
        assertLt(sharesAfter, sharesBefore, "iETHv2 shares should be burned");
        assertLt(
            IVaultV2(address(vault)).allocation(IMYTStrategy(address(strategy)).adapterId()),
            allocationBefore,
            "allocation should decrease"
        );

        // Fee gross-up: more than minStETHOut left the vault, but net of fee at least minStETHOut landed.
        uint256 feePct = IFluidLiteETHVault(IETH).withdrawalFeePercentage();
        uint256 expectedGross = (minStETHOut * FEE_SCALE + (FEE_SCALE - feePct) - 1) / (FEE_SCALE - feePct) + 2;
        assertGt(withdrawnFromVault, minStETHOut, "gross withdrawal must exceed net target");
        assertApproxEqAbs(withdrawnFromVault, expectedGross, 4, "gross withdrawal should match fee math");

        // Only rounding dust may remain; the swap consumed exactly minStETHOut.
        uint256 leftover = IERC20(STETH).balanceOf(address(strategy));
        assertLe(leftover, 4, "strategy should not retain meaningful stETH");
    }

    function test_deallocateWithUnwrapAndSwap_sellsRawStEthBeforeTouchingVault() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);
        _dealStETH(address(strategy), 5e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        uint256 sharesBefore = IERC20(IETH).balanceOf(address(strategy));
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        _mockFreshStEthEthOracle();
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 4e18);

        assertEq(IERC20(IETH).balanceOf(address(strategy)), sharesBefore, "vault shares untouched when raw stETH suffices");
    }

    function test_deallocateWithUnwrapAndSwap_reverts_when_vault_idle_liquidity_too_low() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        // Pretend the vault has only 1 stETH idle.
        vm.mockCall(STETH, abi.encodeWithSelector(IERC20.balanceOf.selector, IETH), abi.encode(uint256(1e18)));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        _mockFreshStEthEthOracle();
        vm.expectRevert(bytes("Vault idle stETH too low"));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 4e18);
    }

    function test_deallocateWithUnwrapAndSwap_reverts_when_minOut_exceeds_oracle_bound() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        deal(WETH, address(swapper), 4e18);
        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        // Ask for far more stETH than slippage math allows for a 4 WETH shortfall.
        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (STETH, WETH, 4e18, 4e18));

        _mockFreshStEthEthOracle();
        vm.expectRevert(bytes("Intermediate exceeds max oracle token in"));
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithUnwrapAndSwap(address(strategy), 4e18, txData, 8e18);
    }

    function test_deallocateWithSwap_reverts_useUnwrapPath() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).deallocateWithSwap(address(strategy), 1e18, hex"01");
    }

    function test_deallocate_direct_reverts() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(address(allocator)).deallocate(address(strategy), 1e18);
    }

    /* ========== PREVIEW ========== */

    function test_previewAdjustedWithdraw_is_conservative_and_accounts_for_fee() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        uint256 requested = 4e18;
        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(requested);

        assertGt(preview, 0, "preview should be positive");
        assertLt(preview, requested, "preview should be below requested");
        // At most slippage haircut; fee only bites when position is the binding constraint.
        assertGe(preview, (requested * (10_000 - SLIPPAGE_BPS)) / 10_000 - 1, "preview too pessimistic");
    }

    function test_previewAdjustedWithdraw_clamps_to_vault_idle_liquidity() public {
        _mockFreshStEthEthOracle();

        _allocateViaSwap(10e18);

        uint256 liquidity = 2e18;
        vm.mockCall(STETH, abi.encodeWithSelector(IERC20.balanceOf.selector, IETH), abi.encode(liquidity));

        uint256 fee = IFluidLiteETHVault(IETH).getWithdrawFee(liquidity);
        uint256 expectedCap = (_stEthToWeth(liquidity - fee) * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 preview = IMYTStrategy(address(strategy)).previewAdjustedWithdraw(8e18);
        assertApproxEqAbs(preview, expectedCap, 2, "preview should clamp to net idle liquidity");
    }

    function test_previewAdjustedWithdraw_returns_full_amount_from_idle() public {
        deal(WETH, address(strategy), 5e18);
        assertEq(IMYTStrategy(address(strategy)).previewAdjustedWithdraw(5e18), 5e18, "idle covers request");
    }

    /* ========== PROTECTED TOKENS ========== */

    function test_rescue_reverts_for_protected_tokens() public {
        address[3] memory protectedTokens = [WETH, STETH, IETH];
        for (uint256 i; i < protectedTokens.length; i++) {
            vm.expectRevert();
            vm.prank(admin);
            MYTStrategy(address(strategy)).rescueTokens(protectedTokens[i], admin, 1);
        }
    }

    /* ========== HELPERS ========== */

    function _params() internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: admin,
            name: "FluidLiteETH",
            protocol: "FluidLite",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 544,
            additionalIncentives: false,
            slippageBPS: SLIPPAGE_BPS
        });
    }

    /// @dev Enter the position through the only supported path: a 1:1 WETH->stETH mock swap.
    function _allocateViaSwap(uint256 amount) internal {
        MockSwapperForFluidLiteETH swapper = new MockSwapperForFluidLiteETH();
        _dealStETH(address(swapper), amount);

        vm.prank(admin);
        MYTStrategy(address(strategy)).setAllowanceHolder(address(swapper));

        bytes memory txData = abi.encodeCall(MockSwapperForFluidLiteETH.swap, (WETH, STETH, amount, amount));

        vm.prank(admin);
        IAllocator(address(allocator)).allocateWithSwap(address(strategy), amount, txData);
    }

    function _stEthToWeth(uint256 stETHAmount) internal view returns (uint256) {
        (, int256 answer,,,) = AggregatorV3Interface(STETH_ETH_ORACLE).latestRoundData();
        return stETHAmount * uint256(answer) / 1e18;
    }

    function _dealStETH(address to, uint256 amount) internal {
        vm.prank(STETH_WHALE);
        require(IERC20(STETH).transfer(to, amount), "stETH deal failed");
    }

    function _mockFreshStEthEthOracle() internal {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(STETH_ETH_ORACLE).latestRoundData();
        vm.mockCall(
            STETH_ETH_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
        );
    }

    function _setUpMYT() internal {
        vm.startPrank(operator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        IVaultV2(address(vault)).setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(strategy)));
        IVaultV2(address(vault)).addAdapter(address(strategy));

        bytes memory idData = IMYTStrategy(address(strategy)).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, ABSOLUTE_CAP)));
        IVaultV2(address(vault)).increaseAbsoluteCap(idData, ABSOLUTE_CAP);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        IVaultV2(address(vault)).increaseRelativeCap(idData, RELATIVE_CAP);
        vm.stopPrank();
    }

    function _depositToVault(uint256 amount) internal {
        deal(WETH, admin, amount);
        vm.startPrank(admin);
        TokenUtils.safeApprove(WETH, address(vault), amount);
        IVaultV2(address(vault)).deposit(amount, admin);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(address(vault)).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(address(vault)).timelock(selector));
    }

    function getForkBlockNumber() internal pure returns (uint256) {
        return 26_156_774;
    }
}
