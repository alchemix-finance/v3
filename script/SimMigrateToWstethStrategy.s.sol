// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultV2} from "../lib/vault-v2/src/VaultV2.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {WstETHEthereumStrategy} from "../src/strategies/WstETHEthereumStrategy.sol";
import {MYTTokenSwapper} from "../src/MYTTokenSwapper.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";

/// @notice Swap venue at 0x4f8f...C901 (aEthWETH -> aEthwstETH, premium-aware quote).
interface IAaveWethSwap {
    function getWstETHAmountOut(uint256 amountIn) external view returns (uint256);

    function swapToWstETH(uint256 amountIn, uint256 amountOutMin) external returns (uint256);
}

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

interface IChainlinkOracle {
    function latestAnswer() external view returns (int256);
}

/// @notice Fork simulation: migrate the AaveStrategy's aEthWETH into the new WstethMainnetStrategy
/// without dropping the vault share price, and without any treasury top-up.
///
/// Flow (all in one msig-pranked sequence):
///   0. deploy WstethMainnetStrategy and wire it into the vault as an adapter
///      (vault's addAdapter timelock is 0 and adapterRegistry is unset — verified on-chain)
///   1. update caps on new strategy
///   2a. old strategy: setAllowanceHolder -> migration helper
///   2b. old strategy: adminDexSwap executes the helper's atomic
///       aEthWETH -> aEthwstETH -> wstETH -> newStrategy flow
///   3. vault.accrueInterest() — old strategy realAssets drops by ~aWethBal,
///      new strategy realAssets rises by ~aWethBal (via oracle) → net zero, share price held.
///   4. resrote allowanceHolder on old strategy.
///   5. force allocation sync

