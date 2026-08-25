// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {RevertContext, RevertSelectors} from "../base/StrategyTypes.sol";
import {E2EInvariantStrategyTest} from "../base/E2EInvariantStrategyTest.sol";
import {SFraxETHStrategy} from "../../strategies/SFraxETHStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {MockSwapper} from "../mocks/MockSwapper.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISfrxETHView {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

interface IRedemptionQueueView {
    function nftInformation(uint256 nftId) external view returns (bool hasBeenRedeemed, uint64 maturity, uint120 amount, uint64 earlyExitFee);
}

/// @notice Mock frxETH: mint/burn restricted to the minter and the redemption queue.
contract MockFrxETH is ERC20 {
    address public minter;
    address public redemptionQueue;

    constructor() ERC20("frxETH", "frxETH") {}

    function setPrivileged(address _minter, address _redemptionQueue) external {
        require(minter == address(0) && redemptionQueue == address(0), "already set");
        require(_minter != address(0) && _redemptionQueue != address(0), "zero address");
        minter = _minter;
        redemptionQueue = _redemptionQueue;
    }

    modifier onlyPrivileged() {
        require(msg.sender == minter || msg.sender == redemptionQueue, "only minter or queue");
        _;
    }

    function mint(address to, uint256 amount) external onlyPrivileged {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyPrivileged {
        _burn(from, amount);
    }
}

/// @notice Mock sfrxETH: share vault with a controllable rate and canonical 4626 rounding.
contract MockSfrxETH is ERC20 {
    uint256 public rate = 1.15e18; // frxETH per 1 sfrxETH share
    address public immutable frxETH;

    constructor(address _frxETH) ERC20("sfrxETH", "sfrxETH") {
        frxETH = _frxETH;
    }

    function setRate(uint256 newRate) external {
        require(newRate > 0, "zero rate");
        rate = newRate;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / rate;
    }

    /// @dev Pulls caller-approved frxETH and mints shares (rounds down).
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, "zero assets");
        IERC20(frxETH).transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / rate;
        require(shares > 0, "zero shares");
        _mint(receiver, shares);
    }

    /// @dev Burns msg.sender's shares and pays frxETH to `receiver` (rounds down).
    function redeem(uint256 shares, address receiver, address) external returns (uint256 assets) {
        require(shares > 0, "zero shares");
        assets = convertToAssets(shares);
        _burn(msg.sender, shares);
        IERC20(frxETH).transfer(receiver, assets);
    }
}

/// @notice Mock Frax minter: ETH in -> frxETH minted -> deposited for sfrxETH shares.
contract MockFraxMinter {
    address public immutable frxETH;
    address public immutable sfrxETH;

    constructor(address _frxETH, address _sfrxETH) {
        frxETH = _frxETH;
        sfrxETH = _sfrxETH;
    }

    function submitAndDeposit(address recipient) external payable returns (uint256 shares) {
        require(msg.value > 0, "zero value");
        MockFrxETH(frxETH).mint(address(this), msg.value);
        MockFrxETH(frxETH).approve(sfrxETH, msg.value);
        shares = MockSfrxETH(sfrxETH).deposit(msg.value, recipient);
        require(shares > 0, "no shares");
    }
}

