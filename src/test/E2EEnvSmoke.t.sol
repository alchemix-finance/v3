// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";

import {E2EInvariantEnv} from "./base/E2EInvariantEnv.sol";
import {E2EStrategyHandler} from "./base/E2EStrategyHandler.sol";

contract E2EEnvSmokeTest is E2EInvariantEnv {
    E2EStrategyHandler internal smokeHandler;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getForkBlockNumber() internal override returns (uint256) {
        return 22_089_302;
    }

    function getAsset() internal override returns (address) {
        return WETH;
    }

    function setUp() public override {
        super.setUp();

        smokeHandler = new E2EStrategyHandler(
            E2EStrategyHandler.InitParams({
                vault: address(vault),
                strategies: strategies,
                allocator: allocator,
                classifier: classifier,
                admin: admin,
                operator: operator,
                alchemist: address(alchemist),
                alchemistNFT: address(alchemistNFT),
                alToken: address(alToken),
                transmuter: address(transmuterLogic),
                actors: vaultActors,
                alchSenders: alchemistSenders,
                mockStrategyA: mockStrategyA,
                mockStrategyB: mockStrategyB,
                mockYieldTokenA: mockYieldTokenA,
                mockYieldTokenB: mockYieldTokenB
            })
        );

        targetContract(address(smokeHandler));

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = smokeHandler.deposit.selector;
        selectors[1] = smokeHandler.withdraw.selector;
        selectors[2] = smokeHandler.allocate.selector;
        selectors[3] = smokeHandler.deallocate.selector;
        selectors[4] = smokeHandler.deallocateAll.selector;
        selectors[5] = smokeHandler.forceDeallocate.selector;
        selectors[6] = smokeHandler.simulateYield.selector;
        selectors[7] = smokeHandler.simulateValueLoss.selector;
        selectors[8] = smokeHandler.modifyRiskClassCaps.selector;
        selectors[9] = smokeHandler.reclassifyStrategy.selector;
        selectors[10] = smokeHandler.warpTime.selector;
        selectors[11] = smokeHandler.alchemistDepositCollateral.selector;
        selectors[12] = smokeHandler.alchemistBorrow.selector;

        targetSelector(FuzzSelector({addr: address(smokeHandler), selectors: selectors}));

        for (uint256 i = 0; i < vaultActors.length; i++) {
            targetSender(vaultActors[i]);
        }
    }

    function invariant_smoke_realAssets_nonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            assertGe(IMYTStrategy(strategies[i]).realAssets(), 0, "negative real assets");
        }
    }

    function invariant_smoke_sharePricePositive() public view {
        uint256 ts = vault.totalSupply();
        if (ts == 0) return;
        assertGt((vault.totalAssets() * 1e18) / ts, 0, "share price zero");
    }

    function invariant_smoke_callAccounting() public view {
        bytes4[13] memory sels = [
            smokeHandler.deposit.selector,
            smokeHandler.withdraw.selector,
            smokeHandler.allocate.selector,
            smokeHandler.deallocate.selector,
            smokeHandler.deallocateAll.selector,
            smokeHandler.forceDeallocate.selector,
            smokeHandler.simulateYield.selector,
            smokeHandler.simulateValueLoss.selector,
            smokeHandler.modifyRiskClassCaps.selector,
            smokeHandler.reclassifyStrategy.selector,
            smokeHandler.warpTime.selector,
            smokeHandler.alchemistDepositCollateral.selector,
            smokeHandler.alchemistBorrow.selector
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            (uint256 c, uint256 sk, uint256 ex) = smokeHandler.getStats(sels[i]);
            assertEq(c, sk + ex, "call accounting mismatch");
        }
    }

    function invariant_smoke_allocateProgress() public view {
        uint256 totalCalls = smokeHandler.getCalls(smokeHandler.allocate.selector);
        if (totalCalls < strategies.length) return;
        (,, uint256 ex) = smokeHandler.getStats(smokeHandler.allocate.selector);
        assertGt(ex, 0, "allocate never succeeded");
    }
}
