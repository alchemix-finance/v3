// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fixtures model external counterparties, never replace the owned implementation.
abstract contract GovernanceTestBase is Test {
    address internal constant ADMIN = address(0x1001);
    address internal constant OPERATOR = address(0x1002);
    address internal constant ALICE = address(0x1003);
    address internal constant BOB = address(0x1004);
    address internal constant OUTSIDER = address(0x1005);
    function _error(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }
    function _reject(address target, address caller, bytes memory data, bytes memory expected) internal {
        vm.prank(caller);
        (bool ok, bytes memory result) = target.call(data);
        assert(!ok);
        assert(keccak256(result) == keccak256(expected));
    }
    function _success(address target, address caller, bytes memory data) internal returns (bytes memory result) {
        vm.prank(caller);
        bool ok;
        (ok, result) = target.call(data);
        assert(ok);
    }
    receive() external payable {}
}

contract GovernanceAsset is ERC20 {
    constructor() ERC20("Asset", "AST") {}
    function mint(address recipient, uint256 amount) external { _mint(recipient, amount); }
}

contract GovernanceWETH is GovernanceAsset {
    bool public failUnwrap;
    function setFailUnwrap(bool value) external { failUnwrap = value; }
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) public virtual {
        require(!failUnwrap, "unwrap failed");
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native failed");
    }
    receive() external payable {}
}

contract GovernanceAdapter {
    bytes32 public immutable adapterId;
    constructor(uint256 id) { adapterId = bytes32(id); }
    function getIdData() external view returns (bytes memory) { return abi.encode(adapterId); }
}

/// @dev Recording double: no claim about Morpho cap enforcement or timelocks follows from it.
contract GovernanceRecordingVault {
    address public asset = address(0xA55E7);
    uint256 public totalAssets = 1e24;
    mapping(bytes32 => uint256) public absoluteCap;
    mapping(bytes32 => uint256) public relativeCap;
    mapping(bytes32 => uint256) public allocation;
    address[] public adapters;
    uint256 public calls;
    bytes public lastCall;
    address public lastSender;
    uint256 public lastValue;
    bool public fail;
    function setAsset(address value) external { asset = value; }
    function setTotalAssets(uint256 value) external { totalAssets = value; }
    function configure(bytes32 id, uint256 absolute, uint256 relative, uint256 allocated) external {
        absoluteCap[id] = absolute; relativeCap[id] = relative; allocation[id] = allocated;
    }
    function addFixtureAdapter(address adapter) external { adapters.push(adapter); }
    function adaptersLength() external view returns (uint256) { return adapters.length; }
    function setFail(bool value) external { fail = value; }
    fallback() external payable {
        require(!fail, "target failed");
        calls++;
        lastCall = msg.data;
        lastSender = msg.sender;
        lastValue = msg.value;
    }
}