/// @notice Mock FraxEtherRedemptionQueue mirroring the deployed queue's lifecycle and struct layout.
contract MockFraxEtherRedemptionQueue {
    struct RedemptionQueueItem {
        bool hasBeenRedeemed;
        uint64 maturity;
        uint120 amount;
        uint64 earlyExitFee;
    }

    address public immutable frxETH;
    address public immutable sfrxETH;
    uint256 public queueLengthSecs = 30 days;
    uint256 public nextNftId = 1;
    address public admin;

    mapping(uint256 => RedemptionQueueItem) public nftInformation;
    mapping(uint256 => address) public _ownerOf;

    event EnterRedemptionQueue(uint256 indexed nftId, address indexed sender, address indexed recipient, uint256 amountFrxEthRedeemed);
    event BurnRedemptionTicketNft(uint256 indexed nftId, address indexed sender, address indexed recipient, uint120 amountOut);

    constructor(address _frxETH, address _sfrxETH) {
        frxETH = _frxETH;
        sfrxETH = _sfrxETH;
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
    }

    /// @dev Stands in for the EtherRouter's ETH supply; funds future ticket payouts.
    function fund() external payable {}

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "RequestNotFound");
        return _ownerOf[tokenId];
    }

    /// @notice Mirrors enterRedemptionQueueViaSfrxEth: pull sfrxETH, redeem into this
    ///         queue (frxETH backing lands here), mint the ticket.
    function enterRedemptionQueueViaSfrxEth(address recipient, uint120 sfrxEthAmount) external returns (uint256 nftId) {
        require(sfrxEthAmount > 0, "zero amount");
        require(recipient != address(0), "zero recipient");
        IERC20(sfrxETH).transferFrom(msg.sender, address(this), sfrxEthAmount);

        uint256 frxEthAmount = MockSfrxETH(sfrxETH).convertToAssets(sfrxEthAmount);
        MockSfrxETH(sfrxETH).redeem(sfrxEthAmount, address(this), address(this));

        nftId = nextNftId++;
        nftInformation[nftId] =
            RedemptionQueueItem({hasBeenRedeemed: false, maturity: uint64(block.timestamp + queueLengthSecs), amount: uint120(frxEthAmount), earlyExitFee: 0});
        _ownerOf[nftId] = recipient;
        emit EnterRedemptionQueue(nftId, msg.sender, recipient, frxEthAmount);
    }

    /// @notice Mirrors burnRedemptionTicketNft: only the ticket owner, after maturity,
    ///         while the queue holds enough ETH. Burns the backing frxETH 1:1.
    function burnRedemptionTicketNft(uint256 nftId, address payable recipient) external {
        require(_ownerOf[nftId] == msg.sender, "Erc721CallerNotOwnerOrApproved");
        RedemptionQueueItem memory item = nftInformation[nftId];
        require(!item.hasBeenRedeemed && item.amount > 0, "already redeemed");
        require(block.timestamp >= item.maturity, "NotMatureYet");
        require(address(this).balance >= item.amount, "InvalidEthTransfer");

        delete _ownerOf[nftId];
        nftInformation[nftId].hasBeenRedeemed = true;
        MockFrxETH(frxETH).burnFrom(address(this), item.amount);

        (bool ok,) = recipient.call{value: item.amount}("");
        require(ok, "InvalidEthTransfer");
        emit BurnRedemptionTicketNft(nftId, msg.sender, recipient, item.amount);
    }

    receive() external payable {}
}

/// @notice Full-mock Frax environment: frxETH / sfrxETH / minter / redemption queue.
contract MockFraxEnvironment {
    MockFrxETH public immutable frxETH;
    MockSfrxETH public immutable sfrxETH;
    MockFraxMinter public immutable minter;
    MockFraxEtherRedemptionQueue public immutable redemptionQueue;

    constructor(address admin_, uint256 queueEthFunding) payable {
        frxETH = new MockFrxETH();
        sfrxETH = new MockSfrxETH(address(frxETH));
        redemptionQueue = new MockFraxEtherRedemptionQueue(address(frxETH), address(sfrxETH));
        minter = new MockFraxMinter(address(frxETH), address(sfrxETH));
        frxETH.setPrivileged(address(minter), address(redemptionQueue));
        redemptionQueue.transferAdmin(admin_);
        redemptionQueue.fund{value: queueEthFunding}();
    }
}

contract MockSFraxETHStrategy is SFraxETHStrategy {
    constructor(address _myt, IMYTStrategy.StrategyParams memory _params, address _minter, address _frxETH, address _sfrxETH, address _redemptionQueue)
        SFraxETHStrategy(_myt, _params, _minter, _frxETH, _sfrxETH, _redemptionQueue)
    {}
}

