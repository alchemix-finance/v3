// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

interface IVaultForceRun {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares);
    function forceDeallocatePenalty(address adapter) external view returns (uint256);
    function isAdapter(address adapter) external view returns (bool);
    function liquidityAdapter() external view returns (address);
}

interface ITokeAutoStrategyForceRun {
    function params()
        external
        view
        returns (
            address owner,
            string memory name,
            string memory protocol,
            IMYTStrategy.RiskClass riskClass,
            uint256 cap,
            uint256 globalCap,
            uint256 estimatedYield,
            bool additionalIncentives,
            uint256 slippageBPS
        );
    function adapterId() external view returns (bytes32);
    function previewAdjustedWithdraw(uint256 amount) external view returns (uint256);
    function realAssets() external view returns (uint256);
    function autoVault() external view returns (address);
    function rewarder() external view returns (address);
    function tokeRewardsToken() external view returns (address);
    function killSwitch() external view returns (bool);
}

interface ITokeAutoVaultForceRun {
    enum Rounding {
        Down,
        Up,
        Zero
    }

    enum TotalAssetPurpose {
        Global,
        Deposit,
        Withdraw
    }

    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets(TotalAssetPurpose purpose) external view returns (uint256);
    function convertToShares(uint256 assets, uint256 totalAssetsForPurpose, uint256 supply, Rounding rounding)
        external
        view
        returns (uint256);
}

interface IRewarderForceRun {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20ForceRun {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHForceRun is IERC20ForceRun {
    function deposit() external payable;
}

interface IWstETHForceRun is IERC20ForceRun {
    function stEthPerToken() external view returns (uint256);
}

interface IAaveV3PoolForceRun {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode)
        external;
}

interface IAaveFlashLoanSimpleReceiverForceRun {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

interface IUniV3RouterForceRun {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract TokeAutoForceDeallocateUpdatedRunTest is Test {
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant TOKE_AUTO_ETH_STRATEGY = 0x467Ec89b9E2cD62e66d1b28bd45DB1470D4908A5;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AUTOPILOT_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;

    uint256 internal constant FORK_BLOCK = 25_311_321;
    uint256 internal constant FORCE_DEALLOCATE_ASSETS = 475 ether;
    uint256 internal constant ATTACKER_STARTING_ETH = 120 ether;

    IVaultForceRun internal constant vault = IVaultForceRun(ETH_MYT);
    ITokeAutoStrategyForceRun internal constant strategy = ITokeAutoStrategyForceRun(TOKE_AUTO_ETH_STRATEGY);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETHEREUM_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);
        _overlayUpdatedStrategy();
    }

    function _overlayUpdatedStrategy() internal {
        address autoVault = strategy.autoVault();
        address rewarder = strategy.rewarder();
        address tokeRewardsToken = strategy.tokeRewardsToken();

        (
            address pOwner,
            ,
            ,
            IMYTStrategy.RiskClass pRisk,
            uint256 pCap,
            uint256 pGlobalCap,
            uint256 pYield,
            bool pAI,
            uint256 pSlip
        ) = strategy.params();

        IMYTStrategy.StrategyParams memory p = IMYTStrategy.StrategyParams({
            owner: pOwner,
            name: "TokeAutoETH (updated)",
            protocol: "TokeAuto",
            riskClass: pRisk,
            cap: pCap,
            globalCap: pGlobalCap,
            estimatedYield: pYield,
            additionalIncentives: pAI,
            slippageBPS: pSlip
        });

        // Production-default execution tolerance (DEFAULT_EXEC_TOLERANCE_BPS = 25 bps).
        bytes memory args =
            abi.encode(ETH_MYT, p, WETH, autoVault, rewarder, tokeRewardsToken, AUTOPILOT_ROUTER, uint256(25));
        deployCodeTo("TokeAutoStrategy.sol:TokeAutoStrategy", args, TOKE_AUTO_ETH_STRATEGY);

        assertEq(strategy.adapterId(), keccak256(abi.encode("this", TOKE_AUTO_ETH_STRATEGY)), "adapterId mismatch");
        assertEq(strategy.previewAdjustedWithdraw(1 ether), 0.94 ether, "slippage param not preserved");
        console2.log("overlaid updated TokeAutoStrategy; slippageBPS:", pSlip);
    }

    function _directParams() internal pure returns (bytes memory) {
        return abi.encode(
            IMYTStrategy.VaultAdapterParams({
                action: IMYTStrategy.ActionType.direct,
                swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
            })
        );
    }

    function _strategyAutoShares() internal view returns (uint256) {
        return ITokeAutoVaultForceRun(strategy.autoVault()).balanceOf(TOKE_AUTO_ETH_STRATEGY)
            + IRewarderForceRun(strategy.rewarder()).balanceOf(TOKE_AUTO_ETH_STRATEGY);
    }

