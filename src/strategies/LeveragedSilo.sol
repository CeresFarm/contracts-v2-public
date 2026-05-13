// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {LibError} from "../libraries/LibError.sol";
import {ISiloLens} from "../interfaces/silo/ISiloLens.sol";
import {ISilo, ISiloConfig} from "../interfaces/silo/ISilo.sol";

import {LeveragedStrategy} from "./LeveragedStrategy.sol";

contract LeveragedSilo is LeveragedStrategy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.LeveragedSilo
    // prettier-ignore
    struct LeveragedSiloStorage {
        // Slot 0: 160 + 8 = 168 bits (88 bits free)
        // Co-read in _depositCollateral and _withdrawCollateral
        ISilo depositSilo;
        ISilo.CollateralType collateralType;

        // Slot 1: 160 bits (96 bits free)
        ISilo borrowSilo;

        // Slot 2: 160 bits (96 bits free)
        ISiloLens siloLens;
    }

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedSilo")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LEVERAGED_SILO_STORAGE_LOCATION =
        0xd3347dc4810054ab576f4fa720be0262b5439ed263df1188320586c713f01100;

    function _getLeveragedSiloStorage() private pure returns (LeveragedSiloStorage storage S) {
        assembly {
            S.slot := LEVERAGED_SILO_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Silo leveraged strategy with its market and role configuration.
    /// @param _assetToken The ERC-20 token accepted as the strategy asset (denominator for shares).
    /// @param _name ERC-20 name of the vault share token.
    /// @param _symbol ERC-20 symbol of the vault share token.
    /// @param _collateralToken Token supplied as collateral to the Silo deposit silo.
    /// @param _debtToken Token borrowed from the Silo borrow silo.
    /// @param _siloLens Address of the Silo lens contract used for balance and LTV queries.
    /// @param _siloMarket Address of the SiloConfig contract identifying the two-silo market.
    /// @param _isProtected If true, collateral is deposited as protected (non-liquidatable by silo).
    /// @param _roleManager Address of the RoleManager contract controlling access roles.
    function initialize(
        address _assetToken,
        string memory _name,
        string memory _symbol,
        address _collateralToken,
        address _debtToken,
        address _siloLens,
        address _siloMarket,
        bool _isProtected,
        address _roleManager
    ) external initializer {
        __LeveragedStrategy_init(_assetToken, _name, _symbol, _collateralToken, _debtToken, _roleManager);
        __LeveragedSilo_init_unchained(_collateralToken, _debtToken, _siloLens, _siloMarket, _isProtected);
    }

    /// @notice Initializes Silo-specific state: resolves deposit/borrow silos and sets collateral type.
    /// @param _collateralToken Token supplied as collateral; determines which silo is the deposit silo.
    /// @param _debtToken Token borrowed; validated against the borrow silo's asset.
    /// @param _siloLens Address of the Silo lens contract.
    /// @param _siloMarket Address of the SiloConfig contract.
    /// @param _isProtected If true, use protected collateral type; otherwise use standard collateral.
    function __LeveragedSilo_init_unchained(
        address _collateralToken,
        address _debtToken,
        address _siloLens,
        address _siloMarket,
        bool _isProtected
    ) internal onlyInitializing {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();

        S.siloLens = ISiloLens(_siloLens);

        (address _silo0, address _silo1) = ISiloConfig(_siloMarket).getSilos();

        // Determine and set the deposit and borrow silos
        if (_collateralToken == ISilo(_silo0).asset()) {
            S.depositSilo = ISilo(_silo0);
            S.borrowSilo = ISilo(_silo1);
        } else if (_collateralToken == ISilo(_silo1).asset()) {
            S.depositSilo = ISilo(_silo1);
            S.borrowSilo = ISilo(_silo0);
        } else {
            revert LibError.InvalidMarket();
        }

        // Validate the debt token
        if (S.borrowSilo.asset() != _debtToken) revert LibError.InvalidMarket();

        if (_isProtected) {
            S.collateralType = ISilo.CollateralType.Protected;
        } else {
            S.collateralType = ISilo.CollateralType.Collateral;
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EXTERNAL FUNCTIONS: GETTERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the current Silo market configuration for this strategy.
    /// @return siloLens Address of the SiloLens contract.
    /// @return depositSilo Address of the silo used for collateral deposits.
    /// @return borrowSilo Address of the silo used for borrowing.
    /// @return collateralType Deposit collateral type: Protected or standard Collateral.
    function getMarketDetails()
        external
        view
        returns (address siloLens, address depositSilo, address borrowSilo, ISilo.CollateralType collateralType)
    {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        siloLens = address(S.siloLens);
        depositSilo = address(S.depositSilo);
        borrowSilo = address(S.borrowSilo);
        collateralType = S.collateralType;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               SILO MARKET CORE FUNCTIONS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposits collateral into the `depositSilo` using the configured collateral type.
    /// @param collateralAmount Amount of collateral token to deposit.
    function _depositCollateral(uint256 collateralAmount) internal override {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        COLLATERAL_TOKEN().forceApprove(address(S.depositSilo), collateralAmount);
        S.depositSilo.deposit(collateralAmount, address(this), S.collateralType);
    }

    /// @notice Withdraws collateral from the `depositSilo` to this contract.
    /// @param collateralAmount Amount of collateral token to withdraw.
    function _withdrawCollateral(uint256 collateralAmount) internal override {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        S.depositSilo.withdraw(collateralAmount, address(this), address(this), S.collateralType);
    }

    /// @notice Borrows debt tokens from the `borrowSilo`.
    /// @param borrowAmount Amount of debt token to borrow.
    function _borrowFromMarket(uint256 borrowAmount) internal override {
        _getLeveragedSiloStorage().borrowSilo.borrow(borrowAmount, address(this), address(this));
    }

    /// @notice Repays debt tokens to the `borrowSilo`.
    /// @param repayAmount Amount of debt token to repay.
    function _repayDebt(uint256 repayAmount) internal override {
        ISilo borrowSilo = _getLeveragedSiloStorage().borrowSilo;
        DEBT_TOKEN().forceApprove(address(borrowSilo), repayAmount);
        borrowSilo.repay(repayAmount, address(this));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               SILO MARKET INTERNAL FUNCTIONS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the strategy's current collateral balance in tokens via SiloLens.
    /// @return The collateral amount held in the deposit silo.
    function _getCollateralAmount() internal view override returns (uint256) {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        return S.siloLens.collateralBalanceOfUnderlying(S.depositSilo, address(this));
    }

    /// @notice Returns the strategy's current debt balance in tokens via SiloLens.
    /// @return The debt amount owed to the borrow silo.
    function _getDebtAmount() internal view override returns (uint256) {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        return S.siloLens.debtBalanceOfUnderlying(S.borrowSilo, address(this));
    }

    /// @notice Computes the current LTV of this strategy position in basis points.
    /// @dev Reads WAD-scaled LTV from SiloLens and converts to BPS (1e18 = 100% = 10000 BPS) with ceil rounding.
    /// @return ltvBps Current loan-to-value ratio in basis points.
    function _getStrategyLtv() internal view override returns (uint16 ltvBps) {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        // LTV for an address is returned by the borrow silo
        // `ltvWad` would need to exceed `6.5 * 1e18` (650% LTV) for this to overflow
        uint256 ltvWad = S.siloLens.getLtv(S.borrowSilo, address(this));
        ltvBps = (ltvWad.mulDiv(BPS_PRECISION, 1e18, Math.Rounding.Ceil)).toUint16();
    }

    /// @notice Returns the maximum allowed LTV for the deposit silo in WAD (1e18 = 100%).
    /// @return Maximum LTV in WAD precision.
    function _getMaxLtv() internal view returns (uint256) {
        LeveragedSiloStorage storage S = _getLeveragedSiloStorage();
        // Max LTV is configured for the DEPOSIT_SILO, it is 0 for BORROW_SILO
        return S.siloLens.getMaxLtv(S.depositSilo);
    }

    /// @notice Returns the maximum allowed LTV for this strategy in basis points.
    /// @dev Converts the WAD-scaled max LTV from SiloLens to BPS using floor rounding.
    /// @return maxLtvBps Maximum loan-to-value ratio in basis points.
    function _getStrategyMaxLtvBps() internal view override returns (uint16 maxLtvBps) {
        // Silo returns the MAX LTV in 18 decimals points. 1e18 = 100%
        // To convert it to BPS, ltv_bps = (maxLtv * BPS_PRECISION) / 1e18
        uint256 maxLtv = _getMaxLtv();
        maxLtvBps = maxLtv.mulDiv(BPS_PRECISION, 1e18, Math.Rounding.Floor).toUint16();
    }
}
