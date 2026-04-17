// SPDX-License-Identifier: BUSL
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOracleAdapter} from "src/interfaces/periphery/IOracleAdapter.sol";

/// @title MockOracleAdapter
/// @notice Mock implementation of IOracleAdapter for testing purposes
/// @dev Supports both related (asset=collateral) and variable (asset≠collateral) scenarios
contract MockOracleAdapter is IOracleAdapter {
    uint256 public constant ORACLE_PRECISION = 1e18;

    address public immutable override ASSET_TOKEN;
    address public immutable override COLLATERAL_TOKEN;
    address public immutable override DEBT_TOKEN;

    uint8 public immutable ASSET_DECIMALS;
    uint8 public immutable COLLATERAL_DECIMALS;
    uint8 public immutable DEBT_DECIMALS;

    bool public immutable IS_ASSET_COLLATERAL;

    // Configurable prices (in ORACLE_PRECISION = 1e18)
    uint256 public assetPriceInDebt; // Price of 1 asset token in debt token terms
    uint256 public collateralPriceInDebt; // Price of 1 collateral token in debt token terms
    uint256 public assetPriceInCollateral; // Price of 1 asset token in collateral token terms

    // Flags for testing error conditions
    bool public shouldRevert;

    constructor(address _assetToken, address _collateralToken, address _debtToken) {
        ASSET_TOKEN = _assetToken;
        COLLATERAL_TOKEN = _collateralToken;
        DEBT_TOKEN = _debtToken;

        IS_ASSET_COLLATERAL = (_assetToken == _collateralToken);

        ASSET_DECIMALS = IERC20Metadata(_assetToken).decimals();
        COLLATERAL_DECIMALS = IERC20Metadata(_collateralToken).decimals();
        DEBT_DECIMALS = IERC20Metadata(_debtToken).decimals();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    ADMIN FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Set the asset price in debt token terms
    /// @param _price Price with ORACLE_PRECISION (1e18)
    function setAssetPriceInDebt(uint256 _price) external {
        assetPriceInDebt = _price;
    }

    /// @notice Set the collateral price in debt token terms
    /// @param _price Price with ORACLE_PRECISION (1e18)
    function setCollateralPriceInDebt(uint256 _price) external {
        collateralPriceInDebt = _price;
    }

    /// @notice Set the asset price in collateral token terms
    /// @param _price Price with ORACLE_PRECISION (1e18)
    function setAssetPriceInCollateral(uint256 _price) external {
        assetPriceInCollateral = _price;
    }

    /// @notice Set all prices at once for convenience
    function setPrices(
        uint256 _assetPriceInDebt,
        uint256 _collateralPriceInDebt,
        uint256 _assetPriceInCollateral
    ) external {
        assetPriceInDebt = _assetPriceInDebt;
        collateralPriceInDebt = _collateralPriceInDebt;
        assetPriceInCollateral = _assetPriceInCollateral;
    }

    /// @notice Toggle revert behavior for testing
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function convertCollateralToAssets(uint256 collateralAmount) external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return collateralAmount;
        }
        // collateralAmount * (collateralPriceInDebt / assetPriceInDebt)
        // Adjust for decimals: result should be in asset decimals
        if (assetPriceInCollateral == 0) return 0;
        return
            (collateralAmount * ORACLE_PRECISION * (10 ** ASSET_DECIMALS)) /
            (assetPriceInCollateral * (10 ** COLLATERAL_DECIMALS));
    }

    function convertAssetsToCollateral(uint256 assetAmount) external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return assetAmount;
        }
        // assetAmount * assetPriceInCollateral
        // Adjust for decimals: result should be in collateral decimals
        return
            (assetAmount * assetPriceInCollateral * (10 ** COLLATERAL_DECIMALS)) /
            (ORACLE_PRECISION * (10 ** ASSET_DECIMALS));
    }

    function convertCollateralToDebt(uint256 collateralAmount) public view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (collateralPriceInDebt == 0) return 0;
        // collateralAmount * collateralPriceInDebt
        // Adjust for decimals: result should be in debt decimals
        return
            (collateralAmount * collateralPriceInDebt * (10 ** DEBT_DECIMALS)) /
            (ORACLE_PRECISION * (10 ** COLLATERAL_DECIMALS));
    }

    function convertDebtToCollateral(uint256 debtAmount) public view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (collateralPriceInDebt == 0) return 0;
        // debtAmount / collateralPriceInDebt
        // Adjust for decimals: result should be in collateral decimals
        return
            (debtAmount * ORACLE_PRECISION * (10 ** COLLATERAL_DECIMALS)) /
            (collateralPriceInDebt * (10 ** DEBT_DECIMALS));
    }

    function convertDebtToAssets(uint256 debtAmount) public view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return convertDebtToCollateral(debtAmount);
        }
        if (assetPriceInDebt == 0) return 0;
        // debtAmount / assetPriceInDebt
        // Adjust for decimals: result should be in asset decimals
        return (debtAmount * ORACLE_PRECISION * (10 ** ASSET_DECIMALS)) / (assetPriceInDebt * (10 ** DEBT_DECIMALS));
    }

    function convertAssetsToDebt(uint256 assetAmount) public view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return convertCollateralToDebt(assetAmount);
        }
        // assetAmount * assetPriceInDebt
        // Adjust for decimals: result should be in debt decimals
        return (assetAmount * assetPriceInDebt * (10 ** DEBT_DECIMALS)) / (ORACLE_PRECISION * (10 ** ASSET_DECIMALS));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    PRICE FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getAssetPriceInCollateralToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return 10 ** ASSET_DECIMALS;
        }
        return assetPriceInCollateral;
    }

    function getAssetPriceInDebtToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return collateralPriceInDebt;
        }
        return assetPriceInDebt;
    }

    function getCollateralPriceInAssetToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            return ORACLE_PRECISION;
        }
        if (assetPriceInCollateral == 0) return 0;
        return (ORACLE_PRECISION * ORACLE_PRECISION) / assetPriceInCollateral;
    }

    function getCollateralPriceInDebtToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        return collateralPriceInDebt;
    }

    function getDebtPriceInAssetToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (IS_ASSET_COLLATERAL) {
            if (collateralPriceInDebt == 0) return 0;
            return (ORACLE_PRECISION * ORACLE_PRECISION) / collateralPriceInDebt;
        }
        if (assetPriceInDebt == 0) return 0;
        return (ORACLE_PRECISION * ORACLE_PRECISION) / assetPriceInDebt;
    }

    function getDebtPriceInCollateralToken() external view override returns (uint256) {
        require(!shouldRevert, "MockOracleAdapter: forced revert");
        if (collateralPriceInDebt == 0) return 0;
        return (ORACLE_PRECISION * ORACLE_PRECISION) / collateralPriceInDebt;
    }
}
