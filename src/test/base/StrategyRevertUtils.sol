// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RevertSelectors} from "./StrategyTypes.sol";

/// @notice Shared revert decoding and forwarding helpers for strategy tests.
/// @dev Use this mixin from base modules/handlers to keep revert handling consistent.
abstract contract StrategyRevertUtils {
    error UnexpectedRevert(bytes4 selector, bytes data);

    function _revertSelector(bytes memory errData) internal pure returns (bytes4 sel) {
        if (errData.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(errData, 32))
        }
    }

    function _revertUnlessWhitelisted(bytes memory errData, bool isWhitelisted) internal pure {
        if (isWhitelisted) return;
        bytes4 sel = _revertSelector(errData);
        revert UnexpectedRevert(sel, errData);
    }

    /// @dev True when `errData` is `Error(string)` with exactly `message`.
    function errorStringEquals(bytes memory errData, string memory message) internal pure returns (bool) {
        if (errData.length < 4) return false;
        if (_revertSelector(errData) != RevertSelectors.ERROR_STRING) return false;
        return keccak256(errData) == keccak256(abi.encodeWithSignature("Error(string)", message));
    }
}
