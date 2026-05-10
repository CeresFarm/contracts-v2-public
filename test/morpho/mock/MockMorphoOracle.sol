// SPDX-License-Identifier: BUSL
pragma solidity 0.8.35;

import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {LibError} from "src/libraries/LibError.sol";

/// @title MockMorphoOracle
/// @notice Mock implementation of Morpho's IOracle interface for testing
/// @dev The price returned follows Morpho's convention:
///      price() returns the price of 1 asset of collateral token quoted in 1 asset of loan token,
///      scaled by 1e36. It corresponds to the price of 10**(collateral token decimals) assets of
///      collateral token quoted in 10**(loan token decimals) assets of loan token with
///      `36 + loan token decimals - collateral token decimals` decimals of precision.
contract MockMorphoOracle is IOracle {
    uint256 private _price;
    bool public shouldRevert;

    constructor() {}

    /// @notice Set the price returned by the oracle
    /// @param newPrice The price following Morpho's convention:
    ///        For example, if collateral has 18 decimals, debt has 6 decimals, and 1 collateral = 1.21 debt:
    ///        price = 1.21 * 1e36 * 10^6 / 10^18 = 1.21 * 1e24 = 1210000000000000000000000
    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    /// @notice Helper to set price with collateral and debt decimals
    /// @param priceWithE18Precision Price with 1e18 precision (e.g., 1.21e18 for $1.21)
    /// @param collateralDecimals Decimals of the collateral token
    /// @param debtDecimals Decimals of the debt token
    function setPriceWithDecimals(
        uint256 priceWithE18Precision,
        uint8 collateralDecimals,
        uint8 debtDecimals
    ) external {
        // Morpho price format: price * 1e36 * 10^debtDecimals / 10^collateralDecimals / 1e18
        // Simplified: price * 1e18 * 10^debtDecimals / 10^collateralDecimals
        _price = (priceWithE18Precision * (10 ** debtDecimals)) / (10 ** collateralDecimals);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36
    function price() external view override returns (uint256) {
        if (shouldRevert) revert LibError.OracleError();
        return _price;
    }
}
