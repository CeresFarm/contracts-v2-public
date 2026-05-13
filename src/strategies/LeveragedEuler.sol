// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {LibError} from "../libraries/LibError.sol";
import {IEVault} from "../interfaces/euler/IEVault.sol";
import {IEVC} from "../interfaces/euler/IEVC.sol";

import {LeveragedStrategy} from "./LeveragedStrategy.sol";

contract LeveragedEuler is LeveragedStrategy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          STATE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.LeveragedEuler
    struct LeveragedEulerStorage {
        IEVault collateralVault;
        IEVault borrowVault;
    }

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedEuler")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LEVERAGED_EULER_STORAGE_LOCATION =
        0x5129f9cf92b365d54467f5b32a6becb76a960704fe1848c67450f68943359400;

    function _getLeveragedEulerStorage() private pure returns (LeveragedEulerStorage storage S) {
        assembly {
            S.slot := LEVERAGED_EULER_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Euler-backed leveraged strategy.
    /// @param _assetToken The deposit asset.
    /// @param _name ERC20 name for the vault share token.
    /// @param _symbol ERC20 symbol for the vault share token.
    /// @param _collateralToken The token supplied as collateral (must match `_collateralVault` asset).
    /// @param _debtToken The token borrowed (must match `_borrowVault` asset).
    /// @param _collateralVault Euler vault used for collateral deposits.
    /// @param _borrowVault Euler vault used for borrowing.
    /// @param _vaultConnector Euler Vault Connector (EVC) address.
    /// @param _roleManager Address of the RoleManager.
    function initialize(
        address _assetToken,
        string memory _name,
        string memory _symbol,
        address _collateralToken,
        address _debtToken,
        address _collateralVault,
        address _borrowVault,
        address _vaultConnector,
        address _roleManager
    ) external initializer {
        __LeveragedStrategy_init(_assetToken, _name, _symbol, _collateralToken, _debtToken, _roleManager);
        __LeveragedEuler_init_unchained(_collateralToken, _debtToken, _collateralVault, _borrowVault, _vaultConnector);
    }

    function __LeveragedEuler_init_unchained(
        address _collateralToken,
        address _debtToken,
        address _collateralVault,
        address _borrowVault,
        address _vaultConnector
    ) internal onlyInitializing {
        LeveragedEulerStorage storage S = _getLeveragedEulerStorage();

        // Validate Euler market
        if (IEVault(_collateralVault).asset() != _collateralToken) revert LibError.InvalidMarket();
        if (IEVault(_borrowVault).asset() != _debtToken) revert LibError.InvalidMarket();

        S.collateralVault = IEVault(_collateralVault);
        S.borrowVault = IEVault(_borrowVault);

        IEVC(_vaultConnector).enableCollateral(address(this), _collateralVault);
        IEVC(_vaultConnector).enableController(address(this), _borrowVault);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EXTERNAL FUNCTIONS: GETTERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the Euler vault addresses used by the strategy.
    function getMarketDetails() external view returns (address collateralVault, address borrowVault) {
        LeveragedEulerStorage storage S = _getLeveragedEulerStorage();
        collateralVault = address(S.collateralVault);
        borrowVault = address(S.borrowVault);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              EULER MARKET CORE FUNCTIONS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Deposits collateral into the Euler collateral vault.
    /// @param collateralAmount Amount of collateral to deposit.
    function _depositCollateral(uint256 collateralAmount) internal override {
        IEVault collateralVault = _getLeveragedEulerStorage().collateralVault;
        COLLATERAL_TOKEN().forceApprove(address(collateralVault), collateralAmount);
        collateralVault.deposit(collateralAmount, address(this));
    }

    /// @dev Withdraws collateral from the Euler collateral vault.
    /// @param collateralAmount Amount of collateral to withdraw.
    function _withdrawCollateral(uint256 collateralAmount) internal override {
        _getLeveragedEulerStorage().collateralVault.withdraw(collateralAmount, address(this), address(this));
    }

    /// @dev Borrows debt token from the Euler borrow vault.
    /// @param borrowAmount Amount of debt to borrow.
    function _borrowFromMarket(uint256 borrowAmount) internal override {
        _getLeveragedEulerStorage().borrowVault.borrow(borrowAmount, address(this));
    }

    /// @dev Repays debt token to the Euler borrow vault.
    /// @param repayAmount Amount of debt to repay.
    function _repayDebt(uint256 repayAmount) internal override {
        IEVault borrowVault = _getLeveragedEulerStorage().borrowVault;
        DEBT_TOKEN().forceApprove(address(borrowVault), repayAmount);
        borrowVault.repay(repayAmount, address(this));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              EULER MARKET INTERNAL FUNCTIONS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Returns collateral by converting vault shares to underlying assets.
    function _getCollateralAmount() internal view override returns (uint256) {
        IEVault collateralVault = _getLeveragedEulerStorage().collateralVault;
        return collateralVault.convertToAssets(collateralVault.balanceOf(address(this)));
    }

    /// @dev Returns the outstanding debt via `debtOf` on the Euler borrow vault.
    function _getDebtAmount() internal view override returns (uint256) {
        return _getLeveragedEulerStorage().borrowVault.debtOf(address(this));
    }

    /// @dev Computes the strategy LTV using Euler's `accountLiquidity` risk-adjusted values.
    /// The risk-adjusted collateral is divided by the collateral factor to recover the actual value.
    function _getStrategyLtv() internal view override returns (uint16 ltvBps) {
        LeveragedEulerStorage storage S = _getLeveragedEulerStorage();

        (uint256 collateralValue, uint256 liabilityValue) = S.borrowVault.accountLiquidity(address(this), false);
        if (collateralValue == 0) return 0;

        // collateralValue returned by Euler is risk adjusted value
        // hence to calculate actual collateral value, divide by collateralization ratio (LTV) of collateral
        uint256 maxLtv = Math.max(1, _getMaxLtv()); // Avoid division by zero if collateral is disabled
        uint256 actualCollateralValue = collateralValue.mulDiv(BPS_PRECISION, maxLtv, Math.Rounding.Floor);

        // Round-up the strategy LTV to be on the conservative side
        ltvBps = (liabilityValue.mulDiv(BPS_PRECISION, actualCollateralValue, Math.Rounding.Ceil)).toUint16();
    }

    /// @dev Returns the borrow LTV configured in Euler for the collateral vault (already in basis points).
    function _getMaxLtv() internal view returns (uint256) {
        LeveragedEulerStorage storage S = _getLeveragedEulerStorage();
        // Euler returns the LTV directly in basis points, so additional conversion is not required
        return S.borrowVault.LTVBorrow(address(S.collateralVault));
    }

    /// @dev Returns the market max LTV in basis points.
    function _getStrategyMaxLtvBps() internal view override returns (uint16 maxLtvBps) {
        maxLtvBps = _getMaxLtv().toUint16();
    }
}
