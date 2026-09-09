// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMYTStrategy} from "../../../interfaces/IMYTStrategy.sol";
import {ERC4626Candidate} from "./ERC4626StrategyTestBase.sol";

library ERC4626Candidates {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    string internal constant BASE_RPC_FALLBACK = "https://base.gateway.tenderly.co";

    function steakhouseUSDC() internal pure returns (ERC4626Candidate memory) {
        return ERC4626Candidate({
            targetVault: 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100,
            asset: BASE_USDC,
            rpcEnv: "BASE_RPC_URL",
            fallbackRpcUrl: BASE_RPC_FALLBACK,
            name: "Steakhouse High Yield USDC",
            protocol: "Steakhouse",
            riskClass: IMYTStrategy.RiskClass.LOW,
            forkBlock: 50_765_525,
            assetDecimals: 6,
            shareDecimals: 18,
            initialDeposit: 1000e6,
            absoluteCap: 10_000e6,
            relativeCap: 1e18,
            strategyCap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            slippageBPS: 1,
            additionalIncentives: false,
            maxWithdrawIsAuthoritative: true,
            zeroMaxWithdrawIsUnbounded: false
        });
    }

    function yearnOGUSDCV2() internal pure returns (ERC4626Candidate memory) {
        return ERC4626Candidate({
            targetVault: 0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42,
            asset: BASE_USDC,
            rpcEnv: "BASE_RPC_URL",
            fallbackRpcUrl: BASE_RPC_FALLBACK,
            name: "Yearn OG USDC V2",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            forkBlock: 50_768_896,
            assetDecimals: 6,
            shareDecimals: 18,
            initialDeposit: 10_000e6,
            absoluteCap: 10_000e6,
            relativeCap: 0.25e18,
            strategyCap: 10_000e6,
            globalCap: 0.25e18,
            estimatedYield: 531,
            slippageBPS: 50,
            additionalIncentives: false,
            maxWithdrawIsAuthoritative: true,
            zeroMaxWithdrawIsUnbounded: true
        });
    }

    function yearnUSDCHorizon() internal pure returns (ERC4626Candidate memory) {
        return ERC4626Candidate({
            targetVault: 0xc3BD0A2193c8F027B82ddE3611D18589ef3f62a9,
            asset: BASE_USDC,
            rpcEnv: "BASE_RPC_URL",
            fallbackRpcUrl: BASE_RPC_FALLBACK,
            name: "USDC Horizon yVault",
            protocol: "Yearn V3",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            forkBlock: 50_742_730,
            assetDecimals: 6,
            shareDecimals: 6,
            initialDeposit: 10_000e6,
            absoluteCap: 10_000e6,
            relativeCap: 0.1e18,
            strategyCap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 454,
            slippageBPS: 100,
            additionalIncentives: false,
            maxWithdrawIsAuthoritative: true,
            zeroMaxWithdrawIsUnbounded: false
        });
    }

    function gauntletUSDCFrontier() internal pure returns (ERC4626Candidate memory) {
        return ERC4626Candidate({
            targetVault: 0x1deEfABEe758AAbdC29a542B24ca3b75aFD56765,
            asset: BASE_USDC,
            rpcEnv: "BASE_RPC_URL",
            fallbackRpcUrl: BASE_RPC_FALLBACK,
            name: "Gauntlet USDC Frontier",
            protocol: "Morpho V2",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            forkBlock: 50_828_803,
            assetDecimals: 6,
            shareDecimals: 18,
            initialDeposit: 10_000e6,
            absoluteCap: 10_000e6,
            relativeCap: 0.1e18,
            strategyCap: 10_000e6,
            globalCap: 0.1e18,
            estimatedYield: 483,
            slippageBPS: 100,
            additionalIncentives: false,
            maxWithdrawIsAuthoritative: true,
            zeroMaxWithdrawIsUnbounded: true
        });
    }
}
