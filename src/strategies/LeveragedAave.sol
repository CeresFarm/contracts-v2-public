// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {LibError} from "../libraries/LibError.sol";
import {IPoolAddressesProvider} from "../interfaces/aave/IPoolAddressesProvider.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {DataTypes} from "../interfaces/aave/DataTypes.sol";

import {LeveragedStrategy} from "./LeveragedStrategy.sol";

contract LeveragedAave is LeveragedStrategy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    uint16 internal constant REFERRAL_CODE = 0;
    uint256 internal constant INTEREST_RATE_MODE = 2; // Variable

    event StrategyEModeUpdated(uint8 categoryId);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          STATE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.LeveragedAave
    struct LeveragedAaveStorage {
        IPool aavePool;
        IERC20 aToken;
        IERC20 variableDebtToken;
    }

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedAave")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LEVERAGED_AAVE_STORAGE_LOCATION =
        0x16fe70a3b45d16bac8a7d7f7b6f25abbb858baa31b7fa49f55d83c3aa013cb00;

    function _getLeveragedAaveStorage() private pure returns (LeveragedAaveStorage storage S) {
        assembly {
            S.slot := LEVERAGED_AAVE_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Aave-backed leveraged strategy.
    /// @param _assetToken The deposit asset.
    /// @param _name ERC20 name for the vault share token.
    /// @param _symbol ERC20 symbol for the vault share token.
    /// @param _collateralToken The Aave collateral token.
    /// @param _debtToken The Aave borrow token.
    /// @param _aavePoolAddressesProvider Aave PoolAddressesProvider address.
    /// @param _roleManager Address of the RoleManager.
    function initialize(
        address _assetToken,
        string memory _name,
        string memory _symbol,
        address _collateralToken,
        address _debtToken,
        address _aavePoolAddressesProvider,
        address _roleManager
    ) external initializer {
        __LeveragedStrategy_init(_assetToken, _name, _symbol, _collateralToken, _debtToken, _roleManager);
        __LeveragedAave_init_unchained(_collateralToken, _debtToken, _aavePoolAddressesProvider);
    }

    /// @notice Initializes the Aave strategy with pool configuration and token details.
    /// @param _collateralToken The collateral token address held in the Aave pool.
    /// @param _debtToken The debt token borrowed from the Aave pool.
    /// @param _aavePoolAddressesProvider Address of the Aave PoolAddressesProvider contract.
    function __LeveragedAave_init_unchained(
        address _collateralToken,
        address _debtToken,
        address _aavePoolAddressesProvider
    ) internal onlyInitializing {
        LeveragedAaveStorage storage S = _getLeveragedAaveStorage();
        IPoolAddressesProvider aavePoolAddressesProvider = IPoolAddressesProvider(_aavePoolAddressesProvider);

        S.aavePool = IPool(aavePoolAddressesProvider.getPool());

        // Store aTokenAddress and variableDebtTokenAddress for internal function calls
        S.aToken = IERC20(S.aavePool.getReserveData(_collateralToken).aTokenAddress);
        S.variableDebtToken = IERC20(S.aavePool.getReserveData(_debtToken).variableDebtTokenAddress);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EXTERNAL FUNCTIONS: GETTERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the Aave pool addresses provider and pool addresses used by the strategy.
    /// @return aavePool Address of the Aave Pool contract.
    function getMarketDetails() external view returns (address aavePool) {
        aavePool = address(_getLeveragedAaveStorage().aavePool);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      ADMIN FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Activates or changes the Aave eMode category for this strategy.
    /// @dev eMode enables higher LTVs for correlated asset pairs (e.g. stablecoins).
    /// @param categoryId The Aave eMode category ID (0 = disabled).
    function setAaveEMode(uint8 categoryId) external nonReentrant onlyRole(MANAGEMENT_ROLE) {
        LeveragedAaveStorage storage S = _getLeveragedAaveStorage();
        S.aavePool.setUserEMode(categoryId);

        emit StrategyEModeUpdated(categoryId);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              AAVE MARKET CORE FUNCTIONS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Supplies collateral to the Aave pool.
    /// @param collateralAmount Amount of collateral to supply.
    function _depositCollateral(uint256 collateralAmount) internal override {
        // Cache state variables
        IPool pool = _getLeveragedAaveStorage().aavePool;
        IERC20 collateralToken = COLLATERAL_TOKEN();

        collateralToken.forceApprove(address(pool), collateralAmount);
        pool.supply(address(collateralToken), collateralAmount, address(this), REFERRAL_CODE);
    }

    /// @dev Withdraws collateral from the Aave pool.
    /// @param collateralAmount Amount of collateral to withdraw.
    function _withdrawCollateral(uint256 collateralAmount) internal override {
        IPool pool = _getLeveragedAaveStorage().aavePool;
        IERC20 collateralToken = COLLATERAL_TOKEN();

        pool.withdraw(address(collateralToken), collateralAmount, address(this));
    }

    /// @dev Borrows debt token from the Aave pool at variable rate.
    /// @param borrowAmount Amount of debt token to borrow.
    function _borrowFromMarket(uint256 borrowAmount) internal override {
        IPool pool = _getLeveragedAaveStorage().aavePool;
        IERC20 debtToken = DEBT_TOKEN();

        pool.borrow(address(debtToken), borrowAmount, INTEREST_RATE_MODE, REFERRAL_CODE, address(this));
    }

    /// @dev Repays debt token to the Aave pool.
    /// @param repayAmount Amount of debt token to repay.
    function _repayDebt(uint256 repayAmount) internal override {
        IPool pool = _getLeveragedAaveStorage().aavePool;
        IERC20 debtToken = DEBT_TOKEN();

        debtToken.forceApprove(address(pool), repayAmount);
        pool.repay(address(debtToken), repayAmount, INTEREST_RATE_MODE, address(this));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              AAVE MARKET INTERNAL FUNCTIONS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Returns the collateral balance via the aToken balance (aToken is 1:1 with collateral).
    function _getCollateralAmount() internal view override returns (uint256) {
        IERC20 aToken = _getLeveragedAaveStorage().aToken;
        return aToken.balanceOf(address(this));
    }

    /// @dev Returns the outstanding debt via the variable debt token balance.
    function _getDebtAmount() internal view override returns (uint256) {
        IERC20 variableDebtToken = _getLeveragedAaveStorage().variableDebtToken;
        return variableDebtToken.balanceOf(address(this));
    }

    /// @dev Returns the LTV calculated from Aave's USD-denominated account data, rounding up.
    function _getStrategyLtv() internal view override returns (uint16 ltvBps) {
        (uint256 totalCollateralBase, uint256 totalDebtBase, , , , ) = _getLeveragedAaveStorage()
            .aavePool
            .getUserAccountData(address(this));
        if (totalCollateralBase == 0) return 0;

        // Round-up the strategy LTV to be on the conservative side
        ltvBps = (totalDebtBase.mulDiv(BPS_PRECISION, totalCollateralBase, Math.Rounding.Ceil)).toUint16();
    }

    /// @dev Returns the max LTV for this strategy in basis points.
    /// Uses the active eMode LTV when eMode is enabled, otherwise falls back to the reserve config LTV.
    function _getMaxLtv() internal view returns (uint256) {
        IPool aavePool = _getLeveragedAaveStorage().aavePool;

        // Check if the strategy has an active eMode
        uint256 eModeId = aavePool.getUserEMode(address(this));

        if (eModeId != 0) {
            // eMode is active, use eMode category LTV
            DataTypes.EModeCategoryLegacy memory eModeData = aavePool.getEModeCategoryData(uint8(eModeId));
            return eModeData.ltv; // already in bps, e.g. 9300 = 93%
        }

        // Disabled, fall back to reserve config LTV
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(COLLATERAL_TOKEN()));
        return config.data & 0xFFFF;
    }

    /// @dev Returns the market max LTV in basis points.
    function _getStrategyMaxLtvBps() internal view override returns (uint16 maxLtvBps) {
        maxLtvBps = _getMaxLtv().toUint16();
    }
}
