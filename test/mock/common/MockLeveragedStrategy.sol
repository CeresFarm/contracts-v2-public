// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

import {LeveragedStrategy} from "../../../src/strategies/LeveragedStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockLeveragedStrategy
contract MockLeveragedStrategy is LeveragedStrategy {
    using Math for uint256;
    using SafeCast for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint16 private constant MOCK_MAX_LTV_BPS = 9_000; // 90%

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Virtual collateral/asset position in Money market
    uint256 public marketCollateral;

    /// @notice Virtual debt position in Money market
    uint256 public marketDebt;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               CONSTRUCTOR/INITIALIZERS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function initialize(address assetToken_, address debtToken_, address roleManager_) external initializer {
        __LeveragedStrategy_init(
            assetToken_,
            "Ceres Mock Leveraged Vault",
            "ceres-MOCK",
            assetToken_, // collateral == asset -> isAssetCollateral = true
            debtToken_,
            roleManager_
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CORE FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _depositCollateral(uint256 amount) internal override {
        MockERC20(asset()).burn(address(this), amount);
        marketCollateral += amount;
    }

    function _withdrawCollateral(uint256 amount) internal override {
        marketCollateral -= amount;
        MockERC20(asset()).mint(address(this), amount);
    }

    function _borrowFromMarket(uint256 amount) internal override {
        marketDebt += amount;
        MockERC20(address(DEBT_TOKEN())).mint(address(this), amount);
    }

    function _repayDebt(uint256 amount) internal override {
        marketDebt -= amount;
        MockERC20(address(DEBT_TOKEN())).burn(address(this), amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _getCollateralAmount() internal view override returns (uint256) {
        return marketCollateral;
    }

    function _getDebtAmount() internal view override returns (uint256) {
        return marketDebt;
    }

    function _getStrategyLtv() internal view override returns (uint16 ltvBps) {
        if (marketCollateral == 0) return 0;
        uint256 collateralInDebt = oracleAdapter().convertCollateralToDebt(marketCollateral);
        ltvBps = marketDebt.mulDiv(BPS_PRECISION, collateralInDebt, Math.Rounding.Ceil).toUint16();
    }

    function _getStrategyMaxLtvBps() internal pure override returns (uint16) {
        return MOCK_MAX_LTV_BPS;
    }

    function getStrategyMaxLtvBps() external pure returns (uint16) {
        return MOCK_MAX_LTV_BPS;
    }
}
