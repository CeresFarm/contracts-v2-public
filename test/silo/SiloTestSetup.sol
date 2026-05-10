// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {LeveragedSilo} from "src/strategies/LeveragedSilo.sol";
import {OracleAdapter} from "src/periphery/OracleAdapter.sol";
import {UniversalOracleRouter} from "src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "src/interfaces/periphery/IUniversalOracleRouter.sol";
import {SiloOracleRoute} from "src/periphery/routes/SiloOracleRoute.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {FlashLoanRouter} from "src/periphery/FlashLoanRouter.sol";

import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";
import {ILeveragedSilo} from "src/interfaces/strategies/ILeveragedSilo.sol";

import {ISilo, ISiloConfig} from "src/interfaces/silo/ISilo.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MockSilo} from "test/silo/mock/MockSilo.sol";
import {MockSiloConfig} from "test/silo/mock/MockSiloConfig.sol";
import {MockSiloLens} from "test/silo/mock/MockSiloLens.sol";
import {MockSiloOracle} from "test/silo/mock/MockSiloOracle.sol";
import {MockCeresSwapper} from "test/mock/periphery/MockCeresSwapper.sol";

/// @title SiloTestSetup
/// @notice Silo-specific test setup inheriting from LeveragedStrategyBaseSetup
/// @dev Tests savUSD as asset/collateral with USDC as debt using Silo Finance
contract SiloTestSetup is LeveragedStrategyBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SILO-SPECIFIC CONSTANTS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 constant ORACLE_PRECISION = 1e18;
    uint256 constant SILO_ID = 1;

    // Silo LTV parameters
    uint256 constant MAX_LTV = 870000000000000000; // 87%
    uint256 constant LT = 900000000000000000; // 90%

    // Token decimals
    uint8 public constant SAVUSD_DECIMALS = 18;
    uint8 public constant USDC_DECIMALS = 6;

    // Prices in USD (18 decimals)
    uint256 public constant SAVUSD_PRICE = 1.12e18; // $1.12 (kept for reference / swapper use)
    uint256 public constant USDC_PRICE = 1e18; // $1.00

    // Oracle price: 1e18 normalized price returned by ISiloOracle.quote per 1e18 savUSD
    // MockSiloOracle.quote(1e18, savUSD) = (1e18 * SAVUSD_ORACLE_PRICE) / 1e18 = SAVUSD_ORACLE_PRICE
    // Adapter scales: SAVUSD_ORACLE_PRICE * USDC_UNIT / 1e18 = 1.12e18 * 1e6 / 1e18 = 1_120_000
    uint256 public constant SAVUSD_ORACLE_PRICE = SAVUSD_TO_USDC_RATE; // 1.12e18

    // Exchange rates (18 decimals precision)
    uint256 public constant SAVUSD_TO_USDC_RATE = 1.12e18; // 1 savUSD = 1.12 USDC
    uint256 public constant USDC_TO_SAVUSD_RATE = 0.892857143e18; // 1 USDC = ~0.893 savUSD

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SILO-SPECIFIC CONTRACTS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Silo infrastructure
    MockSilo public savUSDSilo;
    MockSilo public usdcSilo;
    MockSiloConfig public siloConfig;
    MockSiloLens public siloLens;
    MockSiloOracle public siloOracle;

    // Typed references (same as base but with concrete types)
    MockERC20 public savUSD;
    MockERC20 public usdc;
    OracleAdapter public siloOracleAdapter;
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
        savUSD = new MockERC20("Avant Staked USD", "savUSD", SAVUSD_DECIMALS);
        usdc = new MockERC20("Circle USD", "USDC", USDC_DECIMALS);

        // Set base contract references
        assetToken = savUSD;
        debtToken = usdc;
    }

    function _setupProtocolContracts() internal override {
        // Deploy Silo contracts
        savUSDSilo = new MockSilo(address(savUSD));
        usdcSilo = new MockSilo(address(usdc));

        // Deploy oracle and set prices
        siloOracle = new MockSiloOracle(address(usdc)); // Quote token is USDC
        siloOracle.setPrice(address(savUSD), SAVUSD_ORACLE_PRICE); // actual USDC units per 1e18 savUSD
        siloOracle.setPrice(address(usdc), USDC_PRICE);

        // Deploy SiloConfig with proper configuration
        ISiloConfig.ConfigData memory savUSDConfig = _createConfigData(
            address(savUSDSilo),
            address(savUSD),
            address(siloOracle)
        );

        ISiloConfig.ConfigData memory usdcConfig = _createConfigData(
            address(usdcSilo),
            address(usdc),
            address(siloOracle)
        );

        siloConfig = new MockSiloConfig(SILO_ID, savUSDConfig, usdcConfig);

        // Link silos to config
        savUSDSilo.setSiloConfig(siloConfig);
        usdcSilo.setSiloConfig(siloConfig);

        // Deploy SiloLens
        siloLens = new MockSiloLens();
    }

    /// @notice Create ConfigData for SiloConfig
    function _createConfigData(
        address silo,
        address token,
        address oracle
    ) internal pure returns (ISiloConfig.ConfigData memory) {
        return
            ISiloConfig.ConfigData({
                daoFee: 0.0,
                deployerFee: 0,
                silo: silo,
                token: token,
                protectedShareToken: address(0),
                collateralShareToken: silo,
                debtShareToken: address(0),
                solvencyOracle: oracle,
                maxLtvOracle: oracle,
                interestRateModel: address(0),
                maxLtv: MAX_LTV,
                lt: LT,
                liquidationTargetLtv: LT,
                liquidationFee: 500, // 5%
                flashloanFee: 0,
                hookReceiver: address(0),
                callBeforeQuote: false
            });
    }

    function _setupOracleAdapter() internal override {
        router = new UniversalOracleRouter(address(roleManager));
        SiloOracleRoute siloRoute = new SiloOracleRoute(address(siloOracle), address(savUSD), address(usdc));

        IUniversalOracleRouter.RouteStep[] memory collToDebt = new IUniversalOracleRouter.RouteStep[](1);
        collToDebt[0] = IUniversalOracleRouter.RouteStep({targetToken: address(usdc), oracleRoute: address(siloRoute)});
        _runViaTimelock(address(router), abi.encodeCall(router.setRoute, (address(savUSD), address(usdc), collToDebt)));

        IUniversalOracleRouter.RouteStep[] memory debtToColl = new IUniversalOracleRouter.RouteStep[](1);
        debtToColl[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(savUSD),
            oracleRoute: address(siloRoute)
        });
        _runViaTimelock(address(router), abi.encodeCall(router.setRoute, (address(usdc), address(savUSD), debtToColl)));

        siloOracleAdapter = new OracleAdapter(
            address(router),
            address(savUSD), // asset token
            address(savUSD), // collateral token
            address(usdc) // debt token
        );

        // Set base contract reference
        oracleAdapter = siloOracleAdapter;
    }

    function _setupSwapper() internal override {
        swapper = new MockCeresSwapper();

        // Set exchange rates for savUSD <-> USDC
        swapper.setExchangeRate(address(savUSD), address(usdc), SAVUSD_TO_USDC_RATE);
        swapper.setExchangeRate(address(usdc), address(savUSD), USDC_TO_SAVUSD_RATE);

        savUSD.mint(address(swapper), 100_000_000 * 1e18);
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
            "LeveragedSilo.sol:LeveragedSilo",
            management,
            abi.encodeCall(
                LeveragedSilo.initialize,
                (
                    address(savUSD), // asset token
                    "Ceres Leveraged savUSD-USDC Silo", // name
                    "ceres-savUSD-USDC-Silo", // symbol
                    address(savUSD), // collateral token (same as asset)
                    address(usdc), // debt token
                    address(siloLens), // silo lens
                    address(siloConfig), // silo market (config)
                    true, // isProtected (use Protected collateral type)
                    address(roleManager) // role manager
                )
            )
        );

        strategy = ILeveragedStrategy(proxy);
        console.log("Strategy proxy deployed at:", address(strategy));

        vm.stopPrank();
    }

    function _initializeStrategy() internal override {
        // Timelocked setters: route through real TimelockController.
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setSwapper, (address(swapper))));
        _runViaTimelock(address(strategy), abi.encodeCall(strategy.setOracleAdapter, (address(siloOracleAdapter))));
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
                (address(strategy), FlashLoanRouter.FlashSource.ERC3156, address(usdcSilo), true)
            )
        );
    }

    function _addProtocolLiquidity() internal override {
        uint256 amountCollateralToken = 100_000_000 * 10 ** SAVUSD_DECIMALS;
        uint256 amountDebtToken = 100_000_000 * 10 ** USDC_DECIMALS;

        savUSD.mint(liquidityProvider, amountCollateralToken);
        usdc.mint(liquidityProvider, amountDebtToken);

        vm.startPrank(liquidityProvider);
        savUSD.approve(address(savUSDSilo), amountCollateralToken);
        savUSDSilo.deposit(amountCollateralToken, liquidityProvider, ISilo.CollateralType.Protected);

        usdc.approve(address(usdcSilo), amountDebtToken);
        usdcSilo.deposit(amountDebtToken, liquidityProvider, ISilo.CollateralType.Protected);

        vm.stopPrank();
    }

    function _simulateInterestAccrual(
        uint256 interestRateBpsCollateral,
        uint256 interestRateBpsDebt,
        uint256 timeElapsed
    ) internal override {
        // Calculate interest amount
        uint256 totalDebt = usdcSilo.totalDebtAssets();

        // Use swapper rate (1e18 precision) as canonical price source
        uint256 currentSwapperRate = swapper.exchangeRates(address(savUSD), address(usdc));
        uint256 updatedSwapperRate = currentSwapperRate +
            (currentSwapperRate * interestRateBpsCollateral * timeElapsed) / (BPS_PRECISION * 365 days);

        // Oracle price is 18 decimla normalized (same precision as swapper rate)
        uint256 updatedOraclePrice = updatedSwapperRate;

        siloOracle.setPrice(address(savUSD), updatedOraclePrice);
        swapper.setExchangeRate(address(savUSD), address(usdc), updatedSwapperRate);
        swapper.setExchangeRate(address(usdc), address(savUSD), 1e36 / updatedSwapperRate);

        if (totalDebt > 0 && interestRateBpsDebt > 0) {
            uint256 debtInterest = (totalDebt * interestRateBpsDebt * timeElapsed) / (BPS_PRECISION * 365 days);
            usdcSilo.accrueDebtInterest(debtInterest);
        }

        // Move time forward
        skip(timeElapsed);
    }

    function _simulatePriceChange(int256 percentChange) internal override {
        // Use swapper rate as canonical source
        uint256 currentSwapperRate = swapper.exchangeRates(address(savUSD), address(usdc));
        uint256 newSwapperRate;

        if (percentChange >= 0) {
            newSwapperRate = currentSwapperRate + (currentSwapperRate * uint256(percentChange)) / 100;
        } else {
            newSwapperRate = currentSwapperRate - (currentSwapperRate * uint256(-percentChange)) / 100;
        }

        uint256 newOraclePrice = newSwapperRate;

        siloOracle.setPrice(address(savUSD), newOraclePrice);
        swapper.setExchangeRate(address(savUSD), address(usdc), newSwapperRate);
        swapper.setExchangeRate(address(usdc), address(savUSD), 1e36 / newSwapperRate);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    LABEL ADDRESSES                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _labelAddresses() internal override {
        vm.label(address(savUSD), "savUSD");
        vm.label(address(usdc), "USDC");
        vm.label(address(savUSDSilo), "savUSD Silo");
        vm.label(address(usdcSilo), "USDC Silo");
        vm.label(address(siloConfig), "Silo Config");
        vm.label(address(siloLens), "Silo Lens");
        vm.label(address(siloOracle), "Silo Oracle");
        vm.label(address(siloOracleAdapter), "Silo Oracle Adapter");
        vm.label(address(swapper), "Ceres Swapper");
        vm.label(address(strategy), "LeveragedSilo Strategy");
    }
}
