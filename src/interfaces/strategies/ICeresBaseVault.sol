// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

interface ICeresBaseVault is IERC4626 {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         EVENTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event RedeemRequest(
        address indexed controller,
        address indexed owner_,
        uint256 indexed requestId,
        address requester,
        uint256 shares
    );

    event RequestProcessed(uint256 indexed requestId, uint256 totalShares, uint256 pricePerShare);
    event StrategyReported(address indexed keeper, uint256 profit, uint256 loss, uint256 performanceFees);

    event ConfigUpdated();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STRUCTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    struct RequestDetails {
        uint128 totalShares;
        uint128 pricePerShare;
    }

    struct UserRedeemRequest {
        uint128 requestId;
        uint128 shares;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    STATE VARIABLES                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function requestDetails(uint256 requestId) external view returns (RequestDetails memory);
    function userRedeemRequests(address user) external view returns (UserRedeemRequest memory);

    function withdrawalReserve() external view returns (uint128);
    function currentRequestId() external view returns (uint128);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getDepositWithdrawLimits()
        external
        view
        returns (uint128 depositLimit, uint128 redeemLimitShares, uint128 minDepositAmount);

    function getConfig()
        external
        view
        returns (
            uint16 maxSlippageBps,
            uint16 performanceFeeBps,
            uint16 maxLossBps,
            uint48 lastReportTimestamp,
            address performanceFeeRecipient,
            address roleManager
        );

    function getStats() external view returns (int128 cumulativeNetProfit, int128 snapshotNetProfit);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              EXTERNAL FUNCTIONS: ERC7540                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function requestRedeem(uint256 shares, address controller, address owner_) external returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 claimableShares);

    function claimableRedeemRequest(address controller) external view returns (uint256 claimableShares);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS: STRATEGY OPERATIONS                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function processCurrentRequest(bytes calldata extraData) external;

    function harvestAndReport() external returns (uint256 profit, uint256 loss);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS: ADMIN FUNCTIONS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function updateConfig(
        uint16 _maxSlippageBps,
        uint16 _performanceFeeBps,
        uint16 _maxLossBps,
        address _performanceFeeRecipient
    ) external;

    function setDepositWithdrawLimits(uint128 _depositLimit, uint128 _redeemLimit, uint96 _minDepositAmount) external;
}