contract SFraxETHStrategyTest is BaseStrategyTest {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address public constant FRAX_MINTER_V2 = 0x7Bc6bad540453360F744666D625fec0ee1320cA3;
    address public constant FRAX_REDEMPTION_QUEUE = 0x82bA8da44Cd5261762e629dd5c605b17715727bd;

    /// @dev Instant-capacity exhaustion reverts are tolerated in fuzz/handler flows:
    ///      Frax has no protocol-native instant exit, so amounts parked in the queue
    ///      legitimately cannot be withdrawn synchronously.
    function isProtocolRevertAllowed(bytes4 selector, RevertContext context) external pure override returns (bool) {
        bool isFuzzOrHandler = context == RevertContext.HandlerAllocate || context == RevertContext.HandlerDeallocate || context == RevertContext.FuzzAllocate
            || context == RevertContext.FuzzDeallocate;
        if (!isFuzzOrHandler) return false;
        return selector == RevertSelectors.ERROR_STRING;
    }

    MockSwapper public swapper;
    MockFraxEnvironment public mockEnv;

    function setUp() public override {
        swapper = new MockSwapper();
        mockEnv = new MockFraxEnvironment{value: 50_000e18}(address(this), 20_000e18);
        super.setUp();

        vm.startPrank(admin);
        MYTStrategy(strategy).setAllowanceHolder(address(swapper));
        vm.stopPrank();

        // Only swap execution is mocked; protocol contracts are live mainnet.
        deal(WETH, address(swapper), 1_000_000e18);
        deal(FRXETH, address(swapper), 1_000_000e18);
    }

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "sfrxETH",
            protocol: "Frax",
            riskClass: IMYTStrategy.RiskClass.LOW,
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
        return address(new MockSFraxETHStrategy(vault_, params, FRAX_MINTER_V2, FRXETH, SFRXETH, FRAX_REDEMPTION_QUEUE));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24_595_012;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function getDeallocateVaultParams(uint256 assets) internal view override returns (bytes memory) {
        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: _swapCallDataForWethOut(assets), minIntermediateOut: _frxEthTarget(assets)});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: sp});
        return abi.encode(vp);
    }

    function _useAllocatorDeallocateUnwrapAndSwap() internal pure override returns (bool) {
        return true;
    }

    function _allocatorDeallocateSwapData(uint256 amount) internal view override returns (bytes memory) {
        return _swapCallDataForWethOut(amount);
    }

    function _allocatorDeallocateMinIntermediateOut(uint256 amount) internal view override returns (uint256) {
        return _frxEthTarget(amount);
    }

    function _assertDeallocateChange(int256 change, uint256 amountToDeallocate) internal view override {
        assertApproxEqRel(change, -int256(amountToDeallocate), 1e16);
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 positionAssets = IERC20(FRXETH).balanceOf(strategy) + ISfrxETHView(SFRXETH).convertToAssets(ISfrxETHView(SFRXETH).balanceOf(strategy));
        if (positionAssets == 0) return 0;
        // deallocate() requires totalValueAfter >= assets; cap at half the position
        uint256 maxSafe = positionAssets / 2;
        if (maxSafe == 0) return 0;
        return requestedAssets < maxSafe ? requestedAssets : maxSafe;
    }

    function test_rate_checkpoint_advances_on_allocation() public {
        vm.startPrank(vault);
        deal(WETH, strategy, 10e18);
        IMYTStrategy(strategy).allocate(getVaultParams(), 10e18, "", address(vault));
        vm.stopPrank();

        uint256 checkpoint = SFraxETHStrategy(payable(strategy)).rateCheckpoint();
        assertGt(checkpoint, 0, "checkpoint should be recorded");
        assertApproxEqRel(checkpoint, ISfrxETHView(SFRXETH).convertToAssets(1e18), 1e12, "checkpoint should track canonical rate");
    }

    /// @notice Oracle-free valuation: realAssets must equal idle + canonical share value exactly.
    function test_realAssets_matches_canonical_rate_fork() public {
        vm.startPrank(vault);
        deal(WETH, strategy, 25e18);
        IMYTStrategy(strategy).allocate(getVaultParams(), 25e18, "", address(vault));
        vm.stopPrank();

        uint256 expected = IERC20(FRXETH).balanceOf(strategy) + ISfrxETHView(SFRXETH).convertToAssets(ISfrxETHView(SFRXETH).balanceOf(strategy));
        assertEq(IMYTStrategy(strategy).realAssets(), expected, "realAssets should equal canonical valuation");
    }

    function test_allocate_swap_mock_success() public {
        uint256 amount = 10e18;
        uint256 minFrxEthOut = _canonicalMinFrxEthOut(amount);
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, FRXETH, amount, minFrxEthOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();

        assertGt(ISfrxETHView(SFRXETH).balanceOf(strategy), 0, "strategy should hold sfrxETH after swap allocation");
        assertEq(IERC20(FRXETH).balanceOf(strategy), 0, "strategy should not retain frxETH after deposit");
    }

    function test_allocate_swap_reverts_when_allowanceHolder_returns_less_than_minAmountOut() public {
        uint256 amount = 10e18;
        uint256 minFrxEthOut = _canonicalMinFrxEthOut(amount);
        require(minFrxEthOut > 1, "min output too small");
        uint256 insufficientOut = minFrxEthOut - 1;
        bytes memory callData = abi.encodeCall(MockSwapper.swap, (WETH, FRXETH, amount, insufficientOut));

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({txData: callData, minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: sp});

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, minFrxEthOut, insufficientOut));
        IMYTStrategy(strategy).allocate(abi.encode(vp), amount, "", address(vault));
        vm.stopPrank();
    }

    function test_deallocate_unwrapAndSwap_mock_success() public {
        uint256 amount = 10e18;

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(getVaultParams(), amount, "", address(vault));
        vm.stopPrank();

        uint256 deallocateAmount = _effectiveDeallocateAmount(amount);
        require(deallocateAmount > 0, "dealloc amount is zero");

        vm.startPrank(vault);
        IMYTStrategy(strategy).deallocate(getDeallocateVaultParams(deallocateAmount), deallocateAmount, "", address(vault));
        vm.stopPrank();

        assertGe(IERC20(WETH).balanceOf(strategy), deallocateAmount, "idle WETH should cover deallocation");
    }

    function test_deallocate_unwrapAndSwap_reverts_on_insufficient_swap_output() public {
        uint256 amount = 10e18;

        vm.startPrank(vault);
        deal(WETH, strategy, amount);
        IMYTStrategy(strategy).allocate(getVaultParams(), amount, "", address(vault));
        vm.stopPrank();

        uint256 deallocateAmount = _effectiveDeallocateAmount(amount);
        require(deallocateAmount > 1, "dealloc amount too small");
        uint256 insufficientOut = deallocateAmount - 1;

        IMYTStrategy.SwapParams memory sp = IMYTStrategy.SwapParams({
            txData: abi.encodeCall(MockSwapper.swap, (FRXETH, WETH, _frxEthTarget(deallocateAmount), insufficientOut)),
            minIntermediateOut: _frxEthTarget(deallocateAmount)
        });
        IMYTStrategy.VaultAdapterParams memory vp = IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: sp});

        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, deallocateAmount, insufficientOut));
        IMYTStrategy(strategy).deallocate(abi.encode(vp), deallocateAmount, "", address(vault));
        vm.stopPrank();
    }

    function _deployMockStrategy() internal returns (SFraxETHStrategy localStrategy, MockFraxEnvironment env) {
        env = mockEnv;
        localStrategy = new MockSFraxETHStrategy(
            vault, strategyConfig, address(env.minter()), address(env.frxETH()), address(env.sfrxETH()), address(env.redemptionQueue())
        );
    }

    function _mockAllocate(SFraxETHStrategy localStrategy, uint256 amount) internal {
        vm.startPrank(vault);
        deal(WETH, address(localStrategy), amount);
        IMYTStrategy(address(localStrategy)).allocate(getVaultParams(), amount, "", address(vault));
        vm.stopPrank();
    }

    function test_async_request_and_claim_full_lifecycle() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        uint256 valueBefore = IMYTStrategy(address(localStrategy)).realAssets();
        assertGt(valueBefore, 0, "real assets should be positive after allocation");

        vm.prank(address(1)); // owner
        uint256 tokenId = localStrategy.requestExits(5e18);
        assertEq(localStrategy.pendingExitCount(), 1, "one pending exit expected");
        assertEq(
            MockFraxEtherRedemptionQueue(payable(address(env.redemptionQueue()))).ownerOf(tokenId), address(localStrategy), "ticket should be held by strategy"
        );

        // pending claim valued at amount minus haircut: no phantom loss
        uint256 valuePending = IMYTStrategy(address(localStrategy)).realAssets();
        assertGe(valuePending + 1, (valueBefore * 99) / 100, "pending accounting should not create a phantom loss");

        // Preview excludes pending liquidity.
        uint256 preview = IMYTStrategy(address(localStrategy)).previewAdjustedWithdraw(type(uint256).max);
        assertLt(preview, valuePending, "preview should not count pending queue claims as instant");

        // Claiming before maturity reverts via the protocol.
        vm.expectRevert(bytes("NotMatureYet"));
        localStrategy.claimExits();

        (, uint64 maturity, uint120 amount,) = IRedemptionQueueView(address(env.redemptionQueue())).nftInformation(tokenId);
        vm.warp(uint256(maturity));
        assertEq(localStrategy.claimableExits(), amount, "claimable should equal ticket amount");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(localStrategy));
        localStrategy.claimExits(); // anyone can call
        assertEq(IERC20(WETH).balanceOf(address(localStrategy)), wethBefore + amount, "claimed ETH should become idle WETH");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be pruned");

        // Double-claim reverts: nothing pending anymore.
        vm.expectRevert(SFraxETHStrategy.NoPendingExit.selector);
        localStrategy.claimExits();
    }

    function test_async_request_requires_keeper_or_owner() public {
        (SFraxETHStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.expectRevert(abi.encodeWithSelector(SFraxETHStrategy.NotKeeper.selector, address(0xBEEF)));
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
        (SFraxETHStrategy localStrategy,) = _deployMockStrategy();
        vm.prank(address(1));
        vm.expectRevert(bytes("No sfrxETH available"));
        localStrategy.requestExits(1e18);
    }

    function test_async_claim_reverts_when_no_pending_exit() public {
        (SFraxETHStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.expectRevert(SFraxETHStrategy.NoPendingExit.selector);
        localStrategy.claimExits();
    }

    function test_async_request_reverts_while_exit_pending() public {
        (SFraxETHStrategy localStrategy,) = _deployMockStrategy();
        _mockAllocate(localStrategy, 100e18);

        vm.startPrank(address(1));
        uint256 tokenId = localStrategy.requestExits(1e18);
        vm.expectRevert(abi.encodeWithSelector(SFraxETHStrategy.ExitPending.selector, tokenId));
        localStrategy.requestExits(1e18);
        vm.stopPrank();
    }

    function test_async_request_auto_claims_stale_matured_exit() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        vm.prank(address(1));
        uint256 firstTokenId = localStrategy.requestExits(4e18);
        (, uint64 maturity,,) = IRedemptionQueueView(address(env.redemptionQueue())).nftInformation(firstTokenId);
        vm.warp(uint256(maturity));

        // stale matured claim is settled in the same tx as the new request
        uint256 wethBefore = IERC20(WETH).balanceOf(address(localStrategy));
        vm.prank(address(1));
        uint256 secondTokenId = localStrategy.requestExits(4e18);
        assertGt(IERC20(WETH).balanceOf(address(localStrategy)), wethBefore, "stale claim should be auto-settled");
        assertEq(localStrategy.pendingExitCount(), 1, "only the new exit should be pending");
        assertTrue(localStrategy.isPendingExit(secondTokenId), "new exit should be tracked");
        assertFalse(localStrategy.isPendingExit(firstTokenId), "old exit should be pruned");
    }

    function test_async_eth_shortage_at_maturity_is_tolerated_by_settle_but_loud_by_direct_claim() public {
        (SFraxETHStrategy localStrategy, MockFraxEtherRedemptionQueue queue) = _deployWithDrainableQueue(20e18);

        vm.prank(address(1));
        uint256 tokenId = localStrategy.requestExits(4e18);
        (, uint64 maturity,,) = IRedemptionQueueView(address(queue)).nftInformation(tokenId);
        vm.warp(uint256(maturity));

        // Drain the queue's ETH so the payout reverts with the queue's ETH-shortage error.
        vm.deal(address(queue), 0);

        // Auto-settle (inside requestExits) tolerates only this documented state and stays pending.
        vm.prank(address(1));
        vm.expectRevert(abi.encodeWithSelector(SFraxETHStrategy.ExitPending.selector, tokenId));
        localStrategy.requestExits(1e18);
        assertEq(localStrategy.pendingExitCount(), 1, "exit should remain pending under ETH shortage");

        // An explicit claim surfaces the protocol error loudly.
        vm.expectRevert(bytes("InvalidEthTransfer"));
        localStrategy.claimExits();
    }

    function test_deallocate_auto_claims_matured_exit() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 20e18);

        vm.prank(address(1));
        uint256 tokenId = localStrategy.requestExits(6e18);
        (, uint64 maturity,,) = IRedemptionQueueView(address(env.redemptionQueue())).nftInformation(tokenId);

        // While unmatured, direct deallocate beyond idle must revert: nothing instant available.
        vm.prank(vault);
        vm.expectRevert(bytes("Insufficient WETH available"));
        IMYTStrategy(address(localStrategy)).deallocate(getVaultParams(), 1e18, "", address(vault));

        // once matured, plain deallocate self-serves the claim
        vm.warp(uint256(maturity));
        vm.prank(vault);
        IMYTStrategy(address(localStrategy)).deallocate(getVaultParams(), 1e18, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(address(localStrategy)), 1e18, "auto-claimed exit should fund deallocation");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be settled");
    }

    function test_async_value_continuity_across_maturity_boundary() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 10e18);

        vm.prank(address(1));
        uint256 tokenId = localStrategy.requestExits(4e18);

        uint256 before = IMYTStrategy(address(localStrategy)).realAssets();
        (, uint64 maturity,,) = IRedemptionQueueView(address(env.redemptionQueue())).nftInformation(tokenId);
        vm.warp(uint256(maturity));
        uint256 afterMaturity = IMYTStrategy(address(localStrategy)).realAssets();

        // haircut-discounted -> exact claimable: value can only recover
        assertGe(afterMaturity + 1, before, "maturity should not reduce value");

        localStrategy.claimExits();
        uint256 afterClaim = IMYTStrategy(address(localStrategy)).realAssets();
        assertApproxEqRel(afterClaim, afterMaturity, 1e15, "claim should be value-neutral");
    }

    function test_rate_guard_trips_kill_switch_on_rate_drop() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 10e18);
        assertFalse(localStrategy.killSwitch(), "kill switch should start off");

        MockSfrxETH(address(env.sfrxETH())).setRate(0.5e18);

        // the observing allocation completes; the switch trips for future ones
        _mockAllocate(localStrategy, 1e18);
        assertTrue(localStrategy.killSwitch(), "kill switch should trip after rate crash");
        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector, address(localStrategy)));
        IMYTStrategy(address(localStrategy)).allocate(getVaultParams(), 1e18, "", address(vault));
        vm.stopPrank();

        // deallocate stays available (idle leg)
        deal(WETH, address(localStrategy), 1e18);
        vm.prank(vault);
        IMYTStrategy(address(localStrategy)).deallocate(getVaultParams(), 1e18, "", address(vault));
    }

    /// @notice Full async lifecycle against the live FraxEtherRedemptionQueue.
    function test_async_full_lifecycle_fork() public {
        SFraxETHStrategy localStrategy = SFraxETHStrategy(payable(strategy));
        _mockAllocate(localStrategy, 10e18);

        uint256 valueBefore = IMYTStrategy(strategy).realAssets();

        vm.prank(address(1));
        uint256 tokenId = localStrategy.requestExits(1e18);
        assertEq(localStrategy.pendingExitCount(), 1, "one pending exit expected");

        // value continuity: haircut only
        assertGe(IMYTStrategy(strategy).realAssets() + 1, (valueBefore * 99) / 100, "no phantom loss while queued");

        (, uint64 maturity, uint120 amount,) = IRedemptionQueueView(FRAX_REDEMPTION_QUEUE).nftInformation(tokenId);
        assertGt(amount, 0, "ticket should carry a claim");

        // Ensure the live queue can service this ticket (it may hold earlier liabilities).
        vm.deal(FRAX_REDEMPTION_QUEUE, address(FRAX_REDEMPTION_QUEUE).balance + uint256(amount) + 1e18);

        vm.warp(uint256(maturity));
        assertEq(localStrategy.claimableExits(), amount, "claimable should equal ticket amount");

        uint256 wethBefore = IERC20(WETH).balanceOf(strategy);
        vm.prank(address(0xBEEF)); // permissionless
        localStrategy.claimExits();
        assertEq(IERC20(WETH).balanceOf(strategy), wethBefore + amount, "claimed ETH should become idle WETH");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be pruned");
    }

    /// @notice A matured exit is auto-settled by the next deallocate on the live queue.
    function test_deallocate_auto_claims_matured_exit_fork() public {
        SFraxETHStrategy localStrategy = SFraxETHStrategy(payable(strategy));
        _mockAllocate(localStrategy, 10e18);

        vm.prank(address(1));
        uint256 tokenId = localStrategy.requestExits(1e18);
        (, uint64 maturity, uint120 amount,) = IRedemptionQueueView(FRAX_REDEMPTION_QUEUE).nftInformation(tokenId);

        // While unmatured there is no instant capacity: revert.
        vm.prank(vault);
        vm.expectRevert(bytes("Insufficient WETH available"));
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));

        vm.deal(FRAX_REDEMPTION_QUEUE, address(FRAX_REDEMPTION_QUEUE).balance + uint256(amount) + 1e18);
        vm.warp(uint256(maturity));

        vm.prank(vault);
        IMYTStrategy(strategy).deallocate(getVaultParams(), 1e18, "", address(vault));
        assertGe(IERC20(WETH).balanceOf(strategy), 1e18, "auto-claimed exit should fund deallocation");
        assertEq(localStrategy.pendingExitCount(), 0, "pending exit should be settled");
    }

    function test_rescue_blocks_protected_tokens() public {
        (SFraxETHStrategy localStrategy, MockFraxEnvironment env) = _deployMockStrategy();
        _mockAllocate(localStrategy, 5e18);

        vm.startPrank(address(1));
        address[4] memory protected = [WETH, address(env.frxETH()), address(env.sfrxETH()), address(env.redemptionQueue())];
        for (uint256 i = 0; i < protected.length; i++) {
            vm.expectRevert(bytes("Protected token"));
            localStrategy.rescueTokens(protected[i], address(0xBEEF), 1);
        }
        vm.stopPrank();
    }

    function _deployWithDrainableQueue(uint256 allocAmount) internal returns (SFraxETHStrategy localStrategy, MockFraxEtherRedemptionQueue queue) {
        MockFraxEnvironment env = mockEnv;
        localStrategy = new MockSFraxETHStrategy(
            vault, strategyConfig, address(env.minter()), address(env.frxETH()), address(env.sfrxETH()), address(env.redemptionQueue())
        );
        queue = MockFraxEtherRedemptionQueue(payable(address(env.redemptionQueue())));
        _mockAllocate(localStrategy, allocAmount);
    }

    /// @dev Canonical-rate minimum frxETH out for a WETH swap input (1:1 peg floor).
    function _canonicalMinFrxEthOut(uint256 wethAmount) internal view returns (uint256) {
        uint256 minFrxEthOut = (wethAmount * (10_000 - strategyConfig.slippageBPS)) / 10_000;
        return minFrxEthOut == 0 ? 1 : minFrxEthOut;
    }

    /// @dev Max frxETH input permitted by slippage math for a WETH shortfall.
    function _frxEthTarget(uint256 wethAmount) internal view returns (uint256) {
        uint256 idleBalance = IERC20(WETH).balanceOf(strategy);
        uint256 shortfall = wethAmount > idleBalance ? wethAmount - idleBalance : 0;
        if (shortfall == 0) return 0;
        uint256 target = (shortfall * 10_000 + (10_000 - strategyConfig.slippageBPS) - 1) / (10_000 - strategyConfig.slippageBPS);
        return target == 0 ? 1 : target;
    }

    function _swapCallDataForWethOut(uint256 wethOut) internal view returns (bytes memory) {
        uint256 frxEthAmount = _frxEthTarget(wethOut);
        if (frxEthAmount == 0) {
            return abi.encodeCall(MockSwapper.swap, (FRXETH, WETH, 0, 0));
        }
        uint256 shortfall = wethOut - IERC20(WETH).balanceOf(strategy);
        return abi.encodeCall(MockSwapper.swap, (FRXETH, WETH, frxEthAmount, shortfall));
    }
}

