// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IEVC} from "src/interfaces/euler/IEVC.sol";

/// @title MockEVC
/// @notice Minimal mock implementation of the Ethereum Vault Connector for testing purposes
/// @dev Only implements the essential functions needed by LeveragedEulerStrategy
contract MockEVC is IEVC {
    // Mapping to track enabled collaterals for each account
    mapping(address account => mapping(address vault => bool enabled)) private collaterals;

    // Mapping to track enabled controllers for each account
    mapping(address account => mapping(address vault => bool enabled)) private controllers;

    // Mapping to store collaterals array for each account
    mapping(address account => address[] vaults) private collateralsList;

    // Mapping to store controllers array for each account
    mapping(address account => address[] vaults) private controllersList;

    /// @notice Enables a collateral for an account
    function enableCollateral(address account, address vault) external payable override {
        if (!collaterals[account][vault]) {
            collaterals[account][vault] = true;
            collateralsList[account].push(vault);
        }
    }

    /// @notice Disables a collateral for an account
    function disableCollateral(address account, address vault) external payable override {
        if (collaterals[account][vault]) {
            collaterals[account][vault] = false;
            _removeFromArray(collateralsList[account], vault);
        }
    }

    /// @notice Enables a controller for an account
    function enableController(address account, address vault) external payable override {
        if (!controllers[account][vault]) {
            controllers[account][vault] = true;
            controllersList[account].push(vault);
        }
    }

    /// @notice Disables a controller for an account
    function disableController(address account) external payable override {
        if (controllers[account][msg.sender]) {
            controllers[account][msg.sender] = false;
            _removeFromArray(controllersList[account], msg.sender);
        }
    }

    /// @notice Returns an array of collaterals enabled for an account
    function getCollaterals(address account) external view override returns (address[] memory) {
        return collateralsList[account];
    }

    /// @notice Returns whether a collateral is enabled for an account
    function isCollateralEnabled(address account, address vault) external view override returns (bool) {
        return collaterals[account][vault];
    }

    /// @notice Returns an array of enabled controllers for an account
    function getControllers(address account) external view override returns (address[] memory) {
        return controllersList[account];
    }

    /// @notice Returns whether a controller is enabled for an account
    function isControllerEnabled(address account, address vault) external view override returns (bool) {
        return controllers[account][vault];
    }

    // Helper function to remove an element from an array
    function _removeFromArray(address[] storage array, address element) private {
        uint256 length = array.length;
        for (uint256 i = 0; i < length; i++) {
            if (array[i] == element) {
                array[i] = array[length - 1];
                array.pop();
                break;
            }
        }
    }

    // Minimal implementations of other required interface functions
    // These are not used by LeveragedEulerStrategy but needed to satisfy the interface

    function getRawExecutionContext() external pure override returns (uint256) {
        return 0;
    }

    function getCurrentOnBehalfOfAccount(address) external pure override returns (address, bool) {
        return (address(0), false);
    }

    function areChecksDeferred() external pure override returns (bool) {
        return false;
    }

    function areChecksInProgress() external pure override returns (bool) {
        return false;
    }

    function isControlCollateralInProgress() external pure override returns (bool) {
        return false;
    }

    function isOperatorAuthenticated() external pure override returns (bool) {
        return false;
    }

    function isSimulationInProgress() external pure override returns (bool) {
        return false;
    }

    function haveCommonOwner(address, address) external pure override returns (bool) {
        return false;
    }

    function getAddressPrefix(address) external pure override returns (bytes19) {
        return bytes19(0);
    }

    function getAccountOwner(address) external pure override returns (address) {
        return address(0);
    }

    function isLockdownMode(bytes19) external pure override returns (bool) {
        return false;
    }

    function isPermitDisabledMode(bytes19) external pure override returns (bool) {
        return false;
    }

    function getNonce(bytes19, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getOperator(bytes19, address) external pure override returns (uint256) {
        return 0;
    }

    function isAccountOperatorAuthorized(address, address) external pure override returns (bool) {
        return false;
    }

    function setLockdownMode(bytes19, bool) external payable override {}

    function setPermitDisabledMode(bytes19, bool) external payable override {}

    function setNonce(bytes19, uint256, uint256) external payable override {}

    function setOperator(bytes19, address, uint256) external payable override {}

    function setAccountOperator(address, address, bool) external payable override {}

    function reorderCollaterals(address, uint8, uint8) external payable override {}

    function permit(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata,
        bytes calldata
    ) external payable override {}

    function call(address, address, uint256, bytes calldata) external payable override returns (bytes memory) {
        return "";
    }

    function controlCollateral(
        address,
        address,
        uint256,
        bytes calldata
    ) external payable override returns (bytes memory) {
        return "";
    }

    function batch(BatchItem[] calldata) external payable override {}

    function batchRevert(BatchItem[] calldata) external payable override {}

    function batchSimulation(
        BatchItem[] calldata
    )
        external
        payable
        override
        returns (BatchItemResult[] memory, StatusCheckResult[] memory, StatusCheckResult[] memory)
    {
        return (new BatchItemResult[](0), new StatusCheckResult[](0), new StatusCheckResult[](0));
    }

    function getLastAccountStatusCheckTimestamp(address) external pure override returns (uint256) {
        return 0;
    }

    function isAccountStatusCheckDeferred(address) external pure override returns (bool) {
        return false;
    }

    function requireAccountStatusCheck(address) external payable override {}

    function forgiveAccountStatusCheck(address) external payable override {}

    function isVaultStatusCheckDeferred(address) external pure override returns (bool) {
        return false;
    }

    function requireVaultStatusCheck() external payable override {}

    function forgiveVaultStatusCheck() external payable override {}

    function requireAccountAndVaultStatusCheck(address) external payable override {}
}
