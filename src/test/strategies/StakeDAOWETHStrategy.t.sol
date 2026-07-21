// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakeDAOWETHStrategy} from "../../strategies/StakeDAOWETHStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {IStakeDAORewardVault, ICurveStableSwapPool} from "../../strategies/interfaces/IStakeDAO.sol";

interface ICurvePoolManipulation {
    function balances(uint256 index) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver) external returns (uint256);
}

interface IExchangeRateProvider {
    function exchangeRate() external view returns (uint256);
}

contract MockEnsoBidirectional {
    IERC20 public immutable weth;
    IERC20 public immutable rewardVaultShares;

    constructor(address _weth, address _rewardVaultShares) {
        weth = IERC20(_weth);
        rewardVaultShares = IERC20(_rewardVaultShares);
    }

    fallback() external {
        uint256 wethAllowance = weth.allowance(msg.sender, address(this));
        if (wethAllowance > 0) {
            uint256 wethBalance = weth.balanceOf(msg.sender);
            uint256 wethAmount = wethAllowance < wethBalance ? wethAllowance : wethBalance;
            weth.transferFrom(msg.sender, address(this), wethAmount);
            rewardVaultShares.transfer(msg.sender, wethAmount);
            return;
        }

        uint256 shareAllowance = rewardVaultShares.allowance(msg.sender, address(this));
        require(shareAllowance > 0, "No Enso allowance");

        uint256 shareBalance = rewardVaultShares.balanceOf(msg.sender);
        uint256 shareAmount = shareAllowance < shareBalance ? shareAllowance : shareBalance;
        rewardVaultShares.transferFrom(msg.sender, address(this), shareAmount);
        weth.transfer(msg.sender, shareAmount);
    }
}

contract MockCurvePool is IERC20 {
    string public name = "Curve ETH+/WETH LP";
    string public symbol = "crvETH+WETH";
    uint8 public decimals = 18;

    IERC20 public immutable weth;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address _weth) {
        weth = IERC20(_weth);
    }

    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount, address receiver) external returns (uint256) {
        require(amounts.length == 2 && amounts[1] > 0, "WETH amount required");
        weth.transferFrom(msg.sender, address(this), amounts[1]);
        uint256 lpMinted = amounts[1];
        require(lpMinted >= minMintAmount, "Slippage");
        balanceOf[receiver] += lpMinted;
        totalSupply += lpMinted;
        return lpMinted;
    }

    function remove_liquidity_one_coin(uint256 burnAmount, int128, uint256 minReceived, address receiver) external returns (uint256) {
        balanceOf[msg.sender] -= burnAmount;
        totalSupply -= burnAmount;
        require(burnAmount >= minReceived, "Slippage");
        weth.transfer(receiver, burnAmount);
        return burnAmount;
    }

    function calc_token_amount(uint256[] calldata amounts, bool) external view returns (uint256) {
        require(amounts.length == 2 && amounts[1] > 0, "WETH amount required");
        return amounts[1];
    }

    function calc_withdraw_one_coin(uint256 tokenAmount, int128) external pure returns (uint256) {
        return tokenAmount;
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1e18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockRewardVault is IERC20 {
    string public name = "sd-ETH+ETH-vault";
    string public symbol = "sdETH+ETH";
    uint8 public decimals = 18;

    address public immutable asset;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address _asset) {
        asset = _asset;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function earned(address, address) external pure returns (uint128) {
        return 0;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function getRewardTokens() external pure returns (address[] memory tokens) {
        return tokens;
    }

    function claim(address[] calldata tokens, address) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        return amounts;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256 assets) {
        return shares;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256 shares) {
        return assets;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256 shares) {
        return assets;
    }
}

contract Mock0xRouter {
    IERC20 public immutable sellToken;
    IERC20 public immutable buyToken;
    uint256 public immutable priceWad;

    constructor(address _sellToken, address _buyToken, uint256 _priceWad) {
        sellToken = IERC20(_sellToken);
        buyToken = IERC20(_buyToken);
        priceWad = _priceWad;
    }

    function swap(address sellToken_, address buyToken_, uint256 amountIn) external returns (uint256 amountOut) {
        require(sellToken_ == address(sellToken) && buyToken_ == address(buyToken), "unsupported pair");
        sellToken.transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * priceWad / 1e18;
        buyToken.transfer(msg.sender, amountOut);
        return amountOut;
    }
}

contract MockStakeDAOWETHStrategy is StakeDAOWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _rewardVault, address _curvePool, address _ensoRouter)
        StakeDAOWETHStrategy(_myt, _params, _rewardVault, _curvePool, _ensoRouter, 125, 0.98e18, 0.95e18)
    {}
}

