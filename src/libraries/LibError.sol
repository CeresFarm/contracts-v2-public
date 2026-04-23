// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Central registry of custom errors used across all Ceres contracts.
library LibError {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           COMMON                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error InvalidAction();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidInitiator();
    error InvalidReceiver();
    error InvalidToken();
    error InvalidValue();
    error NotImplemented();
    error PendingActionExists();
    error RoleManagerNotSet();
    error Unauthorized();
    error ZeroAddress();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           VAULT                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error AlreadyProcessed();
    error BelowMinimumDeposit();
    error ExceedsDepositLimit();
    error ExceedsRedeemLimit();
    error ExceededMaxLoss();
    error ExistingPendingRedeemRequest();
    error InsufficientAssets();
    error InsufficientAvailableAssets();
    error InsufficientShares();
    error NoRequestsToProcess();
    error PreviewRedeemDisabled();
    error PreviewWithdrawDisabled();
    error WithdrawalNotReady();
    error ZeroShares();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          SWAPPER                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error InvalidSwapConfig();
    error InvalidSwapSelector();
    error OffsetOutOfRange();
    error ScaledInputFailed();
    error SlippageLimitExceeded(uint256 expected, uint256 received);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          ORACLE                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error InvalidOracleRoute();
    error InvalidPrice();
    error OracleError();
    error ZeroOutputAmount();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     MARKETS / LEVERAGE                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error AboveMaxLtv();
    error InvalidLtv();
    error InvalidMarket();
    error KeeperDelayNotElapsed();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        FLASH LOAN                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error FlashLoanFailed();
    error InvalidFlashLoanProvider();
    error UnexpectedCallback();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     MULTI-STRATEGY VAULT                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error DuplicateStrategy();
    error ExceedsAllocationCap();
    error InvalidQueueLength();
    error MaxQueueLengthExceeded();
    error StrategyAlreadyActive();
    error StrategyAssetMismatch();
    error StrategyHasAllocation();
    error StrategyHasPendingRequest();
    error StrategyNotActive();
}
