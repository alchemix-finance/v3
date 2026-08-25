// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext, RevertSelectors} from "../base/StrategyTypes.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {MockSwapper} from "../mocks/MockSwapper.sol";
import {EtherfiEETHMYTStrategy, IWeETH} from "../../strategies/EtherfiEETHStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

/// @notice Test-only port of the removed Chainlink pricing getter, used for parity checks.
contract ChainlinkPriceHelper {
    AggregatorV3Interface public immutable feed;
    uint256 public immutable maxStaleness;

    constructor(address _feed, uint256 _maxStaleness) {
        feed = AggregatorV3Interface(_feed);
        maxStaleness = _maxStaleness;
    }

    /// @dev Verbatim logic of the removed `OraclePricedSwapStrategy._oracleAnswer`.
    function oracleAnswer() public view returns (uint256 answer) {
        (, int256 raw,, uint256 updatedAt,) = feed.latestRoundData();
        require(raw > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxStaleness, "Stale oracle answer");
        answer = uint256(raw);
    }

    /// @dev weETH -> WETH valuation exactly as the old strategy computed it.
    function weEthToWeth(uint256 weEthAmount) external view returns (uint256) {
        return (weEthAmount * oracleAnswer()) / 1e18;
    }
}

contract MockFeeRedemptionManager {
    uint256 public constant BPS = 10_000;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable weETH;
    address public immutable eETH;
    uint256 public immutable feeBps;
    bool public canRedeemFlag = true;
    address public immutable liquidityPoolAddr;

    constructor(address _weETH, address _eETH, uint256 _feeBps, address _liquidityPool) payable {
        weETH = _weETH;
        eETH = _eETH;
        feeBps = _feeBps;
        liquidityPoolAddr = _liquidityPool;
    }

    function setCanRedeem(bool val) external {
        canRedeemFlag = val;
    }

    function canRedeem(uint256, address token) external view returns (bool) {
        return token == ETH && canRedeemFlag;
    }

    function liquidityPool() external view returns (address) {
        return liquidityPoolAddr;
    }

    function amountForShare(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function sharesForAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function sharesForWithdrawalAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function previewRedeem(uint256 shares, address token) external view returns (uint256) {
        if (token != ETH) return 0;
        uint256 fee = (shares * feeBps + BPS - 1) / BPS;
        return shares - fee;
    }

    function tokenToRedemptionInfo(address token)
        external
        view
        returns (RedemptionLimit memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl)
    {
        if (token != ETH) {
            return (limit, 0, 0, 0);
        }
        return (RedemptionLimit({capacity: type(uint64).max, remaining: type(uint64).max, lastRefill: 0, refillRate: 0}), 0, uint16(feeBps), 0);
    }

    struct RedemptionLimit {
        uint64 capacity;
        uint64 remaining;
        uint64 lastRefill;
        uint64 refillRate;
    }

    function redeemWeEth(uint256 amount, address receiver, address outputToken) external returns (uint256) {
        require(outputToken == ETH, "invalid output token");
        require(IERC20(weETH).transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 grossEth = IWeETH(weETH).getEETHByWeETH(amount);
        uint256 fee = (grossEth * feeBps + BPS - 1) / BPS;
        uint256 netEth = grossEth - fee;
        (bool ok,) = receiver.call{value: netEth}("");
        require(ok, "eth transfer failed");
        return netEth;
    }

    receive() external payable {}
}

/// @notice Mock weETH: ERC20 wrapper over eETH with a controllable rate.
contract MockWeETH is ERC20 {
    IERC20 public immutable eETH;
    uint256 public rate = 1.05e18; // eETH per 1 weETH

    constructor(address _eETH) ERC20("Mock weETH", "mweETH") {
        eETH = IERC20(_eETH);
    }

    function setRate(uint256 newRate) external {
        require(newRate > 0, "zero rate");
        rate = newRate;
    }

    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256) {
        return (weETHAmount * rate) / 1e18;
    }

    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256) {
        return (eETHAmount * 1e18) / rate;
    }

    /// @dev Burns caller's weETH and returns the eETH-equivalent from the wrapper's vault.
    function unwrap(uint256 weETHAmount) external returns (uint256) {
        require(weETHAmount > 0, "ZeroAmount()");
        uint256 eEthOut = (weETHAmount * rate) / 1e18;
        _burn(msg.sender, weETHAmount);
        eETH.transfer(msg.sender, eEthOut);
        return eEthOut;
    }

    /// @dev Pulls eETH from the caller (allowance) and mints weETH at the current rate.
    function wrap(uint256 eETHAmount) external returns (uint256) {
        require(eETHAmount > 0, "ZeroAmount()");
        eETH.transferFrom(msg.sender, address(this), eETHAmount);
        uint256 weEthOut = (eETHAmount * 1e18) / rate;
        _mint(msg.sender, weEthOut);
        return weEthOut;
    }
}

/// @notice Mock WithdrawRequestNFT mirroring the real queue lifecycle and struct layout.
contract MockWithdrawRequestNFT {
    struct WithdrawRequest {
        uint96 amountOfEEth;
        uint96 shareOfEEth;
        bool isValid;
        uint32 feeGwei;
    }

    address public liquidityPool;
    address public admin;
    uint256 public nextRequestId = 1;
    uint256 public lastFinalizedRequestId;
    mapping(uint256 => WithdrawRequest) public _requests;
    mapping(uint256 => address) public _ownerOf;

    event WithdrawRequestCreated(uint256 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner);
    event WithdrawRequestClaimed(uint256 indexed requestId, uint256 amount, address owner);

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not admin");
        _;
    }

    function setLiquidityPool(address _liquidityPool) external onlyAdmin {
        require(liquidityPool == address(0) || liquidityPool == _liquidityPool, "pool already set");
        liquidityPool = _liquidityPool;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
    }

    modifier onlyLiquidityPool() {
        require(msg.sender == liquidityPool, "Caller is not the liquidity pool");
        _;
    }

    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory) {
        require(_ownerOf[requestId] != address(0), "RequestNotFound");
        return _requests[requestId];
    }

    function isFinalized(uint256 requestId) external view returns (bool) {
        return requestId <= lastFinalizedRequestId;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "RequestNotFound");
        return _ownerOf[tokenId];
    }

    function getClaimableAmount(uint256 tokenId) external view returns (uint256) {
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        require(_ownerOf[tokenId] != address(0), "Already Claimed");
        return _requests[tokenId].amountOfEEth;
    }

    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient) external onlyLiquidityPool returns (uint256) {
        uint256 requestId = nextRequestId++;
        _requests[requestId] = WithdrawRequest({amountOfEEth: amountOfEEth, shareOfEEth: shareOfEEth, isValid: true, feeGwei: 0});
        _ownerOf[requestId] = recipient;
        emit WithdrawRequestCreated(requestId, amountOfEEth, shareOfEEth, recipient);
        return requestId;
    }

    function finalizeRequests(uint256 requestId) external onlyAdmin {
        require(requestId >= lastFinalizedRequestId, "Cannot undo finalization");
        require(requestId < nextRequestId, "Cannot finalize future requests");
        lastFinalizedRequestId = requestId;
    }

    function invalidateRequest(uint256 requestId) external onlyAdmin {
        require(_requests[requestId].isValid, "Request is not valid");
        _requests[requestId].isValid = false;
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i]);
        }
    }

    function claimWithdraw(uint256 tokenId) external {
        _claimWithdraw(tokenId);
    }

    function _claimWithdraw(uint256 tokenId) internal {
        require(_ownerOf[tokenId] != address(0), "RequestNotFound");
        require(_requests[tokenId].isValid, "Request is not valid");
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        address recipient = _ownerOf[tokenId];
        uint256 amount = _requests[tokenId].amountOfEEth;
        delete _requests[tokenId];
        delete _ownerOf[tokenId];

        // escrowed ETH lives in the liquidity pool
        MockLiquidityPool(payable(liquidityPool)).payoutClaim(recipient, amount);
        emit WithdrawRequestClaimed(tokenId, amount, recipient);
    }

    receive() external payable {}
}

