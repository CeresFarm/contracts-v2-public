// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {LeveragedStrategy} from "src/strategies/LeveragedStrategy.sol";

/// @title MinimalCeresStrategy
/// @notice Minimal implementation of LeveragedStrategy for invariant testing.
///  - asset == collateral (isAssetCollateral = true) — the same token is used for both,
///    so no swapper or oracle is needed for deposit/harvest paths.
///  - All market operations (_depositCollateral, _withdrawCollateral, etc.) are no-ops.
///    Deposited asset tokens remain idle inside this contract, making
///    `assetToken.balanceOf(address(this))` the source of truth for total assets.
///  - _reportTotalAssets overrides the LeveragedStrategy implementation to return the
///    idle balance directly, bypassing the oracle-dependent getNetAssets() call.
///  - _freeFunds returns 0 immediately (no leverage to unwind).
///
contract MinimalCeresStrategy is LeveragedStrategy {
    uint16 private constant MOCK_MAX_LTV_BPS = 9_000; // 90% – permissive, never reached

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               CONSTRUCTOR/INITIALIZERS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function initialize(address assetToken_, address debtToken_, address roleManager_) external initializer {
        __LeveragedStrategy_init(
            assetToken_, // asset
            "Ceres Minimal Invariant Vault",
            "ceres-INV",
            assetToken_, // collateral == asset -> isAssetCollateral = true
            debtToken_,
            roleManager_
        );
    }

    //  Market operations: all no-ops
    //  Tokens are never physically moved to an external protocol; they stay idle.
    function _depositCollateral(uint256) internal pure override {}

    function _withdrawCollateral(uint256) internal pure override {}

    function _borrowFromMarket(uint256) internal pure override {}

    function _repayDebt(uint256) internal pure override {}

    //  Market reads — always 0 (no external position)
    function _getCollateralAmount() internal pure override returns (uint256) {
        return 0;
    }

    function _getDebtAmount() internal pure override returns (uint256) {
        return 0;
    }

    function _getStrategyLtv() internal pure override returns (uint16) {
        return 0;
    }

    function _getStrategyMaxLtvBps() internal pure override returns (uint16) {
        return MOCK_MAX_LTV_BPS;
    }

    //  Accounting overrides
    /// @dev All assets are idle, total assets equal the vault's own asset balance.
    /// Bypasses getNetAssets() and its oracle dependency entirely.
    function _reportTotalAssets() internal view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint128 reserve = withdrawalReserve();

        // Remove locked `withdrawalReserve` from active total assets
        return total > reserve ? total - reserve : 0;
    }

    /// @dev No leverage to unwind. Returns 0 so processCurrentRequest falls back
    /// to idle-asset coverage only
    function _freeFunds(uint256, bytes calldata) internal pure override returns (uint256) {
        return 0;
    }
}
