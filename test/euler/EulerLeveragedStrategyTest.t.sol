// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

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

    function test_StorageLocationInvariant() public pure override {
        super.test_StorageLocationInvariant();
        bytes32 storageLocation = keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedEuler")) - 1)) &
            ~bytes32(uint256(0xff));
        assertEq(uint256(storageLocation), uint256(0x5129f9cf92b365d54467f5b32a6becb76a960704fe1848c67450f68943359400));
    }
}
