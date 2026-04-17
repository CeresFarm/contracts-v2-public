// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedStrategyTest} from "test/common/LeveragedStrategyTest.sol";
import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {MorphoTestSetup} from "./MorphoTestSetup.sol";

/// @title MorphoLeveragedStrategyTest
/// @notice Runs all common LeveragedStrategy invariant tests against LeveragedMorpho
/// @dev Inherits from both LeveragedStrategyTest (tests) and MorphoTestSetup (setup)
contract MorphoLeveragedStrategyTest is LeveragedStrategyTest, MorphoTestSetup {
    /// @notice Use MorphoTestSetup's setUp which calls all the abstract implementations
    function setUp() public override(LeveragedStrategyBaseSetup, MorphoTestSetup) {
        MorphoTestSetup.setUp();
    }

    /// @notice Skip this test for Morpho due to borrowing interest rate mock limitations
    function test_Loss_WithdrawAfterLoss() public override {
        vm.skip(true);
    }
}
