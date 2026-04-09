// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Reproduction of H-04: EtherfiEETH Missing _isProtectedToken
/// Shows that rescueTokens succeeds for weETH (not protected) but fails for WETH (protected).
contract SimMYTStrategy {
    address public owner;
    address public mytAsset; // WETH — protected by base

    constructor(address _owner, address _mytAsset) {
        owner = _owner;
        mytAsset = _mytAsset;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function _isProtectedToken(address token) internal view virtual returns (bool) {
        return token == mytAsset;
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(!_isProtectedToken(token), "Protected token");
        IERC20(token).transfer(to, amount);
    }
}

/// @notice Simulates EtherfiEETHStrategy — does NOT override _isProtectedToken
contract SimEtherfiStrategy is SimMYTStrategy {
    address public weETH;

    constructor(address _owner, address _mytAsset, address _weETH)
        SimMYTStrategy(_owner, _mytAsset)
    {
        weETH = _weETH;
    }
    // NOTE: No _isProtectedToken override — weETH is NOT protected. This is the bug.
}

/// @notice Fixed version for comparison
contract SimEtherfiStrategyFixed is SimMYTStrategy {
    address public weETH;

    constructor(address _owner, address _mytAsset, address _weETH)
        SimMYTStrategy(_owner, _mytAsset)
    {
        weETH = _weETH;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == mytAsset || token == weETH;
    }
}
