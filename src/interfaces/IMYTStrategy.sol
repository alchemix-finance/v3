// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMYTStrategy {
    // Enums
    enum RiskClass {
        LOW,
        MEDIUM,
        HIGH
    }

    // Structs
    struct StrategyParams {
        address owner;
        string name;
        string protocol;
        RiskClass riskClass;
        uint256 cap;
        uint256 globalCap;
        uint256 estimatedYield;
        bool additionalIncentives;
        uint256 slippageBPS;
    }



    enum ActionType {
        direct,       // for wrap/unwrap
        swap,         // for dex swap
        unwrapAndSwap // for unwrap -> dex swap
    }

    struct VaultAdapterParams {
        ActionType action;
        SwapParams swapParams;
    }

    struct SwapParams {
        bytes txData;               // 0x swap calldata
        uint256 minIntermediateOut; // Minimum intermediate token out (e.g., stETH from unwrap)
    }                              // Only used for ActionType.unwrapAndSwap



    // Events
    event Allocate(uint256 indexed amount, address indexed strategy);
    event Deallocate(uint256 indexed amount, address indexed strategy);
    event DeallocateDex(uint256 indexed amount);
    event YieldUpdated(uint256 indexed yield);
    event RiskClassUpdated(RiskClass indexed class);
    event IncentivesUpdated(bool indexed enabled);
    event SlippageBPSUpdated(uint256 indexed newSlippageBPS);
    event MinAllocationOutBpsUpdated(uint256 indexed newMinAllocationOutBps);
    event Emergency(bool indexed isEmergency);
    event StrategyAllocationLoss(string message, uint256 amountRequested, uint256 actualAmountAllocated);
    event WithdrawToVault(uint256 indexed amount);
    event RewardsClaimed(address indexed token, uint256 indexed amount);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    // Errors
    error StrategyAllocationPaused(address strategy);
    error CounterfeitSettler(address);
    error ActionNotSupported();
    error ForceDeallocateSwapNotAllowed();
    error InvalidAmount(uint256 min, uint256 received);
    error InsufficientBalance(uint256 required, uint256 available);


    // Functions
    /// @dev wrapper function for the customizable _allocate counterpart
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender) external returns (bytes32[] memory strategyIds, int256 change);

    /// @dev wrapper function for the customizable _deallocate counterpart
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender) external returns (bytes32[] memory strategyIds, int256 change);

    /// @dev alternative withdraw/deallocate route using a 0x quote
    //function deallocateDex(bytes memory data, uint256 amount) external returns (bytes32[] memory strategyIds, int256 change);

    /// @dev override this function to handle strategies with withdrawal queue NFT
    function claimWithdrawalQueue(uint256 positionId) external returns (uint256);

    /// @notice withdraw any leftover assets back to the vault
    function withdrawToVault() external returns (uint256);

    /// @dev override this function to claim all available rewards from the respective
    /// protocol of this strategy
    function claimRewards(address token, bytes memory quote, uint256 minAmountOut) external returns (uint256);

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(RiskClass newClass) external;

    function setAdditionalIncentives(bool newValue) external;

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(bool val) external;

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield() external view returns (uint256);

    // Getter for params
    function params()
        external
        view
        returns (
            address owner,
            string memory name,
            string memory protocol,
            RiskClass riskClass,
            uint256 cap,
            uint256 globalCap,
            uint256 estimatedYield,
            bool additionalIncentives,
            uint256 slippageBPS
        );

    function getCap() external view returns (uint256);
    function getGlobalCap() external view returns (uint256);
    function realAssets() external view returns (uint256);
    function positionToken() external view returns (address);
    function intermediateToken() external view returns (address);
    function getIdData() external view returns (bytes memory);
    function ids() external view returns (bytes32[] memory);
    function adapterId() external view returns (bytes32);
    function previewAdjustedWithdraw(uint256 amount) external view returns (uint256);
}
