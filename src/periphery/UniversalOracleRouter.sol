// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUniversalOracleRouter} from "../interfaces/periphery/IUniversalOracleRouter.sol";
import {IOracleRoute} from "../interfaces/periphery/IOracleRoute.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {LibError} from "../libraries/LibError.sol";

/// @title Universal Oracle Router
/// @notice A common entry point to resolve all oracle quotes
/// @dev Implements multi-hop routing using configurable `OracleRoute` adapters.
/// Route updates are gated by `TIMELOCKED_ADMIN_ROLE`. Delay is enforced externally by the
/// `TimelockController` that holds the role; the router itself stores no pending state.
contract UniversalOracleRouter is IUniversalOracleRouter {
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");
    IAccessControlDefaultAdminRules public immutable ROLE_MANAGER;

    /// @notice mapping `tokenIn` => `tokenOut` => Array of hops
    mapping(address tokenIn => mapping(address tokenOut => RouteStep[])) private _routes;

    modifier onlyRole(bytes32 role) {
        _validateRole(role, msg.sender);
        _;
    }

    /// @notice Deploys the router with the given role manager.
    /// @param _roleManager Address of the RoleManager that controls MANAGEMENT_ROLE.
    constructor(address _roleManager) {
        if (_roleManager == address(0)) revert LibError.ZeroAddress();
        ROLE_MANAGER = IAccessControlDefaultAdminRules(_roleManager);
    }

    /// @dev Reverts if the account does not hold the required role.
    /// @param role The role identifier to check.
    /// @param account The account to validate.
    function _validateRole(bytes32 role, address account) internal view {
        if (!ROLE_MANAGER.hasRole(role, account)) revert LibError.Unauthorized();
    }

    /// @notice Resolves a multi-hop price quote from `tokenIn` to `tokenOut`.
    /// @dev Walks the configured route steps in order, passing the output of each hop as the input to the next.
    /// @param tokenIn Source token address.
    /// @param tokenOut Destination token address.
    /// @param amountIn Amount of `tokenIn` to convert.
    /// @return Equivalent amount of `tokenOut`.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        if (amountIn == 0) return 0;
        if (tokenIn == tokenOut) return amountIn;

        RouteStep[] memory path = _routes[tokenIn][tokenOut];
        if (path.length == 0) revert LibError.InvalidOracleRoute();

        uint256 currentAmount = amountIn;
        address currentToken = tokenIn;

        for (uint256 i = 0; i < path.length; i++) {
            RouteStep memory step = path[i];

            // Query the specific OracleRoute for this hop
            currentAmount = IOracleRoute(step.oracleRoute).getQuote(currentAmount, currentToken, step.targetToken);

            currentToken = step.targetToken;
        }

        return currentAmount;
    }

    /// @notice Sets (or replaces) the route for a `tokenIn` -> `tokenOut` pair.
    /// @dev Gated by `TIMELOCKED_ADMIN_ROLE`. The required delay is enforced by
    /// the `TimelockController` that holds this role
    /// @param tokenIn Source token address.
    /// @param tokenOut Destination token address.
    /// @param path Ordered array of route steps defining the conversion path.
    function setRoute(
        address tokenIn,
        address tokenOut,
        RouteStep[] calldata path
    ) external onlyRole(TIMELOCKED_ADMIN_ROLE) {
        _validatePath(tokenOut, path);
        _writeRoute(tokenIn, tokenOut, path);
        emit RouteUpdated(tokenIn, tokenOut, path);
    }

    /// @notice Returns the configured route steps for a `tokenIn` -> `tokenOut` pair.
    /// @param tokenIn Source token address.
    /// @param tokenOut Destination token address.
    /// @return Array of route steps for this pair.
    function getRoute(address tokenIn, address tokenOut) external view returns (RouteStep[] memory) {
        return _routes[tokenIn][tokenOut];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   INTERNAL HELPERS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Validates that `path` is a well-formed route ending at `tokenOut`.
    function _validatePath(address tokenOut, RouteStep[] memory path) internal pure {
        if (path.length == 0) revert LibError.InvalidOracleRoute();
        if (path[path.length - 1].targetToken != tokenOut) revert LibError.InvalidToken();
        for (uint256 i = 0; i < path.length; i++) {
            if (path[i].oracleRoute == address(0)) revert LibError.InvalidOracleRoute();
            if (path[i].targetToken == address(0)) revert LibError.InvalidOracleRoute();
        }
    }

    /// @dev Clears any existing route for the pair and writes the new one.
    function _writeRoute(address tokenIn, address tokenOut, RouteStep[] memory path) internal {
        delete _routes[tokenIn][tokenOut];
        for (uint256 i = 0; i < path.length; i++) {
            _routes[tokenIn][tokenOut].push(path[i]);
        }
    }
}
