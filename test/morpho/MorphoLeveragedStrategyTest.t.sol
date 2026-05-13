// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

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

    function test_StorageLocationInvariant() public pure override {
        super.test_StorageLocationInvariant();
        bytes32 storageLocation = keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedMorpho")) - 1)) &
            ~bytes32(uint256(0xff));
        assertEq(uint256(storageLocation), uint256(0xa9fd9e8f1dae938a896b7bee3848a739e7c4f05ef07b7f7fc43c459652bf3100));
    }

    /// @notice Skip this test for Morpho due to borrowing interest rate mock limitations
    function test_Loss_WithdrawAfterLoss() public override {
        vm.skip(true);
    }
}
