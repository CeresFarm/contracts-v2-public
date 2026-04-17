// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedStrategyTest} from "test/common/LeveragedStrategyTest.sol";
import {LeveragedStrategyBaseSetup} from "test/common/LeveragedStrategyBaseSetup.sol";
import {EulerTestSetup} from "./EulerTestSetup.sol";

/// @title EulerLeveragedStrategyTest
/// @notice Runs all common LeveragedStrategy invariant tests against LeveragedEuler
/// @dev Inherits from both LeveragedStrategyTest (tests) and EulerTestSetup (setup)
contract EulerLeveragedStrategyTest is LeveragedStrategyTest, EulerTestSetup {
    /// @notice Use EulerTestSetup's setUp which calls all the abstract implementations
    function setUp() public override(LeveragedStrategyBaseSetup, EulerTestSetup) {
        EulerTestSetup.setUp();
    }
}
