// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EulerTestSetup} from "./EulerTestSetup.sol";

import {LeveragedEuler} from "src/strategies/LeveragedEuler.sol";
import {ILeveragedEuler} from "src/interfaces/strategies/ILeveragedEuler.sol";
import {LibError} from "src/libraries/LibError.sol";

/// @title EulerSpecificTest
/// @notice Tests specific to LeveragedEuler that don't apply to other protocols
/// @dev Tests Euler-specific features like EVC, EVaults, and flash loan handling
contract EulerSpecificTest is EulerTestSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EULER-SPECIFIC INITIAL VALUES                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_InitialValues_LeveragedEuler() public view {
        ILeveragedEuler eulerStrategy = ILeveragedEuler(address(strategy));

        (address collateralVault_, address borrowVault_, address evc_) = eulerStrategy.getMarketDetails();

        assertEq(collateralVault_, address(collateralVault), "COLLATERAL_VAULT mismatch");
        assertEq(borrowVault_, address(borrowVault), "BORROW_VAULT mismatch");
        assertEq(evc_, address(evc), "VAULT_CONNECTOR mismatch");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               COLLATERAL/DEBT TRACKING TESTS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_EulerSpecific_CollateralTracking() public {
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

    function test_EulerSpecific_DebtTracking() public {
        uint256 depositAmount = 10_000 * 1e18;

        // Setup initial position
        _setupInitialLeveragePosition(depositAmount);

        // Get debt from borrow vault
        uint256 strategyDebt = borrowVault.debtOf(address(strategy));

        // Verify debt tracking
        (, , , , uint256 totalDebt, ) = strategy.getNetAssets();
        assertEq(strategyDebt, totalDebt, "Debt tracking should match borrow vault");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   INTEREST ACCRUAL TESTS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_EulerSpecific_InterestAccrual() public {
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

    function test_EulerSpecific_CollateralYield() public {
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
    //                              RESCUE RECEIPT-TOKEN PROTECTION                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Rescue must not be able to transfer the Euler collateral vault shares.
    function testRevert_RescueTokens_CollateralVaultShares() public {
        vm.prank(management);
        vm.expectRevert(LibError.InvalidToken.selector);
        strategy.executeOperation(4, 0, address(collateralVault));
    }

    /// @notice Rescue must not be able to transfer the Euler borrow vault shares.
    function testRevert_RescueTokens_BorrowVaultShares() public {
        vm.prank(management);
        vm.expectRevert(LibError.InvalidToken.selector);
        strategy.executeOperation(4, 0, address(borrowVault));
    }
}
