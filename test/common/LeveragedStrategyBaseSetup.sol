// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

import {LeverageLib} from "../../src/libraries/LeverageLib.sol";
import {RoleManager} from "../../src/periphery/RoleManager.sol";
import {FlashLoanRouter} from "../../src/periphery/FlashLoanRouter.sol";

import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";
import {ICeresBaseVault} from "src/interfaces/strategies/ICeresBaseVault.sol";
import {IOracleAdapter} from "src/interfaces/periphery/IOracleAdapter.sol";
import {ICeresSwapper} from "src/interfaces/periphery/ICeresSwapper.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MockCeresSwapper} from "test/mock/periphery/MockCeresSwapper.sol";
import {TimelockTestHelper} from "test/common/TimelockTestHelper.sol";

/// @title LeveragedStrategyBaseSetup
/// @notice Common test infrastructure for all LeveragedStrategy implementations
/// @dev Protocol-specific test setups should inherit from this and implement abstract functions
abstract contract LeveragedStrategyBaseSetup is Test {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 constant BPS_PRECISION = 10_000;

    // LTV parameters - common across all protocols
    uint16 constant TARGET_LTV_BPS = 7000; // 70%
    uint16 constant LTV_BUFFER_BPS = 50; // 0.5% buffer to ensure we don't hit max LTV after rebalance
    uint16 constant MAX_LOSS_BPS = 2_00; // 2% max loss during processing request
    uint256 constant MAX_LTV_BPS = 7500; // 75%
    uint256 constant MIN_LTV_BPS = 6500; // 65%
    uint16 constant MAX_SLIPPAGE_BPS = 25; // 0.25%
    uint96 constant DEPOSIT_LIMIT = 10_000_000 * 1e18; // 10 million
    uint128 constant REDEEM_LIMIT_SHARES = type(uint128).max;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    // Default test amounts (helper functions to account for different decimals)
    function DEFAULT_DEPOSIT() internal view returns (uint256) {
        return 10_000 * 10 ** assetToken.decimals();
    }

    /// @notice Minimum fuzz amount for profit-bearing tests. Subclasses must override this when
    /// the oracle's precision requires a higher floor to prevent output rounding to zero.
    function _minFuzzAmount() internal view virtual returns (uint256) {
        return 10_000;
    }

    function LARGE_DEPOSIT() internal view returns (uint256) {
        return 1_000_000 * 10 ** assetToken.decimals();
    }

    function SMALL_DEPOSIT() internal view returns (uint256) {
        return 100 * 10 ** assetToken.decimals();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONTRACTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Core strategy - set by protocol-specific setup
    ILeveragedStrategy public strategy;

    // Oracle adapter - set by protocol-specific setup
    IOracleAdapter public oracleAdapter;

    // Swapper - set by protocol-specific setup
    MockCeresSwapper public swapper;

    // Asset token (collateral in most cases) - set by protocol-specific setup
    MockERC20 public assetToken;

    // Debt token - set by protocol-specific setup
    MockERC20 public debtToken;

    // Rebalances whose required flash loan falls below this threshold are skipped.
    uint256 public minFlashLoanAmount;

    // Role manager
    RoleManager public roleManager;

    // Flash loan router
    FlashLoanRouter public flashLoanRouter;

    // OZ TimelockController holds TIMELOCKED_ADMIN_ROLE so all admin setter calls in tests
    // go through the production schedule->wait->execute path.
    TimelockController public timelock;
    TimelockTestHelper public timelockHelper;
    uint256 public constant TIMELOCK_MIN_DELAY = 1 days;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    TEST ACCOUNTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    address public management;
    address public keeper;
    address public user1;
    address public user2;
    address public feeReceiver;
    address public liquidityProvider;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Re-declare events for expectEmit
    event Rebalance(address indexed keeper, uint256 debtAmount, bool isLeverageUp, bool useFlashLoan);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       SETUP                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function setUp() public virtual {
        // Setup test accounts
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidityProvider = makeAddr("liquidityProvider");
        feeReceiver = makeAddr("feeReceiver");

        // Protocol-specific setup (implemented by child contracts)
        _deployMockTokens();

        minFlashLoanAmount = 10 ** IERC20Metadata(address(debtToken)).decimals();
        _setupProtocolContracts();
        _deployRoleManager();
        _setupOracleAdapter();
        _setupSwapper();
        _deployStrategy();
        _deployFlashLoanRouter();
        _configureFlashLoanRouter();
        _initializeStrategy();
        _addProtocolLiquidity();
        _labelAddresses();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              ABSTRACT FUNCTIONS (Protocol-specific)                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploy mock tokens for the protocol
    function _deployMockTokens() internal virtual;

    /// @notice Setup protocol-specific contracts (Morpho, Euler vaults, Silo, etc.)
    function _setupProtocolContracts() internal virtual;

    /// @notice Setup the oracle adapter
    function _setupOracleAdapter() internal virtual;

    /// @notice Setup the swapper with exchange rates
    function _setupSwapper() internal virtual;

    /// @notice Deploy the role manager contract and set roles
    function _deployRoleManager() internal virtual;

    /// @notice Deploy the protocol-specific strategy
    function _deployStrategy() internal virtual;

    /// @notice Deploy the flash loan router
    function _deployFlashLoanRouter() internal {
        vm.startPrank(management);
        flashLoanRouter = new FlashLoanRouter(address(roleManager));
        vm.stopPrank();
    }

    /// @notice Configure flash loan routing for the deployed strategy
    function _configureFlashLoanRouter() internal virtual;

    /// @notice Initialize the strategy with configuration
    function _initializeStrategy() internal virtual;

    /// @notice Add liquidity to protocol for borrowing
    function _addProtocolLiquidity() internal virtual;

    /// @notice Label addresses for debugging
    function _labelAddresses() internal virtual;

    /// @notice Simulate interest accrual (protocol-specific)
    /// @param interestRateBpsCollateral Collateral yield in BPS
    /// @param interestRateBpsDebt Debt interest in BPS
    /// @param timeElapsed Time elapsed in seconds
    function _simulateInterestAccrual(
        uint256 interestRateBpsCollateral,
        uint256 interestRateBpsDebt,
        uint256 timeElapsed
    ) internal virtual;

    /// @notice Simulate price change (protocol-specific due to oracle differences)
    /// @param percentChange Percent change (positive or negative)
    function _simulatePriceChange(int256 percentChange) internal virtual;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  COMMON HELPER FUNCTIONS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Mint tokens to an address
    function _mintTokens(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
    }

    /// @notice Mint and approve tokens
    function _mintAndApprove(address token, address owner, address spender, uint256 amount) internal {
        _mintTokens(token, owner, amount);
        vm.prank(owner);
        IERC20(token).approve(spender, amount);
    }

    /// @notice Setup user with tokens and deposits to strategy
    function _setupUserDeposit(address user, uint256 depositAmount) internal returns (uint256 shares) {
        _mintAndApprove(address(assetToken), user, address(strategy), depositAmount);

        vm.prank(user);
        shares = strategy.deposit(depositAmount, user);
    }

    /// @notice Setup strategy with initial leverage position
    function _setupInitialLeveragePosition(uint256 initialDeposit) internal {
        // User deposits initial funds
        _setupUserDeposit(user1, initialDeposit);

        // Asset and collateral are same (IS_ASSET_COLLATERAL = true)
        uint256 debtAmount = LeverageLib.computeTargetDebt(initialDeposit, TARGET_LTV_BPS, strategy.oracleAdapter());

        // Mint debt tokens for keeper to perform initial leverage
        _mintAndApprove(address(debtToken), keeper, address(strategy), debtAmount);

        // Keeper performs initial leverage
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");
    }

    /// @notice Helper to get balance
    function _balance(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    /// @notice Get strategy's current leverage ratio
    function _getCurrentLeverage() internal view returns (uint256 leverageRatio) {
        (, uint256 netAssets, , uint256 totalCollateral, , ) = strategy.getNetAssets();

        if (netAssets == 0) return 0;

        // Leverage = (Collateral / NetAssets)
        // Convert to BPS: leverage * 10000
        uint256 collateralInAssets = oracleAdapter.convertCollateralToAssets(totalCollateral);
        leverageRatio = (collateralInAssets * BPS_PRECISION) / netAssets;
    }

    /// @notice Calculate expected LTV
    function _calculateLtv(uint256 collateralAmount, uint256 debtAmount) internal view returns (uint256 ltv) {
        if (collateralAmount == 0) return 0;

        uint256 collateralValue = oracleAdapter.convertCollateralToDebt(collateralAmount);
        ltv = (debtAmount * BPS_PRECISION) / collateralValue;
    }

    /// @notice Helper to assert approximate equality with basis points tolerance
    function _assertApproxEqBps(uint256 a, uint256 b, uint256 toleranceBps, string memory message) internal pure {
        // Convert BPS (basis points) to 18-decimal precision used by assertApproxEqRel
        // toleranceBps is in 10000 scale, Forge expects 1e18 scale
        // So multiply by 1e14 to convert: toleranceBps / 10000 * 1e18 = toleranceBps * 1e14
        assertApproxEqRel(a, b, toleranceBps * 1e14, message);
    }

    /// @notice Get strategy state for debugging
    function _logStrategyState(string memory label) internal view {
        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();
        uint256 leverage = _getCurrentLeverage();
        uint256 ltv = _calculateLtv(totalCollateral, totalDebt);

        console2.log("=== Strategy State:", label, "===");
        console2.log("Net Assets:", netAssets);
        console2.log("Total Collateral:", totalCollateral);
        console2.log("Total Debt:", totalDebt);
        console2.log("Leverage Ratio (BPS):", leverage);
        console2.log("LTV (BPS):", ltv);
        console2.log("Asset Balance:", _balance(address(assetToken), address(strategy)));
        console2.log("Debt Balance:", _balance(address(debtToken), address(strategy)));
        console2.log("=====================================");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                        ASYNC WITHDRAWAL HELPER FUNCTIONS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Helper to request redeem - explicit phase testing
    /// @param user The user requesting the withdrawal
    /// @param shares The number of shares to redeem
    /// @return requestId The request ID for the withdrawal
    function _requestRedeemAs(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = strategy.requestRedeem(shares, user, user);
    }

    /// @notice Helper to process current request with auto-computed flash loan amount
    /// @dev Mirrors what a keeper would compute off-chain:
    ///      1. Get pending request shares -> convert to expectedAssets
    ///      2. Subtract idle assets to get amountToFree
    ///      3. Compute new target debt for reduced net assets
    ///      4. flashLoanAmount = currentDebt - newTargetDebt (with slippage buffer)
    function _processCurrentRequest() internal {
        uint256 currentDebt = strategy.getDebtAmount();

        // No debt -> no flash loan needed (unlevered position)
        if (currentDebt == 0) {
            _processCurrentRequest(abi.encode(uint256(0), bytes(""), bytes("")));
            return;
        }

        // 1. Get pending request details
        uint128 requestId = strategy.currentRequestId();
        ICeresBaseVault.RequestDetails memory request = strategy.requestDetails(requestId);
        uint256 expectedAssets = strategy.convertToAssets(request.totalShares);

        // 2. Compute how much needs to be freed (subtract idle assets)
        uint256 idleAssets = assetToken.balanceOf(address(strategy));
        uint128 reserve = strategy.withdrawalReserve();
        uint256 availableIdle = idleAssets > reserve ? idleAssets - reserve : 0;

        uint256 flashLoanAmount;
        if (expectedAssets > availableIdle) {
            uint256 amountToFree = expectedAssets - availableIdle;

            // 3. Compute new net assets after freeing funds
            (, uint256 currentNetAssets, , , , ) = strategy.getNetAssets();
            uint256 newNetAssets = currentNetAssets > amountToFree ? currentNetAssets - amountToFree : 0;

            // 4. Compute new target debt and flash loan amount.
            // Guard: if newNetAssets is oracle-precision dust (rounds to zero),
            // convertAssetsToDebt() reverts with InvalidPrice. Treat that as
            // newTargetDebt = 0 so the keeper fully deleverages.
            uint256 newTargetDebt = 0;
            try strategy.oracleAdapter().convertAssetsToDebt(newNetAssets) returns (uint256 debtEquivalent) {
                if (debtEquivalent > 0) {
                    newTargetDebt = LeverageLib.computeTargetDebt(
                        newNetAssets,
                        TARGET_LTV_BPS,
                        strategy.oracleAdapter()
                    );
                }
            } catch {
                // newNetAssets is oracle-precision dust -> full deleverage (newTargetDebt stays 0)
            }
            if (currentDebt > newTargetDebt) {
                flashLoanAmount = currentDebt - newTargetDebt;
                // Apply slippage buffer (add MAX_SLIPPAGE_BPS to ensure sufficient deleverage)
                flashLoanAmount = flashLoanAmount + (flashLoanAmount * MAX_SLIPPAGE_BPS) / BPS_PRECISION;
                // Cap at current debt
                if (flashLoanAmount > currentDebt) {
                    flashLoanAmount = currentDebt;
                }
            }
        }

        // Skip if the flash loan amount is below the threshold
        if (flashLoanAmount < minFlashLoanAmount) {
            flashLoanAmount = 0;
        }

        _processCurrentRequest(abi.encode(flashLoanAmount, bytes(""), bytes("")));
    }

    /// @notice Helper to process current request - explicit phase testing
    /// @param extraData Optional extra data for freeing funds
    function _processCurrentRequest(bytes memory extraData) internal {
        vm.prank(keeper);
        strategy.processCurrentRequest(extraData);
    }

    /// @notice Helper to complete redeem - explicit phase testing
    /// @param user The user redeeming
    /// @param shares The number of shares to redeem
    /// @return assets The number of assets received
    function _redeemAs(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = strategy.redeem(shares, user, user);
    }

    /// @notice Helper to complete withdrawal - explicit phase testing
    /// @param user The user withdrawing
    /// @param assets The number of assets to withdraw
    /// @return shares The number of shares burned
    function _withdrawAs(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = strategy.withdraw(assets, user, user);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  TIMELOCK HELPERS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the TimelockController + TimelockTestHelper, grants TIMELOCKED_ADMIN_ROLE
    /// to the timelock, and renounces the bootstrap grant from `management` so the test models
    /// the post-renounce production world (only the timelock can apply timelocked setters).
    /// Child setups should call this from `_deployRoleManager` after the role manager is
    /// constructed.
    /// @dev `management` is used as the bootstrap admin/proposer/executor on the timelock so
    /// test code can drive scheduling and execution. The role hand-off (grant to timelock,
    /// renounce from management) must happen in this exact order: once management renounces,
    /// it loses admin power over the self-administered role.
    function _deployTimelock() internal {
        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, management);

        vm.startPrank(management);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
        // Renounce the bootstrap grant pre-applied by the RoleManager constructor so management
        // can no longer call timelocked setters directly.
        roleManager.renounceRole(TIMELOCKED_ADMIN_ROLE, management);
        vm.stopPrank();
    }

    /// @notice Schedule + skip(min delay) + execute a single call through the timelock,
    /// pranking `management` as the proposer/executor. This is the canonical
    /// path that production deployments use to update TIMELOCKED_ADMIN_ROLE setters.
    function _runViaTimelock(address target, bytes memory data) internal {
        timelockHelper.runViaTimelock(timelock, target, data, management);
    }
}
