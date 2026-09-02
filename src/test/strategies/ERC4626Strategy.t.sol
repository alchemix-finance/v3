// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {ERC4626Candidate, ERC4626StrategyInvariantTestBase, ERC4626StrategyUnitTestBase} from "./base/ERC4626StrategyTestBase.sol";

/**
 * @notice Opt-in test suite for any synchronous, direct ERC4626 vault.
 * @dev Required:
 *      ERC4626_VAULT   - target ERC4626 vault
 *      ERC4626_RPC_URL - RPC URL for the target's network
 *
 *      Optional:
 *      ERC4626_FORK_BLOCK                    - zero or unset forks latest
 *      ERC4626_ZERO_MAX_WITHDRAW_IS_UNBOUNDED - set true for Morpho-style zero sentinels
 */
abstract contract ERC4626RemoteEnv is Test {
    ERC4626Candidate private remoteCandidate;

    function _loadRemoteCandidate() internal returns (bool loaded) {
        address targetVault = vm.envOr("ERC4626_VAULT", address(0));
        if (targetVault == address(0)) {
            vm.skip(true, "set ERC4626_VAULT and ERC4626_RPC_URL to run the remote suite");
            return false;
        }

        string memory rpcUrl = vm.envOr("ERC4626_RPC_URL", string(""));
        require(bytes(rpcUrl).length != 0, "ERC4626_RPC_URL must be set when ERC4626_VAULT is provided");
        uint256 forkBlock = vm.envOr("ERC4626_FORK_BLOCK", uint256(0));

        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        require(targetVault.code.length != 0, "ERC4626_VAULT has no code on the selected fork");

        address asset = IERC4626(targetVault).asset();
        require(asset != address(0) && asset.code.length != 0, "ERC4626_VAULT returned an invalid asset");

        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        require(assetDecimals >= 3, "ERC4626 asset decimals must be at least 3");
        uint256 unit = 10 ** assetDecimals;

        remoteCandidate = ERC4626Candidate({
            targetVault: targetVault,
            asset: asset,
            rpcEnv: "",
            fallbackRpcUrl: rpcUrl,
            name: IERC20Metadata(targetVault).name(),
            protocol: "ERC4626",
            riskClass: IMYTStrategy.RiskClass.LOW,
            forkBlock: forkBlock,
            assetDecimals: assetDecimals,
            shareDecimals: IERC20Metadata(targetVault).decimals(),
            initialDeposit: 1000 * unit,
            absoluteCap: 10_000 * unit,
            relativeCap: 1e18,
            strategyCap: 10_000 * unit,
            globalCap: 1e18,
            estimatedYield: 100 * unit,
            slippageBPS: 1,
            additionalIncentives: false,
            maxWithdrawIsAuthoritative: true,
            zeroMaxWithdrawIsUnbounded: vm.envOr("ERC4626_ZERO_MAX_WITHDRAW_IS_UNBOUNDED", false)
        });
        return true;
    }

    function _remoteCandidate() internal view returns (ERC4626Candidate memory) {
        return remoteCandidate;
    }
}

contract ERC4626RemoteStrategyTest is ERC4626RemoteEnv, ERC4626StrategyUnitTestBase {
    function setUp() public override {
        if (!_loadRemoteCandidate()) return;
        super.setUp();
    }

    function _candidate() internal view override returns (ERC4626Candidate memory) {
        return _remoteCandidate();
    }
}

contract ERC4626RemoteInvariantTest is ERC4626RemoteEnv, ERC4626StrategyInvariantTestBase {
    function setUp() public override {
        if (!_loadRemoteCandidate()) return;
        super.setUp();
    }

    function _candidate() internal view override returns (ERC4626Candidate memory) {
        return _remoteCandidate();
    }
}
