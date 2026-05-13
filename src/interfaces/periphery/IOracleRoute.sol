// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

interface IOracleRoute {
    /// @notice Returns the amount of `tokenOut` equivalent to `amountIn` of `tokenIn`
    /// @dev The Route implementation must handle any decimal normalization required by its underlying oracle.
    /// If returning a virtual fiat currency (e.g. VIRTUAL_USD), it MUST return 18 decimals of precision.
    /// @param amountIn The amount of the input token
    /// @param tokenIn The address of the input token
    /// @param tokenOut The address of the output token
    /// @return amountOut The equivalent amount of the output token
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256 amountOut);
}