/// @notice Mock LiquidityPool with the withdraw-request surface used by the strategy.
contract MockLiquidityPool {
    address public immutable eETH;
    address public immutable withdrawRequestNFT;
    address public admin;
    uint256 public minWithdrawAmount = 0.005e18;
    uint256 public maxWithdrawAmount = 1000e18;
    bool public instantWithdrawAllowed = true;

    constructor(address _eETH, address _withdrawRequestNFT) payable {
        eETH = _eETH;
        withdrawRequestNFT = _withdrawRequestNFT;
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not admin");
        _;
    }

    function amountForShare(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function sharesForAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function sharesForWithdrawalAmount(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function setWithdrawBounds(uint256 minW, uint256 maxW) external onlyAdmin {
        minWithdrawAmount = minW;
        maxWithdrawAmount = maxW;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
    }

    function setInstantWithdrawAllowed(bool val) external onlyAdmin {
        instantWithdrawAllowed = val;
    }

    function requestWithdraw(address recipient, uint256 amount) external returns (uint256) {
        require(amount > 0, "InvalidWithdrawalAmount()");
        IERC20(eETH).transferFrom(msg.sender, address(this), amount);
        return MockWithdrawRequestNFT(payable(withdrawRequestNFT)).requestWithdraw(uint96(amount), uint96(amount), recipient);
    }

    /// @dev Instant withdraw leg; real pool gates the caller, mock gates via a flag.
    function withdraw(address recipient, uint256 amount) external returns (uint256) {
        require(instantWithdrawAllowed, "Incorrect Caller");
        require(amount >= minWithdrawAmount && amount <= maxWithdrawAmount, "InvalidWithdrawalAmount()");
        IERC20(eETH).transferFrom(msg.sender, address(this), amount);
        require(address(this).balance >= amount, "InsufficientLiquidity()");
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "SendFail()");
        return amount;
    }

    /// @dev Called by the WRN mock when a request is claimed.
    function payoutClaim(address recipient, uint256 amount) external {
        require(msg.sender == withdrawRequestNFT, "Incorrect Caller");
        require(address(this).balance >= amount, "InsufficientLiquidity()");
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "SendFail()");
    }

    receive() external payable {}
}

contract MockEtherfiEETHStrategy is EtherfiEETHMYTStrategy {
    constructor(address _myt, IMYTStrategy.StrategyParams memory _params, address _eETH, address _weETH, address _depositAdapter, address _redemptionManager)
        EtherfiEETHMYTStrategy(_myt, _params, _eETH, _weETH, _depositAdapter, _redemptionManager)
    {}
}

/// @notice Full-mock Etherfi environment: weETH/eETH/LP/WRN/DepositAdapter/RedemptionManager.
contract MockEtherfiEnvironment {
    address public immutable eETH;
    address public immutable weETH;
    address public immutable depositAdapter;
    address public immutable redemptionManager;
    address public immutable liquidityPool;
    address public immutable withdrawRequestNFT;

    constructor(address _weth, uint256 redemptionManagerFund, address admin_) payable {
        // plain ERC20 for eETH; the weETH mock holds the eETH accounting
        TestERC20Local eEthToken = new TestERC20Local(0, 18);
        eETH = address(eEthToken);
        MockWeETH weEthToken = new MockWeETH(address(eEthToken));
        weETH = address(weEthToken);

        MockWithdrawRequestNFT wrn = new MockWithdrawRequestNFT();
        withdrawRequestNFT = address(wrn);
        MockLiquidityPool pool = new MockLiquidityPool{value: redemptionManagerFund}(eETH, address(wrn));
        liquidityPool = address(pool);
        wrn.setLiquidityPool(address(pool));
        wrn.transferAdmin(admin_);
        pool.transferAdmin(admin_);

        MockDepositAdapter adapter = new MockDepositAdapter(_weth, address(weEthToken), address(eEthToken));
        depositAdapter = address(adapter);

        MockFullRedemptionManager rm = new MockFullRedemptionManager(address(weEthToken), address(eEthToken), 0, address(pool));
        redemptionManager = address(rm);
        rm.setRefund{value: redemptionManagerFund}();
    }
}

