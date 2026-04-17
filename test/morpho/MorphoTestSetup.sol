// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {LeveragedMorpho} from "src/strategies/LeveragedMorpho.sol";
import {OracleAdapter} from "src/periphery/OracleAdapter.sol";
import {UniversalOracleRouter} from "src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "src/interfaces/periphery/IUniversalOracleRouter.sol";
import {MorphoOracleRoute} from "src/periphery/routes/MorphoOracleRoute.sol";
import {AaveOracleRoute} from "src/periphery/routes/AaveOracleRoute.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {FlashLoanRouter} from "src/periphery/FlashLoanRouter.sol";

import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";

import {MarketParams, Market, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

import {Morpho} from "test/morpho/Morpho.sol";
import {IrmMock} from "test/morpho/mock/IrmMock.sol";
import {OracleMock} from "morpho-blue/mocks/OracleMock.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MockCeresSwapper} from "test/mock/periphery/MockCeresSwapper.sol";

/// @title MorphoTestSetup
/// @notice Morpho-specific test setup inheriting from LeveragedStrategyBaseSetup
/// @dev Tests sUSDe as asset/collateral with USDC as debt
contract MorphoTestSetup is LeveragedStrategyBaseSetup {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /// @notice Setup function - calls parent setUp which invokes all abstract implementations
    function setUp() public virtual override {
        super.setUp();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   MORPHO-SPECIFIC CONSTANTS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 constant MORPHO_ORACLE_PRECISION = 1e36;

    // Morpho LLTV (Liquidation Loan-To-Value)
    uint256 constant MORPHO_LLTV = 86e16; // 86%

    // Token decimals
    uint8 public constant SUSDE_DECIMALS = 18;
    uint8 public constant USDC_DECIMALS = 6;

    // Prices in USD (18 decimals)
    uint256 public constant SUSDE_USD_PRICE = 1.21e18; // $1.21
    uint256 public constant USDC_USD_PRICE = 1e18; // $1.00

    // Morpho Oracle Price Format:
    // price = actualPrice * 1e36 * 10^debtDecimals / 10^collateralDecimals
    // For 1 sUSDe = 1.21 USDC: 1.21 * 1e36 * 1e6 / 1e18 = 1.21e24
    uint256 public constant MORPHO_ORACLE_PRICE = 1210000000000000000000000; // 1.21e24

    // Exchange rates for swapper (1e18 precision)
    uint256 public constant SUSDE_TO_USDC_RATE = 1.21e18; // 1 sUSDe = 1.21 USDC
    uint256 public constant USDC_TO_SUSDE_RATE = 0.826446280991735537e18; // 1 USDC = ~0.826 sUSDe

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   MORPHO-SPECIFIC CONTRACTS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Morpho infrastructure
    Morpho public morpho;
    OracleMock public morphoOracle;
    IrmMock public irm;

    // Market params
    MarketParams public marketParams;

    // Typed references (same as base but with concrete types)
    MockERC20 public sUSDe;
    MockERC20 public usdc;
    OracleAdapter public morphoOracleAdapter;
    UniversalOracleRouter public router;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           IMPLEMENT ABSTRACT FUNCTIONS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _deployMockTokens() internal override {
        sUSDe = new MockERC20("Ethena Staked USDe", "sUSDe", SUSDE_DECIMALS);
        usdc = new MockERC20("Circle USD", "USDC", USDC_DECIMALS);

        // Set base class references
        assetToken = sUSDe;
        debtToken = usdc;
    }

    function _setupProtocolContracts() internal override {
        // Deploy actual Morpho contract (we are the owner)
        morpho = new Morpho(address(this));

        // Deploy IRM mock and enable it
        irm = new IrmMock();
        morpho.enableIrm(address(irm));

        // Enable LLTV
        morpho.enableLltv(MORPHO_LLTV);

        // Deploy oracle and set price
        morphoOracle = new OracleMock();
        morphoOracle.setPrice(MORPHO_ORACLE_PRICE);

        // Create market params
        marketParams = MarketParams({
            collateralToken: address(sUSDe),
            loanToken: address(usdc),
            oracle: address(morphoOracle),
            irm: address(irm),
            lltv: MORPHO_LLTV
        });

        // Create the market
        morpho.createMarket(marketParams);
    }

    function _setupOracleAdapter() internal override {
        router = new UniversalOracleRouter(address(roleManager));
        MorphoOracleRoute morphoRoute = new MorphoOracleRoute(address(morphoOracle), address(sUSDe), address(usdc));

        vm.startPrank(management);
        IUniversalOracleRouter.RouteStep[] memory collToDebt = new IUniversalOracleRouter.RouteStep[](1);
        collToDebt[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(usdc),
            oracleRoute: address(morphoRoute)
        });
        router.setRoute(address(sUSDe), address(usdc), collToDebt);

        IUniversalOracleRouter.RouteStep[] memory debtToColl = new IUniversalOracleRouter.RouteStep[](1);
        debtToColl[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(sUSDe),
            oracleRoute: address(morphoRoute)
        });
        router.setRoute(address(usdc), address(sUSDe), debtToColl);
        vm.stopPrank();

        morphoOracleAdapter = new OracleAdapter(
            address(router),
            address(sUSDe), // asset token
            address(sUSDe), // collateral token
            address(usdc) // debt token
        );

        // Set base class reference
        oracleAdapter = morphoOracleAdapter;
    }

    function _setupSwapper() internal override {
        swapper = new MockCeresSwapper();

        // Set exchange rates for sUSDe <-> USDC
        swapper.setExchangeRate(address(sUSDe), address(usdc), SUSDE_TO_USDC_RATE);
        swapper.setExchangeRate(address(usdc), address(sUSDe), USDC_TO_SUSDE_RATE);

        // Fund swapper with tokens for swaps
        sUSDe.mint(address(swapper), 100_000_000 * 1e18);
        usdc.mint(address(swapper), 500_000_000 * 1e6);
    }

    function _deployRoleManager() internal override {
        roleManager = new RoleManager(2 days, management);

        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        vm.stopPrank();
    }

    function _deployStrategy() internal override {
        vm.startPrank(management);

        // Deploy proxy and initialize
        address proxy = Upgrades.deployTransparentProxy(
            "LeveragedMorpho.sol:LeveragedMorpho",
            management,
            abi.encodeCall(
                LeveragedMorpho.initialize,
                (
                    address(sUSDe), // asset token
                    "Ceres Leveraged sUSDe-USDC Morpho", // name
                    "ceres-sUSDe-USDC-Morpho", // symbol
                    address(sUSDe), // collateral token (same as asset)
                    address(usdc), // debt token
                    address(morpho), // morpho market
                    address(morphoOracle), // oracle
                    address(irm), // irm
                    MORPHO_LLTV, // lltv
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
        vm.startPrank(management);

        // Set swapper and oracle adapter (executes immediately since current values are address(0))
        strategy.manageUpdate(ILeveragedStrategy.UpdateAction.Request, SWAPPER_KEY, address(swapper));
        strategy.manageUpdate(ILeveragedStrategy.UpdateAction.Request, ORACLE_KEY, address(morphoOracleAdapter));
        strategy.manageUpdate(ILeveragedStrategy.UpdateAction.Request, FLASH_LOAN_ROUTER_KEY, address(flashLoanRouter));

        // Set LTV parameters + fee recipient
        strategy.updateConfig(MAX_SLIPPAGE_BPS, 1500, MAX_LOSS_BPS, feeReceiver);
        strategy.setTargetLtv(TARGET_LTV_BPS, LTV_BUFFER_BPS);
        strategy.setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT_SHARES, 0);

        vm.stopPrank();

        // Approve Morpho market to spend strategy's collateral and debt tokens
        vm.startPrank(address(strategy));
        sUSDe.approve(address(morpho), type(uint256).max);
        usdc.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    function _configureFlashLoanRouter() internal override {
        vm.prank(management);
        flashLoanRouter.setFlashConfig(address(strategy), FlashLoanRouter.FlashSource.MORPHO, address(morpho), true);
    }

    function _addProtocolLiquidity() internal override {
        uint256 amountDebtToken = 100_000_000 * 10 ** USDC_DECIMALS; // 100M USDC

        usdc.mint(liquidityProvider, amountDebtToken);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(morpho), amountDebtToken);
        morpho.supply(marketParams, amountDebtToken, 0, liquidityProvider, "");
        vm.stopPrank();
    }

    function _labelAddresses() internal override {
        vm.label(address(sUSDe), "sUSDe");
        vm.label(address(usdc), "USDC");
        vm.label(address(morpho), "Morpho");
        vm.label(address(morphoOracle), "Morpho Oracle");
        vm.label(address(morphoOracleAdapter), "Morpho Oracle Adapter");
        vm.label(address(swapper), "Ceres Swapper");
        vm.label(address(strategy), "LeveragedMorpho Strategy");
    }

    function _simulateInterestAccrual(
        uint256 interestRateBpsCollateral,
        uint256 interestRateBpsDebt,
        uint256 timeElapsed
    ) internal override {
        // Configure IRM mock with the desired annualized borrow rate so Morpho accrues debt interest at this rate
        irm.setAnnualBorrowRateBps(interestRateBpsDebt);

        // Collateral token interest is indicated by an increase in the price
        uint256 currentPrice = morphoOracle.price();
        uint256 updatedPrice = currentPrice +
            (currentPrice * interestRateBpsCollateral * timeElapsed) / (BPS_PRECISION * 365 days);

        morphoOracle.setPrice(updatedPrice);

        // Update swapper exchange rates accordingly
        uint256 newSusdeToUsdcRate = (updatedPrice * 10 ** SUSDE_DECIMALS) / (10 ** USDC_DECIMALS);
        newSusdeToUsdcRate = newSusdeToUsdcRate / 1e18;

        swapper.setExchangeRate(address(sUSDe), address(usdc), newSusdeToUsdcRate);
        swapper.setExchangeRate(address(usdc), address(sUSDe), (MORPHO_ORACLE_PRECISION) / newSusdeToUsdcRate);

        skip(timeElapsed);

        // Trigger interest accrual in Morpho
        morpho.accrueInterest(marketParams);
    }

    function _simulatePriceChange(int256 percentChange) internal override {
        uint256 currentPrice = morphoOracle.price();
        uint256 newPrice;

        if (percentChange >= 0) {
            newPrice = currentPrice + (currentPrice * uint256(percentChange)) / 100;
        } else {
            newPrice = currentPrice - (currentPrice * uint256(-percentChange)) / 100;
        }

        morphoOracle.setPrice(newPrice);

        // Update swapper rates accordingly
        uint256 newSusdeToUsdcRate = (newPrice * 10 ** SUSDE_DECIMALS) / (10 ** USDC_DECIMALS);
        newSusdeToUsdcRate = newSusdeToUsdcRate / 1e18;

        swapper.setExchangeRate(address(sUSDe), address(usdc), newSusdeToUsdcRate);
        swapper.setExchangeRate(address(usdc), address(sUSDe), (MORPHO_ORACLE_PRECISION) / newSusdeToUsdcRate);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              MORPHO-SPECIFIC HELPERS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Get the LeveragedMorpho strategy typed reference
    function _getMorphoStrategy() internal view returns (LeveragedMorpho) {
        return LeveragedMorpho(address(strategy));
    }
}
