// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CeresBaseVault} from "src/strategies/CeresBaseVault.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MinimalCeresStrategy} from "../../mock/common/MinimalCeresStrategy.sol";

/// @title BaseVaultHandler
contract BaseVaultHandler is Test {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      CONSTANTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 public constant ACTOR_COUNT = 6;
    uint256 public constant MAX_MINT = 100_000_000 * 1e18;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       STATE                                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Contracts
    MinimalCeresStrategy public strategy;
    MockERC20 public asset;
    address public keeper;
    address public management;
    address public feeRecipient;

    address[ACTOR_COUNT] public actors;

    //  Ghost variables
    /// @notice Sum of all actor share balances (excludes fee recipient + strategy).
    uint256 public ghost_sumActorShares;

    /// @notice PPS recorded at settlement for each requestId.
    mapping(uint256 requestId => uint128 pps) public ghost_firstSettledPPS;

    /// @notice Maximum of snapshotNetProfit seen after each harvest.
    int128 public ghost_maxSnapshotNetProfit;

    /// @notice Maximum requestId value
    uint128 public ghost_maxRequestIdOffchain;

    //  Call counters (coverage diagnostics)
    uint256 public calls_deposit;
    uint256 public calls_requestRedeem;
    uint256 public calls_processCurrentRequest;
    uint256 public calls_redeem;
    uint256 public calls_harvestAndReport;
    uint256 public calls_simulateYield;
    uint256 public calls_simulateLoss;
    uint256 public calls_warp;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(
        MinimalCeresStrategy strategy_,
        MockERC20 asset_,
        address keeper_,
        address management_,
        address feeRecipient_
    ) {
        strategy = strategy_;
        asset = asset_;
        keeper = keeper_;
        management = management_;
        feeRecipient = feeRecipient_;

        // Pre-fund and approve all actors so deposits never revert due to balance.
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            asset.mint(actors[i], MAX_MINT);

            vm.prank(actors[i]);
            asset.approve(address(strategy), type(uint256).max);
        }

        ghost_maxSnapshotNetProfit = type(int128).min;
        ghost_maxRequestIdOffchain = strategy.currentRequestId();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             INTERNAL HELPER FUNCTIONS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    /// @dev Returns the gross idle balance available for new withdrawals.
    ///      Mirrors the check inside processCurrentRequest: availableAssets = balance - reserve.
    function _availableIdleAssets() internal view returns (uint256) {
        uint256 bal = asset.balanceOf(address(strategy));
        uint128 reserve = strategy.withdrawalReserve();
        return bal > reserve ? bal - reserve : 0;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   HELPER FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    //  Handler: deposit
    function deposit(uint256 assets, uint256 actorSeed) external {
        address actor = _actor(actorSeed);

        (, , uint128 minDeposit) = strategy.getDepositWithdrawLimits();
        uint256 maxDepositable = strategy.maxDeposit(actor);
        if (maxDepositable == 0 || minDeposit == 0) return;

        assets = bound(assets, minDeposit, maxDepositable);

        // Top up actor balance if needed.
        uint256 bal = asset.balanceOf(actor);
        if (bal < assets) {
            asset.mint(actor, assets - bal);
        }

        vm.prank(actor);
        try strategy.deposit(assets, actor) returns (uint256 shares) {
            ghost_sumActorShares += shares;
            calls_deposit++;
        } catch {}
    }

    //  Handler: requestRedeem
    function requestRedeem(uint256 sharesFuzz, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 actorBalance = strategy.balanceOf(actor);
        if (actorBalance == 0) return;

        CeresBaseVault.UserRedeemRequest memory req = strategy.userRedeemRequests(actor);
        uint128 currentReqId = strategy.currentRequestId();

        // Skip if user has a pending request for an OLDER (already processed) batch.
        // They must redeem those shares first before they can join the current batch.
        if (req.requestId != 0 && req.requestId != currentReqId) return;

        (, uint128 redeemLimit, ) = strategy.getDepositWithdrawLimits();
        uint256 maxShares = _min(actorBalance, redeemLimit);
        uint256 sharesToRequest = bound(sharesFuzz, 1, maxShares);

        vm.prank(actor);
        try strategy.requestRedeem(sharesToRequest, actor, actor) returns (uint256) {
            ghost_sumActorShares -= sharesToRequest;
            calls_requestRedeem++;
        } catch {}
    }

    //  Handler: processCurrentRequest
    /// @notice Keeper settles the active withdrawal batch.
    /// Guard: only proceed when idle assets cover the expected payout.
    /// Without leverage, _freeFunds returns 0, so any shortfall triggers the
    /// maxLoss revert. The guard keeps the fuzzer from burning depth on reverts.
    function processCurrentRequest() external {
        uint128 currentReqId = strategy.currentRequestId();
        CeresBaseVault.RequestDetails memory details = strategy.requestDetails(currentReqId);

        // Nothing to process.
        if (details.totalShares == 0) return;
        // Already processed.
        if (details.pricePerShare != 0) return;

        // extraData: (flashLoanAmount=0, swapData="", collateralToAssetSwapData="")
        bytes memory extraData = abi.encode(uint256(0), bytes(""), bytes(""));

        vm.prank(keeper);
        try strategy.processCurrentRequest(extraData) {
            uint128 settledPPS = strategy.requestDetails(currentReqId).pricePerShare;
            if (ghost_firstSettledPPS[currentReqId] == 0) {
                ghost_firstSettledPPS[currentReqId] = settledPPS;
            }

            (, int128 snap) = strategy.getStats();
            if (snap > ghost_maxSnapshotNetProfit) {
                ghost_maxSnapshotNetProfit = snap;
            }

            ghost_maxRequestIdOffchain++;
            calls_processCurrentRequest++;
        } catch {}
    }

    //  Handler: redeem
    function redeem(uint256 sharesFuzz, uint256 actorSeed) external {
        address actor = _actor(actorSeed);

        CeresBaseVault.UserRedeemRequest memory req = strategy.userRedeemRequests(actor);
        if (req.requestId == 0 || req.shares == 0) return;

        CeresBaseVault.RequestDetails memory details = strategy.requestDetails(req.requestId);
        if (details.pricePerShare == 0) return; // batch not yet processed

        uint256 sharesToRedeem = bound(sharesFuzz, 1, req.shares);

        vm.prank(actor);
        try strategy.redeem(sharesToRedeem, actor, actor) {
            // Shares were already deducted from ghost_sumActorShares at requestRedeem time.
            calls_redeem++;
        } catch {}
    }

    //  Handler: harvestAndReport
    function harvestAndReport() external {
        vm.prank(keeper);
        try strategy.harvestAndReport() {
            (, int128 snap) = strategy.getStats();
            if (snap > ghost_maxSnapshotNetProfit) {
                ghost_maxSnapshotNetProfit = snap;
            }

            calls_harvestAndReport++;
        } catch {}
    }

    //  Handler: simulateYield
    /// @notice Mint tokens directly into the strategy, simulating interest or airdrop income.
    /// totalAssets() (the STORED value) must NOT increase until the next harvest.
    function simulateYield(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000_000 * 1e18);
        asset.mint(address(strategy), amount);
        calls_simulateYield++;
    }

    //  Handler: simulateLoss
    /// @notice Burn tokens from the strategy, simulating a drawdown or slippage.
    /// Only burns from the available idle portion (above the withdrawal reserve) to
    /// avoid making outstanding withdrawal claims uncoverable.
    function simulateLoss(uint256 amount) external {
        uint256 burnable = _availableIdleAssets();
        if (burnable == 0) return;

        amount = bound(amount, 1, burnable);
        asset.burn(address(strategy), amount);
        calls_simulateLoss++;
    }

    //  Handler: warp
    /// @notice Advance block time.
    function warp(uint256 secondsFuzz) external {
        skip(bound(secondsFuzz, 1, 30 days));
        calls_warp++;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
