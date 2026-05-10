// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

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

    function test_StorageLocationInvariant() public pure override {
        super.test_StorageLocationInvariant();
        bytes32 storageLocation = keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedSilo")) - 1)) &
            ~bytes32(uint256(0xff));
        assertEq(uint256(storageLocation), uint256(0xd3347dc4810054ab576f4fa720be0262b5439ed263df1188320586c713f01100));
    }
}