contract TestERC20Local is ERC20 {
    constructor(uint256 amountToMint, uint8) ERC20("Mock", "MCK") {
        _mint(msg.sender, amountToMint);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDepositAdapter {
    address public immutable weth;
    address public immutable weETH;
    address public immutable eETH;

    constructor(address _weth, address _weETH, address _eETH) {
        weth = _weth;
        weETH = _weETH;
        eETH = _eETH;
    }

    /// @dev WETH in -> eETH minted to this adapter -> wrapped into weETH for the caller.
    function depositWETHForWeETH(uint256 amount, address) external returns (uint256) {
        IERC20(weth).transferFrom(msg.sender, address(this), amount);
        TestERC20Local(eETH).mint(address(this), amount);
        TestERC20Local(eETH).approve(weETH, amount);
        MockWeETH(weETH).wrap(amount);
        uint256 wrapped = MockWeETH(weETH).balanceOf(address(this));
        require(wrapped > 0, "no weETH minted");
        MockWeETH(weETH).transfer(msg.sender, wrapped);
        return amount;
    }
}

/// @notice RedemptionManager mock delegating share math + liquidityPool to the mock LP.
contract MockFullRedemptionManager {
    uint256 public constant BPS = 10_000;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public immutable weETH;
    address public immutable eETH;
    uint256 public immutable feeBps;
    address public immutable lp;

    constructor(address _weETH, address _eETH, uint256 _feeBps, address _lp) {
        weETH = _weETH;
        eETH = _eETH;
        feeBps = _feeBps;
        lp = _lp;
    }

    receive() external payable {}

    function setRefund() external payable {}

    /// @dev Sends the ETH backing `canRedeem` to a sink outside the prank context.
    function drain(address payable sink) external {
        uint256 bal = address(this).balance;
        (bool ok,) = sink.call{value: bal}("");
        require(ok, "drain failed");
    }

    function canRedeem(uint256, address token) external view returns (bool) {
        return token == ETH && address(this).balance > 0;
    }

    function liquidityPool() external view returns (address) {
        return lp;
    }

    function previewRedeem(uint256 shares, address token) external view returns (uint256) {
        if (token != ETH) return 0;
        uint256 fee = (shares * feeBps + BPS - 1) / BPS;
        return shares - fee;
    }

    function tokenToRedemptionInfo(address token)
        external
        view
        returns (uint64 capacity, uint64 remaining, uint64 lastRefill, uint64 refillRate, uint16 split, uint16 fee, uint16 watermark)
    {
        if (token != ETH) return (0, 0, 0, 0, 0, 0, 0);
        return (type(uint64).max, type(uint64).max, 0, 0, 0, uint16(feeBps), 0);
    }

    function redeemWeEth(uint256 amount, address receiver, address outputToken) external returns (uint256) {
        require(outputToken == ETH, "invalid output token");
        require(IERC20(weETH).transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 grossEth = IWeETH(weETH).getEETHByWeETH(amount);
        uint256 fee = (grossEth * feeBps + BPS - 1) / BPS;
        uint256 netEth = grossEth - fee;
        (bool ok,) = receiver.call{value: netEth}("");
        require(ok, "eth transfer failed");
        return netEth;
    }
}

contract EtherfiEETHStrategyTest is BaseStrategyTest {
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address public constant WEETH_ETH_ORACLE = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    uint256 public constant MAX_ORACLE_STALENESS = 24 hours;
    /// @notice Max allowed canonical-vs-Chainlink divergence for parity assertions.
    uint256 public constant MAX_DIVERGENCE_BPS = 100;
    uint256 public constant TEST_RESIDUAL_TOLERANCE_BPS = 100;

    /// @dev Instant-capacity exhaustion string reverts are tolerated in fuzz/handler flows.
    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzAllocate
            || context == RevertContext.FuzzDeallocate;
        if (!isFuzzOrHandler) return false;
        return selector == RevertSelectors.ERROR_STRING;
    }

    /// @notice Fork impersonation target authorized to finalize withdrawal requests.
    address public constant ETHERFI_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    MockSwapper public swapper;
    MockEtherfiEnvironment public mockEnv;

    function setUp() public override {
        swapper = new MockSwapper();
        mockEnv = new MockEtherfiEnvironment{value: 50_000e18}(WETH, 20_000e18, address(this));
        super.setUp();

        vm.startPrank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(swapper));
        vm.stopPrank();

        // Only swap execution is mocked; protocol contracts are live mainnet.
        deal(WETH, address(swapper), 1_000_000e18);
        deal(WEETH, address(swapper), 1_000_000e18);
    }

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "EETH",
            protocol: "EtherFi",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 2_000_000e18,
            globalCap: 2_000_000e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 10
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 2_000_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockEtherfiEETHStrategy(vault_, params, EETH, WEETH, DEPOSIT_ADAPTER, REDEMPTION_MANAGER));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24_595_012;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    /// @notice Canonical pricing must stay within MAX_DIVERGENCE_BPS of Chainlink at the fork state.
    function test_pricing_parity_canonical_vs_chainlink_fork() public view {
        uint256 rate = IWeETH(WEETH).getEETHByWeETH(1e18);
        (, int256 raw,, uint256 updatedAt,) = AggregatorV3Interface(WEETH_ETH_ORACLE).latestRoundData();
        require(raw > 0 && updatedAt != 0, "invalid oracle answer");

        uint256 divergenceBps = rate > uint256(raw) ? ((rate - uint256(raw)) * 10_000) / rate : ((uint256(raw) - rate) * 10_000) / rate;
        assertLe(divergenceBps, MAX_DIVERGENCE_BPS, "canonical rate diverged from chainlink");
    }

    /// @notice Fuzzed valuation parity: canonical vs Chainlink pricing per weETH unit.
    function test_fuzz_pricing_parity_valuation(uint96 weEthAmount) public {
        // bound above wei dust: a 1-wei diff at 1-wei scale is ~10k bps of noise
        weEthAmount = uint96(bound(weEthAmount, 1e14, 1_000_000e18));

        ChainlinkPriceHelper helper = new ChainlinkPriceHelper(WEETH_ETH_ORACLE, MAX_ORACLE_STALENESS);
        uint256 chainlinkValue = helper.weEthToWeth(weEthAmount);
        uint256 canonicalValue = IWeETH(WEETH).getEETHByWeETH(weEthAmount);

        uint256 diff = chainlinkValue > canonicalValue ? chainlinkValue - canonicalValue : canonicalValue - chainlinkValue;
        assertLe((diff * 10_000) / chainlinkValue, MAX_DIVERGENCE_BPS, "valuation parity broken");
    }

    /// @notice The helper rejects stale feed data.
    function test_parity_helper_reverts_on_stale_feed() public {
        ChainlinkPriceHelper helper = new ChainlinkPriceHelper(WEETH_ETH_ORACLE, MAX_ORACLE_STALENESS);
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = AggregatorV3Interface(WEETH_ETH_ORACLE).latestRoundData();
        vm.mockCall(
            WEETH_ETH_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp - MAX_ORACLE_STALENESS - 1, answeredInRound)
        );
        vm.expectRevert(bytes("Stale oracle answer"));
        helper.oracleAnswer();
        vm.clearMockedCalls();
    }

    function test_rate_checkpoint_advances_on_allocation() public {
        vm.startPrank(vault);
        deal(WETH, strategy, 10e18);
        IMYTStrategy(strategy).allocate(getDirectAllocateVaultParams(10e18), 10e18, "", address(vault));
        vm.stopPrank();

        uint256 checkpoint = EtherfiEETHMYTStrategy(payable(strategy)).rateCheckpoint();
        assertGt(checkpoint, 0, "checkpoint should be recorded");
        assertApproxEqRel(checkpoint, IWeETH(WEETH).getEETHByWeETH(1e18), 1e12, "checkpoint should track canonical rate");
    }

    function test_deallocate_direct_uses_instant_redeem_path_cant_redeem() public {
        uint256 allocateAmount = 1e18;
        uint256 deallocateAmount = 1e16;
        bytes memory allocParams = getAllocateVaultParams(allocateAmount);

        vm.startPrank(vault);
        deal(WETH, strategy, allocateAmount);
        IMYTStrategy(strategy).allocate(allocParams, allocateAmount, "", address(vault));
        vm.stopPrank();

        // If canRedeem is unavailable/reverting at this fork state, skip deterministically.
        uint256 grossRedeemAmount = _grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount);
        bool redeemable = IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(grossRedeemAmount, ETH);
        if (redeemable) return;

        // if liquidity is unavailable everywhere, direct deallocate should revert
        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        vm.startPrank(vault);
        vm.expectRevert(bytes("Insufficient WETH available"));
        IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        vm.stopPrank();
    }

    function test_vault_user_forceDeallocate_reverts_when_strategy_disables_force_deallocation() public {
        uint256 allocateAmount = 10e18;
        uint256 forceDeallocateAmount = 1e18;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        vm.prank(admin);
        EtherfiEETHMYTStrategy(payable(strategy)).setCanForceDeallocate(false);

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(IMYTStrategy.ForceDeallocateSwapNotAllowed.selector);
        vm.prank(vaultDepositor);
        IVaultV2(vault).forceDeallocate(strategy, abi.encode(directDealloc), forceDeallocateAmount, vaultDepositor);
    }

    function test_fuzz_deallocate_direct_succeeds_with_updated_gross_redeem_amount_buffer(
        uint256 rawAllocateAmount,
        uint256 rawDeallocateAmount,
        uint256 rawBuffer
    ) public {
        // sanity check that the pinned fork block exposes instant redemption liquidity at all
        require(
            IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(_grossRedeemAmount(REDEMPTION_MANAGER, 1e18), ETH),
            "fork block should support instant redemption"
        );

        uint256 allocateAmount = bound(rawAllocateAmount, 2e18, 100e18);
        uint256 buffer = bound(rawBuffer, 1, EtherfiEETHMYTStrategy(payable(strategy)).MAX_GROSS_REDEEM_AMOUNT_BUFFER());

        vm.prank(admin);
        EtherfiEETHMYTStrategy(payable(strategy)).setGrossRedeemAmountBuffer(buffer);

        bytes memory allocParams = getDirectAllocateVaultParams(allocateAmount);

        vm.startPrank(vault);
        deal(WETH, strategy, allocateAmount);
        IMYTStrategy(strategy).allocate(allocParams, allocateAmount, "", address(vault));

        // gross redeem (shortfall grossed up + buffer) must fit the position
        (, uint16 exitFeeInBps,) = _redemptionInfo(REDEMPTION_MANAGER);
        uint256 positionEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 maxDeallocate = ((positionEETH - buffer) * (10_000 - exitFeeInBps)) / 10_000 - 1e3;
        uint256 deallocateAmount = bound(rawDeallocateAmount, 1e16, maxDeallocate);

        // closed-form bound must agree with the gross-up getter
        assertLe(_grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount) + buffer, positionEETH, "bound diverges from getter");

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);

        IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(strategy), deallocateAmount, "idle WETH should cover requested deallocation");
        vm.stopPrank();
    }

    function test_deallocate_direct_cascades_to_liquidity_pool_withdraw() public {
        // Mock env with redemption drained but the LP instant withdraw leg open.
        MockEtherfiEnvironment env = mockEnv;
        EtherfiEETHMYTStrategy localStrategy =
            new MockEtherfiEETHStrategy(vault, strategyConfig, env.eETH(), env.weETH(), env.depositAdapter(), env.redemptionManager());

        uint256 allocateAmount = 5e18;
        vm.startPrank(vault);
        deal(WETH, address(localStrategy), allocateAmount);
        IMYTStrategy(address(localStrategy)).allocate(getDirectAllocateVaultParams(allocateAmount), allocateAmount, "", address(vault));

        // Drain the redemption manager so the first cascade leg is unavailable.
        MockFullRedemptionManager(payable(env.redemptionManager())).drain(payable(address(this)));

        uint256 deallocateAmount = 1e18;
        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;

        IMYTStrategy(address(localStrategy)).deallocate(abi.encode(directDealloc), deallocateAmount, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(address(localStrategy)), deallocateAmount, "LP withdraw leg should cover deallocation");
        vm.stopPrank();
    }

    function test_deallocate_direct_reverts_when_all_instant_legs_exhausted() public {
        MockEtherfiEnvironment env = mockEnv;
        EtherfiEETHMYTStrategy localStrategy =
            new MockEtherfiEETHStrategy(vault, strategyConfig, env.eETH(), env.weETH(), env.depositAdapter(), env.redemptionManager());

        uint256 allocateAmount = 5e18;
        // pool admin is the test; close the LP leg before the prank
        MockLiquidityPool(payable(env.liquidityPool())).setInstantWithdrawAllowed(false);

        vm.startPrank(vault);
        deal(WETH, address(localStrategy), allocateAmount);
        IMYTStrategy(address(localStrategy)).allocate(getDirectAllocateVaultParams(allocateAmount), allocateAmount, "", address(vault));

        MockFullRedemptionManager(payable(env.redemptionManager())).drain(payable(address(this)));

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;

        vm.expectRevert(bytes("Insufficient WETH available"));
        IMYTStrategy(address(localStrategy)).deallocate(abi.encode(directDealloc), 1e18, "", address(vault));
        vm.stopPrank();
    }

    function test_allocate_swap_mock_success() public {
        uint256 amount = 10e18;
        // canonical floor: minWeETH = WETH * (1-slippage) converted at canonical rate (up-rounded)
        uint256 minWeEthOut = _canonicalMinWeEthOut(amount);
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, WEETH, amount, minWeEthOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();

        assertGe(IWeETH(WEETH).balanceOf(strategy), minWeEthOut, "weETH balance should satisfy canonical min out");
    }

    function test_allocate_swap_reverts_when_allowanceHolder_returns_less_than_minAmountOut() public {
        uint256 amount = 10e18;
        uint256 minWeEthOut = _canonicalMinWeEthOut(amount);
        require(minWeEthOut > 1, "min output too small");
        uint256 insufficientOut = minWeEthOut - 1;
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, WEETH, amount, insufficientOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        assertEq(MYTStrategy(strategy).allowanceHolder(), address(swapper), "test should execute through allowance holder");
        // swap succeeds but under-delivers; dexSwap reverts on the balance check
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minWeEthOut, insufficientOut));
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();
    }

    function getDeallocateVaultParams(uint256 assets) internal view override returns (bytes memory) {
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: _swapCallDataForWethOut(assets), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        return abi.encode(vp);
    }

    function _useAllocatorDeallocateSwap() internal pure override returns (bool) {
        return false;
    }

    function _allocatorDeallocateSwapData(uint256 amount) internal view override returns (bytes memory) {
        return _swapCallDataForWethOut(amount);
    }

    function _assertDeallocateChange(int256 change, uint256 amountToDeallocate) internal view override {
        assertApproxEqRel(change, -int256(amountToDeallocate), 1e16);
    }

    function test_deallocate_swap_mock_success() public {
        uint256 amount = 10e18;
        bytes memory directParams = getVaultParams();

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(directParams, amount, "", address(vault));
        vm.stopPrank();

        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 deallocCap = maxEETH / 2;
        uint256 deallocAmount = amount < deallocCap ? amount : deallocCap;
        require(deallocAmount > 0, "dealloc amount is zero");
        deal(WETH, address(swapper), deallocAmount);
        bytes memory callData = _swapCallDataForWethOut(deallocAmount);
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        bytes memory deallocParams = abi.encode(vp);

        vm.startPrank(vault);
        IMYTStrategy(strategy).deallocate(deallocParams, deallocAmount, "", address(vault));
        vm.stopPrank();
    }

    function test_deallocate_swap_mock_reverts_on_insufficient_swap_output() public {
        uint256 amount = 10e18;
        bytes memory directParams = getVaultParams();

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(directParams, amount, "", address(vault));
        vm.stopPrank();

        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        uint256 deallocCap = maxEETH / 2;
        uint256 deallocAmount = amount < deallocCap ? amount : deallocCap;
        require(deallocAmount > 1, "dealloc amount too small");
        uint256 insufficientOut = deallocAmount - 1;
        uint256 sellAmount = IWeETH(WEETH).getWeETHByeETH(deallocAmount);
        uint256 weETHBalance = IWeETH(WEETH).balanceOf(strategy);
        if (sellAmount > weETHBalance) sellAmount = weETHBalance;

        deal(WETH, address(swapper), insufficientOut);
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WEETH, WETH, sellAmount, insufficientOut));
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});
        bytes memory deallocParams = abi.encode(vp);

        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, deallocAmount, insufficientOut));
        IMYTStrategy(strategy).deallocate(deallocParams, deallocAmount, "", address(vault));
        vm.stopPrank();
    }

    function _deployMockStrategy() internal returns (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) {
        env = mockEnv;
        localStrategy = new MockEtherfiEETHStrategy(vault, strategyConfig, env.eETH(), env.weETH(), env.depositAdapter(), env.redemptionManager());
    }

    function _mockAllocate(EtherfiEETHMYTStrategy localStrategy, uint256 amount) internal {
        vm.startPrank(vault);
        deal(WETH, address(localStrategy), amount);
        IMYTStrategy(address(localStrategy)).allocate(getDirectAllocateVaultParams(amount), amount, "", address(vault));
        vm.stopPrank();
    }

    function test_async_request_and_claim_full_lifecycle() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        uint256 valueBefore = IMYTStrategy(address(localStrategy)).realAssets();
        assertGt(valueBefore, 0, "real assets should be positive after allocation");

        vm.prank(address(1)); // owner
        (uint256 tokenId, uint96 shares) = localStrategy.requestExits(5e18);
        assertGt(shares, 0, "pending exit should track shares");
        assertEq(localStrategy.pendingExitCount(), 1, "one pending exit expected");

        // pending claim valued at shares minus haircut: no phantom loss
        uint256 valuePending = IMYTStrategy(address(localStrategy)).realAssets();
        assertGe(valuePending + 1, (valueBefore * 99) / 100, "pending accounting should not create a phantom loss");

        // Preview excludes pending liquidity.
        uint256 preview = IMYTStrategy(address(localStrategy)).previewAdjustedWithdraw(type(uint256).max);
        assertLt(preview, valuePending, "preview should not count pending queue claims as instant");

        // Claiming before finalization reverts via the protocol.
        vm.expectRevert(bytes("Request is not finalized"));
        localStrategy.claimExits();

        // Finalize (admin of the mock WRN) and settle permissionlessly.
        MockWithdrawRequestNFT(payable(env.withdrawRequestNFT())).finalizeRequests(tokenId);
        assertEq(localStrategy.claimableExits(), 5e18, "claimable should equal requested eETH");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(localStrategy));
        localStrategy.claimExits(); // anyone can call
        assertEq(IERC20(WETH).balanceOf(address(localStrategy)), wethBefore + 5e18, "claimed ETH should become idle WETH");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be pruned");

        // Double-claim reverts: nothing pending anymore.
        vm.expectRevert(EtherfiEETHMYTStrategy.NoPendingExit.selector);
        localStrategy.claimExits();
    }

    function test_async_request_requires_keeper_or_owner() public {
        (EtherfiEETHMYTStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.expectRevert(abi.encodeWithSelector(EtherfiEETHMYTStrategy.NotKeeper.selector, address(0xBEEF)));
        vm.prank(address(0xBEEF));
        localStrategy.requestExits(1e18);

        // keeper path works
        vm.prank(address(1));
        localStrategy.setKeeper(address(0xBEEF));
        vm.prank(address(0xBEEF));
        localStrategy.requestExits(1e18);
        assertEq(localStrategy.pendingExitCount(), 1, "keeper should be able to request exits");
    }

    function test_async_request_reverts_when_no_position() public {
        (EtherfiEETHMYTStrategy localStrategy,) = _deployMockStrategy();
        vm.prank(address(1));
        vm.expectRevert(bytes("No weETH available"));
        localStrategy.requestExits(1e18);
    }

    function test_async_claim_reverts_when_no_pending_exit() public {
        (EtherfiEETHMYTStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.expectRevert(EtherfiEETHMYTStrategy.NoPendingExit.selector);
        localStrategy.claimExits();
    }

    function test_async_request_reverts_while_exit_pending() public {
        (EtherfiEETHMYTStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 100e18);

        vm.startPrank(address(1));
        (uint256 tokenId,) = localStrategy.requestExits(1e18);
        vm.expectRevert(abi.encodeWithSelector(EtherfiEETHMYTStrategy.ExitPending.selector, tokenId));
        localStrategy.requestExits(1e18);
        vm.stopPrank();
    }

    function test_async_request_auto_claims_stale_finalized_exit() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        vm.prank(address(1));
        (uint256 firstTokenId,) = localStrategy.requestExits(4e18);
        MockWithdrawRequestNFT(payable(env.withdrawRequestNFT())).finalizeRequests(firstTokenId);

        // stale finalized claim is settled in the same tx as the new request
        uint256 wethBefore = IERC20(WETH).balanceOf(address(localStrategy));
        vm.prank(address(1));
        (uint256 secondTokenId,) = localStrategy.requestExits(4e18);
        assertEq(IERC20(WETH).balanceOf(address(localStrategy)), wethBefore + 4e18, "stale claim should be auto-settled");
        assertEq(localStrategy.pendingExitCount(), 1, "only the new exit should be pending");
        assertTrue(localStrategy.isPendingExit(secondTokenId), "new exit should be tracked");
        assertFalse(localStrategy.isPendingExit(firstTokenId), "old exit should be pruned");
    }

    function test_deallocate_auto_claims_finalized_exit() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        vm.prank(address(1));
        (uint256 tokenId,) = localStrategy.requestExits(6e18);

        // kill every instant leg: deallocate must revert while the exit is unfinalized
        MockFullRedemptionManager(payable(env.redemptionManager())).drain(payable(address(this)));
        MockLiquidityPool(payable(env.liquidityPool())).setInstantWithdrawAllowed(false);

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;

        vm.prank(vault);
        vm.expectRevert(bytes("Insufficient WETH available"));
        IMYTStrategy(address(localStrategy)).deallocate(abi.encode(directDealloc), 1e18, "", address(vault));

        // once finalized, plain deallocate self-serves the claim
        MockWithdrawRequestNFT(payable(env.withdrawRequestNFT())).finalizeRequests(tokenId);
        vm.prank(vault);
        IMYTStrategy(address(localStrategy)).deallocate(abi.encode(directDealloc), 1e18, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(address(localStrategy)), 1e18, "auto-claimed exit should fund deallocation");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be settled");
    }

    function test_async_invalidated_exit_can_be_removed() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.prank(address(1));
        (uint256 tokenId, uint96 shares) = localStrategy.requestExits(1e18);

        // removing a still-valid exit must fail
        vm.expectRevert(abi.encodeWithSelector(EtherfiEETHMYTStrategy.ExitStillValid.selector, tokenId));
        vm.prank(address(1));
        localStrategy.removeInvalidExit();

        MockWithdrawRequestNFT(payable(env.withdrawRequestNFT())).invalidateRequest(tokenId);

        uint256 valueWithInvalid = IMYTStrategy(address(localStrategy)).realAssets();

        vm.prank(address(1));
        localStrategy.removeInvalidExit();
        assertEq(localStrategy.pendingExitCount(), 0, "invalid exit should be removed");
        // Removal realizes the seized amount: pending value (shares minus haircut) stops counting.
        uint256 pendingValueAtRemoval = (uint256(shares) * (10_000 - localStrategy.pendingHaircutBps())) / 10_000;
        assertApproxEqRel(
            IMYTStrategy(address(localStrategy)).realAssets() + pendingValueAtRemoval,
            valueWithInvalid,
            1e15,
            "removal should realize exactly the seized pending value"
        );
    }

    function test_async_value_continuity_across_finalize_boundary() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 10e18);

        vm.prank(address(1));
        (uint256 tokenId,) = localStrategy.requestExits(4e18);

        uint256 before = IMYTStrategy(address(localStrategy)).realAssets();
        MockWithdrawRequestNFT(payable(env.withdrawRequestNFT())).finalizeRequests(tokenId);
        uint256 afterFinalize = IMYTStrategy(address(localStrategy)).realAssets();

        // haircut-discounted -> exact claimable: value can only recover
        assertGe(afterFinalize + 1, before, "finalization should not reduce value");

        localStrategy.claimExits();
        uint256 afterClaim = IMYTStrategy(address(localStrategy)).realAssets();
        assertApproxEqRel(afterClaim, afterFinalize, 1e15, "claim should be value-neutral");
    }

    function test_rate_guard_trips_kill_switch_on_rate_drop() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 10e18);
        assertFalse(localStrategy.killSwitch(), "kill switch should start off");

        MockWeETH(payable(env.weETH())).setRate(0.5e18);

        // the observing allocation completes; the switch trips for future ones
        _mockAllocate(localStrategy, 1e18);
        assertTrue(localStrategy.killSwitch(), "kill switch should trip after rate crash");
        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector, address(localStrategy)));
        IMYTStrategy(address(localStrategy)).allocate(getDirectAllocateVaultParams(1e18), 1e18, "", address(vault));
        vm.stopPrank();

        // deallocate stays available
        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        vm.prank(vault);
        IMYTStrategy(address(localStrategy)).deallocate(abi.encode(directDealloc), 1e18, "", address(vault));
    }

    function test_rescue_blocks_protected_tokens() public {
        (EtherfiEETHMYTStrategy localStrategy, MockEtherfiEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.startPrank(address(1));
        address[] memory protected = new address[](3);
        protected[0] = WETH;
        protected[1] = env.weETH();
        protected[2] = env.withdrawRequestNFT();
        for (uint256 i = 0; i < protected.length; i++) {
            vm.expectRevert(bytes("Protected token"));
            localStrategy.rescueTokens(protected[i], address(0xBEEF), 1);
        }
        vm.stopPrank();
    }

    receive() external payable {}

    /// @dev Canonical-rate minimum weETH out for a WETH swap input (mirrors strategy math).
    function _canonicalMinWeEthOut(uint256 wethAmount) internal view returns (uint256) {
        uint256 minEEthOut = (wethAmount * (10_000 - strategyConfig.slippageBPS)) / 10_000;
        if (minEEthOut == 0) minEEthOut = 1;
        uint256 minWeEthOut = IWeETH(WEETH).getWeETHByeETH(minEEthOut);
        if (IWeETH(WEETH).getEETHByWeETH(minWeEthOut) < minEEthOut) minWeEthOut += 1;
        return minWeEthOut == 0 ? 1 : minWeEthOut;
    }

    function _maxWeEthIn(uint256 wethAmount) internal view returns (uint256) {
        uint256 maxWethIn = (wethAmount * 10_000 + (10_000 - strategyConfig.slippageBPS) - 1) / (10_000 - strategyConfig.slippageBPS);
        uint256 maxWeEthIn = IWeETH(WEETH).getWeETHByeETH(maxWethIn);
        if (IWeETH(WEETH).getEETHByWeETH(maxWeEthIn) < maxWethIn) maxWeEthIn += 1;
        return maxWeEthIn == 0 ? 1 : maxWeEthIn;
    }

    function _grossRedeemAmount(address manager, uint256 netAmount) internal view returns (uint256) {
        (, uint16 exitFeeInBps,) = _redemptionInfo(manager);
        return (netAmount * 10_000 + (10_000 - exitFeeInBps) - 1) / (10_000 - exitFeeInBps);
    }

    function _maxNetDirectDeallocate(address manager) internal view returns (uint256) {
        uint256 maxGrossDeallocate = _effectiveDeallocateAmount(type(uint256).max);
        (, uint16 exitFeeInBps,) = _redemptionInfo(manager);
        if (exitFeeInBps >= 10_000) return 0;
        return (maxGrossDeallocate * (10_000 - exitFeeInBps)) / 10_000;
    }

    function _redemptionInfo(address manager) internal view returns (uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl) {
        (, exitFeeSplitToTreasuryInBps, exitFeeInBps, lowWatermarkInBpsOfTvl) = IRedemptionManagerView(manager).tokenToRedemptionInfo(ETH);
    }

    function _swapCallDataForWethOut(uint256 wethOut) internal view returns (bytes memory) {
        uint256 idleBalance = IERC20(WETH).balanceOf(strategy);
        uint256 shortfall = wethOut > idleBalance ? wethOut - idleBalance : 0;
        if (shortfall == 0) {
            return abi.encodeCall(MockSwapper.swap, (WEETH, WETH, 0, 0));
        }
        uint256 weETHBalance = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(shortfall);
        if (weETHToSwap > weETHBalance) weETHToSwap = weETHBalance;
        if (weETHToSwap == 0 && weETHBalance > 0) weETHToSwap = 1;
        return abi.encodeCall(MockSwapper.swap, (WEETH, WETH, weETHToSwap, shortfall));
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 maxEETH = IWeETH(WEETH).getEETHByWeETH(IWeETH(WEETH).balanceOf(strategy));
        if (maxEETH == 0) return 0;
        // deallocate() requires totalValueAfter >= assets; cap at half the position
        uint256 maxSafe = maxEETH / 2;
        if (maxSafe == 0) return 0;
        uint256 capped = requestedAssets < maxSafe ? requestedAssets : maxSafe;
        uint256 minAssetForOneWeETH = IWeETH(WEETH).getEETHByWeETH(1);
        if (capped < minAssetForOneWeETH && minAssetForOneWeETH <= maxSafe) {
            return minAssetForOneWeETH;
        }
        return capped;
    }

    function _allocateMultipleTimes(uint256[] memory rawAmounts) internal {
        uint256 iterations = bound(rawAmounts.length, 2, 10);
        bytes memory allocParams = getAllocateVaultParams(0);
        uint256 lastRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 successfulAllocs = 0;
        uint256 minAllocUnit = 1e16;

        vm.startPrank(vault);
        for (uint256 i = 0; i < iterations; i++) {
            (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
            if (maxAlloc < minAllocUnit) break;

            uint256 remainingIterations = iterations - i;
            uint256 maxPerIteration = maxAlloc / remainingIterations;
            if (maxPerIteration < minAllocUnit) break;

            uint256 seed = rawAmounts.length == 0 ? uint256(keccak256(abi.encode(i))) : rawAmounts[i % rawAmounts.length];
            uint256 amount = bound(seed, minAlloc, maxPerIteration);
            deal(WETH, strategy, amount);
            IMYTStrategy(strategy).allocate(allocParams, amount, "", address(vault));

            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            assertGe(currentRealAssets, lastRealAssets, "Real assets should not decrease after allocation");
            lastRealAssets = currentRealAssets;
            successfulAllocs++;
        }
        vm.stopPrank();

        assertGt(successfulAllocs, 1, "Expected multiple successful allocations");
        assertGt(IMYTStrategy(strategy).realAssets(), 0, "Final real assets should be positive");
    }

    function test_fuzz_allocate_multiple_times(uint256[] memory rawAmounts) public {
        _allocateMultipleTimes(rawAmounts);
    }

    function test_fuzz_deallocate_direct_uses_instant_redeem_path_can_redeem(uint256[] memory rawAllocateAmounts, uint256 rawDeallocateAmount) public {
        _allocateMultipleTimes(rawAllocateAmounts);

        uint256 maxDeallocate = _maxNetDirectDeallocate(REDEMPTION_MANAGER);
        require(maxDeallocate > 0, "max dealloc is zero");

        uint256 deallocateAmount = bound(rawDeallocateAmount, 1, maxDeallocate);
        uint256 grossRedeemAmount = _grossRedeemAmount(REDEMPTION_MANAGER, deallocateAmount);
        if (!IRedemptionManagerView(REDEMPTION_MANAGER).canRedeem(grossRedeemAmount, ETH)) return;

        IMYTStrategy.VaultAdapterParams memory directDealloc;
        directDealloc.action = IMYTStrategy.ActionType.direct;
        bytes memory deallocParams = abi.encode(directDealloc);
        vm.startPrank(vault);
        try IMYTStrategy(strategy).deallocate(deallocParams, deallocateAmount, "", address(vault)) {
            vm.stopPrank();
            assertGe(IERC20(WETH).balanceOf(strategy), deallocateAmount, "instant legs should cover deallocation");
        } catch (bytes memory errData) {
            vm.stopPrank();
            // Only tolerated failure: the closed-form bound overshoots instant capacity
            // by fee/rounding dust. Anything else is a real regression.
            require(errorStringEquals(errData, "Insufficient WETH available"), "unexpected deallocate revert");
        }
    }

    function getDirectAllocateVaultParams(uint256) internal view virtual returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function test_allocator_deallocate_max_preview_from_total_value(uint256 amountToAllocate) public {
        amountToAllocate = bound(amountToAllocate, 1e18, 100e18);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amountToAllocate);

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 targetDeallocate = _effectiveDeallocateAmount(realAssetsBefore);
        require(targetDeallocate > 0, "target deallocate is zero");

        uint256 previewedDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDeallocate);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");
        assertLe(previewedDeallocate, targetDeallocate, "previewed amount should not exceed target");

        uint256 weETHBalanceBefore = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(previewedDeallocate);
        assertLe(weETHToSwap, weETHBalanceBefore, "previewed deallocation should be fundable by position");

        deal(WETH, address(swapper), previewedDeallocate);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        IAllocator(allocator).deallocateWithSwap(strategy, previewedDeallocate, _swapCallDataForWethOut(previewedDeallocate));
        vm.stopPrank();

        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 leftoverWeth = IERC20(WETH).balanceOf(strategy);
        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 expectedRemaining = realAssetsBefore > previewedDeallocate ? realAssetsBefore - previewedDeallocate : 0;

        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWeETH(WEETH).balanceOf(strategy), weETHBalanceBefore, "weETH balance should decrease after deallocation");
        assertLe(realAssetsAfter, expectedRemaining + maxResidual, "remaining strategy balance should stay near expected residual");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
    }

    function test_fuzz_allocator_deallocate_with_swap(uint256 amountToAllocate, uint256 rawDeallocateAmount) public {
        amountToAllocate = bound(amountToAllocate, 1e18, 100e18);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(strategy, amountToAllocate);

        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsBefore, 0, "real assets should be positive after allocation");

        uint256 maxDeallocate = _effectiveDeallocateAmount(realAssetsBefore);
        require(maxDeallocate >= 1e16, "max deallocate too small");
        uint256 deallocateAmount = bound(rawDeallocateAmount, 1e16, maxDeallocate);
        uint256 previewedDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocateAmount);
        assertGt(previewedDeallocate, 0, "previewed deallocation should be positive");
        assertLe(previewedDeallocate, deallocateAmount, "previewed amount should not exceed target");

        uint256 weETHBalanceBefore = IWeETH(WEETH).balanceOf(strategy);
        uint256 weETHToSwap = _maxWeEthIn(previewedDeallocate);
        assertLe(weETHToSwap, weETHBalanceBefore, "previewed deallocation should be fundable by position");

        deal(WETH, address(swapper), previewedDeallocate);

        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);

        IAllocator(allocator).deallocateWithSwap(strategy, previewedDeallocate, _swapCallDataForWethOut(previewedDeallocate));
        vm.stopPrank();

        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 leftoverWeth = IERC20(WETH).balanceOf(strategy);
        uint256 maxResidual = (realAssetsBefore * TEST_RESIDUAL_TOLERANCE_BPS) / 10_000 + 1e18;
        uint256 expectedRemaining = realAssetsBefore > previewedDeallocate ? realAssetsBefore - previewedDeallocate : 0;

        assertLt(allocationAfter, allocationBefore, "allocator deallocation should reduce vault allocation");
        assertLt(IWeETH(WEETH).balanceOf(strategy), weETHBalanceBefore, "weETH balance should decrease after deallocation");
        assertLe(realAssetsAfter, expectedRemaining + maxResidual, "remaining strategy balance should stay near expected residual");
        assertLe(leftoverWeth, maxResidual, "leftover idle WETH should stay within slippage tolerance");
    }
}

