// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {SiloTestSetup} from "./SiloTestSetup.sol";
import {console2} from "forge-std/Test.sol";

import {LeveragedSilo} from "src/strategies/LeveragedSilo.sol";
import {ILeveragedSilo} from "src/interfaces/strategies/ILeveragedSilo.sol";
import {ISilo, ISiloConfig} from "src/interfaces/silo/ISilo.sol";
import {LibError} from "src/libraries/LibError.sol";

/// @title SiloSpecificTest
/// @notice Tests specific to LeveragedSilo that don't apply to other protocols
/// @dev Tests Silo-specific features like SiloConfig, SiloLens, protected collateral, and flash loans
contract SiloSpecificTest is SiloTestSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               SILO-SPECIFIC INITIAL VALUES                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_InitialValues_LeveragedSilo() public view {
        ILeveragedSilo siloStrategy = ILeveragedSilo(address(strategy));

        (address siloLens_, , , ISilo.CollateralType collateralType_) = siloStrategy.getMarketDetails();

        assertEq(siloLens_, address(siloLens), "SILO_LENS mismatch");
        assertEq(uint8(collateralType_), uint8(ISilo.CollateralType.Protected), "COLLATERAL_TYPE should be Protected");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SILO CONFIG TESTS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SiloSpecific_SiloConfigSetup() public view {
        // Verify silo config is properly set up
        ISiloConfig.ConfigData memory savUSDConfig = siloConfig.getConfig(address(savUSDSilo));
        ISiloConfig.ConfigData memory usdcConfig = siloConfig.getConfig(address(usdcSilo));

        assertEq(savUSDConfig.token, address(savUSD), "savUSD config token mismatch");
        assertEq(usdcConfig.token, address(usdc), "USDC config token mismatch");
        assertEq(savUSDConfig.maxLtv, MAX_LTV, "Max LTV mismatch");
    }

    function test_SiloSpecific_GetSilos() public view {
        // Verify silos are retrievable from config
        (address collateralSilo, address debtSilo) = siloConfig.getSilos();
        assertEq(collateralSilo, address(savUSDSilo), "Collateral silo mismatch");
        assertEq(debtSilo, address(usdcSilo), "Debt silo mismatch");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               COLLATERAL/DEBT TRACKING TESTS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SiloSpecific_CollateralTracking() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup initial position
        _setupInitialLeveragePosition(depositAmount);

        // Get collateral from strategy
        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();

        // Verify collateral tracking
        assertTrue(totalCollateral > depositAmount, "Collateral should include leveraged amount");
        assertTrue(totalDebt > 0, "Debt should exist after leverage");
        assertTrue(netAssets > 0, "Net assets should be positive");
    }

    function test_SiloSpecific_DebtTracking() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup initial position
        _setupInitialLeveragePosition(depositAmount);

        // Get debt from silo
        uint256 strategyDebt = usdcSilo.debtBalanceOfUnderlying(address(strategy));

        // Verify debt tracking
        (, , , , uint256 totalDebt, ) = strategy.getNetAssets();
        assertEq(strategyDebt, totalDebt, "Debt tracking should match silo");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               PROTECTED COLLATERAL TESTS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SiloSpecific_ProtectedDeposit() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup user deposit
        _setupUserDeposit(user1, depositAmount);

        // Verify funds are deposited as protected collateral
        uint256 protectedBalance = savUSDSilo.collateralBalanceOfUnderlying(
            address(strategy),
            ISilo.CollateralType.Protected
        );
        assertEq(protectedBalance, depositAmount, "Protected collateral should match deposit");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   INTEREST ACCRUAL TESTS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SiloSpecific_InterestAccrual() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup initial position
        _setupInitialLeveragePosition(depositAmount);

        (, , , , uint256 initialDebt, ) = strategy.getNetAssets();

        // Simulate 1 year of interest accrual at 5% APY on debt
        _simulateInterestAccrual(0, 500, 365 days);

        (, , , , uint256 finalDebt, ) = strategy.getNetAssets();

        // Debt should have increased due to interest
        assertTrue(finalDebt > initialDebt, "Debt should increase with interest accrual");
    }

    function test_SiloSpecific_CollateralYield() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup initial position
        _setupInitialLeveragePosition(depositAmount);

        (, uint256 initialNetAssets, , , , ) = strategy.getNetAssets();

        // Simulate 1 year of collateral yield at 10% APY (price increase)
        _simulateInterestAccrual(1000, 0, 365 days);

        (, uint256 finalNetAssets, , , , ) = strategy.getNetAssets();

        // Net assets should have increased due to collateral yield
        assertTrue(finalNetAssets > initialNetAssets, "Net assets should increase with collateral yield");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ORACLE INTEGRATION TESTS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SiloSpecific_OraclePrice() public view {
        // Verify oracle is returning correct prices
        uint256 savUSDPrice = siloOracle.prices(address(savUSD));
        uint256 usdcPrice = siloOracle.prices(address(usdc));

        assertEq(savUSDPrice, SAVUSD_ORACLE_PRICE, "savUSD price mismatch");
        assertEq(usdcPrice, USDC_PRICE, "USDC price mismatch");
    }
}
