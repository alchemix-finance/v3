// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IMidasDataFeed {
    function getDataInBase18() external view returns (uint256);
    function aggregator() external view returns (address);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IMidasDepositVault {
    function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId) external;
    function minAmount() external view returns (uint256);
}

enum MidasRequestStatus {
    Pending,
    Processed,
    Canceled
}

interface IMidasRedemptionVault {
    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;
    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256 requestId);
    function redeemRequests(uint256 id)
        external
        view
        returns (address sender, address tokenOut, MidasRequestStatus status, uint256 amountMToken, uint256 mTokenRate, uint256 tokenOutRate);
    function tokensConfig(address token) external view returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
    function instantFee() external view returns (uint256);
    function instantDailyLimit() external view returns (uint256);
    function dailyLimits(uint256 day) external view returns (uint256);
    function minAmount() external view returns (uint256);
}

/**
 * @title Re7ETHMidasStrategy
 * @notice Allocates WETH into the Re7ETH tokenized fund (Midas) on Optimism via instant mint/redeem,
 *         using a keeper to exit via `redeemRequest`.
 */
contract Re7ETHMidasStrategy is MYTStrategy {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant NO_EXIT = type(uint256).max;

    address public immutable weth;
    address public immutable re7ETH;
    IMidasDepositVault public immutable depositVault;
    IMidasRedemptionVault public immutable redemptionVault;
    IMidasDataFeed public immutable dataFeed;

    IAggregatorV3 public aggregator;
    uint8 public aggregatorDecimals;

    uint256 public maxNavStaleness;
    uint256 public maxNavDeviationBPS;

    uint256 public lastNav;
    uint256 public lastNavUpdatedAt;

    bool public canForceDeallocate;

    address public keeper;
    /// @dev Midas request id of the current exit. `NO_EXIT` when none. Midas ids start at 0.
    uint256 public pendingExitId = NO_EXIT;

    event CanForceDeallocateUpdated(bool newCanForceDeallocate);
    event AggregatorUpdated(address indexed newAggregator, uint8 decimals);
    event NavSynced(uint256 nav);
    event MaxNavStalenessUpdated(uint256 newMaxNavStaleness);
    event MaxNavDeviationBPSUpdated(uint256 newMaxNavDeviationBPS);
    event NavAccepted(uint256 previousNav, uint256 newNav);
    event KeeperUpdated(address indexed keeper);
    /// @dev `mTokenPending` is what Midas escrowed, net of its request fee.
    event ExitRequested(uint256 indexed requestId, uint256 mTokenRequested, uint256 mTokenPending);
    event ExitCleared(uint256 indexed requestId, MidasRequestStatus status);

    modifier onlyKeeperOrOwner() {
        require(msg.sender == keeper || msg.sender == owner(), "Not keeper");
        _;
    }

    constructor(address _myt, StrategyParams memory _params, address _re7ETH, address _depositVault, address _redemptionVault, address _dataFeed)
        MYTStrategy(_myt, _params)
    {
        require(_re7ETH != address(0), "Zero Re7ETH address");
        require(_depositVault != address(0), "Zero deposit vault address");
        require(_redemptionVault != address(0), "Zero redemption vault address");
        require(_dataFeed != address(0), "Zero data feed address");

        weth = MYT.asset();
        re7ETH = _re7ETH;
        depositVault = IMidasDepositVault(_depositVault);
        redemptionVault = IMidasRedemptionVault(_redemptionVault);
        dataFeed = IMidasDataFeed(_dataFeed);

        maxNavStaleness = 7 days;
        maxNavDeviationBPS = 500;

        _setAggregator(IMidasDataFeed(_dataFeed).aggregator());

        require(dataFeed.getDataInBase18() > 0, "Invalid NAV");
        (address wethFeed,,,) = redemptionVault.tokensConfig(weth);
        require(wethFeed != address(0), "WETH not redeemable");
    }

    function setCanForceDeallocate(bool canForceDeallocate_) external onlyOwner {
        canForceDeallocate = canForceDeallocate_;
        emit CanForceDeallocateUpdated(canForceDeallocate_);
    }

    function setAggregator(address aggregator_) external onlyOwner {
        _setAggregator(aggregator_);
    }

    function setMaxNavStaleness(uint256 maxNavStaleness_) external onlyOwner {
        require(maxNavStaleness_ > 0, "Zero staleness");
        maxNavStaleness = maxNavStaleness_;
        emit MaxNavStalenessUpdated(maxNavStaleness_);
    }

    function setMaxNavDeviationBPS(uint256 maxNavDeviationBPS_) external onlyOwner {
        require(maxNavDeviationBPS_ > 0 && maxNavDeviationBPS_ < BPS, "Invalid deviation");
        maxNavDeviationBPS = maxNavDeviationBPS_;
        emit MaxNavDeviationBPSUpdated(maxNavDeviationBPS_);
    }

    /// @notice Permissionless cache refresh. only accepts a healthy print.
    function pokeNav() external {
        _syncNav();
    }

    /// @notice Owner override to accept a fresh print that the deviation guard rejected.
    function acceptNav() external onlyOwner {
        uint256 previous = lastNav;
        _seedNav();
        emit NavAccepted(previous, lastNav);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    /// @notice Queue a Midas redemption worth about `wethAmount` at `lastNav`.
    function requestExit(uint256 wethAmount) external onlyKeeperOrOwner returns (uint256 requestId) {
        if (wethAmount == 0) revert InvalidAmount(1, 0);
        require(_exitEscrowMTokens() == 0, "Exit pending");

        uint256 mTokenIn = (wethAmount * WAD + lastNav - 1) / lastNav;
        uint256 mTokenBalance = _positionBalance();
        if (mTokenIn > mTokenBalance) mTokenIn = mTokenBalance;
        require(mTokenIn > 0, "No Re7ETH to request");

        TokenUtils.safeApprove(re7ETH, address(redemptionVault), mTokenIn);
        requestId = redemptionVault.redeemRequest(weth, mTokenIn);
        TokenUtils.safeApprove(re7ETH, address(redemptionVault), 0);

        pendingExitId = requestId;
        (,,, uint256 pending,,) = redemptionVault.redeemRequests(requestId);
        emit ExitRequested(requestId, mTokenIn, pending);
    }

    /// @notice Release the exit slot once Midas has settled or cancelled it. 
    function clearExit() external onlyOwner {
        uint256 id = pendingExitId;
        require(id != NO_EXIT, "No exit");
        (,, MidasRequestStatus status,,,) = redemptionVault.redeemRequests(id);
        require(status != MidasRequestStatus.Pending, "Exit pending");
        pendingExitId = NO_EXIT;
        emit ExitCleared(id, status);
    }

    /// @notice Re7ETH escrowed at Midas for the current exit, still valued as position.
    function pendingExitMTokens() external view returns (uint256) {
        return _exitEscrowMTokens();
    }

    /// @dev Midas enforces a minimum mint, amounts below it revert here.
    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(weth, amount);
        _syncNav();

        uint256 minMTokenOut = _assetToMTokenDown((amount * (BPS - params.slippageBPS)) / BPS);

        uint256 mTokenBefore = _positionBalance();
        TokenUtils.safeApprove(weth, address(depositVault), amount);
        depositVault.depositInstant(weth, amount, minMTokenOut, bytes32(0));
        TokenUtils.safeApprove(weth, address(depositVault), 0);
        require(_positionBalance() > mTokenBefore, "No Re7ETH received");

        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            _syncNav();
            uint256 shortfall = amount - idleBalance;

            uint256 mTokenIn = _mTokenInForAssetsOut(shortfall);
            uint256 minRedeem = redemptionVault.minAmount();
            if (mTokenIn < minRedeem) mTokenIn = minRedeem;

            uint256 mTokenBalance = _positionBalance();
            if (mTokenIn > mTokenBalance) revert InsufficientBalance(mTokenIn, mTokenBalance);

            TokenUtils.safeApprove(re7ETH, address(redemptionVault), mTokenIn);
            redemptionVault.redeemInstant(weth, mTokenIn, shortfall);
            TokenUtils.safeApprove(re7ETH, address(redemptionVault), 0);

            idleBalance = _idleAssets();
            if (idleBalance < amount) revert InsufficientBalance(amount, idleBalance);
        }

        TokenUtils.safeApprove(weth, msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 mTokenBalance = _positionBalance() + _exitEscrowMTokens();
        if (mTokenBalance == 0) return _idleAssets();

        (uint256 nav, bool healthy) = _readNav();
        if (!healthy) nav = lastNav;
        return _idleAssets() + (mTokenBalance * nav) / WAD;
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(weth, address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) return amount;

        (, bool healthy) = _readNav();
        if (!healthy) return idleBalance;

        uint256 remaining = amount - idleBalance;
        uint256 available = _instantRedeemableAssets();
        uint256 fundable = remaining < available ? remaining : available;

        return idleBalance + (fundable * (BPS - params.slippageBPS)) / BPS;
    }

    /// @dev WETH withdrawable right now via `redeemInstant`, net of fees and bounded by the redemption
    ///      vault's liquidity, daily limit and token allowance. 
    function _instantRedeemableAssets() internal view returns (uint256) {
        uint256 minRedeem = redemptionVault.minAmount();
        uint256 mTokenBalance = _positionBalance();
        if (mTokenBalance < minRedeem) return 0;

        uint256 feeBps = _redeemFeeBps();
        uint256 fromPosition = _netAssetsForGrossMToken(mTokenBalance, feeBps);

        // Consumed in gross mTokens.
        uint256 dailyLimit = redemptionVault.instantDailyLimit();
        if (dailyLimit != type(uint256).max) {
            uint256 dailyUsed = redemptionVault.dailyLimits(block.timestamp / 1 days);
            if (dailyUsed >= dailyLimit || dailyLimit - dailyUsed < minRedeem) return 0;
            uint256 headroomAssets = _netAssetsForGrossMToken(dailyLimit - dailyUsed, feeBps);
            if (headroomAssets < fromPosition) fromPosition = headroomAssets;
        }

        // Consumed in gross WETH.
        (,, uint256 tokenAllowance,) = redemptionVault.tokensConfig(weth);
        if (tokenAllowance != type(uint256).max) {
            if (tokenAllowance < _mTokenToAsset(minRedeem)) return 0;
            uint256 allowanceNet = tokenAllowance - (tokenAllowance * feeBps) / BPS;
            if (allowanceNet < fromPosition) fromPosition = allowanceNet;
        }

        uint256 vaultLiquidity = TokenUtils.safeBalanceOf(weth, address(redemptionVault));
        if (vaultLiquidity < _netAssetsForGrossMToken(minRedeem, feeBps)) return 0;
        if (vaultLiquidity < fromPosition) fromPosition = vaultLiquidity;

        return fromPosition;
    }

    /// @dev Healthy = positive fresh answer within `maxNavDeviationBPS` of `lastNav`. Reverts read as unhealthy.
    function _readNav() internal view returns (uint256 nav, bool healthy) {
        try aggregator.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxNavStaleness) return (0, false);

            nav = (uint256(answer) * WAD) / (10 ** aggregatorDecimals);

            uint256 ref = lastNav;
            uint256 diff = nav > ref ? nav - ref : ref - nav;
            if (diff * BPS > ref * maxNavDeviationBPS) return (nav, false);

            healthy = true;
        } catch {
            return (0, false);
        }
    }

    function _nav() internal view returns (uint256 nav) {
        bool healthy;
        (nav, healthy) = _readNav();
        require(healthy, "NAV unhealthy");
    }

    function _syncNav() internal returns (uint256 nav) {
        nav = _nav();
        if (nav != lastNav) lastNav = nav;
        lastNavUpdatedAt = block.timestamp;
        emit NavSynced(nav);
    }

    function _setAggregator(address aggregator_) internal {
        require(aggregator_ != address(0), "Zero aggregator address");

        aggregator = IAggregatorV3(aggregator_);
        aggregatorDecimals = IAggregatorV3(aggregator_).decimals();
        emit AggregatorUpdated(aggregator_, aggregatorDecimals);

        _seedNav();
    }

    /// @dev Sets `lastNav` from a fresh print, bypassing the deviation guard.
    function _seedNav() internal {
        (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();
        require(answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp, "Invalid NAV");
        require(block.timestamp - updatedAt <= maxNavStaleness, "Stale NAV");
        lastNav = (uint256(answer) * WAD) / (10 ** aggregatorDecimals);
        lastNavUpdatedAt = block.timestamp;
        emit NavSynced(lastNav);
    }

    function _positionBalance() internal view returns (uint256) {
        return TokenUtils.safeBalanceOf(re7ETH, address(this));
    }

    /// @dev Escrow of the current exit while it is Pending or Canceled. Processed means the WETH already landed.
    function _exitEscrowMTokens() internal view returns (uint256) {
        uint256 id = pendingExitId;
        if (id == NO_EXIT) return 0;
        (,, MidasRequestStatus status, uint256 amountMToken,,) = redemptionVault.redeemRequests(id);
        return status == MidasRequestStatus.Processed ? 0 : amountMToken;
    }

    function _netAssetsForGrossMToken(uint256 grossMToken, uint256 feeBps) internal view returns (uint256) {
        uint256 netMToken = grossMToken - (grossMToken * feeBps) / BPS;
        return _mTokenToAsset(netMToken);
    }

    function _redeemFeeBps() internal view returns (uint256 feeBps) {
        (, uint256 tokenFee,,) = redemptionVault.tokensConfig(weth);
        feeBps = tokenFee + redemptionVault.instantFee();
        if (feeBps > BPS) feeBps = BPS;
    }

    function _mTokenToAsset(uint256 mTokenAmount) internal view returns (uint256) {
        return (mTokenAmount * _nav()) / WAD;
    }

    function _assetToMTokenDown(uint256 assetAmount) internal view returns (uint256) {
        return (assetAmount * WAD) / _nav();
    }

    function _assetToMTokenUp(uint256 assetAmount) internal view returns (uint256) {
        uint256 nav = _nav();
        return (assetAmount * WAD + nav - 1) / nav;
    }

    /// @dev Gross mTokens such that, after Midas fees, at least `assetsOut` WETH is paid.
    function _mTokenInForAssetsOut(uint256 assetsOut) internal view returns (uint256) {
        uint256 netMToken = _assetToMTokenUp(assetsOut);
        uint256 feeBps = _redeemFeeBps();
        if (feeBps == 0) return netMToken;
        uint256 denominator = BPS - feeBps;
        return (netMToken * BPS + denominator - 1) / denominator;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == weth || token == re7ETH;
    }

    function _canForceDeallocate() internal view override returns (bool) {
        return canForceDeallocate;
    }
}
