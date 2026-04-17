// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IOracleAdapter {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     VIEW FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the asset token address
    function ASSET_TOKEN() external view returns (address);

    /// @notice Returns the collateral token address
    function COLLATERAL_TOKEN() external view returns (address);

    /// @notice Returns the debt token address
    function DEBT_TOKEN() external view returns (address);

    /// @notice Converts collateral amount to equivalent asset amount
    /// @param collateralAmount The amount of collateral tokens
    /// @return The equivalent amount of asset tokens
    function convertCollateralToAssets(uint256 collateralAmount) external view returns (uint256);

    /// @notice Converts asset amount to equivalent collateral amount
    /// @param assetAmount The amount of asset tokens
    /// @return The equivalent amount of collateral tokens
    function convertAssetsToCollateral(uint256 assetAmount) external view returns (uint256);

    /// @notice Converts collateral amount to equivalent debt amount
    /// @param collateralAmount The amount of collateral tokens
    /// @return The equivalent amount of debt tokens
    function convertCollateralToDebt(uint256 collateralAmount) external view returns (uint256);

    /// @notice Converts debt amount to equivalent collateral amount
    /// @param debtAmount The amount of debt tokens
    /// @return The equivalent amount of collateral tokens
    function convertDebtToCollateral(uint256 debtAmount) external view returns (uint256);

    /// @notice Converts debt amount to equivalent asset amount
    /// @param debtAmount The amount of debt tokens
    /// @return The equivalent amount of asset tokens
    function convertDebtToAssets(uint256 debtAmount) external view returns (uint256);

    /// @notice Converts asset amount to equivalent debt amount
    /// @param assetAmount The amount of asset tokens
    /// @return The equivalent amount of debt tokens
    function convertAssetsToDebt(uint256 assetAmount) external view returns (uint256);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     PRICE FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the price of 1 unit of asset in collateral tokens
    /// @return The price of asset in collateral tokens
    function getAssetPriceInCollateralToken() external view returns (uint256);

    /// @notice Returns the price of 1 unit of asset in debt tokens
    /// @return The price of asset in debt tokens
    function getAssetPriceInDebtToken() external view returns (uint256);

    /// @notice Returns the price of 1 unit of collateral in asset tokens
    /// @return The price of collateral in asset tokens
    function getCollateralPriceInAssetToken() external view returns (uint256);

    /// @notice Returns the price of 1 unit of collateral in debt tokens
    /// @return The price of collateral in debt tokens
    function getCollateralPriceInDebtToken() external view returns (uint256);

    /// @notice Returns the price of 1 unit of debt in asset tokens
    /// @return The price of debt in asset tokens
    function getDebtPriceInAssetToken() external view returns (uint256);

    /// @notice Returns the price of 1 unit of debt in collateral tokens
    /// @return The price of debt in collateral tokens
    function getDebtPriceInCollateralToken() external view returns (uint256);
}
