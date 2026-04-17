// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveOracle
/// @notice Minimal interface for the Aave price oracle (AaveOracle).
/// All prices are denominated in the market's base currency (USD), with 8 decimal precision.
/// Obtained via IPoolAddressesProvider.getPriceOracle().
interface IAaveOracle {
    /// @notice Returns the USD price of 1 whole unit of the asset (8 decimals).
    /// @dev Returns 0 if no price source is configured for the asset.
    /// @param asset The address of the underlying asset token
    /// @return The USD price of the asset with 8 decimals of precision
    function getAssetPrice(address asset) external view returns (uint256);

    /// @notice Returns the address of the Chainlink price feed source for the asset.
    /// @param asset The address of the underlying asset token
    /// @return The address of the price source (Chainlink aggregator)
    function getSourceOfAsset(address asset) external view returns (address);
}