    function test_control_plainForceDeallocate_succeeds_boundedLoss() public {
        deal(WETH, address(this), 40 ether);
        IERC20ForceRun(WETH).approve(ETH_MYT, type(uint256).max);
        vault.deposit(40 ether, address(this));

        uint256 sharesBefore = _strategyAutoShares();
        uint256 realBefore = strategy.realAssets();

        vault.forceDeallocate(TOKE_AUTO_ETH_STRATEGY, _directParams(), FORCE_DEALLOCATE_ASSETS, address(this));

        uint256 sharesBurned = sharesBefore - _strategyAutoShares();
        uint256 realAfter = strategy.realAssets();
        uint256 loss = realBefore > realAfter + FORCE_DEALLOCATE_ASSETS ? realBefore - (realAfter + FORCE_DEALLOCATE_ASSETS) : 0;

        console2.log("CONTROL shares burned ", sharesBurned);
        console2.log("CONTROL realAssets before", realBefore);
        console2.log("CONTROL realAssets after ", realAfter);
        console2.log("CONTROL strategy loss   ", loss);

        assertLt(loss, 20 ether, "control loss should be small");
    }

    function test_attack_sandwich_isBlocked() public {
        vm.deal(address(this), ATTACKER_STARTING_ETH);
        UpdatedForceAttacker attacker = new UpdatedForceAttacker();
        attacker.fund{value: ATTACKER_STARTING_ETH}();

        bool reverted;
        try attacker.attackOnce(1_000 ether, FORCE_DEALLOCATE_ASSETS) {
            reverted = false;
        } catch {
            reverted = true;
        }

        if (reverted) {
            console2.log("ATTACK reverted: updated direct path blocked sandwiched forced exit");
        } else {
            uint256 profit = attacker.ethEquivalentValue() > ATTACKER_STARTING_ETH
                ? attacker.ethEquivalentValue() - ATTACKER_STARTING_ETH
                : 0;
            uint256 strategyLoss = attacker.actualStrategyLoss();
            console2.log("ATTACK did NOT revert; profit:", profit);
            console2.log("ATTACK strategy loss:", strategyLoss);
            assertLt(strategyLoss, 20 ether, "updated path still leaks principal");
            assertLt(profit, 1 ether, "updated path still lets attacker profit");
        }

        assertTrue(reverted, "expected sandwiched force-deallocate to revert");
    }

    function test_sweepSandwichForceAmounts_actualStrategyOnly() public {
        uint256[6] memory flashAmounts =
            [uint256(50 ether), uint256(100 ether), uint256(250 ether), uint256(500 ether), uint256(750 ether), uint256(1_000 ether)];
        uint256[7] memory forceAmounts = [
            uint256(25 ether),
            uint256(50 ether),
            uint256(100 ether),
            uint256(150 ether),
            uint256(200 ether),
            uint256(300 ether),
            uint256(475 ether)
        ];

        for (uint256 j = 0; j < flashAmounts.length; j++) {
            for (uint256 i = 0; i < forceAmounts.length; i++) {
                uint256 snapshot = vm.snapshotState();
                uint256 flashAmount = flashAmounts[j];
                uint256 forceAmount = forceAmounts[i];

                vm.deal(address(this), ATTACKER_STARTING_ETH);
                UpdatedForceAttacker attacker = new UpdatedForceAttacker();
                attacker.fund{value: ATTACKER_STARTING_ETH}();

                uint256 valueBefore = attacker.ethEquivalentValue();
                try attacker.attackOnce(flashAmount, forceAmount) {
                    uint256 valueAfter = attacker.ethEquivalentValue();
                    uint256 profit = valueAfter > valueBefore ? valueAfter - valueBefore : 0;
                    uint256 strategyLoss = attacker.actualStrategyLoss();
                    console2.log("SWEEP flash amount   :", flashAmount);
                    console2.log("SWEEP force amount   :", forceAmount);
                    console2.log("SWEEP attacker profit:", profit);
                    console2.log("SWEEP strategy loss  :", strategyLoss);
                } catch {
                    console2.log("SWEEP reverted flash:", flashAmount);
                    console2.log("SWEEP reverted force:", forceAmount);
                }

                vm.revertToState(snapshot);
            }
        }
    }

    /// @notice Honest (no-sandwich) deallocations across sizes. The reported loss is
    /// NAV(shares burned) - pulled, i.e. the real execution cost of the redeem. loss_bps is
    /// the minimum EXEC_TOLERANCE_BPS that size requires to not revert.
    function test_measure_honest_exec_slippage() public {
        deal(WETH, address(this), 2_000 ether);
        IERC20ForceRun(WETH).approve(ETH_MYT, type(uint256).max);
        vault.deposit(1_500 ether, address(this));

        uint256[10] memory sizes = [
            uint256(25 ether),
            uint256(50 ether),
            uint256(100 ether),
            uint256(150 ether),
            uint256(200 ether),
            uint256(300 ether),
            uint256(475 ether),
            uint256(750 ether),
            uint256(1_000 ether),
            uint256(1_500 ether)
        ];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 size = sizes[i];
            uint256 realBefore = strategy.realAssets();
            try vault.forceDeallocate(TOKE_AUTO_ETH_STRATEGY, _directParams(), size, address(this)) {
                uint256 realAfter = strategy.realAssets();
                uint256 loss = realBefore > realAfter + size ? realBefore - (realAfter + size) : 0;
                uint256 lossBps = loss * 10_000 / size;
                console2.log("HONEST size (wei)  :", size);
                console2.log("HONEST loss (wei)  :", loss);
                console2.log("HONEST loss (bps)  :", lossBps);
            } catch {
                console2.log("HONEST reverted size:", size);
            }
            vm.revertToState(snap);
        }
    }

