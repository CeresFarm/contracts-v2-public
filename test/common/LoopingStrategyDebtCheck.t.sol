// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockLeveragedStrategy} from "../mock/common/MockLeveragedStrategy.sol";
import {MockERC20} from "../mock/common/MockERC20.sol";
import {RoleManager} from "../../src/periphery/RoleManager.sol";
import {MinimalOracleAdapter} from "../mock/common/MinimalOracleAdapter.sol";
import {MockCeresSwapper} from "../mock/periphery/MockCeresSwapper.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Unit and integration tests for `getNetAssets()` on a self-looping strategy
/// (assetToken == debtToken == WETH, collateralToken == WSTETH).
///
/// For the test, the debt token and the asset token are the same. Any idle assetToken held
/// by the strategy is already included in `assetBalance`. It must NOT also be used to offset
/// or reduce `marketDebt`, because the debt is a real obligation owed to the lending market and
/// can only be reduced by an explicit repayment. `netDebt` must always equal `marketDebt` minus
/// any debt tokens that are genuinely distinct from the idle asset balance.
///
/// Expected invariant for all states:
///   netAssets = assetBalance + collateralValue - netDebt
///   netDebt   = marketDebt  (idle assetToken does not offset it)
contract LoopingStrategyDebtCheckTest is Test {
    MockERC20 internal assetToken;
    MockERC20 internal wethCollateral;
    MockLeveragedStrategy internal strategy;
    RoleManager internal roleManager;
    MinimalOracleAdapter internal oracle;
    MockCeresSwapper internal swapper;

    address internal management;
    address internal keeper;
    address internal user;

    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    function setUp() public {
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        user = makeAddr("user");

        // asset == debtToken (WETH looping), collateral is distinct (WSTETH).
        assetToken = new MockERC20("Mock WETH", "WETH", 18);
        wethCollateral = new MockERC20("Mock WSTETH", "WSTETH", 18);

        // 1:1 oracle for all conversions — isolates net-asset arithmetic from price effects.
        oracle = new MinimalOracleAdapter(address(assetToken), address(wethCollateral), address(assetToken));

        swapper = new MockCeresSwapper();
        swapper.setExchangeRate(address(assetToken), address(wethCollateral), 1e18);
        swapper.setExchangeRate(address(wethCollateral), address(assetToken), 1e18);

        vm.prank(management);
        roleManager = new RoleManager(0, management);

        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        // Management holds TIMELOCKED_ADMIN_ROLE directly so admin calls need no timelock delay in tests.
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, management);
        vm.stopPrank();

        vm.startPrank(management);
        address proxy = Upgrades.deployTransparentProxy(
            "MockLeveragedStrategy.sol:MockLeveragedStrategy",
            management,
            abi.encodeCall(
                MockLeveragedStrategy.initialize,
                (address(assetToken), address(wethCollateral), address(assetToken), address(roleManager))
            )
        );
        strategy = MockLeveragedStrategy(proxy);

        strategy.setOracleAdapter(address(oracle));
        strategy.setSwapper(address(swapper));
        // maxSlippageBps=200, performanceFeeBps=10, maxLossBps=500, noFeeRecipient, profitUnlockPeriod=0.
        // profitUnlockPeriod=0 -> totalAssets() == realizedAssets at all times (no locked-profit accounting).
        strategy.updateConfig(200, 10, 500, address(0), 0);
        strategy.setDepositWithdrawLimits(100_000_000e18, type(uint128).max, 0);
        vm.stopPrank();
    }

    //  Position state is built with executeOperation + MockERC20 mint/burn so each
    //  test can assert exact values on all six return values of getNetAssets().
    //  These tests do not exercise vault accounting (totalAssets / realizedAssets).

    /// @notice When idle assetToken equals marketDebt, the outstanding debt is still a
    /// real liability and must be carried in full as netDebt. The idle balance has
    /// already been counted as assetBalance
    ///
    /// State: marketCollateral=3500, marketDebt=500, idle assetToken=500.
    /// Expected:
    ///   assetBalance = 500  (idle WETH counted once)
    ///   netDebt      = 500  (full market obligation, unaffected by idle balance)
    ///   netAssets    = 500 + 3500 - 500 = 3500
    function test_getNetAssets_idleEqualsDebt_debtNotZeroed() public {
        // Borrow first (zero collateral -> LTV=0), then deposit collateral (LTV = 500/3500 ~ 14%).
        vm.startPrank(management);
        wethCollateral.mint(address(strategy), 3500e18);
        strategy.executeOperation(0, 3500e18); // deposit 3500 collateral (burns wethCollateral)
        strategy.executeOperation(2, 500e18); // borrow 500 -> mints 500 assetToken to strategy
        vm.stopPrank();

        assertEq(strategy.marketCollateral(), 3500e18, "marketCollateral");
        assertEq(strategy.marketDebt(), 500e18, "marketDebt");
        assertEq(assetToken.balanceOf(address(strategy)), 500e18, "idle assetToken");

        (uint256 assetBalance, uint256 netAssets, , , , uint256 netDebt) = strategy.getNetAssets();

        assertEq(assetBalance, 500e18, "assetBalance");
        assertEq(netDebt, 500e18, "netDebt must equal full marketDebt");
        assertEq(netAssets, 3500e18, "netAssets must equal collateral + idle - debt");
    }

    /// @notice When idle assetToken exceeds marketDebt the surplus is genuine free capital,
    /// but the debt obligation itself is unchanged. netDebt stays at marketDebt and the
    /// surplus is already reflected in the higher assetBalance — it must not be added again.
    ///
    /// State: marketCollateral=3500, marketDebt=500, idle assetToken=1500.
    /// Expected:
    ///   assetBalance = 1500
    ///   netDebt      = 500
    ///   netAssets    = 1500 + 3500 - 500 = 4500
    function test_getNetAssets_idleExceedsDebt_surplusReflectedInAssetBalanceOnly() public {
        vm.startPrank(management);
        wethCollateral.mint(address(strategy), 3500e18);
        strategy.executeOperation(0, 3500e18);
        strategy.executeOperation(2, 500e18);
        vm.stopPrank();
        assetToken.mint(address(strategy), 1000e18); // idle = 500 (borrow proceeds) + 1000 = 1500

        assertEq(assetToken.balanceOf(address(strategy)), 1500e18, "idle assetToken");

        (uint256 assetBalance, uint256 netAssets, , , , uint256 netDebt) = strategy.getNetAssets();

        assertEq(assetBalance, 1500e18, "assetBalance");
        assertEq(netDebt, 500e18, "netDebt must equal full marketDebt");
        assertEq(netAssets, 4500e18, "netAssets must equal collateral + idle - debt");
    }

    /// @notice Baseline: no debt, no idle assetToken.
    /// netAssets equals the collateral value exactly.
    function test_getNetAssets_noDebtNoIdle_equalsCollateral() public {
        wethCollateral.mint(address(strategy), 3500e18);
        vm.prank(management);
        strategy.executeOperation(0, 3500e18); // deposit only, no borrow

        (uint256 assetBalance, uint256 netAssets, , , , uint256 netDebt) = strategy.getNetAssets();

        assertEq(assetBalance, 0, "assetBalance should be zero");
        assertEq(netDebt, 0, "netDebt should be zero");
        assertEq(netAssets, 3500e18, "netAssets should equal collateral");
    }

    /// @notice After a partial repayment the remaining marketDebt is still a real obligation.
    /// The idle assetToken left in the strategy after repayment is not a further offset —
    /// it is simply undeployed capital already captured in assetBalance.
    ///
    /// State: deposit 3500 collateral, borrow 500, repay 300.
    ///   -> marketCollateral=3500, marketDebt=200, idle assetToken=200.
    /// Expected:
    ///   assetBalance = 200
    ///   netDebt      = 200  (remaining debt, not zeroed by idle balance)
    ///   netAssets    = 200 + 3500 - 200 = 3500
    function test_getNetAssets_afterPartialRepay_remainingDebtNotZeroed() public {
        vm.startPrank(management);
        wethCollateral.mint(address(strategy), 3500e18);
        strategy.executeOperation(0, 3500e18);
        strategy.executeOperation(2, 500e18);
        strategy.executeOperation(3, 300e18); // repay 300 -> burns 300 assetToken, marketDebt->200
        vm.stopPrank();

        assertEq(strategy.marketCollateral(), 3500e18, "marketCollateral");
        assertEq(strategy.marketDebt(), 200e18, "marketDebt");
        assertEq(assetToken.balanceOf(address(strategy)), 200e18, "idle assetToken");

        (uint256 assetBalance, uint256 netAssets, , , , uint256 netDebt) = strategy.getNetAssets();

        assertEq(assetBalance, 200e18, "assetBalance");
        assertEq(netDebt, 200e18, "netDebt must equal remaining marketDebt");
        assertEq(netAssets, 3500e18, "netAssets must equal collateral + idle - debt");
    }

    /// @notice Full lifecycle: deposit -> lever up -> requestRedeem -> processCurrentRequest -> harvest.
    ///
    /// After processCurrentRequest unwinds part of the leveraged position, idle assetToken
    /// accumulates in the strategy (collateral was withdrawn and swapped back to WETH).
    /// This idle WETH is already captured in assetBalance. It must not also reduce netDebt,
    /// so the oracle live view (getNetAssets) must stay in lockstep with the accounting
    /// baseline (realizedAssets). A drift between the two would cause a phantom profit on
    /// the next harvest.
    ///
    /// Invariants verified:
    ///   1. realizedAssets == getNetAssets().netAssets
    ///   2. harvestAndReport() returns profit=0, loss=0
    ///      Slippage cost is borne by the withdrawing user via a lower price-per-share;
    ///      it is not a vault-level loss and must not appear in the harvest report.
    function test_processCurrentRequest_noPhantomProfitAfterUnwind() public {
        uint256 depositAmount = 3000e18;
        uint256 borrowAmount = 500e18;
        uint256 collateralAmount = depositAmount + borrowAmount; // 3500 — full idle balance swapped

        // 1. User deposits 3000 WETH.
        assetToken.mint(user, depositAmount);
        vm.startPrank(user);
        assetToken.approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.totalAssets(), depositAmount, "post-deposit");

        // 2. Borrow 500. Zero collateral -> LTV=0 -> validateStrategyLtv passes.
        //    Strategy now holds 3500 idle WETH, marketDebt=500.
        vm.prank(management);
        strategy.executeOperation(2, borrowAmount);

        // 3. Swap all 3500 idle WETH -> WSTETH 1:1 and deposit as collateral.
        //    The swapper holds WSTETH to fund the swap.
        //    After: idle=0, marketCollateral=3500, marketDebt=500, netAssets=3000 (unchanged).
        wethCollateral.mint(address(swapper), collateralAmount);
        vm.prank(keeper);
        strategy.swapAndDepositCollateral(collateralAmount, bytes(""));

        assertEq(strategy.totalAssets(), depositAmount, "post-levererage up: netAssets must not change");
        assertEq(strategy.marketCollateral(), collateralAmount, "marketCollateral");
        assertEq(strategy.marketDebt(), borrowAmount, "marketDebt");

        // 4. User requests a partial withdrawal (1000 shares ~ 1000 WETH at current 1:1 PPS).
        uint256 withdrawShares = 1000e18;
        vm.prank(user);
        strategy.requestRedeem(withdrawShares, user, user);

        // 5. Set 100 bps exit slippage on the collateral->asset swap.
        //    This slippage is the cost of unwinding; it is absorbed by the withdrawing user
        //    through a reduced price-per-share, not carried as a vault-level loss.
        swapper.setExchangeRate(address(wethCollateral), address(assetToken), 0.99e18);

        // 6. Keeper processes the withdrawal with no flash loan.
        vm.prank(keeper);
        strategy.processCurrentRequest(abi.encode(uint256(0), bytes(""), bytes("")));

        // 7. Invariant 1: oracle live view must equal the accounting baseline.
        //    If idle assetToken freed during the unwind were miscounted in getNetAssets(),
        //    netAssetsLive would exceed realizedAssets and the next harvest would report
        //    phantom profit.
        (, uint256 netAssetsLive, , , , ) = strategy.getNetAssets();
        (, , , uint256 currentlyLocked) = strategy.getProfitUnlockState();
        uint256 realizedAssets = strategy.totalAssets() + currentlyLocked;

        assertEq(realizedAssets, netAssetsLive, "oracle view diverged from accounting baseline");

        // 8. Invariant 2: no profit and no vault-level loss on the next harvest.
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.harvestAndReport();

        assertEq(profit, 0, "phantom profit: idle assetToken was double-counted in getNetAssets");
        assertEq(loss, 0, "unexpected vault loss: unwind slippage must be absorbed by the withdrawing user");
    }
}
