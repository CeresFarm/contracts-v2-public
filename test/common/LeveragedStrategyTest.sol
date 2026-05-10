// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {LeveragedStrategyBaseSetup} from "./LeveragedStrategyBaseSetup.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {console, console2} from "forge-std/Test.sol";

import {LeverageLib} from "../../src/libraries/LeverageLib.sol";

import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";
import {ICeresBaseVault} from "src/interfaces/strategies/ICeresBaseVault.sol";
import {LibError} from "src/libraries/LibError.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";

/// @title LeveragedStrategyTest
/// @notice Abstract test contract containing all common invariant tests for LeveragedStrategy implementations
/// @dev Protocol-specific test contracts should inherit from this AND their protocol's TestSetup
abstract contract LeveragedStrategyTest is LeveragedStrategyBaseSetup {
    using Math for uint256;
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         EVENTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Async withdrawal events
    event RedeemRequest(
        address indexed controller,
        address indexed owner_,
        uint256 indexed requestId,
        address requester,
        uint256 shares
    );

    event RequestProcessed(uint256 indexed requestId, uint256 totalShares, uint256 pricePerShare);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  SETUP VERIFICATION TESTS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_StorageLocationInvariant() public pure virtual {
        bytes32 storageLocation = keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedStrategy")) - 1)) &
            ~bytes32(uint256(0xff));
        assertEq(uint256(storageLocation), uint256(0xdf5835635f9c63f5038c3c39a3e8c20793eb241995cc033746644d7d39feeb00));
    }

    function test_InitialState() public view {
        assertTrue(address(0) != address(strategy), "Strategy should be deployed");
        assertEq(strategy.asset(), address(assetToken), "Asset mismatch");
        assertTrue(roleManager.hasRole(MANAGEMENT_ROLE, management), "management role missing");
        assertTrue(roleManager.hasRole(KEEPER_ROLE, keeper), "keeper role missing");

        // Leveraged strategy config
        assertEq(address(strategy.COLLATERAL_TOKEN()), address(assetToken), "COLLATERAL_TOKEN mismatch");
        assertEq(address(strategy.DEBT_TOKEN()), address(debtToken), "DEBT_TOKEN mismatch");
        assertEq(address(strategy.oracleAdapter()), address(oracleAdapter), "oracleAdapter mismatch");

        (
            bool isExactOutSwapEnabled,
            uint16 targetLtvBps,
            uint16 ltvBufferBps,
            address oracleAdapter_,
            address swapper_,

        ) = strategy.getLeveragedStrategyConfig();

        assertEq(oracleAdapter_, address(oracleAdapter), "oracle adapter mismatch");
        assertEq(swapper_, address(swapper), "swapper mismatch");
        assertEq(targetLtvBps, TARGET_LTV_BPS, "targetLtvBps mismatch");
        assertEq(ltvBufferBps, LTV_BUFFER_BPS, "ltvBufferBps mismatch");

        assertFalse(isExactOutSwapEnabled, "isExactOutSwapEnabled should be false");

        (uint128 depositLimit, uint128 redeemLimitShares, ) = strategy.getDepositWithdrawLimits();
        (uint16 maxSlippageBps, uint16 performanceFeeBps, , , address performanceFeeRecipient_, , ) = strategy
            .getConfig();
        assertEq(maxSlippageBps, MAX_SLIPPAGE_BPS, "maxSlippageBps mismatch");
        assertEq(depositLimit, DEPOSIT_LIMIT, "depositLimit mismatch");
        assertEq(redeemLimitShares, REDEEM_LIMIT_SHARES, "redeemLimitShares mismatch");

        // Base strategy config
        assertEq(performanceFeeRecipient_, feeReceiver, "feeReceiver mismatch");
        assertEq(performanceFeeBps, 1500, "performanceFee should be 1500 (15%)");
        assertEq(strategy.totalSupply(), 0, "totalSupply should be 0");
        assertEq(strategy.totalAssets(), 0, "totalAssets should be 0");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    DEPOSIT TESTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Deposit_Basic() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();

        _mintAndApprove(address(assetToken), user1, address(strategy), depositAmount);

        vm.prank(user1);
        uint256 shares = strategy.deposit(depositAmount, user1);

        assertEq(shares, depositAmount, "Shares should equal deposit for first deposit");
        assertEq(strategy.balanceOf(user1), shares, "User balance should match shares");

        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();
        assertEq(netAssets, depositAmount, "Net assets should match deposit");
        assertEq(totalCollateral, depositAmount, "Collateral should match deposit");
        assertEq(totalDebt, 0, "Debt should be 0");
    }

    function test_Deposit_Basic_MultipleUsers() public {
        uint256 deposit1 = DEFAULT_DEPOSIT();
        uint256 deposit2 = DEFAULT_DEPOSIT() * 2;

        uint256 shares1 = _setupUserDeposit(user1, deposit1);
        uint256 shares2 = _setupUserDeposit(user2, deposit2);

        assertEq(strategy.balanceOf(user1), shares1, "User1 shares mismatch");
        assertEq(strategy.balanceOf(user2), shares2, "User2 shares mismatch");
        assertEq(strategy.totalAssets(), deposit1 + deposit2, "Total assets mismatch");
    }

    function test_Deposit_AssetsDeployedAsCollateral() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 collateral = strategy.getCollateralAmount();
        assertEq(collateral, depositAmount, "Collateral should be deposited to protocol");
    }

    function testFuzz_Deposit(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e16, DEPOSIT_LIMIT);

        _mintAndApprove(address(assetToken), user1, address(strategy), depositAmount);

        vm.prank(user1);
        uint256 shares = strategy.deposit(depositAmount, user1);

        assertGt(shares, 0, "Should receive shares");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              ASYNC WITHDRAWAL TESTS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          PHASE 1: REQUEST REDEEM TESTS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test basic redeem request functionality
    function test_RequestRedeem_Basic() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        uint256 sharesToRedeem = shares / 2;
        uint256 initialStrategyBalance = strategy.balanceOf(address(strategy));

        // Request redemption
        vm.expectEmit(true, true, true, true);
        emit RedeemRequest(user1, user1, 1, user1, sharesToRedeem);

        uint256 requestId = _requestRedeemAs(user1, sharesToRedeem);

        // Verify request ID
        assertEq(requestId, 1, "First request should be requestId 1");

        // Verify shares transferred to strategy
        assertEq(
            strategy.balanceOf(address(strategy)),
            initialStrategyBalance + sharesToRedeem,
            "Shares should be transferred to strategy"
        );
        assertEq(strategy.balanceOf(user1), shares - sharesToRedeem, "User shares should decrease");

        // Verify user request state
        ICeresBaseVault.UserRedeemRequest memory userRequest = strategy.userRedeemRequests(user1);
        assertEq(userRequest.requestId, requestId, "User requestId should be set");
        assertEq(userRequest.shares, sharesToRedeem, "User shares should be recorded");

        // Verify request details
        ICeresBaseVault.RequestDetails memory details = strategy.requestDetails(requestId);
        assertEq(details.totalShares, sharesToRedeem, "Request totalShares should be updated");
        assertEq(details.pricePerShare, 0, "Request should not be processed yet");
    }

    /// @notice Test multiple users requesting in same batch
    function test_RequestRedeem_MultipleUsersInBatch() public {
        uint256 deposit1 = DEFAULT_DEPOSIT();
        uint256 deposit2 = DEFAULT_DEPOSIT() * 2;

        uint256 shares1 = _setupUserDeposit(user1, deposit1);
        uint256 shares2 = _setupUserDeposit(user2, deposit2);

        uint256 redeem1 = shares1 / 2;
        uint256 redeem2 = shares2 / 3;

        // Both users request in same batch (requestId 1)
        uint256 requestId1 = _requestRedeemAs(user1, redeem1);
        uint256 requestId2 = _requestRedeemAs(user2, redeem2);

        assertEq(requestId1, 1, "Should be requestId 1");
        assertEq(requestId1, requestId2, "Both should be in same requestId");

        // Verify batch total
        ICeresBaseVault.RequestDetails memory details = strategy.requestDetails(requestId1);
        assertEq(details.totalShares, redeem1 + redeem2, "Total shares should be sum of both requests");

        // Verify individual user states
        ICeresBaseVault.UserRedeemRequest memory user1Request = strategy.userRedeemRequests(user1);
        ICeresBaseVault.UserRedeemRequest memory user2Request = strategy.userRedeemRequests(user2);
        assertEq(user1Request.shares, redeem1, "User1 shares mismatch");
        assertEq(user2Request.shares, redeem2, "User2 shares mismatch");
    }

    /// @notice Test user requesting multiple times in same batch
    function test_RequestRedeem_IncrementalSameUser() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        uint256 firstRequest = shares / 4;
        uint256 secondRequest = shares / 4;

        // First request
        uint256 requestId1 = _requestRedeemAs(user1, firstRequest);

        // Second request (same batch)
        uint256 requestId2 = _requestRedeemAs(user1, secondRequest);

        assertEq(requestId1, requestId2, "Should be same requestId");

        // Verify cumulative shares
        ICeresBaseVault.UserRedeemRequest memory userRequest = strategy.userRedeemRequests(user1);
        assertEq(userRequest.shares, firstRequest + secondRequest, "Shares should accumulate");

        // Verify batch total
        ICeresBaseVault.RequestDetails memory details = strategy.requestDetails(requestId1);
        assertEq(details.totalShares, firstRequest + secondRequest, "Batch total should include both requests");
    }

    /// @notice Test reverting when user has existing pending request in different batch
    function testRevert_RequestRedeem_ExistingPendingRequest() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // Request in batch 0
        _requestRedeemAs(user1, shares / 4);

        // Process batch 0 (moves to batch 1)
        _processCurrentRequest();

        // Don't claim yet - user still has pending request in batch 0

        // Try to request in batch 1 (should fail because batch 0 not claimed)
        vm.expectRevert(LibError.ExistingPendingRedeemRequest.selector);
        _requestRedeemAs(user1, shares / 4);
    }

    /// @notice Test reverting when requesting more shares than owned
    function testRevert_RequestRedeem_InsufficientShares() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        vm.expectRevert();
        _requestRedeemAs(user1, shares * 2);
    }

    /// @notice Test reverting when requesting zero shares
    function testRevert_RequestRedeem_ZeroShares() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        vm.expectRevert(LibError.ZeroShares.selector);
        _requestRedeemAs(user1, 0);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                        PHASE 2: PROCESS REQUEST TESTS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test processing request sets pricePerShare
    function test_ProcessRequest_SetsPricePerShare() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        uint256 requestId = _requestRedeemAs(user1, shares / 2);

        // Before processing
        uint128 pricePerShareBefore = strategy.requestDetails(requestId).pricePerShare;
        assertEq(pricePerShareBefore, 0, "Price per share should be 0 before processing");

        // Process
        vm.expectEmit(true, false, false, false);
        emit RequestProcessed(requestId, 0, 0); // We'll check actual values separately
        _processCurrentRequest();

        // After processing
        uint128 pricePerShareAfter = strategy.requestDetails(requestId).pricePerShare;
        assertGt(pricePerShareAfter, 0, "Price per share should be set after processing");
    }

    /// @notice Test processing with idle funds (no deleverage needed)
    function test_ProcessRequest_WithIdleFunds() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 shares = strategy.balanceOf(user1);
        uint256 sharesToRedeem = shares / 4; // Only 25%, plenty of idle funds

        uint256 requestId = _requestRedeemAs(user1, sharesToRedeem);

        uint128 reserveBefore = strategy.withdrawalReserve();

        // Process (should use idle funds)
        _processCurrentRequest();

        uint128 reserveAfter = strategy.withdrawalReserve();

        // Verify withdrawal reserve increased
        assertGt(reserveAfter, reserveBefore, "Withdrawal reserve should increase");

        // Verify requestId incremented
        assertEq(strategy.currentRequestId(), requestId + 1, "Current requestId should increment");
    }

    /// @notice Test processing requires freeing funds (deleverage)
    function test_ProcessRequest_RequiresFreeFunds() public {
        // Setup leveraged position
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 shares = strategy.balanceOf(user1);

        // Request all shares (will require deleveraging)
        uint256 requestId = _requestRedeemAs(user1, shares);

        (, , , , uint256 debtBefore, ) = strategy.getNetAssets();

        // Process (should trigger _freeFunds and deleveraging)
        _processCurrentRequest();

        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();

        // Verify debt reduced (deleveraged)
        assertLt(debtAfter, debtBefore, "Debt should decrease from deleveraging");

        // Verify request processed
        uint128 pricePerShare = strategy.requestDetails(requestId).pricePerShare;
        assertGt(pricePerShare, 0, "Request should be processed");
    }

    /// @notice Test processing increments currentRequestId
    function test_ProcessRequest_IncrementsRequestId() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        uint256 currentIdBefore = strategy.currentRequestId();

        _requestRedeemAs(user1, strategy.balanceOf(user1) / 2);
        _processCurrentRequest();

        uint256 currentIdAfter = strategy.currentRequestId();

        assertEq(currentIdAfter, currentIdBefore + 1, "CurrentRequestId should increment");
    }

    /// @notice Test processing multiple sequential requests
    function test_ProcessRequest_MultipleRequestsSequential() public {
        uint256 deposit = DEFAULT_DEPOSIT();

        // Batch 1
        uint256 shares1 = _setupUserDeposit(user1, deposit);
        uint256 requestAmount1 = shares1 / 4;
        uint256 requestId1 = _requestRedeemAs(user1, requestAmount1);
        _processCurrentRequest();

        // Batch 2
        uint256 shares2 = _setupUserDeposit(user2, deposit);
        uint256 requestAmount2 = shares2 / 3;
        uint256 requestId2 = _requestRedeemAs(user2, requestAmount2);
        _processCurrentRequest();

        // Batch 3
        uint256 shares3 = _setupUserDeposit(liquidityProvider, deposit);

        uint256 balanceOfUser1 = strategy.balanceOf(user1);
        console.log("balanceOfUser1:", balanceOfUser1);
        console.log("shares1:", shares1);

        // User1 new request should fail if an existing request is yet to be claimed
        vm.startPrank(user1);
        vm.expectRevert(LibError.ExistingPendingRedeemRequest.selector);
        strategy.requestRedeem(requestAmount1, user1, user1);
        vm.stopPrank();

        // Claim existing processed request for user1
        uint256 maxShares = strategy.maxRedeem(user1);
        console.log("maxShares:", maxShares);
        console.log("claimable shares", strategy.claimableRedeemRequest(requestId1, user1));

        vm.prank(user1);
        strategy.redeem(maxShares, user1, user1);

        uint256 requestId3 = _requestRedeemAs(liquidityProvider, shares3);
        _processCurrentRequest();

        // Redeem unclaimed requests
        _redeemAs(user2, requestAmount2);
        _redeemAs(liquidityProvider, shares3);

        // Verify all different
        assertEq(requestId1, 1, "First batch should be 0");
        assertEq(requestId2, 2, "Second batch should be 1");
        assertEq(requestId3, 3, "Third batch should be 2");

        // Verify all processed
        uint128 pps1 = strategy.requestDetails(requestId1).pricePerShare;
        uint128 pps2 = strategy.requestDetails(requestId2).pricePerShare;
        uint128 pps3 = strategy.requestDetails(requestId3).pricePerShare;

        assertGt(pps1, 0, "Batch 1 should be processed");
        assertGt(pps2, 0, "Batch 2 should be processed");
        assertGt(pps3, 0, "Batch 3 should be processed");
    }

    /// @notice Test reverting when trying to process already processed request
    function testRevert_ProcessRequest_NoRequestsToProcess() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        _requestRedeemAs(user1, strategy.balanceOf(user1) / 2);

        // Process existing request
        _processCurrentRequest();

        uint256 currentId = strategy.currentRequestId();
        console.log("Current request ID: ", currentId);

        ILeveragedStrategy.RequestDetails memory request = strategy.requestDetails(currentId);

        console.log("totalShares", request.totalShares);
        console.log("pps", request.pricePerShare);

        // Try to process new requestId without any deposits
        vm.expectRevert(LibError.NoRequestsToProcess.selector);
        vm.prank(keeper);
        strategy.processCurrentRequest("");
    }

    /// @notice Test only keeper can process requests
    function testRevert_ProcessRequest_OnlyKeeper() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        _requestRedeemAs(user1, strategy.balanceOf(user1) / 2);

        // Non-keeper tries to process
        vm.expectRevert();
        vm.prank(user1);
        strategy.processCurrentRequest("");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                        PHASE 3: COMPLETE REDEEM TESTS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test completing redeem after processing
    function test_CompleteRedeem_AfterProcessing() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        uint256 sharesToRedeem = shares / 2;

        // Request and process
        uint256 requestId = _requestRedeemAs(user1, sharesToRedeem);
        console.log("Request ID ", requestId);

        uint256 strategySharesBeforeProcess = strategy.balanceOf(address(strategy));

        _processCurrentRequest();

        uint256 reserveBefore = strategy.withdrawalReserve();
        uint256 strategySharesAfterProcess = strategy.balanceOf(address(strategy));

        // Verify shares were correctly burned from strategy during processing, not during redeem
        assertEq(
            strategySharesAfterProcess,
            strategySharesBeforeProcess - sharesToRedeem,
            "Shares should be burned from strategy during processing"
        );

        // Complete redeem
        uint256 assetsReceived = _redeemAs(user1, sharesToRedeem);

        // Verify assets received
        assertGt(assetsReceived, 0, "Should receive assets");
        assertApproxEqRel(assetsReceived, depositAmount / 2, 1e15, "Should receive ~half of deposit");

        assertEq(strategy.balanceOf(address(strategy)), 0, "Strategy should have 0 shares after processing and claim");

        // Verify withdrawal reserve decreased
        assertLt(strategy.withdrawalReserve(), reserveBefore, "Withdrawal reserve should decrease");

        // Verify user balance
        assertApproxEqRel(assetToken.balanceOf(user1), assetsReceived, 1e15, "User should have received assets");
    }

    /// @notice Test reverting when trying to redeem before processing
    function testRevert_CompleteRedeem_NotYetProcessed() public {
        uint256 shares = _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        // Request but don't process
        _requestRedeemAs(user1, shares / 2);

        // Try to redeem
        vm.expectRevert(LibError.WithdrawalNotReady.selector);
        _redeemAs(user1, shares / 2);
    }

    /// @notice Test reverting when trying to redeem more than processed
    function testRevert_CompleteRedeem_ExceedsProcessedAmount() public {
        uint256 shares = _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        uint256 requestedShares = shares / 2;

        // Request and process
        _requestRedeemAs(user1, requestedShares);
        _processCurrentRequest();

        // Try to redeem more than requested
        vm.expectRevert();
        _redeemAs(user1, requestedShares * 2);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                    CASE 2: VIEW FUNCTIONS & STATE TESTS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Traces all view functions through the full redemption lifecycle:
    ///         requested -> processed -> claimed
    function test_AsyncWithdrawal_ViewFunctions_Lifecycle() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);
        uint256 sharesToRedeem = shares / 2;

        // PHASE 1 — before request
        assertEq(strategy.maxRedeem(user1), 0, "maxRedeem: no request");
        assertEq(strategy.maxWithdraw(user1), 0, "maxWithdraw: no request");

        // PHASE 2 — after request, before processing
        uint256 requestId = _requestRedeemAs(user1, sharesToRedeem);
        assertEq(strategy.pendingRedeemRequest(requestId, user1), sharesToRedeem, "pending: before process");
        assertEq(strategy.claimableRedeemRequest(requestId, user1), 0, "claimable: before process");
        assertEq(strategy.maxRedeem(user1), 0, "maxRedeem: before process");
        assertEq(strategy.maxWithdraw(user1), 0, "maxWithdraw: before process");

        // PHASE 3 — after processing
        _processCurrentRequest();
        assertEq(strategy.pendingRedeemRequest(requestId, user1), 0, "pending: after process");
        assertEq(strategy.claimableRedeemRequest(requestId, user1), sharesToRedeem, "claimable: after process");
        assertEq(strategy.maxRedeem(user1), sharesToRedeem, "maxRedeem: after process");
        assertGt(strategy.maxWithdraw(user1), 0, "maxWithdraw: after process");
        assertApproxEqRel(strategy.maxWithdraw(user1), depositAmount / 2, 1e15, "maxWithdraw ~half of deposit");

        // PHASE 4 — after claiming
        _redeemAs(user1, sharesToRedeem);
        assertEq(strategy.claimableRedeemRequest(requestId, user1), 0, "claimable: after claim");
        assertEq(strategy.maxRedeem(user1), 0, "maxRedeem: after claim");
        assertEq(strategy.maxWithdraw(user1), 0, "maxWithdraw: after claim");
    }

    /// @notice Verifies view functions are correctly scoped per user in a shared batch
    function test_AsyncWithdrawal_ViewFunctions_MultiUser() public {
        uint256 shares1 = _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        uint256 shares2 = _setupUserDeposit(user2, DEFAULT_DEPOSIT() * 2);

        uint256 redeem1 = shares1 / 2;
        uint256 redeem2 = shares2 / 3;

        uint256 requestId = _requestRedeemAs(user1, redeem1);
        _requestRedeemAs(user2, redeem2); // same batch

        assertEq(strategy.pendingRedeemRequest(requestId, user1), redeem1, "User1 pending mismatch");
        assertEq(strategy.pendingRedeemRequest(requestId, user2), redeem2, "User2 pending mismatch");

        _processCurrentRequest();

        assertEq(strategy.maxRedeem(user1), redeem1, "User1 maxRedeem after process");
        assertEq(strategy.maxRedeem(user2), redeem2, "User2 maxRedeem after process");
    }

    /// @notice maxRedeem must respect the configured redeemLimitShares cap
    function test_MaxRedeem_RespectsRedeemLimitShares() public {
        uint256 shares = _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        uint256 sharesToRedeem = shares; // Request all

        _requestRedeemAs(user1, sharesToRedeem);

        // Set a redeem limit (e.g., half of shares)
        uint128 redeemLimit = uint128(shares / 2);

        vm.prank(management);
        strategy.setDepositWithdrawLimits(type(uint128).max, redeemLimit, 0);

        _processCurrentRequest();

        // maxRedeem should be limited by redeemLimitShares
        uint256 maxRedeemable = strategy.maxRedeem(user1);

        assertLe(maxRedeemable, redeemLimit, "Should be limited by redeemLimitShares");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          WITHDRAWAL RESERVE ACCOUNTING TESTS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test withdrawalReserve increases when request is processed
    function test_WithdrawalReserve_IncreasesOnProcess() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        uint128 reserveBefore = strategy.withdrawalReserve();

        _requestRedeemAs(user1, strategy.balanceOf(user1) / 2);
        _processCurrentRequest();

        uint128 reserveAfter = strategy.withdrawalReserve();

        assertGt(reserveAfter, reserveBefore, "Withdrawal reserve should increase");
    }

    /// @notice Test withdrawalReserve decreases when redemption is completed
    function test_WithdrawalReserve_DecreasesOnRedeem() public {
        uint256 shares = _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        uint256 sharesToRedeem = shares / 2;

        _requestRedeemAs(user1, sharesToRedeem);
        _processCurrentRequest();

        uint128 reserveBefore = strategy.withdrawalReserve();

        _redeemAs(user1, sharesToRedeem);

        uint128 reserveAfter = strategy.withdrawalReserve();

        assertLt(reserveAfter, reserveBefore, "Withdrawal reserve should decrease");
    }

    /// @notice Test withdrawalReserve with multiple outstanding processed requests
    function test_WithdrawalReserve_MultipleOutstanding() public {
        uint256 deposit = DEFAULT_DEPOSIT();

        // Batch 0: User1 requests
        uint256 shares1 = _setupUserDeposit(user1, deposit);
        _requestRedeemAs(user1, shares1 / 2);
        _processCurrentRequest();

        uint128 reserveAfter1 = strategy.withdrawalReserve();
        assertGt(reserveAfter1, 0, "Reserve should be non-zero after first batch");

        // Batch 1: User2 requests
        uint256 shares2 = _setupUserDeposit(user2, deposit);
        _requestRedeemAs(user2, shares2 / 3);
        _processCurrentRequest();

        uint128 reserveAfter2 = strategy.withdrawalReserve();
        assertGt(reserveAfter2, reserveAfter1, "Reserve should increase with second batch");

        // User1 claims - reserve should decrease but still > 0 (user2 hasn't claimed)
        _redeemAs(user1, shares1 / 2);

        uint128 reserveAfter3 = strategy.withdrawalReserve();
        assertLt(reserveAfter3, reserveAfter2, "Reserve should decrease after user1 claim");
        assertGt(reserveAfter3, 0, "Reserve should still be positive (user2 unclaimed)");

        // User2 claims - reserve should go to ~0
        _redeemAs(user2, shares2 / 3);

        uint128 reserveAfter4 = strategy.withdrawalReserve();
        assertLt(reserveAfter4, reserveAfter3, "Reserve should decrease after user2 claim");
    }

    /// @notice Test withdrawalReserve prevents double-use of funds
    function test_WithdrawalReserve_PreventsDoubleUse() public {
        uint256 deposit = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, deposit);

        // Request and process withdrawal
        _requestRedeemAs(user1, strategy.balanceOf(user1) / 2);
        _processCurrentRequest();

        uint128 reserve = strategy.withdrawalReserve();
        assertGt(reserve, 0, "Should have withdrawal reserve");

        // The idle assets available for new processing should exclude the reserve
        // This is tested implicitly: if we process another large request,
        // it should need to free funds even though there are "idle" assets in the contract
        uint256 shares2 = _setupUserDeposit(user2, deposit);
        _requestRedeemAs(user2, shares2);

        // This should succeed but may trigger _freeFunds if reserve reduces available idle assets
        _processCurrentRequest();

        // Both reserves should be properly tracked
        assertGt(strategy.withdrawalReserve(), reserve, "Reserve should account for both requests");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          MULTI-USER ASYNC SCENARIOS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test multiple users in same batch get same pricePerShare
    function test_MultiUser_SameBatch_SamePricePerShare() public {
        uint256 deposit1 = DEFAULT_DEPOSIT();
        uint256 deposit2 = DEFAULT_DEPOSIT() * 2;

        uint256 shares1 = _setupUserDeposit(user1, deposit1);
        uint256 shares2 = _setupUserDeposit(user2, deposit2);

        // Both request in same batch
        uint256 requestId = _requestRedeemAs(user1, shares1 / 2);
        _requestRedeemAs(user2, shares2 / 2);

        _processCurrentRequest();

        // Both should have same pricePerShare
        uint128 pricePerShare = strategy.requestDetails(requestId).pricePerShare;
        assertGt(pricePerShare, 0, "Price per share should be set");

        // User1 claims
        uint256 assets1 = _redeemAs(user1, shares1 / 2);

        // User2 claims later
        uint256 assets2 = _redeemAs(user2, shares2 / 2);

        // Both should get proportional assets based on same price
        assertApproxEqRel(assets1, deposit1 / 2, 1e15, "User1 should get ~half deposit");
        assertApproxEqRel(assets2, deposit2 / 2, 1e15, "User2 should get ~half deposit");
    }

    /// @notice Test user can request new batch after claiming previous
    function test_MultiUser_SequentialRequestsAfterClaim() public {
        uint256 deposit = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, deposit);

        // Batch 0: Request and complete
        uint256 requestId0 = _requestRedeemAs(user1, shares / 4);
        _processCurrentRequest();
        _redeemAs(user1, shares / 4);

        // Now user1 can request again (batch 2)
        uint256 requestId1 = _requestRedeemAs(user1, shares / 4);
        _processCurrentRequest();

        assertEq(requestId1, 2, "Should be batch 2");
        assertNotEq(requestId0, requestId1, "Should be different batches");

        // Should be able to claim batch 1
        uint256 assets = _redeemAs(user1, shares / 4);
        assertGt(assets, 0, "Should receive assets from batch 1");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          WITHDRAW (OLD BASIC TESTS - LEGACY)                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testFuzz_Withdraw(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1000 * 1e18, 100_000 * 1e18);
        withdrawPercent = bound(withdrawPercent, 10, 100);

        uint256 shares = _setupUserDeposit(user1, depositAmount);
        uint256 withdrawShares = (shares * withdrawPercent) / 100;

        // Full async flow
        _requestRedeemAs(user1, withdrawShares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, withdrawShares);

        assertGt(assets, 0, "Should receive assets");
        assertApproxEqRel(assets, (depositAmount * withdrawPercent) / 100, 1e16, "Should receive proportional assets");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  NET ASSETS TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_GetNetAssets_AfterDeposit() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();

        assertEq(netAssets, depositAmount, "Net assets should equal deposit");
        assertEq(totalCollateral, depositAmount, "Collateral should equal deposit");
        assertEq(totalDebt, 0, "Debt should be zero before leverage");
    }

    function test_GetNetAssets_AfterLeverage() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();

        assertApproxEqRel(netAssets, depositAmount, 1e15, "Net assets should be ~deposit");
        assertGt(totalCollateral, depositAmount, "Collateral should increase from leverage");
        assertApproxEqRel(totalDebt, debtAmount, 1e15, "Debt should be non-zero after leverage");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  REBALANCE TESTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Rebalance_LeverageUp() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

        uint256 collateralBefore = strategy.getCollateralAmount();

        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        uint256 collateralAfter = strategy.getCollateralAmount();
        uint256 debt = strategy.getDebtAmount();

        assertGt(collateralAfter, collateralBefore, "Collateral should increase");
        assertGt(debt, 0, "Should have debt");
    }

    function test_Rebalance_LeverageDown() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, , , , uint256 debtBefore, ) = strategy.getNetAssets();
        uint256 deleverageAmount = debtBefore / 2;

        _mintAndApprove(address(debtToken), keeper, address(strategy), deleverageAmount);

        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, false, "");

        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();

        assertLt(debtAfter, debtBefore, "Debt should decrease");
    }

    function test_Rebalance_LeverageUp_AchievesTargetLtv() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 newTargetLtv = 7500; // 75% — within every protocol's max LTV minus the 0.5% buffer

        // Get current state to calculate the delta
        (, uint256 currentNetAssets, , , uint256 currentDebt, ) = strategy.getNetAssets();

        // Calculate target debt for new LTV
        uint256 targetDebt = LeverageLib.computeTargetDebt(currentNetAssets, newTargetLtv, strategy.oracleAdapter());

        // Calculate ADDITIONAL debt needed (delta)
        uint256 additionalDebt = targetDebt - currentDebt;

        _mintAndApprove(address(debtToken), keeper, address(strategy), additionalDebt);

        vm.prank(keeper);
        strategy.rebalance(additionalDebt, true, false, "");

        uint256 actualLtv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());
        // Allow 0.1% tolerance
        assertApproxEqRel(actualLtv, newTargetLtv, 1e15, "LTV should be near target");
    }

    function test_Rebalance_ZeroDebt_NoOp() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        // Try to leverage down when there's no debt
        _mintAndApprove(address(debtToken), keeper, address(strategy), 1000 * 1e6);

        uint256 keeperBalance = debtToken.balanceOf(keeper);

        vm.prank(keeper);
        strategy.rebalance(1000 * 1e6, false, false, "");

        // Should not revert and debt should still be zero
        (, , , , uint256 totalDebt, ) = strategy.getNetAssets();
        assertEq(totalDebt, 0, "Debt should still be zero");
        assertEq(keeperBalance, debtToken.balanceOf(keeper), "keeper balance should be the same");
    }

    function test_Rebalance_EmitsEvent() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 debtAmount = 1000 * 1e6;
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Rebalance(keeper, debtAmount, true, false);
        strategy.rebalance(debtAmount, true, false, "");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                            FLASH LOAN REBALANCE TESTS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_RebalanceUsingFlashLoan_LeverageUp() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());

        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, true, "");

        assertGt(strategy.getDebtAmount(), 0, "Should have debt after flash loan leverage");
    }

    function test_RebalanceUsingFlashLoan_LeverageDown() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, , , , uint256 debtBefore, ) = strategy.getNetAssets();
        uint256 deleverageAmount = debtBefore / 2;

        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, true, "");

        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();
        assertLt(debtAfter, debtBefore, "Debt should decrease");
    }

    function test_RebalanceUsingFlashLoan_EmitsEvent() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 flashLoanAmount = 2000 * 1e6;

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Rebalance(keeper, flashLoanAmount, true, true);
        strategy.rebalance(flashLoanAmount, true, true, "");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          EXACT OUT SWAP CONFIGURATION TESTS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SetExactOutSwapEnabled_Success() public {
        // Initially should be false
        (bool isExactOutSwapEnabled, , , , , ) = strategy.getLeveragedStrategyConfig();
        assertFalse(isExactOutSwapEnabled, "isExactOutSwapEnabled should be false initially");

        // Enable exactOut swap
        vm.prank(management);
        vm.expectEmit(true, true, true, true);
        emit ILeveragedStrategy.SetExactOutSwapEnabled(true);
        strategy.setExactOutSwapEnabled(true);

        (isExactOutSwapEnabled, , , , , ) = strategy.getLeveragedStrategyConfig();
        assertTrue(isExactOutSwapEnabled, "isExactOutSwapEnabled should be true after setting");

        // Disable exactOut swap
        vm.prank(management);
        vm.expectEmit(true, true, true, true);
        emit ILeveragedStrategy.SetExactOutSwapEnabled(false);
        strategy.setExactOutSwapEnabled(false);

        (isExactOutSwapEnabled, , , , , ) = strategy.getLeveragedStrategyConfig();
        assertFalse(isExactOutSwapEnabled, "isExactOutSwapEnabled should be false after disabling");
    }

    function testRevert_SetExactOutSwapEnabled_NotManagement() public {
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.setExactOutSwapEnabled(true);
    }

    function test_LeverageDown_WithExactOutSwapEnabled() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        // Enable exactOut swap
        vm.prank(management);
        strategy.setExactOutSwapEnabled(true);

        (, , , , uint256 debtBefore, ) = strategy.getNetAssets();
        uint256 deleverageAmount = debtBefore / 2;

        uint256 strategyDebtBalanceBefore = debtToken.balanceOf(address(strategy));

        // Use flash loan to deleverage with exactOut swap enabled
        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, true, "");

        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();
        assertLt(debtAfter, debtBefore, "Debt should decrease");

        // With exactOut swap, the strategy should use swapTo which swaps to get exactly the required debt amount
        // Hence, the strategy should not have any extra debt token balance from dust
        uint256 strategyDebtBalanceAfter = debtToken.balanceOf(address(strategy));
        assertEq(strategyDebtBalanceBefore, strategyDebtBalanceAfter, "DebtBalance mismatch");
    }

    function test_LeverageDown_WithExactOutSwapDisabled() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        // Ensure exactOut swap is disabled (default state)
        (bool isExactOutSwapEnabled, , , , , ) = strategy.getLeveragedStrategyConfig();
        assertFalse(isExactOutSwapEnabled, "exactOut should be disabled by default");

        uint256 strategyDebtBalanceBefore = debtToken.balanceOf(address(strategy));

        (, , , , uint256 debtBefore, ) = strategy.getNetAssets();
        uint256 deleverageAmount = debtBefore / 2;

        // Use flash loan to deleverage with exactOut swap disabled
        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, true, "");

        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();
        assertLt(debtAfter, debtBefore, "Debt should decrease");

        // strategy should not have some dust debt token balance from exactIn swap
        uint256 strategyDebtBalanceAfter = debtToken.balanceOf(address(strategy));
        assertGt(strategyDebtBalanceAfter, strategyDebtBalanceBefore, "DebtBalance mismatch");
    }

    function test_FlashLoan_RepaymentWithInsufficientDebtTokens_LeverageDown() public {
        // Setup initial leveraged position
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        // Get current debt
        (, , , , uint256 currentDebt, ) = strategy.getNetAssets();
        uint256 deleverageAmount = currentDebt / 3;

        // Disable exactOut to use swapFrom which may have slippage
        (bool isExactOutSwapEnabled, , , , , ) = strategy.getLeveragedStrategyConfig();
        assertFalse(isExactOutSwapEnabled, "exactOut should be disabled");

        // Set higher slippage on swapper to simulate insufficient debt tokens after swap
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (300, 1500, MAX_LOSS_BPS, feeReceiver, uint32(1 days)))
        );

        swapper.setSlippage(310); // 3.1% slippage - will return less than expected

        uint256 debtBefore = strategy.getDebtAmount();

        // Execute deleverage - should handle insufficient tokens by borrowing the shortfall
        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, true, "");

        // The strategy should successfully complete despite slippage
        // Debt should still decrease overall even though we had to borrow for the shortfall
        uint256 debtAfter = strategy.getDebtAmount();
        assertLt(debtAfter, debtBefore, "Overall debt should still decrease");
        assertGt(debtAfter, debtBefore - deleverageAmount, "debtAfter should be more to cover foor shortfall");

        // Reset slippage
        swapper.setSlippage(0);
    }

    function test_FlashLoan_RepaymentWithSufficientDebtTokens() public {
        // Setup initial deposit
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        // No slippage - should have sufficient debt tokens
        swapper.setSlippage(0);

        uint256 flashLoanAmount = 3000 * 1e6;
        uint256 debtBalanceBefore = debtToken.balanceOf(address(strategy));

        vm.prank(keeper);
        strategy.rebalance(flashLoanAmount, true, true, "");

        // Verify successful flash loan repayment without needing to borrow additional
        uint256 debtAmount = strategy.getDebtAmount();
        assertGt(debtAmount, 0, "Should have debt after leverage");

        assertEq(
            debtToken.balanceOf(address(strategy)),
            debtBalanceBefore,
            "Strategy should not have extra debt tokens "
        );

        // The debt should be approximately equal to the flash loan amount (borrowed normally, not for shortfall)
        assertApproxEqRel(debtAmount, flashLoanAmount, 10e16, "Debt should match flash loan amount");
    }

    function test_FlashLoan_EdgeCase_ExactRepaymentAmount() public {
        // Test the edge case where debt token balance exactly matches repayment amount
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        // Use zero slippage to get exact amounts
        swapper.setSlippage(0);

        uint256 flashLoanAmount = 2000 * 1e6;

        vm.prank(keeper);
        strategy.rebalance(flashLoanAmount, true, true, "");

        // Should complete successfully without needing additional borrowing
        assertGt(strategy.getDebtAmount(), 0, "Should have debt after flash loan");
    }

    function test_FlashLoan_EdgeCase_VerySmallShortfall() public {
        // Test handling of very small shortfall (dust amounts)
        _setupUserDeposit(user1, LARGE_DEPOSIT());

        // Set minimal slippage to create a very small shortfall
        swapper.setSlippage(1); // 0.01% slippage

        uint256 flashLoanAmount = 10000 * 1e6;

        vm.prank(keeper);
        strategy.rebalance(flashLoanAmount, true, true, "");

        // Should handle even tiny shortfalls correctly
        assertGt(strategy.getDebtAmount(), 0, "Should have debt after flash loan");

        // Reset slippage
        swapper.setSlippage(0);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  LEVERAGE RATIO TESTS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_GetLeverage_AfterLeverageUp() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssets, , uint256 totalCollateral, , ) = strategy.getNetAssets();

        // Leverage = (Collateral / NetAssets)
        // Net assets is equivalent to Collateral - Debt
        // Convert to BPS: leverage * 10000
        uint256 collateralInAssets = oracleAdapter.convertCollateralToAssets(totalCollateral);
        uint256 leverage = collateralInAssets.mulDiv(BPS_PRECISION, netAssets, Math.Rounding.Ceil);

        // At 70% LTV, leverage should be approximately 3.33x (33333 BPS)
        assertGt(leverage, 33000, "Leverage should be greater than 3.3x");
        assertLt(leverage, 34000, "Leverage should be less than 3.4x");
    }

    function test_GetStrategyLtv_AfterLeverageUp() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 ltv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());

        // LTV should be near target
        assertApproxEqRel(ltv, TARGET_LTV_BPS, 10e16, "LTV should be near target");
    }

    function testFuzz_Leverage(uint256 depositAmount, uint16 ltvBps) public {
        depositAmount = bound(depositAmount, SMALL_DEPOSIT() / 10, LARGE_DEPOSIT() * 10);
        ltvBps = uint16(bound(ltvBps, 1000, 7000)); // 10% to 70%

        _setupUserDeposit(user1, depositAmount);

        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, ltvBps, strategy.oracleAdapter());

        if (debtAmount > 0) {
            _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

            vm.prank(keeper);
            strategy.rebalance(debtAmount, true, false, "");

            uint256 actualLtv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());
            assertApproxEqRel(actualLtv, ltvBps, 10e16, "LTV should be near target");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              PROFIT SCENARIO TESTS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testFuzz_PriceChange(int256 priceChangePercent) public {
        priceChangePercent = bound(priceChangePercent, -25, 50);

        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssetsBefore, , , , ) = strategy.getNetAssets();

        _simulatePriceChange(priceChangePercent);

        (, uint256 netAssetsAfter, , , , ) = strategy.getNetAssets();

        if (priceChangePercent > 0) {
            assertGt(netAssetsAfter, netAssetsBefore, "Should gain on price increase");
        } else if (priceChangePercent < 0) {
            assertLt(netAssetsAfter, netAssetsBefore, "Should lose on price decrease");
        }

        // Should still be solvent for reasonable price changes
        assertGt(netAssetsAfter, 0, "Should remain solvent");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               LOSS SCENARIO TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Loss_LeveragedLossesAmplified() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssetsBefore, , , , ) = strategy.getNetAssets();

        // Simulate 10% price decrease
        _simulatePriceChange(-10);

        (, uint256 netAssetsAfter, , , , ) = strategy.getNetAssets();

        uint256 lossPercent = ((netAssetsBefore - netAssetsAfter) * 100) / netAssetsBefore;

        // With 70% LTV (~3.33x leverage), 10% price drop should cause ~33% loss
        assertGt(lossPercent, 20, "Leveraged losses should exceed unleveraged");
        assertLt(lossPercent, 40, "Leveraged losses should exceed unleveraged");
    }

    function test_Loss_ApproachingLiquidation() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        // Simulate significant price drop (15%)
        _simulatePriceChange(-15);

        uint256 currentLtv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());

        // LTV should increase significantly due to price drop
        assertGt(currentLtv, TARGET_LTV_BPS, "LTV should increase after price drop");

        // Strategy should still have positive net assets (not liquidated)
        (, uint256 netAssets, , , , ) = strategy.getNetAssets();
        assertGt(netAssets, 0, "Should still have positive net assets");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  EDGE CASE TESTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_EdgeCase_OraclePriceVolatility() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        // Rapid price changes
        _simulatePriceChange(5);
        (, uint256 netAssets1, , , , ) = strategy.getNetAssets();

        _simulatePriceChange(-8);
        (, uint256 netAssets2, , , , ) = strategy.getNetAssets();

        _simulatePriceChange(3);
        (, uint256 netAssets3, , , , ) = strategy.getNetAssets();

        // Strategy should handle volatility without reverting
        assertGt(netAssets1, 0, "Should have positive assets after +5%");
        assertGt(netAssets2, 0, "Should have positive assets after -8%");
        assertGt(netAssets3, 0, "Should have positive assets after +3%");
    }

    function test_EdgeCase_FreeFunds_RequiresDeleverage() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 shares = strategy.balanceOf(user1);
        uint256 withdrawShares = shares / 2;

        // Withdrawing should trigger deleveraging via async flow
        _requestRedeemAs(user1, withdrawShares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, withdrawShares);

        assertGt(assets, 0, "Should receive assets");

        // Debt should be reduced
        (, , , , uint256 debtAfter, ) = strategy.getNetAssets();
        assertLt(
            debtAfter,
            (DEFAULT_DEPOSIT() * TARGET_LTV_BPS) / BPS_PRECISION,
            "Debt should be reduced after withdrawal"
        );
    }

    function test_EdgeCase_FullWithdrawAfterLeverage() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // Setup leverage
        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        // Full withdrawal using async flow
        _requestRedeemAs(user1, shares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, shares);

        assertGt(assets, 0, "Should receive assets on full withdrawal");

        // Strategy should be mostly empty
        (, uint256 netAssets, , , , ) = strategy.getNetAssets();
        assertLt(netAssets, depositAmount / 100, "Net assets should be near zero after full withdrawal");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              ACCESS CONTROL TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testRevert_Slippage_Exceeded() public {
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());

        // Set low slippage tolerance
        (, uint16 performanceFeeBps, uint16 maxLossBps, , , , ) = strategy.getConfig();
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (10, performanceFeeBps, maxLossBps, feeReceiver, uint32(1 days))) // 0.1%
        );

        // Set high swapper slippage
        swapper.setSlippage(100); // 1%

        uint256 debtAmount = LeverageLib.computeTargetDebt(DEFAULT_DEPOSIT(), TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

        vm.prank(keeper);
        vm.expectRevert();
        strategy.rebalance(debtAmount, true, false, "");
    }

    function testRevert_SwapAndDepositCollateral_AssetIsCollateral() public {
        // In our setup, asset == collateral, so this should revert
        vm.prank(keeper);
        vm.expectRevert(LibError.InvalidAction.selector);
        strategy.swapAndDepositCollateral(1000 * 1e18, "");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              ADMIN FUNCTION TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SetTargetLtv_Success() public {
        uint16 newLtv = 6000; // 60%
        uint16 newLtvBuffer = 100; // 1%

        vm.prank(management);
        strategy.setTargetLtv(newLtv, newLtvBuffer);

        (, uint16 targetLtvBps, uint16 ltvBufferBps, , , ) = strategy.getLeveragedStrategyConfig();
        assertEq(targetLtvBps, newLtv, "Target LTV should be updated");
        assertEq(ltvBufferBps, newLtvBuffer, "LTV buffer");
    }

    function test_SetMaxSlippage_Success() public {
        uint16 newSlippage = 100; // 1%

        vm.expectEmit(true, true, true, true);
        emit ICeresBaseVault.ConfigUpdated();
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (newSlippage, 1500, MAX_LOSS_BPS, feeReceiver, uint32(1 days)))
        );

        (uint16 maxSlippageBps, , , , , , ) = strategy.getConfig();
        assertEq(maxSlippageBps, newSlippage, "Max slippage should be updated");
    }

    /// @dev Verifies that passing address(0) to updateConfig clears `performanceFeeRecipient`
    /// and that subsequent harvests do not mint fee shares while the recipient is unset.
    /// Also verifies that re-setting a non-zero recipient re-enables fee minting.
    function test_UpdateConfig_DisableFees_ViaZeroRecipient() public {
        (uint16 maxSlippageBps, uint16 performanceFeeBps, uint16 maxLossBps, , address recipientBefore, , ) = strategy
            .getConfig();
        assertEq(recipientBefore, feeReceiver, "recipient is feeReceiver");
        assertGt(performanceFeeBps, 0, "fees enabled");

        // Step 1: clear the recipient via updateConfig(address(0)).
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(
                strategy.updateConfig,
                (maxSlippageBps, performanceFeeBps, maxLossBps, address(0), uint32(1 days))
            )
        );

        (, , , , address recipientAfterClear, , ) = strategy.getConfig();
        assertEq(recipientAfterClear, address(0), "recipient should be zeroed");

        // Step 2: generate profit and harvest. No fee shares should be minted to the old recipient.
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 feeReceiverSharesBefore = strategy.balanceOf(feeReceiver);

        uint256 toAirdrop = (depositAmount * 500) / BPS_PRECISION; // 5% profit
        assetToken.mint(address(strategy), toAirdrop);

        vm.prank(keeper);
        strategy.harvestAndReport();

        assertEq(
            strategy.balanceOf(feeReceiver),
            feeReceiverSharesBefore,
            "no fee shares should mint while recipient is zero"
        );

        // Step 3: re-enable by setting recipient back; subsequent profits should mint fee shares.
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(
                strategy.updateConfig,
                (maxSlippageBps, performanceFeeBps, maxLossBps, feeReceiver, uint32(1 days))
            )
        );

        assetToken.mint(address(strategy), toAirdrop);

        vm.prank(keeper);
        strategy.harvestAndReport();

        assertGt(
            strategy.balanceOf(feeReceiver),
            feeReceiverSharesBefore,
            "fee shares should mint after re-enabling recipient"
        );
    }

    function test_SetDepositAndRedeemLimit_Success() public {
        uint128 newDepositLimit = 5_000_000 * 1e18;
        uint128 newRedeemLimit = 1_000_000 * 1e18;

        vm.startPrank(management);
        strategy.setDepositWithdrawLimits(newDepositLimit, newRedeemLimit, 0);
        vm.stopPrank();

        (uint128 depositLimit, uint128 redeemLimitShares, ) = strategy.getDepositWithdrawLimits();
        assertEq(depositLimit, newDepositLimit, "Deposit limit should be updated");
        assertEq(redeemLimitShares, newRedeemLimit, "Redeem limit should be updated");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          ORACLE/SWAPPER UPDATE TESTS (TIMELOCKED_ADMIN_ROLE)              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SetOracleAdapter_Success() public {
        address newAdapter = address(0x123);
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setOracleAdapter, (newAdapter)));
        assertEq(address(strategy.oracleAdapter()), newAdapter, "oracle adapter should be updated");
    }

    function test_SetSwapper_Success() public {
        address newSwapper = address(0x456);
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setSwapper, (newSwapper)));
        (, , , , address updatedSwapper, ) = strategy.getLeveragedStrategyConfig();
        assertEq(updatedSwapper, newSwapper, "swapper should be updated");
    }

    function test_SetFlashLoanRouter_Success() public {
        address newRouter = address(0x789);
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setFlashLoanRouter, (newRouter)));
        (, , , , , address updatedRouter) = strategy.getLeveragedStrategyConfig();
        assertEq(updatedRouter, newRouter, "flash loan router should be updated");
    }

    function test_SetKeeperDelay_Success() public {
        uint48 newDelay = 1 hours;
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setKeeperDelay, (newDelay)));
        assertEq(strategy.keeperDelay(), newDelay, "keeper delay should be updated");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          ADMIN FUNCTION REVERT TESTS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Covers all management-only and keeper-only functions — all use LibError.Unauthorized.
    function testRevert_UnauthorizedCallers() public {
        // Management-only: setTargetLtv
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.setTargetLtv(6000, LTV_BUFFER_BPS);

        // TIMELOCKED_ADMIN_ROLE-only: setOracleAdapter. Direct call (even from management) reverts
        // because only the timelock holds the role.
        vm.prank(management);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.setOracleAdapter(address(0x123));

        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.setOracleAdapter(address(0x123));

        // Keeper-only: rebalance
        _setupUserDeposit(user1, DEFAULT_DEPOSIT());
        uint256 debtAmount = LeverageLib.computeTargetDebt(DEFAULT_DEPOSIT(), TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), user1, address(strategy), debtAmount);
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.rebalance(debtAmount, true, false, "");

        // Keeper-only: rebalance with flash loan
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        strategy.rebalance(1e6, true, true, "");
    }

    function testRevert_SetTargetLtv_InvalidLtv() public {
        vm.prank(management);
        vm.expectRevert(LibError.InvalidLtv.selector);
        strategy.setTargetLtv(10000, LTV_BUFFER_BPS); // 100%
    }

    function testRevert_SetMaxSlippage_InvalidValue() public {
        // updateConfig is timelocke,  the InvalidValue revert must bubble up from execute().
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (10001, 1500, MAX_LOSS_BPS, address(0), uint32(1 days))), // > 100%
            management,
            LibError.InvalidValue.selector
        );
    }

    function testRevert_SetOracleAdapter_ZeroAddress() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setOracleAdapter, (address(0))),
            management,
            LibError.InvalidAddress.selector
        );
    }

    function testRevert_SetSwapper_ZeroAddress() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setSwapper, (address(0))),
            management,
            LibError.InvalidAddress.selector
        );
    }

    function testRevert_SetFlashLoanRouter_ZeroAddress() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setFlashLoanRouter, (address(0))),
            management,
            LibError.InvalidAddress.selector
        );
    }

    function testRevert_RescueTokens_StrategyTokens() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.rescueTokens, (address(assetToken), 0, management)),
            management,
            LibError.InvalidToken.selector
        );

        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.rescueTokens, (address(debtToken), 0, management)),
            management,
            LibError.InvalidToken.selector
        );
    }

    function testRevert_Deposit_ExceedsLimit() public {
        uint256 excessDeposit = DEPOSIT_LIMIT + 200 * 1e18;
        _mintAndApprove(address(assetToken), user1, address(strategy), excessDeposit);

        vm.prank(user1);
        vm.expectRevert();
        strategy.deposit(excessDeposit, user1);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              RESCUE TOKENS TEST                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_RescueTokens_NonStrategyToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(strategy), 1000 * 1e18);

        uint256 balanceBefore = randomToken.balanceOf(management);

        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.rescueTokens, (address(randomToken), 1000 * 1e18, management))
        );

        uint256 balanceAfter = randomToken.balanceOf(management);
        assertEq(balanceAfter - balanceBefore, 1000 * 1e18, "Should receive rescued tokens");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              OPERATION TESTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Operation(uint256 _amount) public {
        vm.assume(_amount > 10_000 && _amount < DEPOSIT_LIMIT);

        // Deposit into strategy
        _setupUserDeposit(user1, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.harvestAndReport();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = assetToken.balanceOf(user1);

        // Withdraw all funds using async flow
        _requestRedeemAs(user1, _amount);
        _processCurrentRequest();
        _redeemAs(user1, _amount);

        assertGe(assetToken.balanceOf(user1), balanceBefore + _amount, "!final balance");
    }

    function test_ProfitableReport(uint256 _amount, uint16 _profitFactor) public {
        vm.assume(_amount > _minFuzzAmount() && _amount < DEPOSIT_LIMIT);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, BPS_PRECISION));

        // Deposit into strategy
        _setupUserDeposit(user1, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Simulate earning interest by increasing asset balance
        uint256 toAirdrop = (_amount * _profitFactor) / BPS_PRECISION;
        assetToken.mint(address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.harvestAndReport();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = assetToken.balanceOf(user1);

        // Withdraw all funds using async flow
        _requestRedeemAs(user1, _amount);
        _processCurrentRequest();
        _redeemAs(user1, _amount);

        assertGe(assetToken.balanceOf(user1), balanceBefore + _amount, "!final balance");
    }

    function test_ProfitableReport_WithFees(uint256 _amount, uint16 _profitBps) public {
        vm.assume(_amount > _minFuzzAmount() && _amount < DEPOSIT_LIMIT);
        _profitBps = uint16(bound(uint256(_profitBps), 10, BPS_PRECISION));

        // Set performance fee to 10%
        (uint16 maxSlippageBps, , uint16 maxLossBps, , , , ) = strategy.getConfig();

        // Use profitUnlockPeriod=0 so the post-harvest `convertToShares` and the fee-share mint
        // both denominate against the same `currentAssets`. With a non-zero unlock period the
        // mint uses `currentAssets - performanceFees` while the test's expected-shares calc
        // uses the buffered `totalAssets()`, producing a >0.1% mismatch.
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (maxSlippageBps, 10_00, maxLossBps, feeReceiver, uint32(0)))
        );

        // Deposit into strategy
        _setupUserDeposit(user1, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Simulate earning interest
        uint256 toAirdrop = (_amount * _profitBps) / BPS_PRECISION;
        assetToken.mint(address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.harvestAndReport();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        // Get the expected fee
        uint256 expectedProfitAssets = (profit * 10_00) / BPS_PRECISION;
        uint256 expectedProfitShares = strategy.convertToShares(expectedProfitAssets);

        if (_amount > 10 ** IERC20Metadata(address(assetToken)).decimals()) {
            // 0.1% variance
            _assertApproxEqBps(strategy.balanceOf(feeReceiver), expectedProfitShares, 10, "!expectedProfitShares");
        } else {
            assertApproxEqAbs(strategy.balanceOf(feeReceiver), expectedProfitShares, 1000, "!expectedProfitShares");
        }

        uint256 balanceBefore = assetToken.balanceOf(user1);

        // Withdraw all funds using async flow
        _requestRedeemAs(user1, _amount);
        _processCurrentRequest();
        _redeemAs(user1, _amount);

        assertGe(assetToken.balanceOf(user1), balanceBefore + _amount, "!final balance");

        if (expectedProfitShares != 0) {
            // Withdraw performance fee receiver shares using async flow
            _requestRedeemAs(feeReceiver, expectedProfitShares);
            _processCurrentRequest();
            _redeemAs(feeReceiver, expectedProfitShares);
        }

        console.log("Strategy totalAssets", strategy.totalAssets());
        console.log("Strategy totalSupply", strategy.totalSupply());

        uint256 oneShareUnit = 10 ** strategy.decimals();
        if (_amount > oneShareUnit) {
            assertLe(strategy.totalAssets(), oneShareUnit, "!strategy total assets");
            assertLe(strategy.totalSupply(), oneShareUnit, "!strategy totalSupply");
            _assertApproxEqBps(assetToken.balanceOf(feeReceiver), expectedProfitAssets, 10, "!perf fee out");
        } else {
            assertApproxEqAbs(strategy.totalAssets(), 1, 1000, "!strategy total assets after fee redemption");
            assertApproxEqAbs(strategy.totalSupply(), 1, 1000, "!strategy total supply   after fee redemption");
            assertApproxEqAbs(assetToken.balanceOf(feeReceiver), expectedProfitAssets, 1000, "!perf fee out");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                         MULTI-STEP LIFECYCLE TESTS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_FullLifecycle_DepositLeverageHarvestWithdraw() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();

        // 1. Deposit
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // 2. Leverage up
        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        // 3. Price increases (bull market)
        _simulatePriceChange(15);

        // 4. Report profits
        vm.prank(keeper);
        strategy.harvestAndReport();

        // 5. Withdraw with profit using async flow
        _requestRedeemAs(user1, shares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, shares);

        assertGt(assets, depositAmount, "Should profit from leveraged position");
    }

    function test_MultiUser_DifferentEntryPrices() public {
        // User1 enters at initial price
        uint256 deposit1 = DEFAULT_DEPOSIT();
        uint256 shares1 = _setupUserDeposit(user1, deposit1);

        // Setup leverage
        uint256 debtAmount = LeverageLib.computeTargetDebt(deposit1, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        // Price increases 10%
        _simulatePriceChange(10);

        // User2 enters at higher price
        uint256 deposit2 = DEFAULT_DEPOSIT();
        _setupUserDeposit(user2, deposit2);

        // Rebalance for new deposits
        (, uint256 netAssets, , , uint256 currentDebt, ) = strategy.getNetAssets();
        uint256 newTargetDebt = LeverageLib.computeTargetDebt(netAssets, TARGET_LTV_BPS, strategy.oracleAdapter());
        if (newTargetDebt > currentDebt) {
            uint256 additionalDebt = newTargetDebt - currentDebt;
            _mintAndApprove(address(debtToken), keeper, address(strategy), additionalDebt);
            vm.prank(keeper);
            strategy.rebalance(additionalDebt, true, false, "");
        }

        vm.prank(keeper);
        strategy.harvestAndReport();

        // User1 should have more value per share (entered at lower price)
        uint256 pps = strategy.convertToAssets(10 ** strategy.decimals());
        uint256 user1Value = (shares1 * pps) / 1e18;

        assertGt(user1Value, deposit1, "User1 should have gains (early entry)");
    }

    function test_Rebalance_MaintainTargetLtv() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 initialLtv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());

        // Price drops, LTV increases
        _simulatePriceChange(-10);

        uint256 ltvAfterDrop = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());
        assertGt(ltvAfterDrop, initialLtv, "LTV should increase after price drop");

        // Deleverage to bring LTV back to target
        (, uint256 netAssets, , , uint256 currentDebt, ) = strategy.getNetAssets();
        uint256 targetDebt = LeverageLib.computeTargetDebt(netAssets, TARGET_LTV_BPS, strategy.oracleAdapter());

        uint256 deleverageAmount = currentDebt - targetDebt;

        vm.prank(keeper);
        strategy.rebalance(deleverageAmount, false, true, "");

        uint256 ltvAfterRebalance = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());
        assertApproxEqRel(ltvAfterRebalance, TARGET_LTV_BPS, 10e16, "LTV should be near target after rebalance");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           INTEREST ACCRUAL PROFIT TESTS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test profit from collateral yield accrual
    function test_Profit_CollateralYieldAccrual() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssetsBefore, , , , ) = strategy.getNetAssets();

        // Simulate 10% APY on collateral, 5% APY on debt over 1 year
        _simulateInterestAccrual(1000, 500, 365 days);

        (, uint256 netAssetsAfter, , , , ) = strategy.getNetAssets();

        assertGt(netAssetsAfter, netAssetsBefore, "Net assets should increase from yield");
    }

    /// @notice Test net profit when yield exceeds debt interest
    function test_Profit_YieldExceedsDebtInterest() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssetsBefore, , , , ) = strategy.getNetAssets();
        uint256 ppsBeforeReport = strategy.convertToAssets(10 ** strategy.decimals());

        // Simulate high collateral yield (15% APY) vs low debt interest (3% APY)
        _simulateInterestAccrual(1500, 300, 180 days);

        // Trigger report to realize profits
        vm.prank(keeper);
        strategy.harvestAndReport();

        uint256 ppsAfterReport = strategy.convertToAssets(10 ** strategy.decimals());
        (, uint256 netAssetsAfter, , , , ) = strategy.getNetAssets();

        assertGt(netAssetsAfter, netAssetsBefore, "Net assets should increase");
        assertGe(ppsAfterReport, ppsBeforeReport, "PPS should increase or stay same after profit");
    }

    /// @notice Test that profit reporting updates total assets
    function test_Profit_Report_UpdatesTotalAssets() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 totalAssetsBefore = strategy.totalAssets();

        // Simulate profit
        _simulateInterestAccrual(1000, 200, 90 days);

        vm.prank(keeper);
        strategy.harvestAndReport();

        uint256 totalAssetsAfter = strategy.totalAssets();

        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after report");
    }

    /// @notice Test share price increases after profit
    function test_Profit_SharePriceIncreases() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 ppsBefore = strategy.convertToAssets(10 ** strategy.decimals());

        // Simulate significant profit
        _simulateInterestAccrual(2000, 300, 365 days);

        vm.prank(keeper);
        strategy.harvestAndReport();

        uint256 ppsAfter = strategy.convertToAssets(10 ** strategy.decimals());

        assertGt(ppsAfter, ppsBefore, "Share price should increase");
    }

    /// @notice Test user withdraws and receives profit share
    function test_Profit_WithdrawAfterProfit() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // Setup leverage
        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        // Simulate profit
        _simulateInterestAccrual(1500, 300, 180 days);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.harvestAndReport();

        assertEq(loss, 0, "loss should be 0");
        assertGt(profit, 0, "!profit");

        // Withdraw all using async flow
        _requestRedeemAs(user1, shares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, shares);

        assertGt(assets, depositAmount, "User should receive more than deposited");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           INTEREST ACCRUAL LOSS TESTS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test loss when debt interest exceeds yield
    function test_Loss_DebtInterestExceedsYield() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        (, uint256 netAssetsBefore, , , , ) = strategy.getNetAssets();

        // Simulate low collateral yield (2% APY) vs high debt interest (10% APY)
        _simulateInterestAccrual(200, 1000, 365 days);

        (, uint256 netAssetsAfter, , , , ) = strategy.getNetAssets();

        assertLt(netAssetsAfter, netAssetsBefore, "Net assets should decrease from net negative yield");
    }

    /// @notice Test share price decreases after loss
    function test_Loss_SharePriceDecreases() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 ppsBefore = strategy.convertToAssets(10 ** strategy.decimals());

        // Simulate loss (debt interest > yield)
        _simulateInterestAccrual(100, 1500, 365 days);

        vm.prank(keeper);
        strategy.harvestAndReport();

        uint256 ppsAfter = strategy.convertToAssets(10 ** strategy.decimals());

        assertLt(ppsAfter, ppsBefore, "Share price should decrease after loss");
    }

    /// @notice Test user withdraws with reduced value after loss
    function test_Loss_WithdrawAfterLoss() public virtual {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // Setup leverage
        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        // Simulate loss
        _simulateInterestAccrual(100, 1200, 180 days);

        vm.prank(keeper);
        strategy.harvestAndReport();

        // Withdraw all using async flow
        _requestRedeemAs(user1, shares);
        _processCurrentRequest();
        uint256 assets = _redeemAs(user1, shares);

        assertLt(assets, depositAmount, "User should receive less than deposited after loss");
    }

    /// @notice Test strategy remains solvent after partial loss
    function test_Loss_PartialLoss_StillSolvent() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());
        (, uint256 netAssetsBefore, , uint256 totalCollateralBefore, uint256 totalDebtBefore, ) = strategy
            .getNetAssets();

        // Simulate moderate loss
        _simulateInterestAccrual(100, 800, 180 days);

        (, uint256 netAssetsAfter, , uint256 totalCollateralAfter, uint256 totalDebtAfter, ) = strategy.getNetAssets();

        assertGt(netAssetsAfter, 0, "Strategy should still have positive net assets");
        assertLt(netAssetsAfter, netAssetsBefore, "Net assets should decrease");

        assertEq(totalCollateralBefore, totalCollateralAfter, "Collateral should remain same");
        assertGt(totalDebtAfter, totalDebtBefore, "Debt should increase due to interest");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           ADDITIONAL EDGE CASE TESTS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test handling of zero deposit amount
    function testRevert_Deposit_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(LibError.BelowMinimumDeposit.selector);
        strategy.deposit(0, user1);
    }

    /// @notice Test minimum viable deposit
    function test_EdgeCase_MinimumDeposit() public {
        uint256 minDeposit = 1e15; // Small amount

        _mintAndApprove(address(assetToken), user1, address(strategy), minDeposit);

        vm.prank(user1);
        uint256 shares = strategy.deposit(minDeposit, user1);

        assertGt(shares, 0, "Should receive shares for minimum deposit");
    }

    /// @notice Test deposit at exact limit
    function test_EdgeCase_MaxDeposit_AtLimit() public {
        // Deposit exactly at limit
        _mintAndApprove(address(assetToken), user1, address(strategy), DEPOSIT_LIMIT);

        vm.prank(user1);
        uint256 shares = strategy.deposit(DEPOSIT_LIMIT, user1);

        assertGt(shares, 0, "Should accept deposit at limit");
        assertEq(strategy.maxDeposit(user1), 0, "No more deposits should be available");
    }

    /// @notice Test withdraw more than balance - tests async withdrawal limits
    function testRevert_Withdraw_MoreThanBalance() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        uint256 shares = _setupUserDeposit(user1, depositAmount);

        // Request more shares than user has should fail
        vm.prank(user1);
        vm.expectRevert();
        strategy.requestRedeem(shares * 2, user1, user1);
    }

    /// @notice Test multiple rebalance iterations
    function test_Rebalance_MultipleIterations() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        // First leverage up to 50% LTV
        uint256 debtAmount1 = LeverageLib.computeTargetDebt(depositAmount, 50_00, strategy.oracleAdapter());
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount1);

        vm.prank(keeper);
        strategy.rebalance(debtAmount1, true, false, "");

        (, uint256 netAssets1, , , , ) = strategy.getNetAssets();

        // Second leverage up to higher LTV
        uint256 additionalDebt = LeverageLib.computeTargetDebt(netAssets1, TARGET_LTV_BPS, strategy.oracleAdapter());

        (, , , , uint256 currentDebt, ) = strategy.getNetAssets();
        uint256 debtAmount2 = additionalDebt > currentDebt ? additionalDebt - currentDebt : 0;

        if (debtAmount2 > 0) {
            _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount2);

            vm.prank(keeper);
            strategy.rebalance(debtAmount2, true, false, "");
        }

        uint256 finalLtv = _calculateLtv(strategy.getCollateralAmount(), strategy.getDebtAmount());
        assertGt(finalLtv, 5000, "LTV should increase after second rebalance");
        assertApproxEqRel(finalLtv, TARGET_LTV_BPS, 1e15, "LTV should be near target");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              PROFIT UNLOCK TESTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Helper that re-runs `updateConfig` preserving every field except the unlock period.
    /// Tests opt in to a non-zero `profitUnlockPeriod` without disturbing the strategy
    /// default (which is 0 in test setups to observe profits immediately).
    /// Note: `_runViaTimelock` advances time by `TIMELOCK_MIN_DELAY` (1 day) during the schedule
    /// + execute cycle, so callers must account for this if they have already started a decay.
    function _setProfitUnlockPeriod(uint32 period) internal {
        (uint16 maxSlippageBps, uint16 performanceFeeBps, uint16 maxLossBps, , address recipient, , ) = strategy
            .getConfig();
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (maxSlippageBps, performanceFeeBps, maxLossBps, recipient, period))
        );
    }

    /// @dev Drives a profit-bearing harvest cycle using protocol-specific interest accrual.
    /// Returns the realized profit so tests can reason about decay arithmetic. Note that this
    /// helper advances block.timestamp by 180 days via `_simulateInterestAccrual`.
    function _harvestWithProfit() internal returns (uint256 profit) {
        _simulateInterestAccrual(1500, 300, 180 days);
        vm.prank(keeper);
        uint256 loss;
        (profit, loss) = strategy.harvestAndReport();
        require(profit > 0, "test setup: expected profit");
        require(loss == 0, "test setup: expected no loss");
    }

    /// @notice The full profit buffer is locked at the moment of the report. With period > 0
    /// the freshly reported profit is invisible to `totalAssets()` until any decay has elapsed.
    function test_ProfitUnlock_AtT0_FullyLocked() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());
        _setProfitUnlockPeriod(uint32(1 days));

        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 profit = _harvestWithProfit();

        (uint128 lockedProfit, , uint32 period, uint256 currentlyLocked) = strategy.getProfitUnlockState();
        assertEq(period, 1 days, "period mismatch");
        assertGt(lockedProfit, 0, "lockedProfit should be set");
        assertEq(currentlyLocked, lockedProfit, "no decay should have occurred at T+0");
        assertApproxEqAbs(
            strategy.totalAssets(),
            totalAssetsBefore + (profit - uint256(lockedProfit)),
            1,
            "totalAssets must equal realized minus locked at T+0"
        );
        // The locked buffer is the net-of-fee profit; it cannot exceed the gross profit.
        assertLe(uint256(lockedProfit), profit, "lockedProfit must be net-of-fee <= profit");
    }

    /// @notice Locked profit decays linearly to zero across the unlock period and `lastProfitReport`
    /// remains pinned at the harvest block (anchor is only moved by `_updateLockedProfit`).
    function test_ProfitUnlock_LinearDecay() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());
        _setProfitUnlockPeriod(uint32(1 days));

        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 profit = _harvestWithProfit();
        (uint128 lockedProfit, uint40 lastReport, uint32 period, ) = strategy.getProfitUnlockState();

        // Quarter-period elapsed.
        skip(period / 4);
        uint256 expectedQuarter = (uint256(lockedProfit) * (period - period / 4)) / period;
        (, , , uint256 lockedQuarter) = strategy.getProfitUnlockState();
        assertApproxEqAbs(lockedQuarter, expectedQuarter, 1, "quarter-period decay mismatch");
        assertApproxEqAbs(
            strategy.totalAssets(),
            totalAssetsBefore + (profit - expectedQuarter),
            1,
            "totalAssets at T+P/4 mismatch"
        );

        // Half-period elapsed (skip the second quarter).
        skip(period / 4);
        uint256 expectedHalf = uint256(lockedProfit) / 2;
        (, , , uint256 lockedHalf) = strategy.getProfitUnlockState();
        assertApproxEqAbs(lockedHalf, expectedHalf, 1, "half-period decay mismatch");

        // Past the full period: no profit should remain locked.
        skip(period);
        (, , , uint256 lockedAfter) = strategy.getProfitUnlockState();
        assertEq(lockedAfter, 0, "buffer must be fully unlocked after period");
        assertApproxEqAbs(
            strategy.totalAssets(),
            totalAssetsBefore + profit,
            1,
            "totalAssets must equal realized after full unlock"
        );

        // Anchor unchanged across the whole decay.
        (, uint40 lastReportAfter, , ) = strategy.getProfitUnlockState();
        assertEq(lastReportAfter, lastReport, "lastProfitReport must not move during decay");
    }

    /// @notice Reducing `profitUnlockPeriod` instantly releases the existing buffer. Use a
    /// 7-day period here so the buffer is still substantially locked when the (1-day) timelock
    /// schedule + execute completes; the shrink path then has something to release.
    function test_ProfitUnlock_PeriodShrink_InstantRelease() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());
        _setProfitUnlockPeriod(uint32(7 days));

        uint256 totalAssetsAtRealized = strategy.totalAssets();
        uint256 profit = _harvestWithProfit();
        (uint128 lockedBefore, , , ) = strategy.getProfitUnlockState();
        assertGt(lockedBefore, 0, "buffer prerequisite");

        // Shrink the period to 0. _runViaTimelock advances 1 day; with period=7d the buffer is
        // still ~6/7 locked at execute time. The shrink branch fires and zeroes lockedProfit.
        _setProfitUnlockPeriod(uint32(0));

        (uint128 lockedAfter, , uint32 periodAfter, uint256 currentlyLocked) = strategy.getProfitUnlockState();
        assertEq(periodAfter, 0, "period not updated");
        // lockedAfter isn't 0 because CeresBaseVault just updates to the remainder and sets period=0 (which zeroes currentlyLocked)
        assertEq(currentlyLocked, 0, "currentlyLocked must be zero post-release");
        // Realized total should now be visible: greater than the pre-harvest realized value.
        assertGt(strategy.totalAssets(), totalAssetsAtRealized, "released buffer must surface in totalAssets");
    }

    /// @notice Increasing `profitUnlockPeriod` updates the buffer to the currently locked amount
    /// and resets the anchor to the current block, decaying the remaining buffer over the new schedule.
    function test_ProfitUnlock_PeriodIncrease_NoRelease() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());
        _setProfitUnlockPeriod(uint32(7 days));

        _harvestWithProfit();
        (uint128 lockedBefore, uint40 anchorBefore, , ) = strategy.getProfitUnlockState();
        assertGt(lockedBefore, 0, "buffer prerequisite");

        _setProfitUnlockPeriod(uint32(MAX_PROFIT_UNLOCK_PERIOD()));

        (uint128 lockedAfter, uint40 anchorAfter, uint32 periodAfter, uint256 currentlyLocked) = strategy
            .getProfitUnlockState();
        assertEq(periodAfter, uint32(MAX_PROFIT_UNLOCK_PERIOD()), "period not updated");
        // The buffer settles during the update: it drops from the 1-day timelock decay, but remains partially locked.
        assertLt(lockedAfter, lockedBefore, "buffer must settle and drop on period change");
        assertGt(lockedAfter, 0, "buffer must not be fully released on period increase");
        assertGt(anchorAfter, anchorBefore, "anchor must update to execution block");
        assertEq(currentlyLocked, lockedAfter, "currentlyLocked must equal the newly settled buffer at T+0");
    }

    /// @dev Mirror of the contract constant; declared in the test layer because the constant is
    /// `internal` on `CeresBaseVault` and not exposed via the interface.
    function MAX_PROFIT_UNLOCK_PERIOD() internal pure returns (uint256) {
        return 30 days;
    }
}
