// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {ERC4626Strategy} from "../../strategies/ERC4626Strategy.sol";

interface IERC4626MaxWithdraw {
    function maxWithdraw(address owner) external view returns (uint256);
}

contract MockYvWETHStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _vault) ERC4626Strategy(_myt, _params, _vault) {}
}

contract YvWETHStrategyTest is BaseStrategyTest {
    address public constant YV_WETH_VAULT = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "YvWETH",
            protocol: "YearnWETH",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockYvWETHStrategy(vault, params, YV_WETH_VAULT));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24_850_461;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxWithdrawable = IERC4626MaxWithdraw(YV_WETH_VAULT).maxWithdraw(strategy);
        return requestedAssets < maxWithdrawable ? requestedAssets : maxWithdrawable;
    }
}
