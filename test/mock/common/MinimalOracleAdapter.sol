// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleAdapter} from "src/interfaces/periphery/IOracleAdapter.sol";

/// @title MinimalOracleAdapter
/// @notice 1:1 oracle for invariant testing. Every conversion returns the input amount unchanged,
/// meaning asset == collateral == debt in value. This removes price-related complexity from
/// invariant tests focused purely on CeresBaseStrategy vault accounting.
contract MinimalOracleAdapter is IOracleAdapter {
    address public immutable ASSET_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    address public immutable DEBT_TOKEN;

    constructor(address asset_, address collateral_, address debt_) {
        ASSET_TOKEN = asset_;
        COLLATERAL_TOKEN = collateral_;
        DEBT_TOKEN = debt_;
    }

    function convertAssetsToCollateral(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertAssetsToDebt(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertCollateralToAssets(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertCollateralToDebt(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertDebtToAssets(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertDebtToCollateral(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getAssetPriceInCollateralToken() external pure returns (uint256) {
        return 1e18;
    }

    function getAssetPriceInDebtToken() external pure returns (uint256) {
        return 1e18;
    }

    function getCollateralPriceInAssetToken() external pure returns (uint256) {
        return 1e18;
    }

    function getCollateralPriceInDebtToken() external pure returns (uint256) {
        return 1e18;
    }

    function getDebtPriceInAssetToken() external pure returns (uint256) {
        return 1e18;
    }

    function getDebtPriceInCollateralToken() external pure returns (uint256) {
        return 1e18;
    }
}
