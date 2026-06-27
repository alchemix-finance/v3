// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Transmuter} from "../../src/Transmuter.sol";
import {ITransmuter} from "../../src/interfaces/ITransmuter.sol";
import {IAlchemistV3} from "../../src/interfaces/IAlchemistV3.sol";
import {MockToken, MockAlchemist} from "./TransmuterMocks.sol";

/// @notice Scene harness for Transmuter conservation verification.
///
/// Inherits from the REAL Transmuter — every invariant is checked
/// against the actual contract logic.  The AlchemistV3 and token
/// dependencies are mocked.
///
/// The StakingGraph (Fenwick tree) is included as-is; it only affects
/// `queryGraph` (used by the Alchemist's earmark), not the Transmuter's
/// own conservation properties.
contract TransmuterSceneHarness is Transmuter {
    MockToken public immutable mockMYT;
    MockToken public immutable mockSynthetic;
    MockToken public immutable mockUnderlying;
    MockAlchemist public immutable mockAlchemist;

    address public constant FEE_RECEIVER = address(0xFEED);

    constructor()
        Transmuter(ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(1),
            feeReceiver:    address(0xFEED),
            timeToTransmute: 100,
            transmutationFee: 100,
            exitFee:          50,
            graphSize:        0
        }))
    {
        MockToken myt = new MockToken("Mock MYT", "mMYT");
        MockToken synth = new MockToken("Mock Synthetic", "mSYN");
        MockToken underlying = new MockToken("Mock Underlying", "mUND");
        MockAlchemist alch = new MockAlchemist(address(myt), address(underlying), address(this));

        mockMYT = myt;
        mockSynthetic = synth;
        mockUnderlying = underlying;
        mockAlchemist = alch;

        // Override storage set by base constructor.
        syntheticToken = address(synth);
        admin = address(this);
        alchemist = IAlchemistV3(address(alch));

        // Allow redemptions — without this createRedemption always reverts.
        depositCap = type(uint256).max / 4;

        // OZ ERC20 requires allowance for transferFrom. createRedemption
        // calls safeTransferFrom(synthetic, msg.sender, this, amount) where
        // msg.sender is the harness (external self-call). Without this
        // self-approval, __createRedemption ALWAYS reverts.
        synth.approve(address(this), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Mock Alchemist control
    // -----------------------------------------------------------------------

    function __setTotalLockedUnderlyingValue(uint256 v) external {
        mockAlchemist.__setTotalLockedUnderlyingValue(v);
    }

    // -----------------------------------------------------------------------
    // CVL helpers
    // -----------------------------------------------------------------------

    function __totalSyntheticsIssued() external view returns (uint256) {
        return mockAlchemist.totalSyntheticsIssued();
    }

    function __syntheticBalance() external view returns (uint256) {
        return mockSynthetic.balanceOf(address(this));
    }

    function __BPS() external pure returns (uint256) {
        return 10_000;
    }
}
