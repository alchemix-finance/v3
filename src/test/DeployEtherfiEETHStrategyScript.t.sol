// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployEtherfiEETHStrategyScript} from "../../script/DeployEtherfiEETHStrategy.s.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {EtherfiEETHMYTStrategy} from "../strategies/EtherfiEETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

contract MockOracleForEtherfiEETHDeployTest {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockMYTForEtherfiEETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {}

    fallback() external payable {}
}

contract MockSwapperForEtherfiEETHDeployTest {
    function swap(address from, address to, uint256 amountOut) external {
        uint256 amountIn = IERC20(from).allowance(msg.sender, address(this));
        require(IERC20(from).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(to).transfer(msg.sender, amountOut), "push failed");
    }
}

contract DeployEtherfiEETHStrategyScriptTest is Test {
    address internal constant DEPLOYER = 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2;
    address internal constant MAINNET_NEW_OWNER = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address internal constant MAINNET_WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant MAINNET_DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address internal constant MAINNET_REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address internal constant MAINNET_WEETH_ETH_ORACLE = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address internal constant CURATOR_ADDR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address internal constant ETH_MYT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address internal constant ETH_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;
    uint256 internal constant MAINNET_FORK_BLOCK = 24_980_826;
    uint256 internal constant ALLOCATION_AMOUNT = 10e18;
    uint256 internal constant DEALLOCATION_TARGET = 4e18;
    uint256 internal constant FORCE_DEALLOCATE_PENALTY = 2e16;

    DeployEtherfiEETHStrategyScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal weth;
    MockMYTForEtherfiEETHDeployTest internal myt;
    MockOracleForEtherfiEETHDeployTest internal oracle;

    address internal newOwner;
    address internal eETH;
    address internal weETH;
    address internal depositAdapter;
    address internal redemptionManager;

    function setUp() public {
        deployScript = new DeployEtherfiEETHStrategyScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        weth = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForEtherfiEETHDeployTest(address(weth));
        oracle = new MockOracleForEtherfiEETHDeployTest();

        newOwner = makeAddr("newOwner");
        eETH = makeAddr("eETH");
        weETH = makeAddr("weETH");
        depositAdapter = makeAddr("depositAdapter");
        redemptionManager = makeAddr("redemptionManager");
    }

    function test_deployEtherfiEETHStrategy_setsCoreAddressesAndParams() public {
        DeployEtherfiEETHStrategyScript.EtherfiEETHDeployConfig memory config =
            DeployEtherfiEETHStrategyScript.EtherfiEETHDeployConfig({
                myt: address(myt),
                eETH: eETH,
                weETH: weETH,
                depositAdapter: depositAdapter,
                redemptionManager: redemptionManager,
                weEthEthOracle: address(oracle),
                maxOracleStaleness: deployScript.MAX_ORACLE_STALENESS(),
                params: _buildParams("Ether.fi Mainnet weETH", "Ether.fi")
            });

        address strategyAddr = deployScript.deployEtherfiEETHStrategy(curator, newOwner, config);
        EtherfiEETHMYTStrategy strategy = EtherfiEETHMYTStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.eETH()), eETH, "unexpected eETH");
        assertEq(address(strategy.weETH()), weETH, "unexpected weETH");
        assertEq(address(strategy.depositAdapter()), depositAdapter, "unexpected deposit adapter");
        assertEq(address(strategy.redemptionManager()), redemptionManager, "unexpected redemption manager");
        assertEq(address(strategy.pricedTokenOracle()), address(oracle), "unexpected oracle");
        assertEq(strategy.MAX_ORACLE_STALENESS(), deployScript.MAX_ORACLE_STALENESS(), "unexpected max oracle staleness");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "unexpected owner");
        assertEq(curator.adapterToMYT(strategyAddr), address(0), "deploy script should not register with curator");
        (, string memory strategyName, string memory protocol,,,,,,) = strategy.params();
        assertEq(strategyName, "Ether.fi Mainnet weETH", "unexpected strategy name");
        assertEq(protocol, "Ether.fi", "unexpected protocol");
    }

    function test_deployEtherfiEETHStrategy_blocksForceDeallocateWhenDisabled() public {
        DeployEtherfiEETHStrategyScript.EtherfiEETHDeployConfig memory config =
            DeployEtherfiEETHStrategyScript.EtherfiEETHDeployConfig({
                myt: address(myt),
                eETH: eETH,
                weETH: weETH,
                depositAdapter: depositAdapter,
                redemptionManager: redemptionManager,
                weEthEthOracle: address(oracle),
                maxOracleStaleness: deployScript.MAX_ORACLE_STALENESS(),
                params: _buildParams("Ether.fi Mainnet weETH", "Ether.fi")
            });

        address strategyAddr = deployScript.deployEtherfiEETHStrategy(curator, newOwner, config);
        EtherfiEETHMYTStrategy strategy = EtherfiEETHMYTStrategy(payable(strategyAddr));

        assertTrue(strategy.canForceDeallocate(), "force deallocate should default to enabled");

        vm.prank(newOwner);
        strategy.setCanForceDeallocate(false);
        assertFalse(strategy.canForceDeallocate(), "force deallocate should be disabled");

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(address(myt));
        strategy.deallocate(abi.encode(params), 1, IVaultV2.forceDeallocate.selector, address(myt));
    }

    function test_run_fork_allocatorCanAllocateAndDeallocateEtherfiEETH() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        vm.deal(DEPLOYER, 10 ether);

        // Mirror admin authority so the test can perform post-deploy registration, caps, and proxy setup.
        vm.store(CURATOR_ADDR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));
        vm.store(ETH_ALLOCATOR, bytes32(0), bytes32(uint256(uint160(DEPLOYER))));

        DeployEtherfiEETHStrategyScript forkDeployScript = new DeployEtherfiEETHStrategyScript();
        address strategyAddr = forkDeployScript.run();
        EtherfiEETHMYTStrategy strategy = EtherfiEETHMYTStrategy(payable(strategyAddr));
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
        liveCurator.submitSetForceDeallocatePenalty(strategyAddr, ETH_MYT, FORCE_DEALLOCATE_PENALTY);
        AlchemistAllocator(ETH_ALLOCATOR).setOperator(DEPLOYER, true);
        AlchemistAllocator(ETH_ALLOCATOR).setPermissionedCall(IVaultV2.setForceDeallocatePenalty.selector, true);
        AlchemistAllocator(ETH_ALLOCATOR).proxy(
            ETH_MYT, abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (strategyAddr, FORCE_DEALLOCATE_PENALTY))
        );
        vm.stopPrank();

        assertEq(address(strategy.MYT()), ETH_MYT, "unexpected MYT");
        assertEq(vault.asset(), MAINNET_WETH, "unexpected MYT asset");
        assertEq(address(strategy.eETH()), MAINNET_EETH, "unexpected eETH");
        assertEq(address(strategy.weETH()), MAINNET_WEETH, "unexpected weETH");
        assertEq(address(strategy.depositAdapter()), MAINNET_DEPOSIT_ADAPTER, "unexpected deposit adapter");
        assertEq(address(strategy.redemptionManager()), MAINNET_REDEMPTION_MANAGER, "unexpected redemption manager");
        assertEq(address(strategy.pricedTokenOracle()), MAINNET_WEETH_ETH_ORACLE, "unexpected oracle");
        assertEq(strategy.owner(), MAINNET_NEW_OWNER, "unexpected strategy owner");
        assertTrue(strategy.killSwitch(), "kill switch should be enabled after deploy");
        assertTrue(vault.isAdapter(strategyAddr), "strategy not registered");
        assertEq(vault.absoluteCap(strategy.adapterId()), params.cap, "absolute cap not set");
        assertEq(vault.relativeCap(strategy.adapterId()), params.globalCap, "relative cap not set");
        assertEq(vault.forceDeallocatePenalty(strategyAddr), FORCE_DEALLOCATE_PENALTY, "force deallocate penalty not set");

        uint256 vaultWethBalanceBefore = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        deal(MAINNET_WETH, ETH_MYT, vaultWethBalanceBefore + ALLOCATION_AMOUNT);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setKillSwitch(false);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).allocate(strategyAddr, ALLOCATION_AMOUNT);

        uint256 strategyAssetsAfterAllocate = strategy.realAssets();
        assertGt(strategyAssetsAfterAllocate, 0, "strategy did not receive assets");
        assertGt(vault.allocation(strategy.adapterId()), 0, "vault allocation not updated");

        MockSwapperForEtherfiEETHDeployTest swapper = new MockSwapperForEtherfiEETHDeployTest();
        deal(MAINNET_WETH, address(swapper), DEALLOCATION_TARGET);

        vm.prank(MAINNET_NEW_OWNER);
        strategy.setAllowanceHolder(address(swapper));

        bytes memory txData =
            abi.encodeCall(MockSwapperForEtherfiEETHDeployTest.swap, (MAINNET_WEETH, MAINNET_WETH, DEALLOCATION_TARGET));

        uint256 vaultWethBeforeDeallocate = IERC20(MAINNET_WETH).balanceOf(ETH_MYT);
        uint256 deallocationAmount = strategy.previewAdjustedWithdraw(DEALLOCATION_TARGET);

        vm.prank(DEPLOYER);
        IAllocator(ETH_ALLOCATOR).deallocateWithSwap(strategyAddr, deallocationAmount, txData);

        assertLt(strategy.realAssets(), strategyAssetsAfterAllocate, "strategy assets should decrease");
        assertGt(IERC20(MAINNET_WETH).balanceOf(ETH_MYT), vaultWethBeforeDeallocate, "vault did not receive WETH back");
    }

    function test_defaultParams_usesMainnetEtherfiDefaults() public view {
        IMYTStrategy.StrategyParams memory params = deployScript.defaultParams();

        assertEq(deployScript.curatorAddr(), 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4, "unexpected curator");
        assertEq(deployScript.ethMYT(), 0x29bcfeD246ce37319d94eBa107db90C453D4c43D, "unexpected ETH MYT");
        assertEq(params.owner, 0xf456A36B04B0951Cd19d6D8aA0c0b3b0a07f9fF2, "unexpected owner");
        assertEq(params.name, "Ether.fi Mainnet weETH", "unexpected name");
        assertEq(params.protocol, "Ether.fi", "unexpected protocol");
        assertEq(uint256(params.riskClass), uint256(IMYTStrategy.RiskClass.MEDIUM), "unexpected risk class");
        assertEq(params.cap, 10_000e18, "unexpected cap");
        assertEq(params.globalCap, 1e18, "unexpected global cap");
        assertEq(params.estimatedYield, 500, "unexpected estimated yield");
        assertFalse(params.additionalIncentives, "unexpected incentives flag");
        assertEq(params.slippageBPS, 10, "unexpected slippage");
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
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1_000e18,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 10
        });
    }
}
