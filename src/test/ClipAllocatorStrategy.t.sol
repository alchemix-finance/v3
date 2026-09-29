// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {AaveStrategy} from "../strategies/AaveStrategy.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {ClipAllocator} from "../utils/ClipAllocator.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {MockMYTVault} from "./mocks/MockMYTVault.sol";

/// @notice Direct-path happy path for ClipAllocator against a locally deployed allocator.
///         Subclasses deploy one strategy. The fork only provides the protocol that strategy talks to.
abstract contract ClipAllocatorStrategyTest is Test {
    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal operator = makeAddr("operator");
    address internal depositor = makeAddr("depositor");
    address internal bot = makeAddr("bot");

    MockMYTVault internal vault;
    IMYTStrategy internal strategy;
    AlchemistStrategyClassifier internal classifier;
    AlchemistAllocator internal allocator;
    ClipAllocator internal clip;

    function _rpc() internal view virtual returns (string memory);
    function _asset() internal view virtual returns (address);
    function _deposit() internal view virtual returns (uint256);
    function _clip() internal view virtual returns (uint256);
    function _dust() internal view virtual returns (uint256) {
        return 1e15;
    }
    function _absoluteCap() internal view virtual returns (uint256) {
        return 1_000 ether;
    }
    function _riskClass() internal view virtual returns (IMYTStrategy.RiskClass) {
        return IMYTStrategy.RiskClass.LOW;
    }

    /// @dev 50 bps covers Aave and Yearn rounding. A 9x realAssets move still reverts.
    function _maxLossBps() internal view virtual returns (uint16) {
        return 50;
    }
    function _deployStrategy(address vault_) internal virtual returns (IMYTStrategy);

    /// @dev Override to deploy a liquidity adapter. address(0) skips the liquidity test.
    function _deployLiquidityStrategy(address) internal virtual returns (IMYTStrategy) {
        return IMYTStrategy(address(0));
    }

    function setUp() public {
        vm.createSelectFork(_rpc());

        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(_asset(), admin, curator);
        strategy = _deployStrategy(address(vault));
        classifier = new AlchemistStrategyClassifier(admin);
        allocator = new AlchemistAllocator(address(vault), admin, operator, address(classifier));
        vm.stopPrank();

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        vm.stopPrank();

        _registerAdapter(strategy);

        vm.prank(admin);
        allocator.setMaxRate(uint256(200e16) / 365 days);

        uint256 depositAmount = _deposit();
        deal(_asset(), depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, depositor);
        vm.stopPrank();

        clip = new ClipAllocator(address(allocator));
        vm.prank(admin);
        allocator.setOperator(address(clip), true);
    }

    /// @dev Push one clip into the strategy and pull it back out. No liquidity adapter
    ///      is set, so the clip spends vault idle directly.
    function test_direct_allocateThenDeallocate() public {
        uint256 clipAmount = _clip();
        uint256 dust = _dust();
        address asset = _asset();

        clip.grantAllocate(bot, address(strategy), clipAmount, clipAmount, 0, address(0), 0, _maxLossBps());
        clip.grantDeallocate(bot, address(strategy), clipAmount, clipAmount, 0, address(0), 0, _maxLossBps());

        uint256 vaultBefore = IERC20(asset).balanceOf(address(vault));
        assertEq(strategy.realAssets(), 0);
        assertGe(vaultBefore, clipAmount);

        vm.prank(bot);
        clip.allocateClip(address(strategy), clipAmount);

        uint256 held = strategy.realAssets();
        assertApproxEqAbs(held, clipAmount, dust);
        assertApproxEqAbs(vault.allocation(strategy.adapterId()), held, dust);
        assertEq(IERC20(asset).balanceOf(address(vault)), vaultBefore - clipAmount);
        (uint256 allocateLeft,,,,,,) = clip.allocateGrants(bot, address(strategy));
        assertEq(allocateLeft, 0);

        uint256 pull = held > clipAmount ? clipAmount : held;
        vm.prank(bot);
        clip.deallocateClip(address(strategy), pull);

        assertApproxEqAbs(strategy.realAssets(), held - pull, dust);
        assertEq(IERC20(asset).balanceOf(address(vault)), vaultBefore - clipAmount + pull);
        (uint256 deallocateLeft,,,,,,) = clip.deallocateGrants(bot, address(strategy));
        assertEq(deallocateLeft, clipAmount - pull);
    }

    /// @dev Sweep idle into the liquidity adapter, then allocate a clip into the target.
    ///      The clip must raise the shortfall from that adapter and consume its deallocate grant.
    function test_allocate_raisesFromLiquidityAdapter() public {
        IMYTStrategy liquidity = _deployLiquidityStrategy(address(vault));
        if (address(liquidity) == address(0)) {
            vm.skip(true);
            return;
        }

        _registerAdapter(liquidity);
        vm.prank(admin);
        allocator.setLiquidityAdapter(address(liquidity), _directLiquidityData());

        address asset = _asset();
        uint256 idle = IERC20(asset).balanceOf(address(vault));
        vm.prank(admin);
        allocator.allocate(address(liquidity), idle);

        uint256 idleAfterSweep = IERC20(asset).balanceOf(address(vault));
        uint256 clipAmount = _clip();
        assertLt(idleAfterSweep, clipAmount, "sweep left enough idle to skip the raise");
        uint256 shortfall = clipAmount - idleAfterSweep;
        uint256 liquidityBefore = liquidity.realAssets();

        clip.grantAllocate(bot, address(strategy), clipAmount, clipAmount, 0, address(0), 0, _maxLossBps());
        clip.grantDeallocate(bot, address(liquidity), shortfall, shortfall, 0, address(0), 0, _maxLossBps());

        vm.prank(bot);
        clip.allocateClip(address(strategy), clipAmount);

        assertApproxEqAbs(strategy.realAssets(), clipAmount, _dust());
        assertApproxEqAbs(liquidityBefore - liquidity.realAssets(), shortfall, _dust());
        assertEq(IERC20(asset).balanceOf(address(vault)), 0);
        (uint256 allocateLeft,,,,,,) = clip.allocateGrants(bot, address(strategy));
        assertEq(allocateLeft, 0);
        (uint256 liquidityLeft,,,,,,) = clip.deallocateGrants(bot, address(liquidity));
        assertEq(liquidityLeft, 0);
    }

    function _registerAdapter(IMYTStrategy adapter) internal {
        bytes32 adapterId = adapter.adapterId();
        vm.prank(admin);
        classifier.assignStrategyRiskLevel(uint256(adapterId), uint8(_riskClass()));

        vm.startPrank(curator);
        _submitAndExecute(abi.encodeCall(IVaultV2.addAdapter, address(adapter)));
        vault.addAdapter(address(adapter));
        bytes memory idData = adapter.getIdData();
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, _absoluteCap())));
        vault.increaseAbsoluteCap(idData, _absoluteCap());
        _submitAndExecute(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();
    }

    function _directLiquidityData() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function _submitAndExecute(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }
}

