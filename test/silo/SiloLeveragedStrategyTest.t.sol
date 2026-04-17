// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedStrategyTest} from "test/common/LeveragedStrategyTest.sol";
import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {SiloTestSetup} from "./SiloTestSetup.sol";

/// @title SiloLeveragedStrategyTest
/// @notice Runs all common LeveragedStrategy invariant tests against LeveragedSilo
/// @dev Inherits from both LeveragedStrategyTest (tests) and SiloTestSetup (setup)
contract SiloLeveragedStrategyTest is LeveragedStrategyTest, SiloTestSetup {
    /// @notice Use SiloTestSetup's setUp which calls all the abstract implementations
    function setUp() public override(LeveragedStrategyBaseSetup, SiloTestSetup) {
        SiloTestSetup.setUp();
    }
}
