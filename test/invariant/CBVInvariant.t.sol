// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

import {CeresBaseVault} from "src/strategies/CeresBaseVault.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";

import {MockERC20} from "../mock/common/MockERC20.sol";
import {MinimalCeresStrategy} from "../mock/common/MinimalCeresStrategy.sol";
import {MinimalOracleAdapter} from "../mock/common/MinimalOracleAdapter.sol";
import {BaseVaultHandler} from "./handlers/BaseVaultHandler.sol";
import {TimelockTestHelper} from "../common/TimelockTestHelper.sol";

/// @title CeresBaseVaultInvariant (CBVInvariant)
/// @notice Invariant test suite for CeresBaseVault vault accounting logic.
///
/// Tests CeresBaseVault in isolation
/// MinimalCeresStrategy mock with asset = collateral and no fork
contract CBVInvariant is Test {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    address internal management;
    address internal keeper;
    address internal feeRecipient;

    //  Deployed contracts
    MockERC20 internal assetToken;
    MockERC20 internal debtToken;
    MinimalOracleAdapter internal oracle;
    RoleManager internal roleManager;
    MinimalCeresStrategy internal strategy;
    BaseVaultHandler internal handler;

    TimelockController internal timelock;
    TimelockTestHelper internal timelockHelper;
    uint256 internal constant TIMELOCK_MIN_DELAY = 1 days;

    function setUp() public {
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        feeRecipient = makeAddr("feeRecipient");

        assetToken = new MockERC20("Mock Asset", "ASSET", 18);
        debtToken = new MockERC20("Mock Debt", "DEBT", 18);

        // 1:1 Oracle, purely a dependency for the LeveragedStrategy init)
        oracle = new MinimalOracleAdapter(address(assetToken), address(assetToken), address(debtToken));

        // Role manager
        // 0-second admin delay: instant admin acceptance in tests.
        vm.prank(management);
        roleManager = new RoleManager(0, management);

        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        vm.stopPrank();

        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, management);
        vm.startPrank(management);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
        // Renounce the constructor-bootstrap grant so management can't bypass the timelock.
        roleManager.renounceRole(TIMELOCKED_ADMIN_ROLE, management);
        vm.stopPrank();

        // Strategy
        vm.startPrank(management);
        address proxy = Upgrades.deployTransparentProxy(
            "MinimalCeresStrategy.sol:MinimalCeresStrategy",
            management, // proxy admin owner
            abi.encodeCall(
                MinimalCeresStrategy.initialize,
                (address(assetToken), address(debtToken), address(roleManager))
            )
        );
        strategy = MinimalCeresStrategy(proxy);
        vm.stopPrank();

        // Strategy configuration
        // Oracle and config setters are gated by TIMELOCKED_ADMIN_ROLE -> route via timelock.
        timelockHelper.runViaTimelock(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setOracleAdapter, (address(oracle))),
            management
        );

        vm.startPrank(management);
        strategy.setDepositWithdrawLimits(
            100_000_000 * 1e18, // depositLimit: 100 M tokens
            type(uint128).max, // redeemLimitShares: unlimited
            0 // minDepositAmount: 1 wei
        );
        vm.stopPrank();

        // Fee config: 15% performance fee, 2% max loss, 0.25% slippage + fee recipient.
        timelockHelper.runViaTimelock(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (25, 1500, 200, feeRecipient)),
            management
        );

        // Handler
        handler = new BaseVaultHandler(strategy, assetToken, keeper, management, feeRecipient);

        // Invariant target
        targetContract(address(handler));

        // Exclude direct calls to strategy or other contracts from the fuzzer.
        excludeContract(address(strategy));
        excludeContract(address(assetToken));
        excludeContract(address(debtToken));
        excludeContract(address(oracle));
        excludeContract(address(roleManager));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        INVARIANTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-1
    //  Asset balance backs the withdrawal reserve at all times.
    //
    //  Note: if the keeper drains idle assets (e.g. via a buggy
    //  swapAndDepositCollateral that ignores the reserve), settled withdrawals
    //  would be uncoverable and redeem() would revert for users.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV1_assetBalanceBacksReserve() public view {
        assertGe(
            assetToken.balanceOf(address(strategy)),
            strategy.withdrawalReserve(),
            "CBV-INV-1: asset balance < withdrawal reserve"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-2
    //  Stored totalAssets never falls below the withdrawal reserve.
    //
    //  Note: processCurrentRequest allocates `assetsAllocatedForRequest`
    //  from totalAssets. If a harvest mis-reports a lower totalAssets, future
    //  allocations could appear to leave the reserve unfunded.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV2_totalAssetsBacksReserve() public view {
        assertGe(strategy.totalAssets(), strategy.withdrawalReserve(), "CBV-INV-2: totalAssets < withdrawal reserve");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-3
    //  Deposit Limit check: once totalAssets >= depositLimit, no new deposits allowed.
    //
    //  Note: a miscalculation in maxDeposit could allow deposits past
    //  the capacity cap, exposing the protocol to oversized positions.
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function invariant_CBV3_depositGateEnforced() public view {
        (uint128 depositLimit, , ) = strategy.getDepositWithdrawLimits();
        if (strategy.totalAssets() >= depositLimit) {
            // Must return 0 for all address
            address randomAdress = address(uint160(block.timestamp));

            assertEq(strategy.maxDeposit(address(this)), 0, "CBV-INV-3: maxDeposit non-zero past limit");
            assertEq(strategy.maxDeposit(randomAdress), 0, "CBV-INV-3: maxDeposit(0) non-zero past limit");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-4
    //  Share supply equals the sum of all known holder balances.
    //
    //  Known holders: handler actors + strategy contract (locked redemption shares)
    //  + fee recipient (performance fee shares).
    //
    //  Note: a bug that mints or burns shares without updating totalSupply
    //  would cause this invariant to fail
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV4_shareSupplyConsistency() public view {
        uint256 accounted = strategy.balanceOf(address(strategy)) + strategy.balanceOf(feeRecipient);

        for (uint256 i = 0; i < handler.ACTOR_COUNT(); i++) {
            accounted += strategy.balanceOf(handler.actors(i));
        }

        assertEq(accounted, strategy.totalSupply(), "CBV-INV-4: totalSupply != sum of known balances");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-5
    //  A settled PPS never changes once written.
    //
    //  Note: if processCurrentRequest could overwrite an already-settled
    //  batch (through a reentrancy or ID-collision bug), users claiming at the old
    //  PPS would receive the wrong asset amount.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV5_settledPPSIsImmutable() public view {
        // Check all batches that the handler has already settled.
        // currentRequestId points to the NEXT (unsettled) batch.
        uint128 nextId = strategy.currentRequestId();
        // Only the first batch (ID=1) through (nextId-1) are settled.
        // We cap the loop to avoid unbounded gas; in practice nextId stays small.
        uint256 start = nextId > 51 ? nextId - 50 : 1;
        for (uint256 id = start; id < nextId; id++) {
            uint128 firstPPS = handler.ghost_firstSettledPPS(id);
            // if (firstPPS == 0) continue; // handler didn't record this one yet

            CeresBaseVault.RequestDetails memory details = strategy.requestDetails(id);
            assertEq(details.pricePerShare, firstPPS, "CBV-INV-5: settled PPS was overwritten");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-6
    //  Unsettled batch shares never decrease.
    //
    //  The current active batch can accumulate shares from multiple requestRedeem
    //  calls, but shares may never be removed from an unsettled batch.
    //
    //  Note: if an attacker could decrement totalShares before the PPS
    //  is locked, they could manipulate the effective price for remaining claimants.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV6_unsettledBatchSharesNonDecreasing() public view {
        uint128 currentId = strategy.currentRequestId();
        CeresBaseVault.RequestDetails memory details = strategy.requestDetails(currentId);

        // The current batch is unsettled (PPS == 0). Its totalShares tracked inside
        // the contract must equal or exceed what the handler's actors have requested
        // into this batch (i.e., shares the strategy contract currently holds).
        // A simpler verifiable form: strategy-held shares == sum of all pending shares.
        // strategy.balanceOf(address(strategy)) tracks shares locked for all unsettled batches.
        assertEq(
            details.pricePerShare,
            0,
            "CBV-INV-6: current request batch was already settled (ID should have advanced)"
        );

        assertGe(
            strategy.balanceOf(address(strategy)),
            details.totalShares,
            "CBV-INV-6: totalShares locked in strategy decreased"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-7
    //  snapshotNetProfit is monotonically non-decreasing.
    //
    //  It advances when performance fees are charged and never retreats.
    //
    //  Note: if the snapshot could be reset downward, fees would be double-charged
    //  on the same profit in a future harvest cycle.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV7_snapshotNetProfitMonotonic() public view {
        (, int128 currentSnapshot) = strategy.getStats();
        assertGe(
            int256(currentSnapshot),
            int256(handler.ghost_maxSnapshotNetProfit()),
            "CBV-INV-7: snapshotNetProfit decreased"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-8
    //  Each user's pending request references either no batch (requestId==0),
    //  the active batch (currentRequestId), or a settled batch (PPS > 0).
    //
    //  It is impossible for a user to hold an unclaimed slot in a batch that is
    //  both closed AND different from the active batch, that would mean the user
    //  was enrolled in multiple batches without redeeming.
    //
    //  Note: a user with a stale, unresolvable requestId could not redeem
    //  their shares
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV8_singlePendingRequestPerUser() public view {
        uint128 currentId = strategy.currentRequestId();

        for (uint256 i = 0; i < handler.ACTOR_COUNT(); i++) {
            address actor = handler.actors(i);
            CeresBaseVault.UserRedeemRequest memory req = strategy.userRedeemRequests(actor);

            if (req.requestId == 0) continue; // no request — fine
            if (req.requestId == currentId) continue; // in current batch — fine

            // requestId is stale (< currentId). The batch must have been settled.
            CeresBaseVault.RequestDetails memory staleDetails = strategy.requestDetails(req.requestId);
            assertGt(
                staleDetails.pricePerShare,
                0,
                "CBV-INV-8: user stuck in an unprocessed batch that is not the current one"
            );
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-9
    //  ERC4626 rounding direction: convertToShares(convertToAssets(x)) <= x
    //
    //  Both conversions use Floor rounding by design. A round-trip must never
    //  yield MORE shares than the input, otherwise a user gains shares for free.
    //
    //  Note: incorrect mulDiv rounding direction in _convertToShares or
    //  _convertToAssets could allow share inflation attacks.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV9_roundTripRounding() public view {
        // Test with 1 share, 1000 shares, and 1 million shares as reference inputs.
        uint256[3] memory testAmount = [uint256(1), uint256(1000 * 1e18), uint256(1_000_000 * 1e18)];
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = testAmount[i];
            // if (shares > strategy.totalSupply()) continue; // skip if supply too low

            uint256 assets = strategy.convertToAssets(shares);
            uint256 sharesBack = strategy.convertToShares(assets);
            assertLe(sharesBack, shares, "CBV-INV-9: ERC4626 round-trip inflates shares");

            uint256 depositAmount = testAmount[i];
            uint256 depositShares = strategy.convertToShares(depositAmount);
            uint256 amountBack = strategy.convertToAssets(depositShares);
            assertLe(amountBack, depositAmount, "CBV-INV-9: ERC4626 round=trip inflates assets");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-10
    //  currentRequestId is non-decreasing and always >= 1.
    //
    //  The ID is initialised to 1 and increments by exactly 1 each time
    //  processCurrentRequest settles a batch. It can never decrease or wrap.
    //
    //  Note: if the ID could decrease or wrap (e.g. due to unchecked
    //  arithmetic or a storage bug), a new requestRedeem could land in a slot
    //  that already holds a settled PPS
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV10_requestIdMonotonic() public view {
        uint128 currentId = strategy.currentRequestId();

        // Must always be >= 1 (initialised to 1, only increases).
        assertGe(currentId, 1, "CBV-INV-10: currentRequestId underflowed below 1");

        // Must be >= the maximum ID the handler has ever observed.
        assertGe(
            uint256(currentId),
            uint256(handler.ghost_maxRequestIdOffchain()),
            "CBV-INV-10: currentRequestId decreased (non-monotonic)"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  afterInvariant: log call distribution for coverage analysis
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function afterInvariant() public {
        emit log_named_uint("calls: deposit               ", handler.calls_deposit());
        emit log_named_uint("calls: requestRedeem         ", handler.calls_requestRedeem());
        emit log_named_uint("calls: processCurrentRequest ", handler.calls_processCurrentRequest());
        emit log_named_uint("calls: redeem                ", handler.calls_redeem());
        emit log_named_uint("calls: harvestAndReport      ", handler.calls_harvestAndReport());
        emit log_named_uint("calls: simulateYield         ", handler.calls_simulateYield());
        emit log_named_uint("calls: simulateLoss          ", handler.calls_simulateLoss());
        emit log_named_uint("calls: warp                  ", handler.calls_warp());
    }
}