    /// @notice Honest 1,000 WETH deallocation across several blocks to gauge variance of the
    /// real execution cost (the floor for EXEC_TOLERANCE_BPS).
    function test_measure_honest_exec_slippage_multiblock() public {
        uint256[5] memory blocks = [
            uint256(25_311_321),
            uint256(25_290_000),
            uint256(25_250_000),
            uint256(25_200_000),
            uint256(25_100_000)
        ];

        for (uint256 b = 0; b < blocks.length; b++) {
            vm.createSelectFork(
                vm.envOr("ETHEREUM_RPC_URL", string("https://mainnet.gateway.tenderly.co")), blocks[b]
            );
            _overlayUpdatedStrategy();

            deal(WETH, address(this), 2_000 ether);
            IERC20ForceRun(WETH).approve(ETH_MYT, type(uint256).max);
            try vault.deposit(1_500 ether, address(this)) {} catch {}

            uint256 size = 1_000 ether;
            uint256 realBefore = strategy.realAssets();
            console2.log("BLOCK              :", blocks[b]);
            console2.log("  realBefore (wei) :", realBefore);
            try vault.forceDeallocate(TOKE_AUTO_ETH_STRATEGY, _directParams(), size, address(this)) {
                uint256 realAfter = strategy.realAssets();
                uint256 loss = realBefore > realAfter + size ? realBefore - (realAfter + size) : 0;
                console2.log("  honest loss (wei):", loss);
                console2.log("  honest loss (bps):", loss * 10_000 / size);
            } catch {
                console2.log("  honest 1000 WETH reverted");
            }
        }
    }
}

contract UpdatedForceAttacker is IAaveFlashLoanSimpleReceiverForceRun {
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant TOKE_AUTO_ETH_STRATEGY = 0x467Ec89b9E2cD62e66d1b28bd45DB1470D4908A5;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    IVaultForceRun internal constant vault = IVaultForceRun(ETH_MYT);
    IWETHForceRun internal constant weth = IWETHForceRun(WETH);
    IWstETHForceRun internal constant wsteth = IWstETHForceRun(WSTETH);
    IAaveV3PoolForceRun internal constant aave = IAaveV3PoolForceRun(AAVE_V3_POOL);
    IUniV3RouterForceRun internal constant uni = IUniV3RouterForceRun(UNI_V3_ROUTER);
    ITokeAutoStrategyForceRun internal constant strategy = ITokeAutoStrategyForceRun(TOKE_AUTO_ETH_STRATEGY);

    uint256 internal pendingForce;
    uint256 internal realAssetsBefore;
    uint256 internal realAssetsAfter;

    receive() external payable {}

    function fund() external payable {
        weth.deposit{value: 100 ether}();
        weth.approve(ETH_MYT, type(uint256).max);
        vault.deposit(100 ether, address(this));
        wsteth.approve(UNI_V3_ROUTER, type(uint256).max);
        weth.approve(UNI_V3_ROUTER, type(uint256).max);
        wsteth.approve(AAVE_V3_POOL, type(uint256).max);
    }

    function attackOnce(uint256 flashAmount, uint256 forceAmount) external {
        pendingForce = forceAmount;
        realAssetsBefore = strategy.realAssets();
        aave.flashLoanSimple(address(this), WSTETH, flashAmount, "", 0);
        realAssetsAfter = strategy.realAssets();
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == AAVE_V3_POOL, "only aave");
        require(initiator == address(this), "bad init");
        require(asset == WSTETH, "bad asset");

        uni.exactInputSingle(
            IUniV3RouterForceRun.ExactInputSingleParams({
                tokenIn: WSTETH,
                tokenOut: WETH,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        bytes memory directParams = abi.encode(
            IMYTStrategy.VaultAdapterParams({
                action: IMYTStrategy.ActionType.direct,
                swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
            })
        );
        vault.forceDeallocate(TOKE_AUTO_ETH_STRATEGY, directParams, pendingForce, address(this));

        uni.exactInputSingle(
            IUniV3RouterForceRun.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WSTETH,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: weth.balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        require(wsteth.balanceOf(address(this)) >= amount + premium, "cannot repay flash");
        return true;
    }

    function ethEquivalentValue() external view returns (uint256) {
        uint256 mytShares = vault.balanceOf(address(this));
        uint256 wstethAsWeth = wsteth.balanceOf(address(this)) * wsteth.stEthPerToken() / 1e18;
        return address(this).balance + weth.balanceOf(address(this)) + wstethAsWeth + vault.previewRedeem(mytShares);
    }

    function actualStrategyLoss() external view returns (uint256) {
        return realAssetsBefore > realAssetsAfter + pendingForce ? realAssetsBefore - (realAssetsAfter + pendingForce) : 0;
    }
}
