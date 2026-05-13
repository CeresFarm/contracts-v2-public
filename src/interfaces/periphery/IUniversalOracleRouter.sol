// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

interface IUniversalOracleRouter {
    struct RouteStep {
        address targetToken;
        address oracleRoute;
    }

    /// @notice Emitted when a route is created or replaced via `setRoute`.
    event RouteUpdated(address indexed tokenIn, address indexed tokenOut, RouteStep[] path);

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Sets (or replaces) the route for a `tokenIn` -> `tokenOut` pair.
    /// @dev Gated by `TIMELOCKED_ADMIN_ROLE`; delay is enforced by the upstream TimelockController.
    function setRoute(address tokenIn, address tokenOut, RouteStep[] calldata path) external;

    function getRoute(address tokenIn, address tokenOut) external view returns (RouteStep[] memory);
}
