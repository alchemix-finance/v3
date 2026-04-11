// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {RevertContext} from "./StrategyTypes.sol";
import {StrategySetup} from "./StrategySetup.sol";
import {StrategyRevertUtils} from "./StrategyRevertUtils.sol";

/// @notice Shared allocate/deallocate execution primitives for base tests.
/// @dev Reuse these helpers in scenario/fuzz modules to apply allowlist and preview logic uniformly.
abstract contract StrategyOps is StrategySetup, StrategyRevertUtils {
    function _isWhitelistedRevert(bytes4 sel, RevertContext context) internal view returns (bool) {
        return this.isProtocolRevertAllowed(sel, context) || this.isMytRevertAllowed(sel, context);
    }

    function _allocateOrSkipWhitelisted(uint256 amount, RevertContext context) internal returns (bool) {
        try IAllocator(allocator).allocate(strategy, amount) {
            return true;
        } catch (bytes memory errData) {
            _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), context));
            return false;
        }
    }

    function _deallocateOrSkipWhitelisted(uint256 amount, RevertContext context) internal returns (bool) {
        if (_useAllocatorDeallocateUnwrapAndSwap()) {
            try IAllocator(allocator).deallocateWithUnwrapAndSwap(
                strategy, amount, _allocatorDeallocateSwapData(amount), _allocatorDeallocateMinIntermediateOut(amount)
            ) {
                return true;
            } catch (bytes memory errData) {
                _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), context));
                return false;
            }
        }

        if (_useAllocatorDeallocateSwap()) {
            try IAllocator(allocator).deallocateWithSwap(strategy, amount, _allocatorDeallocateSwapData(amount)) {
                return true;
            } catch (bytes memory errData) {
                _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), context));
                return false;
            }
        }

        try IAllocator(allocator).deallocate(strategy, amount) {
            return true;
        } catch (bytes memory errData) {
            _revertUnlessWhitelisted(errData, _isWhitelistedRevert(_revertSelector(errData), context));
            return false;
        }
    }

    function _deallocateEstimate(uint256 targetAssets) internal returns (bool) {
        return _deallocateEstimate(targetAssets, RevertContext.DirectDeallocate);
    }

    function _deallocateEstimate(uint256 targetAssets, RevertContext context) internal returns (bool) {
        uint256 target = _effectiveDeallocateAmount(targetAssets);
        if (target == 0) return false;
        _beforePreviewWithdraw(target);
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
        if (preview == 0) return false;
        return _deallocateOrSkipWhitelisted(preview, context);
    }

    function _deallocateFromRealAssetsEstimate() internal returns (bool) {
        return _deallocateFromRealAssetsEstimate(RevertContext.DirectDeallocate);
    }

    function _deallocateFromRealAssetsEstimate(RevertContext context) internal returns (bool) {
        uint256 current = IMYTStrategy(strategy).realAssets();
        if (current == 0) return true;
        return _deallocateEstimate(current, context);
    }

}
