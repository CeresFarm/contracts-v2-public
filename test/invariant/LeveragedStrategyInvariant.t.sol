// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

import {CeresBaseVault} from "src/strategies/CeresBaseVault.sol";
import {LeveragedStrategy} from "src/strategies/LeveragedStrategy.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MockCeresSwapper} from "test/mock/periphery/MockCeresSwapper.sol";
import {MockLeveragedStrategy} from "../mock/common/MockLeveragedStrategy.sol";
import {MinimalOracleAdapter} from "../mock/common/MinimalOracleAdapter.sol";
import {LeveragedStrategyHandler} from "./handlers/LeveragedStrategyHandler.sol";
import {TimelockTestHelper} from "../common/TimelockTestHelper.sol";

/// @title LeveragedStrategyInvariant
/// @notice Invariant test suite for LeveragedStrategy vault and leverage logic.
/// Tests MockLeveragedStrategy in isolation (asset = collateral, mock market). No fork.
contract LeveragedStrategyInvariant is Test {
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
    MockCeresSwapper internal swapper;
    RoleManager internal roleManager;
    MockLeveragedStrategy internal strategy;
    LeveragedStrategyHandler internal handler;

    TimelockController internal timelock;
    TimelockTestHelper internal timelockHelper;
    uint256 internal constant TIMELOCK_MIN_DELAY = 1 days;

    function setUp() public {
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        feeRecipient = makeAddr("feeRecipient");

        // Tokens
        assetToken = new MockERC20("Mock Asset", "ASSET", 18);
        debtToken = new MockERC20("Mock Debt", "DEBT", 18);

        // Oracle (1:1 pass-through)
        oracle = new MinimalOracleAdapter(address(assetToken), address(assetToken), address(debtToken));

        // Swapper
        swapper = new MockCeresSwapper();
        // Set 1:1 exchange rates for both swap directions the handler uses:
        //   debt  -> asset  (leverageUp:   swapDebtToCollateral uses debtToken->assetToken)
        //   asset -> debt   (leverageDown: swapCollateralToDebt uses assetToken->debtToken)
        swapper.setExchangeRate(address(debtToken), address(assetToken), 1e18);
        swapper.setExchangeRate(address(assetToken), address(debtToken), 1e18);

        // Role manager
        vm.prank(management);
        roleManager = new RoleManager(0, management);

        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        // Handler.setConfigKey() calls strategy.setOracleAdapter/setSwapper directly during fuzz,
        // so management retains TIMELOCKED_ADMIN_ROLE for the fuzz path
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, management);
        vm.stopPrank();

        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, management);
        vm.prank(management);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));

        // Strategy
        vm.startPrank(management);
        address proxy = Upgrades.deployTransparentProxy(
            "MockLeveragedStrategy.sol:MockLeveragedStrategy",
            management,
            abi.encodeCall(
                MockLeveragedStrategy.initialize,
                (address(assetToken), address(debtToken), address(roleManager))
            )
        );
        strategy = MockLeveragedStrategy(proxy);
        vm.stopPrank();

        // Strategy configuration
        // Oracle/swapper/config setters are TIMELOCKED_ADMIN_ROLE-gated -> route via timelock.
        timelockHelper.runViaTimelock(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setOracleAdapter, (address(oracle))),
            management
        );
        timelockHelper.runViaTimelock(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.setSwapper, (address(swapper))),
            management
        );

        vm.startPrank(management);
        strategy.setDepositWithdrawLimits(
            100_000_000e18, // depositLimit
            type(uint128).max, // redeemLimitShares: unlimited
            0 // minDepositAmount
        );
        vm.stopPrank();

        // 0.25% max slippage, 15% performance fee, 2% max loss + fee recipient.
        timelockHelper.runViaTimelock(
            timelock,
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (25, 1500, 200, feeRecipient)),
            management
        );

        vm.startPrank(management);
        // Target LTV: 70%, buffer: 0.5%. Max LTV is 90%, so 70 + 0.5 = 70.5 < 90.
        strategy.setTargetLtv(7000, 50);
        vm.stopPrank();

        // Handler
        handler = new LeveragedStrategyHandler(
            strategy,
            assetToken,
            debtToken,
            swapper,
            address(oracle),
            keeper,
            management,
            feeRecipient
        );

        // Invariant target
        targetContract(address(handler));

        excludeContract(address(strategy));
        excludeContract(address(assetToken));
        excludeContract(address(debtToken));
        excludeContract(address(oracle));
        excludeContract(address(swapper));
        excludeContract(address(roleManager));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        INVARIANTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-1
    //  Asset balance backs the withdrawal reserve at all times.
    //
    //  Note: if the keeper drains idle assets (e.g. via a buggy swapAndDepositCollateral
    //  that ignores the reserve), settled withdrawals would be uncoverable and redeem()
    //  would revert for users.
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
    //  Note: processCurrentRequest allocates assetsAllocatedForRequest from totalAssets.
    //  If a harvest mis-reports a lower totalAssets, future allocations could appear to
    //  leave the reserve unfunded.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV2_totalAssetsBacksReserve() public view {
        assertGe(strategy.totalAssets(), strategy.withdrawalReserve(), "CBV-INV-2: totalAssets < withdrawal reserve");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-3
    //  Deposit gate: when totalAssets >= depositLimit, no new deposits are allowed.
    //
    //  Note: a miscalculation in maxDeposit could allow deposits past the capacity cap,
    //  exposing the protocol to oversized positions.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV3_depositGateEnforced() public view {
        (uint128 depositLimit, , ) = strategy.getDepositWithdrawLimits();
        if (strategy.totalAssets() >= depositLimit) {
            assertEq(strategy.maxDeposit(address(this)), 0, "CBV-INV-3: maxDeposit non-zero past limit");
            assertEq(strategy.maxDeposit(address(0)), 0, "CBV-INV-3: maxDeposit(0) non-zero past limit");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-4
    //  totalSupply() == sum of all known holder balances.
    //
    //  Known holders: handler actors + strategy contract (locked redemption shares)
    //  + fee recipient (performance fee shares).
    //
    //  Note: a bug that mints or burns shares without updating totalSupply would
    //  cause this invariant to fail.
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
    //  Note: if processCurrentRequest could overwrite an already-settled batch (through
    //  a reentrancy or ID-collision bug), users claiming at the old PPS would receive
    //  the wrong asset amount.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV5_settledPPSIsImmutable() public view {
        uint128 nextId = strategy.currentRequestId();
        uint256 upper = nextId > 51 ? nextId - 50 : 1;
        for (uint256 id = upper; id < nextId; id++) {
            uint128 firstPPS = handler.ghost_firstSettledPPS(id);
            if (firstPPS == 0) continue;

            CeresBaseVault.RequestDetails memory details = strategy.requestDetails(id);
            assertEq(details.pricePerShare, firstPPS, "CBV-INV-5: settled PPS was overwritten");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-6
    //  The current (unsettled) batch always has pricePerShare == 0.
    //
    //  Note: if pricePerShare is set on the active batch before settlement, callers
    //  would read a stale PPS and potentially calculate incorrect redemption amounts.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV6_unsettledBatchSharesNonDecreasing() public view {
        uint128 currentId = strategy.currentRequestId();
        CeresBaseVault.RequestDetails memory details = strategy.requestDetails(currentId);

        assertEq(details.pricePerShare, 0, "CBV-INV-6: current request batch was already settled");
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
    //  Each user's pending request references either no batch (requestId == 0),
    //  the active batch (currentRequestId), or a settled batch (PPS > 0).
    //
    //  Note: a user with a stale, unresolvable requestId in an unsettled non-current
    //  batch could not redeem their shares.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV8_singlePendingRequestPerUser() public view {
        uint128 currentId = strategy.currentRequestId();

        for (uint256 i = 0; i < handler.ACTOR_COUNT(); i++) {
            address actor = handler.actors(i);
            CeresBaseVault.UserRedeemRequest memory req = strategy.userRedeemRequests(actor);

            if (req.requestId == 0) continue;
            if (req.requestId == currentId) continue;

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
    //  ERC4626 rounding direction: convertToShares(convertToAssets(x)) <= x.
    //
    //  Both conversions use Floor rounding by design. A round-trip must never yield
    //  MORE shares than the input, otherwise a user gains shares for free.
    //
    //  Note: incorrect mulDiv rounding direction in _convertToShares or
    //  _convertToAssets could allow share inflation attacks.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV9_roundTripRounding() public view {
        uint256[3] memory testShares = [uint256(1), uint256(1000e18), uint256(1_000_000e18)];
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = testShares[i];
            if (shares > strategy.totalSupply()) continue;

            uint256 assets = strategy.convertToAssets(shares);
            uint256 sharesBack = strategy.convertToShares(assets);
            assertLe(sharesBack, shares, "CBV-INV-9: ERC4626 round-trip inflates shares");
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: CBV-INV-10
    //  currentRequestId is non-decreasing and always >= 1.
    //
    //  The ID is initialised to 1 and increments by exactly 1 each time
    //  processCurrentRequest settles a batch. It can never decrease or wrap.
    //
    //  Note: if the ID could decrease or wrap (e.g. due to unchecked arithmetic or
    //  a storage bug), a new requestRedeem could land in a slot that already holds a
    //  settled PPS.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_CBV10_requestIdMonotonic() public view {
        uint128 currentId = strategy.currentRequestId();

        assertGe(currentId, 1, "CBV-INV-10: currentRequestId underflowed below 1");
        assertGe(
            uint256(currentId),
            uint256(handler.ghost_maxRequestIdOffchain()),
            "CBV-INV-10: currentRequestId decreased"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: LS-INV-1
    //  strategyLtv + ltvBuffer <= getStrategyMaxLtvBps() at all times.
    //
    //  _validateStrategyLtv() enforces this after every keeper operation. If any
    //  code path bypasses the validator, this invariant will fire.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_LS1_ltvBelowBufferedMax() public view {
        // Only meaningful when there is an active collateral position.
        if (strategy.marketCollateral() == 0) return;

        (, , uint16 ltvBuffer, , , ) = strategy.getLeveragedStrategyConfig();
        uint16 maxLtv = strategy.getStrategyMaxLtvBps();
        uint16 currentLtv = strategy.getStrategyLtv();

        assertLe(
            uint256(currentLtv) + uint256(ltvBuffer),
            uint256(maxLtv),
            "LS-INV-1: strategyLtv + ltvBuffer > maxLtvBps"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: LS-INV-2
    //  strategyLtv <= getStrategyMaxLtvBps()
    //
    //  Note: a bug that computes LTV without the buffer check would still be caught
    //  here, the raw LTV must never exceed maxLtvBps.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_LS2_ltvBelowAbsoluteMax() public view {
        if (strategy.marketCollateral() == 0) return;

        uint16 maxLtv = strategy.getStrategyMaxLtvBps();
        uint16 currentLtv = strategy.getStrategyLtv();

        assertLe(uint256(currentLtv), uint256(maxLtv), "LS-INV-2: strategyLtv > maxLtvBps");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //  Invariant: LS-INV-4
    //  isAssetCollateral never changes post-init (COLLATERAL_TOKEN == asset).
    //
    //  The flag influences _deployFunds, _freeFunds, and swapAndDepositCollateral.
    //  If it could flip, the strategy's entire fund flow would silently change
    //  without a re-deploy. Verified indirectly: COLLATERAL_TOKEN() must always
    //  equal asset() since there is no setter that can change it after init.
    ///////////////////////////////////////////////////////////////////////////////////////////////
    function invariant_LS4_isAssetCollateralImmutable() public view {
        assertEq(
            address(strategy.COLLATERAL_TOKEN()),
            strategy.asset(),
            "LS-INV-4: COLLATERAL_TOKEN changed (isAssetCollateral flipped)"
        );
        // Ghost cross-check: the handler captured the initial flag at construction.
        assertTrue(handler.ghost_initialIsAssetCollateral(), "LS-INV-4: ghost_initialIsAssetCollateral is false");
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
        emit log_named_uint("calls: leverageUp            ", handler.calls_leverageUp());
        emit log_named_uint("calls: leverageDown          ", handler.calls_leverageDown());
        emit log_named_uint("calls: setTargetLtv          ", handler.calls_setTargetLtv());
        emit log_named_uint("calls: setConfigKey          ", handler.calls_setConfig());
    }
}
