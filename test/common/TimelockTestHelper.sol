// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

/// @title TimelockTestHelper
/// @notice Test-only helper that wraps the OZ TimelockController `schedule -> wait -> execute`
/// into a single call. Lets test sites exercise timelock process
///
/// Usage:
///   TimelockTestHelper helper = new TimelockTestHelper();
///   TimelockController timelock = helper.deployTimelock(1 days, admin);
///   roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
///   helper.runViaTimelock(
///       timelock,
///       address(strategy),
///       abi.encodeCall(strategy.setOracleAdapter, (newOracle)),
///       admin
///   );
contract TimelockTestHelper is Test {
    /// @dev Monotonic salt counter so successive calls do not collide.
    uint256 private _saltCounter;

    /// @notice Deploy a new TimelockController with the given delay.
    /// @param minDelay The minimum delay (in seconds) before a scheduled operation can execute.
    /// @param admin Address granted PROPOSER_ROLE, EXECUTOR_ROLE, and CANCELLER_ROLE.
    /// Also used as the optional bootstrap `admin` slot so that the timelock
    /// itself is self-administered after grants are wired up.
    function deployTimelock(uint256 minDelay, address admin) external returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        return new TimelockController(minDelay, proposers, executors, admin);
    }

    /// @notice Schedule, fast-forward by `getMinDelay()`, and execute a call via the timelock.
    /// @dev The caller must hold PROPOSER_ROLE and EXECUTOR_ROLE on the timelock.
    function runViaTimelock(TimelockController timelock, address target, bytes memory data, address caller) external {
        bytes32 salt = bytes32(++_saltCounter);
        uint256 delay = timelock.getMinDelay();

        vm.prank(caller);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);

        skip(delay);

        vm.prank(caller);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    /// @notice Same as `runViaTimelock` but expects the inner call to revert with `expectedRevert`.
    /// @dev TimelockController forwards inner-call revert data via OZ Address.functionCallWithValue,
    ///      so `vm.expectRevert(selector)` on `execute` matches the inner contract's revert.
    function runViaTimelockExpectRevert(
        TimelockController timelock,
        address target,
        bytes memory data,
        address caller,
        bytes4 expectedRevert
    ) external {
        bytes32 salt = bytes32(++_saltCounter);
        uint256 delay = timelock.getMinDelay();

        vm.prank(caller);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);

        skip(delay);

        vm.prank(caller);
        vm.expectRevert(expectedRevert);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    /// @notice Schedule a call without executing: for tests that exercise cancel or early-execute paths.
    /// @return salt The salt used for this scheduled operation, needed to call `execute` or `cancel` later.
    function scheduleOnly(
        TimelockController timelock,
        address target,
        bytes memory data,
        address caller
    ) external returns (bytes32 salt) {
        salt = bytes32(++_saltCounter);
        uint256 delay = timelock.getMinDelay();

        vm.prank(caller);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);
    }
}