contract SimMigrateToWstethStrategy is Script, StdCheats {
    address constant ETH_VAULT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;
    address constant AAVE_STRATEGY = 0xb2d750bfA0B8c8C72945F5533442B467230CB4D7;
    address constant ETH_MSIG = 0xF56D660138815fC5d7a06cd0E1630225E788293D;
    address constant ALCHEMIST_CURATOR = 0x7d61E3cDe8B58C4be192a7A35E9d626c419302A4;
    address constant ALCHEMIST_ALLOCATOR = 0x23a3C27Bb007887FD8CbfEaF323799093a450e7e;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant AWSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH_ETH_ORACLE = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant AAVE_POOL_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant SWAP_TARGET = 0x4f8f03caD7512E4F6d1050FB9b2F8b91aE4bC901;

    uint256 constant SLIPPAGE_NUM = 99_999;
    uint256 constant SLIPPAGE_DEN = 100_000;
    uint256 constant SWAP_DEADLINE_WINDOW = 1 hours;

    /// @dev Update this value.
    /// @dev Operator reviewed Fluid quote for the full aWETH balance, e.g. 5246827227535022074113 (5246.827227535022074113).
    uint256 constant MANUALLY_APPROVED_EXPECTED_OUT = 5_246_827_227_535_022_074_113;
    uint256 constant MAX_APPROVED_QUOTE_DEVIATION_BPS = 10; // 0.1%

    /// @dev Market-price wstETH in WETH terms: wstETH -> stETH (via stEthPerToken) -> ETH (via Chainlink).
    function _wstEthToWeth(uint256 wstEthAmount) internal view returns (uint256) {
        uint256 stEthPerWst = IWstETH(WSTETH).stEthPerToken(); // 1e18
        int256 stEthEth = IChainlinkOracle(STETH_ETH_ORACLE).latestAnswer(); // 1e18
        require(stEthEth > 0, "bad oracle");
        return (wstEthAmount * stEthPerWst * uint256(stEthEth)) / 1e36;
    }

    function _logDelta(string memory label, uint256 a, uint256 b) internal pure {
        if (a >= b) {
            console.log(string.concat(label, " (loss):"), a - b);
        } else {
            console.log(string.concat(label, " (gain):"), b - a);
        }
    }

    function _validateApprovedQuote(uint256 expectedOut) internal pure {
        require(MANUALLY_APPROVED_EXPECTED_OUT != 0, "manual quote unset");
        uint256 minApprovedQuote = (MANUALLY_APPROVED_EXPECTED_OUT * (10_000 - MAX_APPROVED_QUOTE_DEVIATION_BPS)) / 10_000;
        require(expectedOut >= minApprovedQuote, "Fluid quote below manually approved value");
    }

    function run() external {
        VaultV2 vault = VaultV2(ETH_VAULT);
        AaveStrategy oldStrategy = AaveStrategy(AAVE_STRATEGY);
        IAaveWethSwap swap = IAaveWethSwap(SWAP_TARGET);
        AlchemistCurator curator = AlchemistCurator(ALCHEMIST_CURATOR);
        AlchemistAllocator allocator = AlchemistAllocator(ALCHEMIST_ALLOCATOR);

        address previousAllowanceHolder = oldStrategy.allowanceHolder();
        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 totalBefore = vault.totalAssets();
        uint256 aWethBal = IERC20(AWETH).balanceOf(AAVE_STRATEGY);

        console.log("--- START ---");
        console.log("vault totalAssets:", totalBefore);
        console.log("share price (WETH/share):", priceBefore);
        console.log("old strategy aWETH:", aWethBal);
        require(aWethBal > 0, "no aWETH");

        // 0. Deploy & wire the new wsteth strategy
        // Note: these strategy cap params are meaningless, need to pass to curator.
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: ETH_MSIG,
            name: "WstETH Mainnet (migration target)",
            protocol: "WstETH",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 20_000e18,
            globalCap: 1e18,
            estimatedYield: 350,
            additionalIncentives: false,
            slippageBPS: 50
        });
        WstETHEthereumStrategy newStrategy = new WstETHEthereumStrategy(ETH_VAULT, params, WSTETH, STETH_ETH_ORACLE);
        console.log("new WstETHEthereumStrategy:", address(newStrategy));

        vm.startPrank(ETH_MSIG);
        curator.submitSetStrategy(address(newStrategy), ETH_VAULT);
        curator.setStrategy(address(newStrategy), ETH_VAULT);
        vm.stopPrank();
        console.log("new strategy added as vault adapter");

        // 1. update caps
        vm.startPrank(ETH_MSIG);
        curator.submitIncreaseAbsoluteCap(address(newStrategy), params.cap);
        curator.increaseAbsoluteCap(address(newStrategy), params.cap);
        curator.submitIncreaseRelativeCap(address(newStrategy), params.globalCap);
        curator.increaseRelativeCap(address(newStrategy), params.globalCap);
        vm.stopPrank();
        console.log("caps updated on new strategy");

        // 2a-b. allowance holder and atomic helper-driven migration into the new strategy
        MYTTokenSwapper helper = new MYTTokenSwapper(ETH_MSIG, AWETH, AWSTETH, WSTETH, SWAP_TARGET, AAVE_POOL_PROVIDER);

        vm.startPrank(ETH_MSIG);
        helper.setWhitelistedSource(address(oldStrategy), true);
        helper.setWhitelistedDestination(address(newStrategy), true);
        oldStrategy.setAllowanceHolder(address(helper));
        vm.stopPrank();

        uint256 expectedOut = swap.getWstETHAmountOut(aWethBal);
        _validateApprovedQuote(expectedOut);
        uint256 minOut = (expectedOut * SLIPPAGE_NUM) / SLIPPAGE_DEN;
        uint256 deadline = block.timestamp + SWAP_DEADLINE_WINDOW;
        console.log("manually approved aWstETH out:", MANUALLY_APPROVED_EXPECTED_OUT);
        console.log("expected aWstETH out:", expectedOut);
        bytes memory callData = abi.encodeCall(MYTTokenSwapper.swapAaveWethToWstethViaFluid, (aWethBal, minOut, address(newStrategy), deadline));

        // IMPORTANT: the helper call below is the atomic migration leg.
        vm.startPrank(ETH_MSIG);
        oldStrategy.adminDexSwap(WETH, AWETH, aWethBal, 0, callData);
        vm.stopPrank();

        // 3. accrue interest to update vault's accounting and realize the migration
        vault.accrueInterest();

        uint256 priceAfter = vault.convertToAssets(1e18);
        uint256 totalAfter = vault.totalAssets();

        console.log("--- AFTER ---");
        console.log("vault totalAssets:", totalAfter);
        console.log("share price (WETH/share):", priceAfter);

        if (totalAfter >= totalBefore) {
            console.log("vault totalAssets delta (+):", totalAfter - totalBefore);
        } else {
            console.log("vault totalAssets delta (-):", totalBefore - totalAfter);
        }
        if (priceAfter >= priceBefore) {
            console.log("share price delta (+):", priceAfter - priceBefore);
        } else {
            console.log("share price delta (-):", priceBefore - priceAfter);
        }

        // 4. restore allowance holder on old strategy
        vm.startPrank(ETH_MSIG);
        oldStrategy.setAllowanceHolder(previousAllowanceHolder);
        vm.stopPrank();

        // 5. force allocation sync

        console.log("--- FORCE ALLOCATION SYNC ---");

        vm.startPrank(ETH_MSIG);
        oldStrategy.setKillSwitch(false);
        allocator.allocate(address(oldStrategy), 1e9);
        allocator.allocate(address(newStrategy), 1e9);
        oldStrategy.setKillSwitch(true);
        vm.stopPrank();

        uint256 newAllocationOfNewStrategy = vault.allocation(newStrategy.adapterId());
        require(newAllocationOfNewStrategy > 1e9, "new strategy allocation not updated");
        console.log("new strategy allocated in vault", newAllocationOfNewStrategy);
        uint256 newAllocationOfOldStrategy = vault.allocation(oldStrategy.adapterId());
        require(newAllocationOfOldStrategy <= 1e9, "old strategy allocation not fully deallocated");
        console.log("old strategy fully deallocated from vault", newAllocationOfOldStrategy);
    }
}