contract StakeDAOWETHStrategyEnsoTest is Test {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public admin = address(1);
    address public curator = address(2);
    address public vault;
    address public strategy;
    address public allocator;

    MockEnsoBidirectional public ensoRouter;
    MockCurvePool public curvePool;
    MockRewardVault public rewardVault;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpc);

        vm.startPrank(admin);
        vault = address(MYTTestHelper._setupVault(WETH, admin, curator));

        curvePool = new MockCurvePool(WETH);
        rewardVault = new MockRewardVault(address(curvePool));
        ensoRouter = new MockEnsoBidirectional(WETH, address(rewardVault));
        rewardVault.mint(address(ensoRouter), 1_000_000e18);
        deal(WETH, address(ensoRouter), 1_000_000e18);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "StakeDAOWETH",
            protocol: "StakeDAO",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: true,
            slippageBPS: 125
        });

        strategy = address(new MockStakeDAOWETHStrategy(vault, params, address(rewardVault), address(curvePool), address(ensoRouter)));

        address classifier = address(new AlchemistStrategyClassifier(admin));
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 1e18, 1e18);
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 0.4e18, 0.25e18);
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 0.1e18, 0.1e18);
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(IMYTStrategy(strategy).adapterId()), uint8(IMYTStrategy.RiskClass.MEDIUM));
        allocator = address(new AlchemistAllocator(vault, admin, curator, classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        IVaultV2(vault).setIsAllocator(allocator, true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, (strategy)));
        IVaultV2(vault).addAdapter(strategy);

        bytes memory idData = IMYTStrategy(strategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, 10_000e18)));
        IVaultV2(vault).increaseAbsoluteCap(idData, 10_000e18);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        IVaultV2(vault).increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        _magicDepositToVault(1000e18);

        vm.prank(admin);
        AlchemistAllocator(allocator).setMaxRate(200e16 / uint256(365 days));
    }

    function _magicDepositToVault(uint256 amount) internal {
        deal(WETH, admin, amount);
        vm.startPrank(admin);
        TokenUtils.safeApprove(WETH, vault, amount);
        IVaultV2(vault).deposit(amount, admin);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(vault).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(vault).timelock(selector));
    }

    function _swapParams(bytes memory txData) internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.swap;
        params.swapParams = IMYTStrategy.SwapParams({txData: txData, minIntermediateOut: 0});
        return abi.encode(params);
    }

    function test_allocate_with_enso_mints_reward_vault_shares() public {
        uint256 amount = 5e18;

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(_swapParams(hex"01"), amount, "", address(vault));
        vm.stopPrank();

        assertEq(IERC20(address(rewardVault)).balanceOf(strategy), amount);
        assertEq(IMYTStrategy(strategy).realAssets(), amount);
    }

    function test_allocate_with_enso_reverts_below_lp_per_weth_floor() public {
        uint256 amount = 5e18;

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinCurveLpPerWeth(2e18);

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        vm.expectPartialRevert(StakeDAOWETHStrategy.CurveLpOutputBelowFloor.selector);
        IMYTStrategy(strategy).allocate(_swapParams(hex"01"), amount, "", address(vault));
        vm.stopPrank();
    }

    function test_deallocate_with_enso_returns_weth() public {
        uint256 allocAmount = 5e18;
        uint256 deallocAmount = 3e18;

        vm.startPrank(vault);
        deal(WETH, strategy, allocAmount);
        IMYTStrategy(strategy).allocate(_swapParams(hex"01"), allocAmount, "", address(vault));

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount);
        IMYTStrategy(strategy).deallocate(_swapParams(hex"02"), preview, "", address(vault));
        vm.stopPrank();

        assertGe(TokenUtils.safeBalanceOf(WETH, strategy), preview);
        assertLt(IERC20(address(rewardVault)).balanceOf(strategy), allocAmount);
    }

    function test_deallocate_with_enso_reverts_below_curve_lp_floor() public {
        uint256 allocAmount = 5e18;

        vm.startPrank(vault);
        deal(WETH, strategy, allocAmount);
        IMYTStrategy(strategy).allocate(_swapParams(hex"01"), allocAmount, "", address(vault));
        vm.stopPrank();

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(2e18);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(3e18);
        vm.startPrank(vault);
        vm.expectPartialRevert(StakeDAOWETHStrategy.CurveLpPriceBelowFloor.selector);
        IMYTStrategy(strategy).deallocate(_swapParams(hex"02"), preview, "", address(vault));
        vm.stopPrank();
    }

    function test_allocator_allocateWithSwap() public {
        uint256 amount = 2e18;

        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(strategy, amount, hex"01");
        assertGt(IMYTStrategy(strategy).realAssets(), 0);
        vm.stopPrank();
    }

    function test_allocator_deallocateWithSwap() public {
        uint256 amount = 2e18;

        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(strategy, amount, hex"01");

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        IAllocator(allocator).deallocateWithSwap(strategy, preview, hex"02");
        vm.stopPrank();

        assertGt(TokenUtils.safeBalanceOf(WETH, vault), 0);
    }

    function test_force_deallocate_swap_reverts() public {
        vm.startPrank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(_swapParams(hex"02"), 1, IVaultV2.forceDeallocate.selector, address(vault));
        vm.stopPrank();
    }

    function test_allocate_succeeds_at_exact_enso_slippage_boundary() public {
        uint256 amount = 5e18;
        uint256 minShares = amount * (10_000 - 125) / 10_000;

        MockEnsoUnderDeliver exactOutputRouter = new MockEnsoUnderDeliver(WETH, address(rewardVault), minShares);
        rewardVault.mint(address(exactOutputRouter), minShares);

        StakeDAOWETHStrategy exactOutputStrategy = new MockStakeDAOWETHStrategy(
            vault,
            IMYTStrategy.StrategyParams({
                owner: admin,
                name: "StakeDAOWETH",
                protocol: "StakeDAO",
                riskClass: IMYTStrategy.RiskClass.MEDIUM,
                cap: 10_000e18,
                globalCap: 1e18,
                estimatedYield: 100e18,
                additionalIncentives: true,
                slippageBPS: 125
            }),
            address(rewardVault),
            address(curvePool),
            address(exactOutputRouter)
        );

        vm.startPrank(vault);
        deal(WETH, address(exactOutputStrategy), amount);
        IMYTStrategy(address(exactOutputStrategy)).allocate(_swapParams(hex"01"), amount, "", address(vault));
        vm.stopPrank();

        assertEq(rewardVault.balanceOf(address(exactOutputStrategy)), minShares);
        assertEq(IERC20(WETH).balanceOf(address(exactOutputStrategy)), 0);
    }

    function test_allocate_reverts_when_enso_under_delivers_shares() public {
        uint256 amount = 5e18;
        uint256 minShares = amount * (10_000 - 125) / 10_000;
        uint256 underDeliveredShares = minShares - 1;

        MockEnsoUnderDeliver underDeliver = new MockEnsoUnderDeliver(WETH, address(rewardVault), underDeliveredShares);
        rewardVault.mint(address(underDeliver), amount);

        StakeDAOWETHStrategy underDeliverStrategy = new MockStakeDAOWETHStrategy(
            vault,
            IMYTStrategy.StrategyParams({
                owner: admin,
                name: "StakeDAOWETH",
                protocol: "StakeDAO",
                riskClass: IMYTStrategy.RiskClass.MEDIUM,
                cap: 10_000e18,
                globalCap: 1e18,
                estimatedYield: 100e18,
                additionalIncentives: true,
                slippageBPS: 125
            }),
            address(rewardVault),
            address(curvePool),
            address(underDeliver)
        );

        vm.startPrank(vault);
        deal(WETH, address(underDeliverStrategy), amount);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minShares, underDeliveredShares));
        IMYTStrategy(address(underDeliverStrategy)).allocate(_swapParams(hex"01"), amount, "", address(vault));
        vm.stopPrank();
    }
}

