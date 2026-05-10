// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControlDefaultAdminRules} from "@openzeppelin-contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title RoleManager
/// @notice Central access control contract that defines and manages all roles used across Ceres contracts.
/// @dev Extends OpenZeppelin's AccessControlDefaultAdminRules. MANAGEMENT_ROLE is the admin of KEEPER_ROLE,
/// CURATOR_ROLE, and VAULT_OR_STRATEGY. The default admin (owner) controls MANAGEMENT_ROLE.
contract RoleManager is AccessControlDefaultAdminRules {
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant VAULT_OR_STRATEGY = keccak256("VAULT_OR_STRATEGY");

    /// @notice Role intended exclusively for an OZ TimelockController. All admin actions guarded by
    /// this role are subject to the controller's minimum delay (schedule -> wait -> execute) flow.
    /// @dev This role is *self-administered* (its admin is itself). The constructor grants it to
    /// the initial default admin so that day-0 deployment configuration can be applied without
    /// having to wait for the timelock delay (the OZ-recommended bootstrap pattern). Once the
    /// deployer renounces this role and grants it to the TimelockController, no other party
    /// — not even `DEFAULT_ADMIN_ROLE` — can grant it again without going through the timelock
    /// itself. This eliminates the foot-gun where the default admin could simply re-grant the
    /// role to themselves and bypass the delay.
    bytes32 public constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    /// @notice Role for a high-trust emergency multisig authorised to invoke time-sensitive
    /// position-management actions that cannot wait for a timelock.
    /// Only emergency position management and swap functions are gated by this role.
    /// @dev *Self-administered* (its admin is itself), similar to `TIMELOCKED_ADMIN_ROLE`.
    ///  The constructor grants it to the initial default admin for the bootstrap window. The deployment
    /// script MUST then grant it to the emergency multisig and renounce the deployer's grant.
    /// After renouncement, only an existing holder (the emergency multisig itself) can grant the
    /// role — `DEFAULT_ADMIN_ROLE` cannot regrant it, preventing the default admin from diluting
    /// the carefully chosen signer set.
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

    /// @notice Deploys the RoleManager and grants all roles to the initial admin.
    /// @dev `TIMELOCKED_ADMIN_ROLE` is granted to the initial default admin for the bootstrap
    /// window (day-0 setRoute / setFlashConfig / etc.). The deployment script MUST then:
    ///   1. Apply day-0 configuration directly.
    ///   2. Grant `TIMELOCKED_ADMIN_ROLE` to the TimelockController.
    ///   3. Renounce `TIMELOCKED_ADMIN_ROLE` from the deployer.
    /// After step 3, the only way to grant the role to anyone else is through the timelock itself,
    /// because the role's admin is the role itself.
    /// `EMERGENCY_ADMIN_ROLE` follows the same bootstrap pattern: granted to the deployer for day-0,
    /// then transferred to the emergency multisig and renounced from the deployer.
    /// @param _initialDelay Timelock delay (in seconds) before the default admin can be transferred.
    /// @param _initialDefaultAdmin Address that receives the default admin, management, keeper,
    /// curator, bootstrap timelocked-admin, and bootstrap emergency-admin roles.
    constructor(
        uint48 _initialDelay,
        address _initialDefaultAdmin
    ) AccessControlDefaultAdminRules(_initialDelay, _initialDefaultAdmin) {
        // Grant roles
        _grantRole(KEEPER_ROLE, _initialDefaultAdmin);
        _grantRole(MANAGEMENT_ROLE, _initialDefaultAdmin);
        _grantRole(CURATOR_ROLE, _initialDefaultAdmin);

        // Bootstrap-only grant for TIMELOCKED_ADMIN_ROLE; deployment script must renounce after
        // day-0 config and transfer the role to the TimelockController.
        _grantRole(TIMELOCKED_ADMIN_ROLE, _initialDefaultAdmin);

        // Bootstrap-only grant for EMERGENCY_ADMIN_ROLE; deployment script must renounce after
        // transferring the role to the emergency multisig.
        _grantRole(EMERGENCY_ADMIN_ROLE, _initialDefaultAdmin);

        _setRoleAdmin(KEEPER_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(CURATOR_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(VAULT_OR_STRATEGY, MANAGEMENT_ROLE);

        // Self-administered: only an existing holder (post-bootstrap, the timelock) can grant it.
        _setRoleAdmin(TIMELOCKED_ADMIN_ROLE, TIMELOCKED_ADMIN_ROLE);

        // Self-administered: only an existing holder (post-bootstrap, the emergency multisig) can grant it.
        _setRoleAdmin(EMERGENCY_ADMIN_ROLE, EMERGENCY_ADMIN_ROLE);
    }
}
