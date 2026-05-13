// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISilo, ISiloConfig} from "src/interfaces/silo/ISilo.sol";
import {ISiloLens, IInterestRateModel, IPartialLiquidation} from "src/interfaces/silo/ISiloLens.sol";
import {ISiloOracle} from "src/interfaces/silo/ISiloOracle.sol";

/// @title MockSiloLens
/// @notice Mock implementation of ISiloLens for testing purposes
/// @dev This mock queries real Silo contracts to provide accurate lens functionality for testing
contract MockSiloLens is ISiloLens {
    uint256 internal constant _PRECISION_DECIMALS = 1e18;

    /// @inheritdoc ISiloLens
    function isSolvent(ISilo _silo, address _borrower) external view override returns (bool) {
        return _silo.isSolvent(_borrower);
    }

    /// @inheritdoc ISiloLens
    function liquidity(ISilo _silo) external view override returns (uint256) {
        return _silo.getLiquidity();
    }

    /// @inheritdoc ISiloLens
    function getRawLiquidity(ISilo _silo) external view virtual override returns (uint256 /*liquidity */) {
        // Get the underlying asset balance
        ISiloConfig siloConfig = _silo.config();
        address asset = siloConfig.getAssetForSilo(address(_silo));
        return IERC20(asset).balanceOf(address(_silo));
    }

    /// @inheritdoc ISiloLens
    function getMaxLtv(ISilo _silo) external view virtual override returns (uint256 maxLtv) {
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));
        return config.maxLtv;
    }

    /// @inheritdoc ISiloLens
    function getLt(ISilo _silo) external view virtual override returns (uint256 lt) {
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));
        return config.lt;
    }

    /// @inheritdoc ISiloLens
    function getUserLT(ISilo _silo, address /* _borrower */) external view override returns (uint256 userLT) {
        // Simplified: return the configured LT for the silo
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));
        return config.lt;
    }

    /// @inheritdoc ISiloLens
    function getUsersLT(Borrower[] calldata _borrowers) external view override returns (uint256[] memory usersLTs) {
        usersLTs = new uint256[](_borrowers.length);

        for (uint256 i; i < _borrowers.length; i++) {
            Borrower memory borrower = _borrowers[i];
            ISiloConfig siloConfig = borrower.silo.config();
            ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(borrower.silo));
            usersLTs[i] = config.lt;
        }
    }

    /// @inheritdoc ISiloLens
    function getUsersHealth(
        Borrower[] calldata _borrowers
    ) external view override returns (BorrowerHealth[] memory healths) {
        healths = new BorrowerHealth[](_borrowers.length);

        for (uint256 i; i < _borrowers.length; i++) {
            Borrower memory borrower = _borrowers[i];
            BorrowerHealth memory health = healths[i];

            health.ltv = _calculateLtv(borrower.silo, borrower.wallet);

            ISiloConfig siloConfig = borrower.silo.config();
            ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(borrower.silo));
            health.lt = config.lt;
        }
    }

    /// @inheritdoc ISiloLens
    function getUserLTV(ISilo _silo, address _borrower) external view override returns (uint256 userLTV) {
        return _calculateLtv(_silo, _borrower);
    }

    /// @inheritdoc ISiloLens
    function getLtv(ISilo _silo, address _borrower) external view virtual override returns (uint256 ltv) {
        return _calculateLtv(_silo, _borrower);
    }

    /// @inheritdoc ISiloLens
    function hasPosition(ISiloConfig _siloConfig, address _borrower) external view virtual override returns (bool has) {
        (address silo0, address silo1) = _siloConfig.getSilos();

        // Check if borrower has collateral in either silo
        uint256 collateral0 = ISilo(silo0).balanceOf(_borrower);
        uint256 collateral1 = ISilo(silo1).balanceOf(_borrower);

        // Check if borrower has debt in either silo
        (, , address debtToken0) = _siloConfig.getShareTokens(silo0);
        (, , address debtToken1) = _siloConfig.getShareTokens(silo1);

        uint256 debt0 = debtToken0 != address(0) ? IERC20(debtToken0).balanceOf(_borrower) : 0;
        uint256 debt1 = debtToken1 != address(0) ? IERC20(debtToken1).balanceOf(_borrower) : 0;

        has = (collateral0 > 0 || collateral1 > 0 || debt0 > 0 || debt1 > 0);
    }

    /// @inheritdoc ISiloLens
    function inDebt(ISiloConfig _siloConfig, address _borrower) external view override returns (bool hasDebt) {
        address debtSilo = _siloConfig.getDebtSilo(_borrower);
        hasDebt = debtSilo != address(0);
    }

    /// @inheritdoc ISiloLens
    function getFeesAndFeeReceivers(
        ISilo _silo
    )
        external
        view
        virtual
        override
        returns (address daoFeeReceiver, address deployerFeeReceiver, uint256 daoFee, uint256 deployerFee)
    {
        // Simplified: return zero addresses for fee receivers in mock
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));

        daoFeeReceiver = address(0);
        deployerFeeReceiver = address(0);
        daoFee = config.daoFee;
        deployerFee = config.deployerFee;
    }

    /// @inheritdoc ISiloLens
    function collateralBalanceOfUnderlying(
        ISilo _silo,
        address _borrower
    ) external view virtual override returns (uint256 borrowerCollateral) {
        // Get regular collateral shares (ERC20 balance of silo token)
        uint256 collateralShares = _silo.balanceOf(_borrower);
        uint256 collateralAssets = _silo.previewRedeem(collateralShares, ISilo.CollateralType.Collateral);

        // Get protected collateral balance
        // For MockSilo, we need to check the protected shares directly
        // since they're not tracked as ERC20 balance
        uint256 protectedAssets = 0;
        try this._getProtectedBalance(_silo, _borrower) returns (uint256 protected) {
            protectedAssets = protected;
        } catch {
            // If the mock doesn't support protected balance query, skip it
        }
        borrowerCollateral = collateralAssets + protectedAssets;
    }

    /// @notice Helper function to get protected collateral balance
    /// @dev This is a workaround to query MockSilo's protected shares
    function _getProtectedBalance(ISilo _silo, address _borrower) external view returns (uint256) {
        // Try to get protected shares from the mock
        // The MockSilo has a public protectedShares mapping
        (bool success, bytes memory data) = address(_silo).staticcall(
            abi.encodeWithSignature("protectedShares(address)", _borrower)
        );

        if (!success || data.length == 0) {
            return 0;
        }

        uint256 protectedShares = abi.decode(data, (uint256));
        if (protectedShares == 0) {
            return 0;
        }

        // Convert protected shares to assets
        return _silo.previewRedeem(protectedShares, ISilo.CollateralType.Protected);
    }

    /// @inheritdoc ISiloLens
    function debtBalanceOfUnderlying(ISilo _silo, address _borrower) external view virtual override returns (uint256) {
        return _silo.maxRepay(_borrower);
    }

    /// @inheritdoc ISiloLens
    function maxLiquidation(
        ISilo _silo,
        IPartialLiquidation /* _hook */,
        address _borrower
    )
        external
        view
        virtual
        override
        returns (uint256 collateralToLiquidate, uint256 debtToRepay, bool sTokenRequired, bool fullLiquidation)
    {
        // Simplified for mock: just check if borrower is insolvent
        bool solvent = _silo.isSolvent(_borrower);

        if (!solvent) {
            debtToRepay = _silo.maxRepay(_borrower);
            collateralToLiquidate = _silo.balanceOf(_borrower);
            sTokenRequired = false;
            fullLiquidation = true;
        }
    }

    /// @inheritdoc ISiloLens
    function totalDeposits(ISilo _silo) external view override returns (uint256) {
        return _silo.getTotalAssetsStorage(ISilo.AssetType.Collateral);
    }

    /// @inheritdoc ISiloLens
    function totalDepositsWithInterest(ISilo _silo) external view override returns (uint256 amount) {
        amount = _silo.getCollateralAssets();
    }

    /// @inheritdoc ISiloLens
    function totalBorrowAmountWithInterest(ISilo _silo) external view override returns (uint256 amount) {
        amount = _silo.getDebtAssets();
    }

    /// @inheritdoc ISiloLens
    function collateralOnlyDeposits(ISilo _silo) external view override returns (uint256) {
        return _silo.getTotalAssetsStorage(ISilo.AssetType.Protected);
    }

    /// @inheritdoc ISiloLens
    function getDepositAmount(
        ISilo _silo,
        address _borrower
    ) external view override returns (uint256 borrowerDeposits) {
        uint256 shares = _silo.balanceOf(_borrower);
        borrowerDeposits = _silo.previewRedeem(shares, ISilo.CollateralType.Collateral);
    }

    /// @inheritdoc ISiloLens
    function totalBorrowAmount(ISilo _silo) external view override returns (uint256) {
        return _silo.getTotalAssetsStorage(ISilo.AssetType.Debt);
    }

    /// @inheritdoc ISiloLens
    function totalBorrowShare(ISilo _silo) external view override returns (uint256) {
        ISiloConfig siloConfig = _silo.config();
        (, , address debtToken) = siloConfig.getShareTokens(address(_silo));

        if (debtToken == address(0)) return 0;

        return IERC20(debtToken).totalSupply();
    }

    /// @inheritdoc ISiloLens
    function getBorrowAmount(ISilo _silo, address _borrower) external view override returns (uint256 maxRepay) {
        maxRepay = _silo.maxRepay(_borrower);
    }

    /// @inheritdoc ISiloLens
    function borrowShare(ISilo _silo, address _borrower) external view override returns (uint256) {
        ISiloConfig siloConfig = _silo.config();
        (, , address debtToken) = siloConfig.getShareTokens(address(_silo));

        if (debtToken == address(0)) return 0;

        return IERC20(debtToken).balanceOf(_borrower);
    }

    /// @inheritdoc ISiloLens
    function protocolFees(ISilo _silo) external view override returns (uint256 daoAndDeployerRevenue) {
        (daoAndDeployerRevenue, , , , ) = _silo.getSiloStorage();
    }

    /// @inheritdoc ISiloLens
    function calculateCollateralValue(
        ISiloConfig _siloConfig,
        address _borrower
    ) external view override returns (uint256 collateralValue) {
        // Simplified: return the collateral balance
        address collateralSilo = _siloConfig.borrowerCollateralSilo(_borrower);
        if (collateralSilo == address(0)) return 0;

        uint256 shares = ISilo(collateralSilo).balanceOf(_borrower);
        collateralValue = ISilo(collateralSilo).previewRedeem(shares, ISilo.CollateralType.Collateral);
    }

    /// @inheritdoc ISiloLens
    function calculateBorrowValue(
        ISiloConfig _siloConfig,
        address _borrower
    ) external view override returns (uint256 borrowValue) {
        // Get debt silo
        address debtSilo = _siloConfig.getDebtSilo(_borrower);
        if (debtSilo == address(0)) return 0;

        borrowValue = ISilo(debtSilo).maxRepay(_borrower);
    }

    /// @inheritdoc ISiloLens
    function getUtilization(ISilo _silo) external view override returns (uint256) {
        ISilo.UtilizationData memory data = _silo.utilizationData();

        if (data.collateralAssets != 0) {
            return (data.debtAssets * _PRECISION_DECIMALS) / data.collateralAssets;
        }

        return 0;
    }

    /// @inheritdoc ISiloLens
    function getInterestRateModel(ISilo _silo) external view virtual override returns (address irm) {
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));
        return config.interestRateModel;
    }

    /// @inheritdoc ISiloLens
    function getBorrowAPR(ISilo /* _silo */) external view virtual override returns (uint256 borrowAPR) {
        // Simplified: return 0 for mock
        // Real implementation would query the interest rate model
        return 0;
    }

    /// @inheritdoc ISiloLens
    function getDepositAPR(ISilo /* _silo */) external view virtual override returns (uint256 depositAPR) {
        // Simplified: return 0 for mock
        // Real implementation would calculate based on borrow APR and utilization
        return 0;
    }

    /// @inheritdoc ISiloLens
    function getAPRs(ISilo[] calldata _silos) external view virtual override returns (APR[] memory aprs) {
        aprs = new APR[](_silos.length);

        for (uint256 i; i < _silos.length; i++) {
            aprs[i] = APR({borrowAPR: 0, depositAPR: 0});
        }
    }

    /// @inheritdoc ISiloLens
    function getModel(ISilo _silo) external view override returns (IInterestRateModel irm) {
        ISiloConfig siloConfig = _silo.config();
        ISiloConfig.ConfigData memory config = siloConfig.getConfig(address(_silo));
        irm = IInterestRateModel(config.interestRateModel);
    }

    /// @inheritdoc ISiloLens
    function getSiloIncentivesControllerProgramsNames(address) external pure override returns (string[] memory) {
        // Return empty array for mock
        return new string[](0);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   INTERNAL FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Calculate LTV for a borrower
    /// @dev LTV = (debt value / collateral value) expressed in 1e18 precision.
    ///      Collateral is converted to debt-token units via the silo's solvency oracle so that
    ///      the ratio is dimensionally correct regardless of collateral/debt decimals.
    function _calculateLtv(ISilo _silo, address _borrower) internal view returns (uint256 ltv) {
        ISiloConfig siloConfig = _silo.config();

        // Get collateral silo and raw collateral token amount
        address collateralSilo = siloConfig.borrowerCollateralSilo(_borrower);
        if (collateralSilo == address(0)) return 0;

        uint256 collateralShares = ISilo(collateralSilo).balanceOf(_borrower);
        if (collateralShares == 0) return 0;

        uint256 collateralAssets = ISilo(collateralSilo).previewRedeem(
            collateralShares,
            ISilo.CollateralType.Collateral
        );
        if (collateralAssets == 0) return 0;

        // Get debt value (already in debt-token units)
        address debtSilo = siloConfig.getDebtSilo(_borrower);
        if (debtSilo == address(0)) return 0;

        uint256 debtValue = ISilo(debtSilo).maxRepay(_borrower);

        // Price collateral in debt-token units using the solvency oracle, mirroring real Silo
        ISiloConfig.ConfigData memory collateralConfig = siloConfig.getConfig(collateralSilo);
        if (collateralConfig.solvencyOracle != address(0)) {
            address collateralAsset = siloConfig.getAssetForSilo(collateralSilo);
            uint256 collateralInDebt = ISiloOracle(collateralConfig.solvencyOracle).quote(
                collateralAssets,
                collateralAsset
            );
            ltv = (debtValue * _PRECISION_DECIMALS) / collateralInDebt;
        } else {
            // Fallback: direct division (only valid when both tokens share the same denomination)
            ltv = (debtValue * _PRECISION_DECIMALS) / collateralAssets;
        }
    }
}
