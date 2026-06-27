// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AlchemistV3} from "../../src/AlchemistV3.sol";
import {AlchemistV3Position} from "../../src/AlchemistV3Position.sol";
import {VaultAnchor, DebtTokenAnchor, TransmuterAnchor} from "./TypedAnchors.sol";

/// @notice End-to-end scene harness for AlchemistV3 conservation and
///         collateralization verification.
///
/// Bypasses `initialize()` (locked by the implementation constructor) and
/// replicates its storage writes directly.  Deploys typed-anchor stubs for
/// the external dependencies (vault, debt token, transmuter) and the real
/// AlchemistV3Position NFT.  Every rule/invariant is checked against the
/// unmodified AlchemistV3 logic — the harness only sets up state.
contract AlchemistV3SceneHarness is AlchemistV3 {
    // -----------------------------------------------------------------------
    // Fixed actor addresses
    // -----------------------------------------------------------------------
    address public constant ADMIN_ACTOR = address(0xA000);
    address public constant FEE_COLLECTOR = address(0xFEED);
    address public constant PROTOCOL_FEE_RECEIVER = address(0xBEEF);
    address public constant UNDERLYING_TOKEN = address(0xCAFE);
    address public constant VAULT_SEED = address(0xDEAD);

    // -----------------------------------------------------------------------
    // Anchors (public for CVL reference)
    // -----------------------------------------------------------------------
    VaultAnchor public immutable vault;
    DebtTokenAnchor public immutable debtTokenAnchor;
    TransmuterAnchor public immutable transmuterAnchor;
    AlchemistV3Position public immutable positionNFT;

    constructor() {
        vault = new VaultAnchor();
        debtTokenAnchor = new DebtTokenAnchor();
        transmuterAnchor = new TransmuterAnchor();
        positionNFT = new AlchemistV3Position(address(this), ADMIN_ACTOR);

        transmuterAnchor.__setAlchemist(address(this));

        vault.__setPerformanceFeeRecipient(FEE_COLLECTOR);

        __initState();
    }

    // -----------------------------------------------------------------------
    // State initialization (bypasses initialize())
    // -----------------------------------------------------------------------
    function __initState() internal {
        // --- public state variables (direct write via inheritance) ---

        admin = ADMIN_ACTOR;
        debtToken = address(debtTokenAnchor);
        myt = address(vault);
        underlyingConversionFactor = 1;
        depositCap = type(uint256).max;
        lastEarmarkBlock = block.number;
        lastRedemptionBlock = block.number;
        minimumCollateralization = uint256(1e36) / 9e17;
        collateralizationLowerBound = 1_052_631_578_950_000_000;
        globalMinimumCollateralization = 1_111_111_111_111_111_111;
        liquidationTargetCollateralization = uint256(1e36) / 88e16;
        protocolFee = 0;
        liquidatorFee = 300;
        repaymentFee = 100;
        alchemistPositionNFT = address(positionNFT);
        protocolFeeReceiver = PROTOCOL_FEE_RECEIVER;
        underlyingToken = UNDERLYING_TOKEN;
        transmuter = address(transmuterAnchor);

        // --- private packed weights (slot-accurate sstore) ---

        assembly {
            // slot 28: _earmarkWeight = ONE_Q128
            sstore(28, shl(128, 1))
            // slot 29: _redemptionWeight = ONE_Q128
            sstore(29, shl(128, 1))

            // slot 34 mapping base, key 0:
            //   _earmarkEpochStartRedemptionWeight[0] = ONE_Q128
            mstore(0x00, 0)
            mstore(0x20, 34)
            sstore(keccak256(0x00, 0x40), shl(128, 1))
        }
    }

    // -----------------------------------------------------------------------
    // Stored-account readers (read RAW storage, NOT unrealized values)
    // -----------------------------------------------------------------------
    // Account struct base: keccak256(tokenId . 33)
    //   offset 0: collateralBalance
    //   offset 1: debt
    //   offset 2: earmarked

    function __accountSlot(uint256 tokenId) internal pure returns (bytes32 base) {
        return keccak256(abi.encode(tokenId, uint256(33)));
    }

    function __storedCollateral(uint256 tokenId) external view returns (uint256 val) {
        bytes32 base = __accountSlot(tokenId);
        assembly { val := sload(base) }
    }

    function __storedDebt(uint256 tokenId) external view returns (uint256 val) {
        bytes32 base = __accountSlot(tokenId);
        assembly { val := sload(add(base, 1)) }
    }

    function __storedEarmarked(uint256 tokenId) external view returns (uint256 val) {
        bytes32 base = __accountSlot(tokenId);
        assembly { val := sload(add(base, 2)) }
    }

    // -----------------------------------------------------------------------
    // Private-variable readers (for invariant checking)
    // -----------------------------------------------------------------------

    function __mytSharesDeposited() external view returns (uint256 val) {
        assembly { val := sload(31) }
    }

    function __pendingCoverShares() external view returns (uint256 val) {
        assembly { val := sload(32) }
    }

    function __totalRedeemedDebt() external view returns (uint256 val) {
        assembly { val := sload(26) }
    }

    function __totalRedeemedSharesOut() external view returns (uint256 val) {
        assembly { val := sload(27) }
    }

    function __earmarkWeight() external view returns (uint256 val) {
        assembly { val := sload(28) }
    }

    function __redemptionWeight() external view returns (uint256 val) {
        assembly { val := sload(29) }
    }

    function __survivalAccumulator() external view returns (uint256 val) {
        assembly { val := sload(30) }
    }

    // -----------------------------------------------------------------------
    // Anchor proxy views (so CVL can read anchor state without multi-contract
    // reference syntax — all reads go through the verified contract)
    // -----------------------------------------------------------------------

    function __vaultBalanceOf(address account) external view returns (uint256) {
        return vault.balanceOf(account);
    }

    function __vaultTotalSupply() external view returns (uint256) {
        return vault.totalSupply();
    }

    function __vaultPerformanceFee() external view returns (uint96) {
        return vault.performanceFee();
    }

    function __vaultConvertToAssets(uint256 shares) external view returns (uint256) {
        return vault.convertToAssets(shares);
    }

    function __vaultConvertToShares(uint256 assets) external view returns (uint256) {
        return vault.convertToShares(assets);
    }

    function __transmuterTotalLocked() external view returns (uint256) {
        return transmuterAnchor.totalLocked();
    }

    function __debtTokenTotalSupply() external view returns (uint256) {
        return debtTokenAnchor.totalSupply();
    }

    function __debtTokenBalanceOf(address account) external view returns (uint256) {
        return debtTokenAnchor.balanceOf(account);
    }

    // -----------------------------------------------------------------------
    // Environment-action wrappers (so Certora `invariant` explores them)
    // -----------------------------------------------------------------------
    // These model external events (vault yield, transmuter
    // staking/claiming) that happen independently of Alchemix's own
    // functions.  Without wrappers, `invariant` would only check after
    // calls to Alchemix itself.

    function __envVaultSetTotalAssets(uint256 assets) external {
        require(assets > 0 || vault.totalSupply() == 0, "cannot zero assets with supply");
        vault.__setTotalAssets(assets);
    }

    function __envVaultSetPerformanceFee(uint96 fee) external {
        vault.__setPerformanceFee(fee);
    }

    function __envTransmuterStakeLocked(uint256 amount) external {
        transmuterAnchor.__stakeLocked(amount);
    }

    function __envTransmuterReduceSynthetics(uint256 amount) external {
        transmuterAnchor.callReduceSyntheticsIssued(amount);
    }

    function __envTransmuterSetQueryGraph(uint256 value) external {
        transmuterAnchor.__setQueryGraphResult(value);
    }

    // -----------------------------------------------------------------------
    // Pure-function wrappers (CVL cannot destructure multi-return values)
    // -----------------------------------------------------------------------

    function calcLiquidation_grossCollateralToSeize(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        (uint256 grossCollateralToSeize, , , ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return grossCollateralToSeize;
    }

    function calcLiquidation_debtToBurn(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        ( , uint256 debtToBurn, , ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return debtToBurn;
    }

    function calcLiquidation_fee(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        ( , , uint256 fee, ) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return fee;
    }

    function calcLiquidation_outsourcedFee(
        uint256 collateral, uint256 debt, uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization, uint256 alchemistMinimumCollateralization, uint256 feeBps
    ) external pure returns (uint256) {
        ( , , , uint256 outsourcedFee) = calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization, feeBps
        );
        return outsourcedFee;
    }

    /// @dev CVL only: set the debt<->underlying conversion factor directly.
    function __setUnderlyingConversionFactor(uint256 v) external {
        underlyingConversionFactor = v;
    }
}
