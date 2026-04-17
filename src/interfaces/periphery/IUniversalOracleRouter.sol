// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IUniversalOracleRouter {
    struct RouteStep {
        address targetToken;
        address oracleRoute;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function setRoute(address tokenIn, address tokenOut, RouteStep[] calldata path) external;

    function getRoute(address tokenIn, address tokenOut) external view returns (RouteStep[] memory);
}
