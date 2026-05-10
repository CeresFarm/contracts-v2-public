// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IOracleAdapter} from "../interfaces/periphery/IOracleAdapter.sol";

/// @title LeverageLib
/// @notice Library for common leverage calculation logic used across leveraged strategies
library LeverageLib {
    using Math for uint256;

    uint16 internal constant BPS_PRECISION = 100_00;

    /// @notice Calculate required collateral amount for a given debt and LTV
    /// @param debtAmount The debt amount
    /// @param ltvBps The loan-to-value ratio in basis points
    /// @param oracleAdapter The oracle adapter for price conversions
    /// @return collateralAmount The required collateral amount
    function computeTargetCollateral(
        uint256 debtAmount,
        uint256 ltvBps,
        IOracleAdapter oracleAdapter
    ) internal view returns (uint256 collateralAmount) {
        if (ltvBps == 0) return 0;

        // The required collateral amount is calculated using the netAssets to account for existing leverage.
        // Using the formula:
        // Target Debt = Net Assets * LTV / (1 - LTV)
        // Net Assets = Target Debt * (1 - LTV) / LTV
        uint256 debtInAssetTokens = oracleAdapter.convertDebtToAssets(debtAmount);

        // Round-up the netAssets for calculating collateral to be on the conservative side
        uint256 netAssets = debtInAssetTokens.mulDiv((BPS_PRECISION - ltvBps), ltvBps, Math.Rounding.Ceil);
        collateralAmount = oracleAdapter.convertAssetsToCollateral(netAssets);
    }

    /// @notice Calculate target debt amount for a given net assets and LTV
    /// @param netAssets The net assets in the strategy
    /// @param ltvBps The loan-to-value ratio in basis points
    /// @param oracleAdapter The oracle adapter for price conversions
    /// @return targetDebt The target debt amount
    function computeTargetDebt(
        uint256 netAssets,
        uint256 ltvBps,
        IOracleAdapter oracleAdapter
    ) internal view returns (uint256 targetDebt) {
        // The targetDebt amount is calculated based on the net assets in the strategy to account for existing leverage.
        // Using the formula:
        // Target Debt = Net Assets * LTV / (1 - LTV)
        // Convert net assets to debt units and then calculate the target debt
        uint256 assetsInDebtToken = oracleAdapter.convertAssetsToDebt(netAssets);

        // Round-down the targetDebt to be on the conservative side
        targetDebt = assetsInDebtToken.mulDiv(ltvBps, (BPS_PRECISION - ltvBps), Math.Rounding.Floor);
    }
}
