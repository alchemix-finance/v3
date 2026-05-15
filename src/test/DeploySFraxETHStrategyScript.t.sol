// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySFraxETHStrategyScript} from "../../script/DeploySFraxETHStrategy.s.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {SFraxETHStrategy} from "../strategies/SFraxETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockOracleForSFraxETHDeployTest {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockSwapperForSFraxETHDeployTest {
    function swap(address from, address to, uint256 amountIn, uint256 amountOut) external {
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract MockMYTForSFraxETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract DeploySFraxETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address internal constant MAINNET_SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    uint256 internal constant MAINNET_FORK_BLOCK = 24_980_826;
    uint256 internal constant ALLOCATION_AMOUNT = 10e18;
    uint256 internal constant DEALLOCATION_TARGET = 4e18;
    uint256 internal constant MAX_ORACLE_STALENESS = 24 hours;

    DeploySFraxETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForSFraxETHDeployTest internal myt;

    address internal newOwner;
    address internal minter;
    address internal frxETH;
    address internal sfrxETH;
    address internal frxEthEthDualOracle;

    uint256 internal constant MIN_FRXETH_OUT_BPS = 9000;

    function setUp() public {
        deployScript = new DeploySFraxETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForSFraxETHDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        minter = makeAddr("minter");
        frxETH = makeAddr("frxETH");
        sfrxETH = makeAddr("sfrxETH");
        frxEthEthDualOracle = makeAddr("frxEthEthDualOracle");
    }

    function test_deploySFraxETHStrategy_setsCoreAddressesAndFloor() public {
        DeploySFraxETHStrategyScript.SFraxETHDeployConfig memory config = DeploySFraxETHStrategyScript
            .SFraxETHDeployConfig({
            myt: address(myt),
            minter: minter,
            frxETH: frxETH,
            sfrxETH: sfrxETH,
            frxEthEthDualOracle: frxEthEthDualOracle,
            minFrxEthOutBps: MIN_FRXETH_OUT_BPS,
            maxOracleStaleness: MAX_ORACLE_STALENESS,
            params: _buildParams("sfrxETH Mainnet", "Frax")
        });

        address strategyAddr = deployScript.deploySFraxETHStrategy(curator, newOwner, config);
        SFraxETHStrategy strategy = SFraxETHStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.minter()), minter, "unexpected minter");
        assertEq(address(strategy.frxETH()), frxETH, "unexpected frxETH");
        assertEq(address(strategy.sfrxETH()), sfrxETH, "unexpected sfrxETH");
        assertEq(strategy.minFrxEthOutBps(), MIN_FRXETH_OUT_BPS, "unexpected minFrxEthOutBps");
        assertEq(strategy.MAX_ORACLE_STALENESS(), MAX_ORACLE_STALENESS, "unexpected max oracle staleness");
        assertEq(strategy.killSwitch(), true, "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "sfrxETH Mainnet", "unexpected strategy name");
        assertEq(protocol, "Frax", "unexpected protocol");
    }

    function test_run_fork_allocatorCanAllocateAndDeallocateSFraxETH() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        // Mirror curator admin authority so the test can perform post-deploy registration and cap setup.
        vm.store(CURATOR_ADDR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));

        DeploySFraxETHStrategyScript forkDeployScript = new DeploySFraxETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        SFraxETHStrategy strategy = SFraxETHStrategy(payable(strategyAddr));
        AlchemistCurator liveCurator = AlchemistCurator(CURATOR_ADDR);
        IVaultV2 vault = IVaultV2(ETH_MYT);
        IMYTStrategy.StrategyParams memory params = forkDeployScript.defaultParams();

        vm.startPrank(DEPLOYER);
        liveCurator.setOperator(DEPLOYER, true);
        liveCurator.submitSetStrategy(strategyAddr, ETH_MYT);
        liveCurator.setStrategy(strategyAddr, ETH_MYT);
        liveCurator.submitIncreaseAbsoluteCap(strategyAddr, params.cap);
        liveCurator.increaseAbsoluteCap(strategyAddr, params.cap);
        liveCurator.submitIncreaseRelativeCap(strategyAddr, params.globalCap);
        liveCurator.increaseRelativeCap(strategyAddr, params.globalCap);
        vm.stopPrank();

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.frxETH()), MAINNET_FRXETH, "unexpected frxETH");
        assertEq(address(strategy.sfrxETH()), MAINNET_SFRXETH, "unexpected sfrxETH");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertTrue(vault.isAdapter(strategyAddr), "strategy not registered");
        assertEq(vault.absoluteCap(strategy.adapterId()), params.cap, "absolute cap not set");
        assertEq(vault.relativeCap(strategy.adapterId()), params.globalCap, "relative cap not set");

        uint256 vaultWethBalanceBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        deal(MAINNET_WETH, ETH_MYT, vaultWethBalanceBefore + ALLOCATION_AMOUNT);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setKillSwitch(false);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).allocate(strategyAddr, ALLOCATION_AMOUNT);

        uint256 strategyAssetsAfterAllocate = strategy.realAssets();
        assertGt(strategyAssetsAfterAllocate, 0, "strategy did not receive assets");
        assertGt(vault.allocation(strategy.adapterId()), 0, "vault allocation not updated");

        MockSwapperForSFraxETHDeployTest swapper = new MockSwapperForSFraxETHDeployTest();
        deal(MAINNET_WETH, address(swapper), DEALLOCATION_TARGET);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setAllowanceHolder(address(swapper));

        bytes memory txData =
            abi.encodeCall(MockSwapperForSFraxETHDeployTest.swap, (MAINNET_FRXETH, MAINNET_WETH, DEALLOCATION_TARGET, DEALLOCATION_TARGET));

        uint256 vaultWethBeforeDeallocate = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 deallocationAmount = strategy.previewAdjustedWithdraw(DEALLOCATION_TARGET);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).deallocateWithUnwrapAndSwap(
            strategyAddr, deallocationAmount, txData, DEALLOCATION_TARGET
        );

        assertLt(strategy.realAssets(), strategyAssetsAfterAllocate, "strategy assets should decrease");
        assertEq(IERC20(MAINNET_FRXETH).balanceOf(strategyAddr), 0, "strategy should not retain frxETH after swap");
        assertGt(IERC20(MAINNET_WETH).balanceOf(ETH_MYT), vaultWethBeforeDeallocate, "vault did not receive WETH back");
    }

    function _buildParams(string memory name, string memory protocol)
        internal
        view
        returns (IMYTStrategy.StrategyParams memory)
    {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1_000e18,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
