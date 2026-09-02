// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

import {ERC4626Strategy} from "../../../strategies/ERC4626Strategy.sol";
import {IMYTStrategy} from "../../../interfaces/IMYTStrategy.sol";
import {BaseStrategyTest} from "../../BaseStrategyTest.sol";
import {E2EInvariantStrategyTest} from "../../base/E2EInvariantStrategyTest.sol";

/// @notice Everything the shared ERC4626 suites need to exercise one candidate vault.
struct ERC4626Candidate {
    address targetVault;
    address asset;
    string rpcEnv;
    string fallbackRpcUrl;
    string name;
    string protocol;
    IMYTStrategy.RiskClass riskClass;
    uint256 forkBlock;
    uint256 assetDecimals;
    uint256 shareDecimals;
    uint256 initialDeposit;
    uint256 absoluteCap;
    uint256 relativeCap;
    uint256 strategyCap;
    uint256 globalCap;
    uint256 estimatedYield;
    uint256 slippageBPS;
    bool additionalIncentives;
    bool maxWithdrawIsAuthoritative;
    bool zeroMaxWithdrawIsUnbounded;
}

/// @notice Shared unit/fuzz suite for synchronous, direct ERC4626 integrations.
abstract contract ERC4626StrategyUnitTestBase is BaseStrategyTest {
    function _candidate() internal view virtual returns (ERC4626Candidate memory);

    function getRpcUrl() internal view virtual override returns (string memory) {
        ERC4626Candidate memory candidate = _candidate();
        if (bytes(candidate.rpcEnv).length == 0) return candidate.fallbackRpcUrl;
        return vm.envOr(candidate.rpcEnv, candidate.fallbackRpcUrl);
    }

    function getForkBlockNumber() internal view virtual override returns (uint256) {
        return _candidate().forkBlock;
    }

    function getStrategyConfig() internal view virtual override returns (IMYTStrategy.StrategyParams memory) {
        return _strategyParams(_candidate(), admin);
    }

    function getTestConfig() internal view virtual override returns (TestConfig memory) {
        ERC4626Candidate memory candidate = _candidate();
        return TestConfig({
            vaultAsset: candidate.asset,
            vaultInitialDeposit: candidate.initialDeposit,
            absoluteCap: candidate.absoluteCap,
            relativeCap: candidate.relativeCap,
            decimals: candidate.assetDecimals
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal virtual override returns (address) {
        return address(new ERC4626Strategy(vault_, params, _candidate().targetVault));
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view virtual override returns (uint256) {
        ERC4626Candidate memory candidate = _candidate();
        if (!candidate.maxWithdrawIsAuthoritative) return requestedAssets;

        uint256 maxWithdrawable = IERC4626(candidate.targetVault).maxWithdraw(strategy);
        if (maxWithdrawable == 0 && candidate.zeroMaxWithdrawIsUnbounded) return requestedAssets;
        return requestedAssets < maxWithdrawable ? requestedAssets : maxWithdrawable;
    }

    function test_erc4626VaultWiring() public view {
        ERC4626Candidate memory candidate = _candidate();
        ERC4626Strategy erc4626Strategy = ERC4626Strategy(strategy);

        assertEq(address(erc4626Strategy.mytAsset()), candidate.asset, "unexpected MYT asset");
        assertEq(address(erc4626Strategy.vault()), candidate.targetVault, "unexpected target vault");
        assertEq(IERC4626(candidate.targetVault).asset(), candidate.asset, "target vault asset mismatch");
        assertEq(IERC4626(candidate.targetVault).decimals(), candidate.shareDecimals, "unexpected share decimals");
    }

    function test_forceDeallocate_directDisabledByDefaultAndOwnerCanEnable() public {
        ERC4626Strategy erc4626Strategy = ERC4626Strategy(strategy);
        assertFalse(erc4626Strategy.canForceDeallocate(), "force deallocate should default disabled");

        vm.prank(vault);
        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);

        vm.prank(admin);
        erc4626Strategy.setCanForceDeallocate(true);
        assertTrue(erc4626Strategy.canForceDeallocate(), "force deallocate should be enabled");

        deal(_candidate().asset, strategy, 1);
        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1, IVaultV2.forceDeallocate.selector, vault);
    }

    function _strategyParams(ERC4626Candidate memory candidate, address owner_) internal pure returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: owner_,
            name: candidate.name,
            protocol: candidate.protocol,
            riskClass: candidate.riskClass,
            cap: candidate.strategyCap,
            globalCap: candidate.globalCap,
            estimatedYield: candidate.estimatedYield,
            additionalIncentives: candidate.additionalIncentives,
            slippageBPS: candidate.slippageBPS
        });
    }
}

/// @notice Shared full-system invariant suite for synchronous, direct ERC4626 integrations.
abstract contract ERC4626StrategyInvariantTestBase is E2EInvariantStrategyTest {
    function _candidate() internal view virtual returns (ERC4626Candidate memory);

    function getRpcUrl() internal view virtual override returns (string memory) {
        ERC4626Candidate memory candidate = _candidate();
        if (bytes(candidate.rpcEnv).length == 0) return candidate.fallbackRpcUrl;
        return vm.envOr(candidate.rpcEnv, candidate.fallbackRpcUrl);
    }

    function getForkBlockNumber() internal view virtual override returns (uint256) {
        return _candidate().forkBlock;
    }

    function getAsset() internal view virtual override returns (address) {
        return _candidate().asset;
    }

    function getRealStrategyParams() internal view virtual override returns (IMYTStrategy.StrategyParams memory) {
        return _strategyParams(_candidate(), address(0));
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal virtual override returns (address) {
        return address(new ERC4626Strategy(vault_, params, _candidate().targetVault));
    }

    function _enableForceDeallocate(address strategy_) internal virtual override {
        ERC4626Strategy(strategy_).setCanForceDeallocate(true);
    }

    function onSimulateValueLoss(address strategy_, uint256 amount) external virtual override {
        address targetVault = _candidate().targetVault;
        uint256 shares = IERC4626(targetVault).convertToShares(amount);
        uint256 balance = IERC20(targetVault).balanceOf(strategy_);
        shares = shares > balance ? balance : shares;
        if (shares == 0) return;

        vm.prank(strategy_);
        IERC20(targetVault).transfer(address(0xdead), shares);
    }

    function _strategyParams(ERC4626Candidate memory candidate, address owner_) internal pure returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: owner_,
            name: candidate.name,
            protocol: candidate.protocol,
            riskClass: candidate.riskClass,
            cap: candidate.strategyCap,
            globalCap: candidate.globalCap,
            estimatedYield: candidate.estimatedYield,
            additionalIncentives: candidate.additionalIncentives,
            slippageBPS: candidate.slippageBPS
        });
    }
}
