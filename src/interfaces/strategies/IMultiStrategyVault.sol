// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICeresBaseVault} from "./ICeresBaseVault.sol";

interface IMultiStrategyVault is ICeresBaseVault {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STRUCTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    struct StrategyConfig {
        uint128 allocationCap; // Max assets that can be allocated to this strategy
        uint128 currentDebt; // Current assets allocated to this strategy
        uint64 activatedAt; // Timestamp when strategy was added (0 = inactive)
        uint64 lastReport; // Timestamp of last report
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         EVENTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyAllocationCapUpdated(address indexed strategy, uint128 newCap);
    event FundsAllocated(address indexed strategy, uint256 assets, uint256 sharesReceived);
    event DeallocateRequested(address indexed strategy, uint256 shares, uint256 requestId);
    event FundsClaimed(address indexed strategy, uint256 assets, uint256 sharesBurned);
    event StrategyReportedFromVault(address indexed strategy, uint256 previousDebt, uint256 newDebt);
    event SupplyQueueUpdated(address[] newQueue);
    event WithdrawQueueUpdated(address[] newQueue);
    event VaultReported(uint256 prevTotalAssets, uint256 newTotalAssets);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function totalDebt() external view returns (uint256);
    function getStrategyConfig(address strategy) external view returns (StrategyConfig memory);
    function getSupplyQueue() external view returns (address[] memory);
    function getWithdrawQueue() external view returns (address[] memory);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          STRATEGY MANAGEMENT (MANAGEMENT_ROLE)                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function addStrategy(address strategy) external;
    function removeStrategy(address strategy) external;
    function setAllocationCap(address strategy, uint128 newCap) external;
    function setSupplyQueue(address[] calldata newQueue) external;
    function setWithdrawQueue(address[] calldata newQueue) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          FUND ALLOCATION (CURATOR_ROLE)                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function allocate(address strategy, uint256 assets) external;
    function requestDeallocate(address strategy, uint256 shares) external returns (uint256 requestId);
    function claimDeallocated(address strategy) external returns (uint256 assets);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          REPORTING (KEEPER_ROLE)                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function reportStrategy(address strategy) external;
}