contract MockEnsoUnderDeliver {
    IERC20 public immutable weth;
    IERC20 public immutable rewardVaultShares;
    uint256 public immutable sharesToMint;

    constructor(address _weth, address _rewardVaultShares, uint256 _sharesToMint) {
        weth = IERC20(_weth);
        rewardVaultShares = IERC20(_rewardVaultShares);
        sharesToMint = _sharesToMint;
    }

    fallback() external {
        uint256 wethAllowance = weth.allowance(msg.sender, address(this));
        if (wethAllowance > 0) {
            uint256 wethBalance = weth.balanceOf(msg.sender);
            uint256 wethAmount = wethAllowance < wethBalance ? wethAllowance : wethBalance;
            weth.transferFrom(msg.sender, address(this), wethAmount);
            rewardVaultShares.transfer(msg.sender, sharesToMint);
        }
    }
}

/// @notice Mainnet fork tests for direct allocate/deallocate against real Curve + RewardVault contracts.
contract StakeDAOWETHStrategyDirectTest is BaseStrategyTest {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ETH_PLUS = 0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8;
    address public constant ETH_PLUS_RATE_PROVIDER = 0x0cAA3EB22Aa22eFB7886308942870ba81aaa05C6;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant REWARD_VAULT = 0x7d3dB01a4AC4aa27534d2951e58d59992686EA5C;
    address public constant ETH_PLUS_WETH_POOL = 0x2c683fAd51da2cd17793219CC86439C1875c353e;
    address public constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    function test_owner_can_set_withdraw_buffer_independently_from_slippage() public {
        uint256 newWithdrawBufferBps = 200;
        (,,,,,,,, uint256 slippageBefore) = IMYTStrategy(strategy).params();

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setWithdrawBufferBps(newWithdrawBufferBps);

        (,,,,,,,, uint256 slippageAfter) = IMYTStrategy(strategy).params();
        assertEq(StakeDAOWETHStrategy(strategy).withdrawBufferBps(), newWithdrawBufferBps);
        assertEq(slippageAfter, slippageBefore, "withdraw buffer should not change slippage");
    }

    function test_set_withdraw_buffer_reverts_above_cap() public {
        uint256 maxWithdrawBufferBps = StakeDAOWETHStrategy(strategy).MAX_WITHDRAW_BUFFER_BPS();

        vm.prank(admin);
        vm.expectRevert("Withdraw buffer too high");
        StakeDAOWETHStrategy(strategy).setWithdrawBufferBps(maxWithdrawBufferBps);
    }

    function test_owner_can_set_curve_lp_floor() public {
        uint256 newFloor = 0.99e18;

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(newFloor);

        assertEq(StakeDAOWETHStrategy(strategy).minWethPerCurveLp(), newFloor);
    }

    function test_set_curve_lp_floor_reverts_for_non_owner_or_zero() public {
        vm.expectRevert();
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(0.99e18);

        vm.prank(admin);
        vm.expectRevert("Zero Curve LP floor");
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(0);
    }

    function test_owner_can_set_lp_per_weth_allocation_floor() public {
        uint256 newFloor = 0.94e18;

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinCurveLpPerWeth(newFloor);

        assertEq(StakeDAOWETHStrategy(strategy).minCurveLpPerWeth(), newFloor);
    }

    function test_set_lp_per_weth_allocation_floor_reverts_for_non_owner_or_zero() public {
        vm.expectRevert();
        StakeDAOWETHStrategy(strategy).setMinCurveLpPerWeth(0.94e18);

        vm.prank(admin);
        vm.expectRevert("Zero allocation floor");
        StakeDAOWETHStrategy(strategy).setMinCurveLpPerWeth(0);
    }

    function test_direct_allocate_reverts_when_curve_manipulation_pushes_lp_output_below_floor() public {
        uint256 allocationAmount = 1e18;
        uint256 floor = StakeDAOWETHStrategy(strategy).minCurveLpPerWeth();
        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);

        _swapCurveCoin(WETH, 1, 0, ICurvePoolManipulation(ETH_PLUS_WETH_POOL).balances(1) * 2);

        uint256[] memory amounts = new uint256[](2);
        amounts[1] = allocationAmount;
        uint256 manipulatedLpQuote = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).calc_token_amount(amounts, true);
        assertLt(manipulatedLpQuote, allocationAmount * floor / 1e18, "manipulation did not breach allocation floor");

        vm.prank(admin);
        vm.expectRevert();
        IAllocator(allocator).allocate(strategy, allocationAmount);

        assertEq(IERC20(REWARD_VAULT).balanceOf(strategy), sharesBefore, "shares changed after reverted allocation");
        assertEq(IERC20(WETH).balanceOf(vault), vaultWethBefore, "vault WETH changed after reverted allocation");
        assertEq(IERC20(WETH).allowance(strategy, ETH_PLUS_WETH_POOL), 0, "Curve WETH allowance not cleared");
    }

    function test_direct_deallocate_reverts_when_curve_manipulation_pushes_weth_output_below_floor() public {
        uint256 allocationAmount = 100e18;
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocationAmount);

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 strategyWethBefore = IERC20(WETH).balanceOf(strategy);
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);
        uint256 floor = StakeDAOWETHStrategy(strategy).minWethPerCurveLp();

        _swapCurveCoin(ETH_PLUS, 0, 1, ICurvePoolManipulation(ETH_PLUS_WETH_POOL).balances(0) * 2);

        uint256 manipulatedWethQuote = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).calc_withdraw_one_coin(1e18, int128(1));
        assertLt(manipulatedWethQuote, floor, "manipulation did not breach withdrawal floor");

        vm.prank(admin);
        vm.expectPartialRevert(StakeDAOWETHStrategy.CurveLpPriceBelowFloor.selector);
        IAllocator(allocator).deallocate(strategy, 1e18);

        assertEq(IERC20(REWARD_VAULT).balanceOf(strategy), sharesBefore, "shares changed after reverted deallocation");
        assertEq(IERC20(WETH).balanceOf(strategy), strategyWethBefore, "strategy WETH changed after reverted deallocation");
        assertEq(IERC20(WETH).balanceOf(vault), vaultWethBefore, "vault WETH changed after reverted deallocation");
        assertEq(IERC20(ETH_PLUS_WETH_POOL).allowance(strategy, ETH_PLUS_WETH_POOL), 0, "Curve LP allowance not cleared");
    }

    function test_total_value_uses_reward_vault_lp_assets_and_virtual_price() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 lpAssets = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 expectedLpValue = Math.mulDiv(lpAssets, ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price(), 1e18);
        uint256 expectedTotalValue = IERC20(WETH).balanceOf(strategy) + expectedLpValue;

        assertEq(IMYTStrategy(strategy).realAssets(), expectedTotalValue, "unexpected virtual-price total value");
    }

    function test_total_value_resists_single_block_curve_exit_price_manipulation() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 lpAssets = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 totalValueBefore = IMYTStrategy(strategy).realAssets();
        uint256 executableWethBefore = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).calc_withdraw_one_coin(lpAssets, int128(1));

        _swapCurveCoin(ETH_PLUS, 0, 1, ICurvePoolManipulation(ETH_PLUS_WETH_POOL).balances(0) * 2);

        uint256 executableWethAfter = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).calc_withdraw_one_coin(lpAssets, int128(1));
        uint256 expectedTotalValue =
            IERC20(WETH).balanceOf(strategy) + Math.mulDiv(lpAssets, ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price(), 1e18);

        assertLt(executableWethAfter, executableWethBefore, "manipulation did not reduce executable WETH quote");
        assertEq(IMYTStrategy(strategy).realAssets(), expectedTotalValue, "total value should use virtual price");
        assertGe(IMYTStrategy(strategy).realAssets(), totalValueBefore, "single-block swap should not reduce total value");
    }

    function test_total_value_resists_direct_token_donations_to_curve_pool() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        uint256 virtualPriceBefore = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price();
        uint256 totalValueBefore = IMYTStrategy(strategy).realAssets();
        address donor = makeAddr("curve-donor");

        deal(WETH, donor, 1000e18);
        deal(ETH_PLUS, donor, 1000e18);
        vm.startPrank(donor);
        IERC20(WETH).transfer(ETH_PLUS_WETH_POOL, 1000e18);
        IERC20(ETH_PLUS).transfer(ETH_PLUS_WETH_POOL, 1000e18);
        vm.stopPrank();

        assertEq(ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price(), virtualPriceBefore, "direct donations changed virtual price");
        assertEq(IMYTStrategy(strategy).realAssets(), totalValueBefore, "direct donations changed total value");
    }

    function test_total_value_resists_imbalanced_liquidity_addition_and_removal() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        uint256 virtualPriceBefore = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price();
        uint256 totalValueBefore = IMYTStrategy(strategy).realAssets();
        address manipulator = makeAddr("liquidity-manipulator");
        uint256 wethAmount = 1000e18;
        uint256[] memory amounts = new uint256[](2);
        amounts[1] = wethAmount;

        deal(WETH, manipulator, wethAmount);
        vm.startPrank(manipulator);
        IERC20(WETH).approve(ETH_PLUS_WETH_POOL, wethAmount);
        uint256 lpMinted = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).add_liquidity(amounts, 0, manipulator);

        uint256 virtualPriceAfterAdd = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price();
        assertGe(virtualPriceAfterAdd, virtualPriceBefore, "imbalanced addition reduced virtual price");

        IERC20(ETH_PLUS_WETH_POOL).approve(ETH_PLUS_WETH_POOL, lpMinted);
        ICurveStableSwapPool(ETH_PLUS_WETH_POOL).remove_liquidity_one_coin(lpMinted, int128(1), 0, manipulator);
        vm.stopPrank();

        uint256 virtualPriceAfterRemove = ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price();
        assertGe(virtualPriceAfterRemove, virtualPriceBefore, "imbalanced removal reduced virtual price");
        assertGe(IMYTStrategy(strategy).realAssets(), totalValueBefore, "liquidity imbalance reduced total value");
    }

    function test_total_value_tracks_eth_plus_rate_provider_changes() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        uint256 totalValueBefore = IMYTStrategy(strategy).realAssets();
        uint256 currentRate = IExchangeRateProvider(ETH_PLUS_RATE_PROVIDER).exchangeRate();
        vm.mockCall(ETH_PLUS_RATE_PROVIDER, abi.encodeCall(IExchangeRateProvider.exchangeRate, ()), abi.encode(currentRate / 2));

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 lpAssets = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 expectedTotalValue =
            IERC20(WETH).balanceOf(strategy) + Math.mulDiv(lpAssets, ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price(), 1e18);

        assertEq(IMYTStrategy(strategy).realAssets(), expectedTotalValue, "total value ignored rate-provider change");
        assertLt(IMYTStrategy(strategy).realAssets(), totalValueBefore, "lower ETH+ rate did not reduce total value");
        vm.clearMockedCalls();
    }

    function test_direct_deallocate_reverts_when_curve_lp_price_is_below_floor() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 1e18);

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(2e18);

        vm.prank(admin);
        vm.expectPartialRevert(StakeDAOWETHStrategy.CurveLpPriceBelowFloor.selector);
        IAllocator(allocator).deallocate(strategy, 0.5e18);
    }

    function test_preview_adjusted_withdraw_caps_position_at_curve_lp_floor() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 1e18);

        uint256 floor = 0.5e18;
        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setMinWethPerCurveLp(floor);

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 lpAssets = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 floorValue = lpAssets * floor / 1e18;
        (,,,,,,,, uint256 slippageBPS) = IMYTStrategy(strategy).params();
        uint256 expectedPreview = floorValue * (10_000 - slippageBPS) / 10_000;

        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(type(uint256).max), expectedPreview, "preview should cap position at floor-priced value");
    }

    function test_force_deallocate_defaults_disabled_and_owner_can_enable() public {
        assertFalse(StakeDAOWETHStrategy(strategy).canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setCanForceDeallocate(true);

        assertTrue(StakeDAOWETHStrategy(strategy).canForceDeallocate(), "force deallocate should be enabled");
    }

    function test_claimRewards_uses_real_reward_vault_and_swaps_cvx_to_weth() public {
        uint256 cvxWethPrice = 0.5e18;
        uint256 earnedRewards = _accrueCvxRewards();
        Mock0xRouter mock0xRouter = _setUp0xRouter(cvxWethPrice);

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);
        uint256 vaultCvxBefore = IERC20(CVX).balanceOf(vault);
        uint256 routerCvxBefore = IERC20(CVX).balanceOf(address(mock0xRouter));
        bytes memory quote = abi.encodeCall(Mock0xRouter.swap, (CVX, WETH, earnedRewards));

        vm.prank(admin);
        uint256 wethReceived = IMYTStrategy(strategy).claimRewards(CVX, quote, 1);

        uint256 cvxSwapped = IERC20(CVX).balanceOf(address(mock0xRouter)) - routerCvxBefore;
        uint256 expectedWeth = cvxSwapped * cvxWethPrice / 1e18;
        assertGt(cvxSwapped, 0, "real RewardVault should transfer CVX");
        assertEq(wethReceived, expectedWeth, "claimRewards should return fixed-price WETH output");
        assertEq(IERC20(WETH).balanceOf(vault), vaultWethBefore + expectedWeth, "MYT should receive WETH");
        assertEq(IERC20(CVX).balanceOf(vault), vaultCvxBefore, "MYT should not receive CVX");
        assertEq(IERC20(CVX).balanceOf(strategy), 0, "strategy should not retain CVX");
    }

    function test_claimRewards_can_sell_half_cvx_and_leave_remainder_in_strategy() public {
        uint256 cvxWethPrice = 0.5e18;
        uint256 earnedRewards = _accrueCvxRewards();
        uint256 sellAmount = earnedRewards / 2;
        Mock0xRouter mock0xRouter = _setUp0xRouter(cvxWethPrice);

        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);
        bytes memory quote = abi.encodeCall(Mock0xRouter.swap, (CVX, WETH, sellAmount));

        vm.prank(admin);
        uint256 wethReceived = IMYTStrategy(strategy).claimRewards(CVX, quote, 1);

        uint256 expectedWeth = sellAmount * cvxWethPrice / 1e18;
        uint256 unsoldCvx = earnedRewards - sellAmount;
        assertEq(wethReceived, expectedWeth, "claimRewards should return WETH from half the CVX");
        assertEq(IERC20(WETH).balanceOf(vault), vaultWethBefore + expectedWeth, "MYT should receive swapped WETH");
        assertEq(IERC20(CVX).balanceOf(strategy), unsoldCvx, "strategy should retain unsold CVX");
        assertEq(IERC20(CVX).balanceOf(address(mock0xRouter)), sellAmount, "router should pull only half the CVX");
    }

    function test_owner_can_rescue_unsold_cvx_after_partial_reward_swap() public {
        uint256 earnedRewards = _accrueCvxRewards();
        uint256 sellAmount = earnedRewards / 2;
        _setUp0xRouter(0.5e18);
        bytes memory quote = abi.encodeCall(Mock0xRouter.swap, (CVX, WETH, sellAmount));

        vm.prank(admin);
        IMYTStrategy(strategy).claimRewards(CVX, quote, 1);

        uint256 unsoldCvx = IERC20(CVX).balanceOf(strategy);
        address recipient = makeAddr("cvx-rescue-recipient");
        vm.prank(admin);
        MYTStrategy(strategy).rescueTokens(CVX, recipient, unsoldCvx);

        assertEq(unsoldCvx, earnedRewards - sellAmount, "unexpected unsold CVX");
        assertEq(IERC20(CVX).balanceOf(strategy), 0, "strategy CVX should be rescued");
        assertEq(IERC20(CVX).balanceOf(recipient), unsoldCvx, "recipient should receive rescued CVX");
    }

    function _accrueCvxRewards() internal returns (uint256 earnedRewards) {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 100e18);

        IStakeDAORewardVault liveRewardVault = IStakeDAORewardVault(REWARD_VAULT);
        address rewardsDistributor = liveRewardVault.getRewardsDistributor(CVX);
        uint128 rewardAmount = 100e18;
        deal(CVX, rewardsDistributor, rewardAmount);
        vm.startPrank(rewardsDistributor);
        IERC20(CVX).approve(REWARD_VAULT, rewardAmount);
        liveRewardVault.depositRewards(CVX, rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        earnedRewards = liveRewardVault.earned(strategy, CVX);
        assertGt(earnedRewards, 1, "real RewardVault should accrue CVX");
    }

    function _setUp0xRouter(uint256 cvxWethPrice) internal returns (Mock0xRouter mock0xRouter) {
        mock0xRouter = new Mock0xRouter(CVX, WETH, cvxWethPrice);
        deal(WETH, address(mock0xRouter), 1_000_000e18);
        vm.prank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(mock0xRouter));
    }

    function _swapCurveCoin(address tokenIn, int128 i, int128 j, uint256 amountIn) internal {
        address manipulator = makeAddr("curve-manipulator");
        deal(tokenIn, manipulator, amountIn);

        vm.startPrank(manipulator);
        IERC20(tokenIn).approve(ETH_PLUS_WETH_POOL, amountIn);
        ICurvePoolManipulation(ETH_PLUS_WETH_POOL).exchange(i, j, amountIn, 0, manipulator);
        vm.stopPrank();
    }

    function testFuzz_forceDeallocate_direct_succeeds(uint256 rawAllocateAmount, uint256 rawForceDeallocateAmount) public {
        uint256 minAllocateAmount = _getMinAllocateAmount();
        (, uint256 maxAllocateAmount) = _getAllocationBounds();
        uint256 allocateAmount = bound(rawAllocateAmount, minAllocateAmount * 2, maxAllocateAmount);
        uint256 forceDeallocateAmount = bound(rawForceDeallocateAmount, minAllocateAmount, allocateAmount / 2);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        uint256 strategyAssetsAfterAllocate = IMYTStrategy(strategy).realAssets();
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);
        uint256 allocationBefore = IVaultV2(vault).allocation(IMYTStrategy(strategy).adapterId());
        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(strategy);

        vm.prank(admin);
        StakeDAOWETHStrategy(strategy).setCanForceDeallocate(true);

        vm.prank(vaultDepositor);
        IVaultV2(vault).forceDeallocate(strategy, getVaultParams(), forceDeallocateAmount, vaultDepositor);

        assertLt(IMYTStrategy(strategy).realAssets(), strategyAssetsAfterAllocate, "strategy assets should decrease");
        assertLt(IVaultV2(vault).allocation(IMYTStrategy(strategy).adapterId()), allocationBefore, "allocation should decrease");
        assertLt(IERC20(REWARD_VAULT).balanceOf(strategy), sharesBefore, "RewardVault shares should decrease");
        assertGt(IERC20(WETH).balanceOf(vault), vaultWethBefore, "vault should receive WETH");
    }

    function testFuzz_deallocate_uses_idle_weth_before_reward_vault_shares(uint256 rawAllocateAmount, uint256 rawIdleAmount, uint256 rawDeallocateAmount)
        public
    {
        uint256 minAllocateAmount = _getMinAllocateAmount();
        (, uint256 maxAllocateAmount) = _getAllocationBounds();
        uint256 allocateAmount = bound(rawAllocateAmount, minAllocateAmount * 2, maxAllocateAmount);
        uint256 idleAmount = bound(rawIdleAmount, minAllocateAmount, allocateAmount / 2);
        uint256 deallocateAmount = bound(rawDeallocateAmount, minAllocateAmount, idleAmount);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 strategyWethBefore = IERC20(WETH).balanceOf(strategy);
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);

        deal(WETH, strategy, strategyWethBefore + idleAmount);

        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, deallocateAmount);

        assertEq(IERC20(REWARD_VAULT).balanceOf(strategy), sharesBefore, "RewardVault shares should remain untouched");
        assertEq(IERC20(WETH).balanceOf(strategy), strategyWethBefore + idleAmount - deallocateAmount, "idle WETH should fund deallocate");
        assertEq(IERC20(WETH).balanceOf(vault), vaultWethBefore + deallocateAmount, "vault should receive idle WETH");
    }

    function testFuzz_deallocate_uses_idle_weth_then_reward_vault_shares_for_shortfall(
        uint256 rawAllocateAmount,
        uint256 rawIdleAmount,
        uint256 rawShortfallAmount
    ) public {
        uint256 minAllocateAmount = _getMinAllocateAmount();
        uint256 allocateAmount = bound(rawAllocateAmount, minAllocateAmount * 20, 1000e18);
        uint256 idleAmount = bound(rawIdleAmount, minAllocateAmount, allocateAmount / 10);
        uint256 shortfallAmount = bound(rawShortfallAmount, minAllocateAmount, allocateAmount / 10);
        uint256 deallocateAmount = idleAmount + shortfallAmount;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        uint256 sharesBefore = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 strategyAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 strategyWethBefore = IERC20(WETH).balanceOf(strategy);
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(vault);

        deal(WETH, strategy, strategyWethBefore + idleAmount);

        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, deallocateAmount);

        uint256 sharesAfter = IERC20(REWARD_VAULT).balanceOf(strategy);
        assertLt(sharesAfter, sharesBefore, "RewardVault shares should cover the shortfall");
        assertGt(sharesAfter, 0, "deallocate should only partially redeem the position");
        assertGe(IMYTStrategy(strategy).realAssets(), strategyWethBefore, "strategy should remain solvent after mixed deallocate");
        assertLt(IMYTStrategy(strategy).realAssets(), strategyAssetsBefore + idleAmount, "strategy assets should decrease");
        assertGe(IERC20(WETH).balanceOf(vault), vaultWethBefore + deallocateAmount, "vault should receive requested WETH");
    }

    function testFuzz_accounting_uses_reward_vault_assets_after_lp_accrual(uint256 rawAllocateAmount, uint256 rawAccruedLp) public {
        uint256 minAllocateAmount = _getMinAllocateAmount();
        uint256 allocateAmount = bound(rawAllocateAmount, minAllocateAmount * 20, 1000e18);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        uint256 shares = IERC20(REWARD_VAULT).balanceOf(strategy);
        uint256 assetsBeforeAccrual = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 accruedLp = bound(rawAccruedLp, minAllocateAmount, allocateAmount / 10);
        uint256 accruedAssets = assetsBeforeAccrual + accruedLp;
        vm.mockCall(REWARD_VAULT, abi.encodeWithSelector(bytes4(keccak256("convertToAssets(uint256)")), shares), abi.encode(accruedAssets));
        vm.warp(block.timestamp + 7 days);

        uint256 lpAssets = IStakeDAORewardVault(REWARD_VAULT).convertToAssets(shares);
        uint256 expectedPositionValue = Math.mulDiv(lpAssets, ICurveStableSwapPool(ETH_PLUS_WETH_POOL).get_virtual_price(), 1e18);
        uint256 idleAssets = IERC20(WETH).balanceOf(strategy);
        uint256 expectedRealAssets = idleAssets + expectedPositionValue;
        uint256 previewTarget = expectedRealAssets / 2;
        uint256 previewFromIdle = previewTarget <= idleAssets ? previewTarget : idleAssets;
        uint256 previewFromPosition = previewTarget - previewFromIdle;
        (,,,,,,,, uint256 slippageBPS) = IMYTStrategy(strategy).params();
        uint256 expectedPreview = previewFromIdle + (previewFromPosition * (10_000 - slippageBPS)) / 10_000;

        assertEq(lpAssets, accruedAssets, "RewardVault LP assets should accrue");
        assertEq(IMYTStrategy(strategy).realAssets(), expectedRealAssets, "realAssets should use convertToAssets");
        assertEq(IMYTStrategy(strategy).previewAdjustedWithdraw(previewTarget), expectedPreview, "previewAdjustedWithdraw should use convertToAssets");
        vm.clearMockedCalls();
    }

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "StakeDAOWETH",
            protocol: "StakeDAO",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: true,
            slippageBPS: 125
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 50_000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new StakeDAOWETHStrategy(vault_, params, REWARD_VAULT, ETH_PLUS_WETH_POOL, ENSO_ROUTER, 125, 1e18, 0.95e18));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
    }

    function _getMinAllocateAmount() internal pure override returns (uint256) {
        return 0.01e18;
    }
}