interface IRedemptionManagerView {
    struct RedemptionLimit {
        uint64 capacity;
        uint64 remaining;
        uint64 lastRefill;
        uint64 refillRate;
    }

    function canRedeem(uint256 amount, address token) external view returns (bool);
    function tokenToRedemptionInfo(address token)
        external
        view
        returns (RedemptionLimit memory limit, uint16 exitFeeSplitToTreasuryInBps, uint16 exitFeeInBps, uint16 lowWatermarkInBpsOfTvl);
}

/// @notice E2E invariant suite against the real Ether.fi protocol on a pinned mainnet fork.
contract EtherfiEETHInvariantTest is E2EInvariantStrategyTest {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    /// @dev Holds WITHDRAW_REQUEST_NFT_ADMIN_ROLE at the fork block.
    address public constant ETHERFI_WITHDRAW_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    function getRpcUrl() internal override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24_595_012;
    }

    function getAsset() internal pure override returns (address) {
        return WETH;
    }

    function getRealStrategyParams() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(0),
            name: "Ether.fi Mainnet weETH",
            protocol: "Ether.fi",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 5000e18,
            globalCap: 0.3e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 125
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new EtherfiEETHMYTStrategy(vault_, params, EETH, WEETH, DEPOSIT_ADAPTER, REDEMPTION_MANAGER));
    }

    /// @dev Requires instant-redemption capacity invisible to the handler's static bounds.
    function _realStrategySupportsForceDeallocate() internal pure override returns (bool) {
        return false;
    }

    /// @dev Burn weETH worth `amount` (asset-denominated) to simulate a value loss.
    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 balance = IWeETH(WEETH).balanceOf(strategy);
        if (balance == 0) return;
        uint256 shares = IWeETH(WEETH).getWeETHByeETH(amount);
        if (shares > balance) shares = balance;
        vm.prank(strategy);
        IERC20(WEETH).transfer(address(0xdead), shares);
    }

    function _realStrategySupportsAsyncExit() internal pure override returns (bool) {
        return true;
    }

    /// @dev Simulates Ether.fi operators finalizing the request and funding the payout.
    /// @dev Simulates Ether.fi operators: finalize the request and re-earmark LP liquidity
    ///      (`ethAmountLockedForWithdrawal` is consumed by every claim and never refilled
    ///      on the static fork). The LP pays claims from its own ETH balance.
    function onBeforeAsyncClaim(address strategy) external override {
        uint256 tokenId = EtherfiEETHMYTStrategy(payable(strategy)).pendingExit().tokenId;
        IE2ERedemptionManager rm = IE2ERedemptionManager(REDEMPTION_MANAGER);
        IE2ELiquidityPool lp = IE2ELiquidityPool(rm.liquidityPool());
        IE2EWithdrawRequestNFT wrn = IE2EWithdrawRequestNFT(lp.withdrawRequestNFT());
        if (!wrn.isFinalized(tokenId)) {
            vm.prank(ETHERFI_WITHDRAW_ADMIN);
            wrn.finalizeRequests(tokenId);
        }
        uint256 claimable = wrn.getClaimableAmount(tokenId);
        vm.prank(ETHERFI_WITHDRAW_ADMIN);
        lp.addEthAmountLockedForWithdrawal(uint128(claimable + 1e18));
    }
}

interface IE2ERedemptionManager {
    function liquidityPool() external view returns (address);
}

interface IE2ELiquidityPool {
    function withdrawRequestNFT() external view returns (address);
    function addEthAmountLockedForWithdrawal(uint128) external;
}

interface IE2EWithdrawRequestNFT {
    function isFinalized(uint256) external view returns (bool);
    function finalizeRequests(uint256) external;
    function getClaimableAmount(uint256) external view returns (uint256);
}
