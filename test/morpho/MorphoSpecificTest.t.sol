// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {MorphoTestSetup} from "./MorphoTestSetup.sol";

import {LeverageLib} from "../../src/libraries/LeverageLib.sol";

import {LeveragedMorpho} from "src/strategies/LeveragedMorpho.sol";
import {LibError} from "src/libraries/LibError.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

/// @title MorphoSpecificTest
/// @notice Tests specific to Morpho implementation that don't apply to other protocols
/// @dev Tests market params, Morpho flash loan callback, collateral/debt tracking
contract MorphoSpecificTest is MorphoTestSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              MORPHO MARKET PARAMS TESTS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test Morpho market params are correctly set
    function test_MorphoSpecific_MarketParams() public view {
        LeveragedMorpho morphoStrategy = _getMorphoStrategy();

        MarketParams memory params = morphoStrategy.MORPHO_MARKET_PARAMS();

        assertEq(params.collateralToken, address(sUSDe), "collateralToken should be sUSDe");
        assertEq(params.loanToken, address(usdc), "loanToken should be USDC");
        assertEq(params.oracle, address(morphoOracle), "oracle should match");
        assertEq(params.irm, address(irm), "irm should match");
        assertEq(params.lltv, MORPHO_LLTV, "lltv should match");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              MORPHO INITIAL VALUES TESTS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test for LeveragedMorpho specific initial values
    function test_InitialValues_LeveragedMorpho() public view {
        LeveragedMorpho morphoStrategy = _getMorphoStrategy();

        (address morphoMarket_, ) = morphoStrategy.getMarketDetails();
        assertEq(morphoMarket_, address(morpho), "MORPHO_MARKET mismatch");

        (, uint256 netAssets, , uint256 totalCollateral, uint256 totalDebt, ) = strategy.getNetAssets();
        assertEq(netAssets, 0, "netAssets should be 0");
        assertEq(totalCollateral, 0, "totalCollateral should be 0");
        assertEq(totalDebt, 0, "totalDebt should be 0");

        assertEq(sUSDe.balanceOf(address(strategy)), 0, "strategy sUSDe balance should be 0");
        assertEq(usdc.balanceOf(address(strategy)), 0, "strategy USDC balance should be 0");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              MORPHO COLLATERAL TRACKING TESTS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test collateral is correctly tracked in Morpho
    function test_MorphoSpecific_CollateralTracking() public {
        uint256 depositAmount = DEFAULT_DEPOSIT();
        _setupUserDeposit(user1, depositAmount);

        uint256 collateralInMorpho = strategy.getCollateralAmount();

        assertEq(collateralInMorpho, depositAmount, "Collateral in Morpho should match deposit");

        // After leverage
        uint256 debtAmount = LeverageLib.computeTargetDebt(depositAmount, TARGET_LTV_BPS, strategy.oracleAdapter());
        _mintAndApprove(address(usdc), keeper, address(strategy), debtAmount);
        vm.prank(keeper);
        strategy.rebalance(debtAmount, true, false, "");

        uint256 collateralAfterLeverage = strategy.getCollateralAmount();
        assertGt(collateralAfterLeverage, depositAmount, "Collateral should increase after leverage");
    }

    /// @notice Test debt is correctly tracked in Morpho
    function test_MorphoSpecific_DebtTracking() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 debtInMorpho = strategy.getDebtAmount();

        (, , , , uint256 debtFromStrategy, ) = strategy.getNetAssets();

        // Allow small rounding differences due to share/asset conversions
        assertApproxEqRel(debtInMorpho, debtFromStrategy, 1e15, "Debt tracking should be consistent");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              MORPHO LTV TESTS                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test getStrategyLtv calculation
    function test_MorphoSpecific_GetStrategyLtv() public {
        _setupInitialLeveragePosition(DEFAULT_DEPOSIT());

        uint256 ltv = strategy.getStrategyLtv();

        // LTV should be near target
        assertApproxEqRel(ltv, TARGET_LTV_BPS, 10e16, "LTV should be near target");

        // LTV should be less than LLTV (liquidation threshold)
        assertLt(ltv, MORPHO_LLTV / 1e14, "LTV should be less than liquidation threshold");
    }
}