/// @notice E2E invariant suite against the real Frax sfrxETH stack on a pinned mainnet fork.
contract SFraxETHInvariantTest is E2EInvariantStrategyTest {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address public constant FRAX_MINTER_V2 = 0x7Bc6bad540453360F744666D625fec0ee1320cA3;
    address public constant FRAX_REDEMPTION_QUEUE = 0x82bA8da44Cd5261762e629dd5c605b17715727bd;

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
            name: "sfrxETH Mainnet",
            protocol: "Frax",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 5000e18,
            globalCap: 1e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new SFraxETHStrategy(vault_, params, FRAX_MINTER_V2, FRXETH, SFRXETH, FRAX_REDEMPTION_QUEUE));
    }

    /// @dev Serves idle WETH only until queue exits are claimed; invisible to the handler's static bounds.
    function _realStrategySupportsForceDeallocate() internal pure override returns (bool) {
        return false;
    }

    /// @dev Burn sfrxETH shares worth `amount` (asset-denominated) to simulate a value loss.
    function onSimulateValueLoss(address strategy, uint256 amount) external override {
        uint256 balance = ISfrxETHView(SFRXETH).balanceOf(strategy);
        if (balance == 0) return;
        uint256 shares = ISfrxETHView(SFRXETH).previewWithdraw(amount);
        if (shares > balance) shares = balance;
        vm.prank(strategy);
        IERC20(SFRXETH).transfer(address(0xdead), shares);
    }

    function _realStrategySupportsAsyncExit() internal pure override returns (bool) {
        return true;
    }

    /// @dev Simulates the redemption queue being funded for the matured ticket.
    function onBeforeAsyncClaim(address strategy) external override {
        uint256 tokenId = SFraxETHStrategy(payable(strategy)).pendingExit().tokenId;
        (bool hasBeenRedeemed, uint64 maturity, uint120 amount,) = IRedemptionQueueView(FRAX_REDEMPTION_QUEUE).nftInformation(tokenId);
        if (hasBeenRedeemed || block.timestamp < maturity) return;
        vm.deal(FRAX_REDEMPTION_QUEUE, address(FRAX_REDEMPTION_QUEUE).balance + uint256(amount) + 1e18);
    }
}
