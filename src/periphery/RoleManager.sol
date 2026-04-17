// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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

    /// @notice Deploys the RoleManager and grants all roles to the initial admin.
    /// @param _initialDelay Timelock delay (in seconds) before the default admin can be transferred.
    /// @param _initialDefaultAdmin Address that receives the default admin, management, keeper, and curator roles.
    constructor(
        uint48 _initialDelay,
        address _initialDefaultAdmin
    ) AccessControlDefaultAdminRules(_initialDelay, _initialDefaultAdmin) {
        // Grant roles
        _grantRole(KEEPER_ROLE, _initialDefaultAdmin);
        _grantRole(MANAGEMENT_ROLE, _initialDefaultAdmin);
        _grantRole(CURATOR_ROLE, _initialDefaultAdmin);

        _setRoleAdmin(KEEPER_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(CURATOR_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(VAULT_OR_STRATEGY, MANAGEMENT_ROLE);
    }
}
