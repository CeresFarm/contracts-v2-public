// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Minimal Lista oracle interface matching Lista Lending docs.
/// @dev Returns the price of 1 unit of `asset` quoted in USD with 8 decimals.
interface IListaOracle {
    function peek(address asset) external view returns (uint256 price);
}
