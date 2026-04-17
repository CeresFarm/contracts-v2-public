// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {IUniversalOracleRouter} from "../interfaces/periphery/IUniversalOracleRouter.sol";
import {IOracleAdapter} from "../interfaces/periphery/IOracleAdapter.sol";
import {LibError} from "../libraries/LibError.sol";

/// @notice A unified adapter that replaces all protocol-specific OracleAdapters.
/// It uses the UniversalOracleRouter to fetch quotes dynamically, stripping away
/// the need for `OracleAdapterBase` and its many typed children.
contract OracleAdapter is IOracleAdapter {
    using Math for uint256;

    /// @dev Internal multiplier used ONLY within inverse conversion math to prevent
    /// integer truncation when quoting small amounts. All returned values respect
    /// the output token decimals.
    uint256 private constant INTERNAL_SCALE_FACTOR = 1e18;

    IUniversalOracleRouter public immutable ROUTER;

    uint256 internal immutable ASSET_UNIT;
    uint256 internal immutable COLLATERAL_UNIT;
    uint256 internal immutable DEBT_UNIT;

    address public immutable ASSET_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    address public immutable DEBT_TOKEN;

    bool public immutable IS_ASSET_COLLATERAL;

    /// @notice Deploys the adapter for a specific strategy's asset/collateral/debt token.
    /// @param _router Address of the UniversalOracleRouter.
    /// @param _assetToken The strategy's deposit asset.
    /// @param _collateralToken The token supplied as collateral in the lending market.
    /// @param _debtToken The token borrowed from the lending market.
    constructor(address _router, address _assetToken, address _collateralToken, address _debtToken) {
        if (_router == address(0)) revert LibError.ZeroAddress();
        ROUTER = IUniversalOracleRouter(_router);

        ASSET_TOKEN = _assetToken;
        COLLATERAL_TOKEN = _collateralToken;
        DEBT_TOKEN = _debtToken;

        IS_ASSET_COLLATERAL = _assetToken == _collateralToken;

        ASSET_UNIT = 10 ** IERC20Metadata(_assetToken).decimals();
        COLLATERAL_UNIT = 10 ** IERC20Metadata(_collateralToken).decimals();
        DEBT_UNIT = 10 ** IERC20Metadata(_debtToken).decimals();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        CONVERSIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Converts collateral token amount to asset token amount.
    /// @param collateralAmount Amount of collateral token (in its token decimals).
    /// @return Equivalent amount of asset token.
    function convertCollateralToAssets(uint256 collateralAmount) public view returns (uint256) {
        if (collateralAmount == 0 || IS_ASSET_COLLATERAL) return collateralAmount;
        return ROUTER.quote(COLLATERAL_TOKEN, ASSET_TOKEN, collateralAmount);
    }

    /// @notice Converts asset token amount to collateral token amount.
    /// @dev Uses a scaled-inverse calculation to avoid integer truncation for low-decimal tokens.
    /// @param assetAmount Amount of asset token (in its token decimals).
    /// @return Equivalent amount of collateral token.
    function convertAssetsToCollateral(uint256 assetAmount) public view returns (uint256) {
        if (assetAmount == 0 || IS_ASSET_COLLATERAL) return assetAmount;
        // Inverts the price of 1 Collateral Unit rather than requiring inverse routing configs.
        // Scale up the reference amount by INTERNAL_SCALE_FACTOR to avoid truncation to zero
        // for low-decimal tokens. The factor cancels out in the final mulDiv.
        uint256 scaledRefAmount = COLLATERAL_UNIT * INTERNAL_SCALE_FACTOR;
        uint256 scaledCollateralInAsset = ROUTER.quote(COLLATERAL_TOKEN, ASSET_TOKEN, scaledRefAmount);
        return assetAmount.mulDiv(scaledRefAmount, scaledCollateralInAsset);
    }

    /// @notice Converts collateral token amount to debt token amount.
    /// @param collateralAmount Amount of collateral token (in its token decimals).
    /// @return Equivalent amount of debt token.
    function convertCollateralToDebt(uint256 collateralAmount) public view returns (uint256) {
        if (collateralAmount == 0) return 0;
        return ROUTER.quote(COLLATERAL_TOKEN, DEBT_TOKEN, collateralAmount);
    }

    /// @notice Converts debt token amount to collateral token amount.
    /// @dev Uses the same scaled-inverse approach as `convertAssetsToCollateral`.
    /// @param debtAmount Amount of debt token (in its token decimals).
    /// @return Equivalent amount of collateral token.
    function convertDebtToCollateral(uint256 debtAmount) public view returns (uint256) {
        if (debtAmount == 0) return 0;
        // Same scaled-inverse approach as convertAssetsToCollateral.
        uint256 scaledRefAmount = COLLATERAL_UNIT * INTERNAL_SCALE_FACTOR;
        uint256 scaledCollateralInDebt = ROUTER.quote(COLLATERAL_TOKEN, DEBT_TOKEN, scaledRefAmount);
        return debtAmount.mulDiv(scaledRefAmount, scaledCollateralInDebt);
    }

    /// @notice Converts debt token amount to asset token amount via collateral as an intermediate.
    /// @param debtAmount Amount of debt token (in its token decimals).
    /// @return Equivalent amount of asset token.
    function convertDebtToAssets(uint256 debtAmount) public view returns (uint256) {
        if (debtAmount == 0) return 0;
        uint256 collateralAmount = convertDebtToCollateral(debtAmount);
        return convertCollateralToAssets(collateralAmount);
    }

    /// @notice Converts asset token amount to debt token amount via collateral as an intermediate.
    /// @param assetAmount Amount of asset token (in its token decimals).
    /// @return Equivalent amount of debt token.
    function convertAssetsToDebt(uint256 assetAmount) public view returns (uint256) {
        if (assetAmount == 0) return 0;
        uint256 collateralAmount = convertAssetsToCollateral(assetAmount);
        return convertCollateralToDebt(collateralAmount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     PRICE FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the price of one asset unit denominated in collateral token.
    /// @return Price of 1 whole asset token expressed in collateral token decimals.
    function getAssetPriceInCollateralToken() public view returns (uint256) {
        return convertAssetsToCollateral(ASSET_UNIT);
    }

    /// @notice Returns the price of one collateral unit denominated in asset token.
    /// @return Price of 1 whole collateral token expressed in asset token decimals.
    function getCollateralPriceInAssetToken() public view returns (uint256) {
        return convertCollateralToAssets(COLLATERAL_UNIT);
    }

    /// @notice Returns the price of one asset unit denominated in debt token.
    /// @return Price of 1 whole asset token expressed in debt token decimals.
    function getAssetPriceInDebtToken() public view returns (uint256) {
        return convertAssetsToDebt(ASSET_UNIT);
    }

    /// @notice Returns the price of one debt unit denominated in asset token.
    /// @return Price of 1 whole debt token expressed in asset token decimals.
    function getDebtPriceInAssetToken() public view returns (uint256) {
        return convertDebtToAssets(DEBT_UNIT);
    }

    /// @notice Returns the price of one collateral unit denominated in debt token.
    /// @return Price of 1 whole collateral token expressed in debt token decimals.
    function getCollateralPriceInDebtToken() public view returns (uint256) {
        return convertCollateralToDebt(COLLATERAL_UNIT);
    }

    /// @notice Returns the price of one debt unit denominated in collateral token.
    /// @return Price of 1 whole debt token expressed in collateral token decimals.
    function getDebtPriceInCollateralToken() public view returns (uint256) {
        return convertDebtToCollateral(DEBT_UNIT);
    }
}