/// @notice Aave v3 WETH on mainnet, deployed by the test.
contract ClipAllocatorAaveTest is ClipAllocatorStrategyTest {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AAVE_V3_ETH_WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address internal constant AAVE_V3_ETH_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address internal constant REWARD_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    /// @dev Yearn WETH-1 vault. Used only as the liquidity adapter.
    address internal constant YV_WETH_VAULT = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;

    function _rpc() internal view override returns (string memory) {
        return vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
    }

    function _asset() internal pure override returns (address) {
        return WETH;
    }

    function _deposit() internal pure override returns (uint256) {
        return 100 ether;
    }

    function _clip() internal pure override returns (uint256) {
        return 10 ether;
    }

    function _deployLiquidityStrategy(address vault_) internal override returns (IMYTStrategy) {
        return new ERC4626Strategy(
            vault_,
            IMYTStrategy.StrategyParams({
                owner: admin,
                name: "Yearn Mainnet WETH-1",
                protocol: "Yearn",
                riskClass: _riskClass(),
                cap: _absoluteCap(),
                globalCap: 1e18,
                estimatedYield: 500,
                additionalIncentives: false,
                slippageBPS: 1
            }),
            YV_WETH_VAULT
        );
    }

    function _deployStrategy(address vault_) internal override returns (IMYTStrategy) {
        return new AaveStrategy(
            vault_,
            _params(),
            WETH,
            AAVE_V3_ETH_WETH_ATOKEN,
            AAVE_V3_ETH_POOL_ADDRESS_PROVIDER,
            REWARDS_CONTROLLER,
            REWARD_TOKEN
        );
    }

    function _params() internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: admin,
            name: "AaveV3ETHWETH",
            protocol: "AaveV3ETHWETH",
            riskClass: _riskClass(),
            cap: _absoluteCap(),
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }
}
