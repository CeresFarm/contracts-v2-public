// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {LeveragedEuler} from "src/strategies/LeveragedEuler.sol";
import {OracleAdapter} from "src/periphery/OracleAdapter.sol";
import {UniversalOracleRouter} from "src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "src/interfaces/periphery/IUniversalOracleRouter.sol";
import {EulerOracleRoute} from "src/periphery/routes/EulerOracleRoute.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {FlashLoanRouter} from "src/periphery/FlashLoanRouter.sol";

import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MockEVault} from "test/euler/mock/MockEVault.sol";
import {MockEVC} from "test/euler/mock/MockEVC.sol";
import {MockEulerOracle} from "test/euler/mock/MockEulerOracle.sol";
import {MockCeresSwapper} from "test/mock/periphery/MockCeresSwapper.sol";

/// @title EulerTestSetup
/// @notice Euler-specific test setup inheriting from LeveragedStrategyBaseSetup
/// @dev Tests sUSDe as asset/collateral with USDC as debt using Euler EVaults
contract EulerTestSetup is LeveragedStrategyBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   EULER-SPECIFIC CONSTANTS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 constant ORACLE_PRECISION = 1e18;

    address public constant USD_SYNTHETIC_TOKEN = 0x0000000000000000000000000000000000000348;

    // Token decimals
    uint8 public constant SUSDE_DECIMALS = 18;
    uint8 public constant USDC_DECIMALS = 6;

    // Prices in USD (18 decimals)
    uint256 public constant SUSDE_USD_PRICE = 1.21e18; // $1.21
    uint256 public constant USDC_USD_PRICE = 1e18; // $1.00

    // Exchange Rates (18 decimals precision for Oracle)
    // Rate = (Base Price / Quote Price) * Precision
    uint256 public constant SUSDE_TO_USDC_ORACLE_PRICE = (SUSDE_USD_PRICE * ORACLE_PRECISION) / USDC_USD_PRICE;
    uint256 public constant USDC_TO_SUSDE_ORACLE_PRICE = (USDC_USD_PRICE * ORACLE_PRECISION) / SUSDE_USD_PRICE;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   EULER-SPECIFIC CONTRACTS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Euler infrastructure
    MockEVault public collateralVault;
    MockEVault public borrowVault;
    MockEVC public evc;
    MockEulerOracle public eulerOracle;

    // Typed references (same as base but with concrete types)
    MockERC20 public sUSDe;
    MockERC20 public usdc;
    OracleAdapter public eulerOracleAdapter;
    UniversalOracleRouter public router;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SETUP OVERRIDE                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Setup function - calls parent setUp which invokes all abstract implementations
    function setUp() public virtual override {
        super.setUp();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           IMPLEMENT ABSTRACT FUNCTIONS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _deployMockTokens() internal override {
        sUSDe = new MockERC20("Ethena Staked USDe", "sUSDe", SUSDE_DECIMALS);
        usdc = new MockERC20("Circle USD", "USDC", USDC_DECIMALS);

        // Set base contract references
        assetToken = sUSDe;
        debtToken = usdc;
    }

    function _setupProtocolContracts() internal override {
        // Deploy Euler Vault Connector
        evc = new MockEVC();

        // Deploy EVaults
        collateralVault = new MockEVault(address(sUSDe), "Euler sUSDe Vault", "esUSDe");
        borrowVault = new MockEVault(address(usdc), "Euler USDC Vault", "eUSDC");

        // Deploy oracle and set prices
        eulerOracle = new MockEulerOracle();

        // Set prices using the calculated constants
        eulerOracle.setPrice(address(sUSDe), address(usdc), SUSDE_TO_USDC_ORACLE_PRICE);
        eulerOracle.setPrice(address(usdc), address(sUSDe), USDC_TO_SUSDE_ORACLE_PRICE);
        eulerOracle.setPrice(address(sUSDe), USD_SYNTHETIC_TOKEN, SUSDE_USD_PRICE);
        eulerOracle.setPrice(address(usdc), USD_SYNTHETIC_TOKEN, USDC_USD_PRICE);

        // Prices for the second hop of the 2-hop VIRTUAL_USD route:
        // 1 USD unit (18 decimals) = 1 USDC = 10**USDC_DECIMALS
        eulerOracle.setPrice(USD_SYNTHETIC_TOKEN, address(usdc), 10 ** USDC_DECIMALS);

        // 1 USD unit (18 decimals) = (1/1.21) sUSDe = USDC_TO_SUSDE_ORACLE_PRICE atoms
        eulerOracle.setPrice(USD_SYNTHETIC_TOKEN, address(sUSDe), USDC_TO_SUSDE_ORACLE_PRICE);

        // Configure borrowVault with EVC + oracle so accountLiquidity returns correct USD values
        borrowVault.setRiskConfig(address(evc), address(eulerOracle), USD_SYNTHETIC_TOKEN);
    }

    function _setupOracleAdapter() internal override {
        router = new UniversalOracleRouter(address(roleManager));
        EulerOracleRoute eulerRoute = new EulerOracleRoute(address(eulerOracle));

        // Set path from Collateral (sUSDe) to Debt (USDC) via VIRTUAL_USD and vice versa
        IUniversalOracleRouter.RouteStep[] memory collToDebt = new IUniversalOracleRouter.RouteStep[](2);
        collToDebt[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(840), // VIRTUAL_USD
            oracleRoute: address(eulerRoute)
        });
        collToDebt[1] = IUniversalOracleRouter.RouteStep({
            targetToken: address(usdc),
            oracleRoute: address(eulerRoute)
        });
        _runViaTimelock(address(router), abi.encodeCall(router.setRoute, (address(sUSDe), address(usdc), collToDebt)));

        IUniversalOracleRouter.RouteStep[] memory debtToColl = new IUniversalOracleRouter.RouteStep[](2);
        debtToColl[0] = IUniversalOracleRouter.RouteStep({targetToken: address(840), oracleRoute: address(eulerRoute)});
        debtToColl[1] = IUniversalOracleRouter.RouteStep({
            targetToken: address(sUSDe),
            oracleRoute: address(eulerRoute)
        });
        _runViaTimelock(address(router), abi.encodeCall(router.setRoute, (address(usdc), address(sUSDe), debtToColl)));

        eulerOracleAdapter = new OracleAdapter(
            address(router),
            address(sUSDe), // asset token
            address(sUSDe), // collateral token (same as asset)
            address(usdc) // debt token
        );

        // Set base contract reference
        oracleAdapter = eulerOracleAdapter;
    }

    function _setupSwapper() internal override {
        swapper = new MockCeresSwapper();

        // Set exchange rates for sUSDe <-> USDC
        swapper.setExchangeRate(address(sUSDe), address(usdc), SUSDE_TO_USDC_ORACLE_PRICE);
        swapper.setExchangeRate(address(usdc), address(sUSDe), USDC_TO_SUSDE_ORACLE_PRICE);

        sUSDe.mint(address(swapper), 100_000_000 * 1e18);
        usdc.mint(address(swapper), 500_000_000 * 1e6);
    }

    function _deployRoleManager() internal override {
        roleManager = new RoleManager(2 days, management);

        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        vm.stopPrank();

        // Deploy timelock and grant TIMELOCKED_ADMIN_ROLE to it
        _deployTimelock();
    }

    function _deployStrategy() internal override {
        vm.startPrank(management);

        // Deploy proxy and initialize
        address proxy = Upgrades.deployTransparentProxy(
            "LeveragedEuler.sol:LeveragedEuler",
            management,
            abi.encodeCall(
                LeveragedEuler.initialize,
                (
                    address(sUSDe), // asset token
                    "Ceres Leveraged sUSDe-USDC Euler", // name
                    "ceres-sUSDe-USDC-Euler", // symbol
                    address(sUSDe), // collateral token (same as asset)
                    address(usdc), // debt token
                    address(collateralVault), // collateral vault
                    address(borrowVault), // borrow vault
                    address(evc), // vault connector
                    address(roleManager) // role manager
                )
            )
        );

        strategy = ILeveragedStrategy(proxy);
        console.log("Strategy proxy deployed at:", address(strategy));

        roleManager.grantRole(KEEPER_ROLE, keeper);

        vm.stopPrank();
    }

    function _initializeStrategy() internal override {
        // Timelocked setters: route through real TimelockController.
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setSwapper, (address(swapper))));
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setOracleAdapter, (address(eulerOracleAdapter))));
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setFlashLoanRouter, (address(flashLoanRouter))));
        _runViaTimelock(
            address(strategy),
            abi.encodeCall(strategy.updateConfig, (MAX_SLIPPAGE_BPS, 1500, MAX_LOSS_BPS, feeReceiver, uint32(0)))
        );

        vm.startPrank(management);
        strategy.setTargetLtv(TARGET_LTV_BPS, LTV_BUFFER_BPS);
        strategy.setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT_SHARES, 0);
        vm.stopPrank();
    }

    function _configureFlashLoanRouter() internal override {
        _runViaTimelock(
            address(flashLoanRouter),
            abi.encodeCall(
                flashLoanRouter.setFlashConfig,
                (address(strategy), FlashLoanRouter.FlashSource.EULER, address(borrowVault), true)
            )
        );
    }

    function _addProtocolLiquidity() internal override {
        uint256 amountCollateralToken = 100_000_000 * 10 ** SUSDE_DECIMALS;
        uint256 amountDebtToken = 500_000_000 * 10 ** USDC_DECIMALS;

        sUSDe.mint(liquidityProvider, amountCollateralToken);
        usdc.mint(liquidityProvider, amountDebtToken);

        vm.startPrank(liquidityProvider);
        sUSDe.approve(address(collateralVault), amountCollateralToken);
        collateralVault.deposit(amountCollateralToken, liquidityProvider);

        usdc.approve(address(borrowVault), amountDebtToken);
        borrowVault.deposit(amountDebtToken, liquidityProvider);
        vm.stopPrank();
    }

    function _simulateInterestAccrual(
        uint256 interestRateBpsCollateral,
        uint256 interestRateBpsDebt,
        uint256 timeElapsed
    ) internal override {
        // For Euler, interest is simulated by accruing to totalBorrows
        uint256 totalDebt = borrowVault.totalBorrows();

        // Collateral token interest is indicated by an increase in the price of the collateral token
        uint256 currentCollateralPrice = eulerOracle.prices(address(sUSDe), address(usdc));
        uint256 updatedPrice = currentCollateralPrice +
            (currentCollateralPrice * interestRateBpsCollateral * timeElapsed) / (BPS_PRECISION * 365 days);

        // Update token price for oracle and swapper exchange rate
        eulerOracle.setPrice(address(sUSDe), address(usdc), updatedPrice);
        swapper.setExchangeRate(address(sUSDe), address(usdc), updatedPrice);

        // Keep USD pricing in sync so adapter reflects collateral appreciation
        uint256 updatedPriceUsd = (updatedPrice * USDC_USD_PRICE) / ORACLE_PRECISION;
        eulerOracle.setPrice(address(sUSDe), USD_SYNTHETIC_TOKEN, updatedPriceUsd);

        // Also update the inverse rate for USDC -> sUSDe swaps (used in leverage down)
        uint256 inverseRate = (ORACLE_PRECISION * ORACLE_PRECISION) / updatedPrice;
        swapper.setExchangeRate(address(usdc), address(sUSDe), inverseRate);
        eulerOracle.setPrice(address(usdc), address(sUSDe), inverseRate);

        // Accrue debt interest
        if (totalDebt > 0 && interestRateBpsDebt > 0) {
            uint256 debtInterest = (totalDebt * interestRateBpsDebt * timeElapsed) / (BPS_PRECISION * 365 days);
            borrowVault.accrueInterest(address(strategy), debtInterest);
        }

        // Move time forward
        skip(timeElapsed);
    }

    function _simulatePriceChange(int256 percentChange) internal override {
        uint256 currentPrice = eulerOracle.prices(address(sUSDe), address(usdc));
        uint256 newPrice;

        if (percentChange >= 0) {
            newPrice = currentPrice + (currentPrice * uint256(percentChange)) / 100;
        } else {
            newPrice = currentPrice - (currentPrice * uint256(-percentChange)) / 100;
        }

        eulerOracle.setPrice(address(sUSDe), address(usdc), newPrice);
        swapper.setExchangeRate(address(sUSDe), address(usdc), newPrice);

        // Keep USD pricing aligned with the new collateral price
        uint256 newPriceUsd = (newPrice * USDC_USD_PRICE) / ORACLE_PRECISION;
        eulerOracle.setPrice(address(sUSDe), USD_SYNTHETIC_TOKEN, newPriceUsd);

        // Update inverse rate
        uint256 inverseRate = (ORACLE_PRECISION * ORACLE_PRECISION) / newPrice;
        eulerOracle.setPrice(address(usdc), address(sUSDe), inverseRate);
        swapper.setExchangeRate(address(usdc), address(sUSDe), inverseRate);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    LABEL ADDRESSES                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _labelAddresses() internal override {
        vm.label(address(sUSDe), "sUSDe");
        vm.label(address(usdc), "USDC");
        vm.label(address(collateralVault), "Collateral Vault");
        vm.label(address(borrowVault), "Borrow Vault");
        vm.label(address(evc), "EVC");
        vm.label(address(eulerOracle), "Euler Oracle");
        vm.label(address(eulerOracleAdapter), "Euler Oracle Adapter");
        vm.label(USD_SYNTHETIC_TOKEN, "USD Token");
        vm.label(address(swapper), "Ceres Swapper");
        vm.label(address(strategy), "LeveragedEuler Strategy");
    }
}
