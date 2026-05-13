// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

import {LibError} from "../libraries/LibError.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {IMorpho, Id, Market, MarketParams, Position} from "morpho-blue/interfaces/IMorpho.sol";

import {LeveragedStrategy} from "./LeveragedStrategy.sol";

contract LeveragedMorpho is LeveragedStrategy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          STATE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.LeveragedMorpho
    // prettier-ignore
    struct LeveragedMorphoStorage {
        IMorpho morphoMarket;
        Id marketId;

        // Morpho market params includes the fields collateralToken, loanToken, oracle, irm, lltv.
        // As we already store collateralToken and loanToken in LeveragedStrategy, we can use existing fields
        // from LeveragedStrategy storage and only store oracle, irm, lltv in LeveragedMorphoStorage.
        // This approach saves 2 storage slots and avoids 2 cold SLOADs (4.2k gas) during runtime
        // Packing LLTV with IRM in a single slot saves a storage slot 
        address morphoOracle;
        address morphoIrm;
        uint96 morphoLltv;
    }

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedMorpho")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LEVERAGED_MORPHO_STORAGE_LOCATION =
        0xa9fd9e8f1dae938a896b7bee3848a739e7c4f05ef07b7f7fc43c459652bf3100;

    function _getLeveragedMorphoStorage() private pure returns (LeveragedMorphoStorage storage S) {
        assembly {
            S.slot := LEVERAGED_MORPHO_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Morpho Blue-backed leveraged strategy.
    /// @param _assetToken The deposit asset.
    /// @param _name ERC20 name for the vault share token.
    /// @param _symbol ERC20 symbol for the vault share token.
    /// @param _collateralToken The Morpho market collateral token.
    /// @param _debtToken The Morpho market loan token.
    /// @param _morphoMarket Address of the Morpho singleton contract.
    /// @param _oracle Address of the Morpho market oracle.
    /// @param _irm Address of the interest rate model.
    /// @param _lltv Liquidation LTV for the Morpho market (in 18 decimal precision).
    /// @param _roleManager Address of the RoleManager.
    function initialize(
        address _assetToken,
        string memory _name,
        string memory _symbol,
        address _collateralToken,
        address _debtToken,
        address _morphoMarket,
        address _oracle,
        address _irm,
        uint256 _lltv,
        address _roleManager
    ) external initializer {
        __LeveragedStrategy_init(_assetToken, _name, _symbol, _collateralToken, _debtToken, _roleManager);
        __LeveragedMorpho_init_unchained(_collateralToken, _debtToken, _morphoMarket, _oracle, _irm, _lltv);
    }

    function __LeveragedMorpho_init_unchained(
        address _collateralToken,
        address _debtToken,
        address _morphoMarket,
        address _oracle,
        address _irm,
        uint256 _lltv
    ) internal onlyInitializing {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();

        S.morphoMarket = IMorpho(_morphoMarket);

        S.morphoOracle = _oracle;
        S.morphoIrm = _irm;
        S.morphoLltv = _lltv.toUint96();

        S.marketId = MarketParams({
            collateralToken: _collateralToken,
            loanToken: _debtToken,
            oracle: _oracle,
            irm: _irm,
            lltv: _lltv
        }).id();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EXTERNAL FUNCTIONS: GETTERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the Morpho singleton address and the market parameters.
    function getMarketDetails() external view returns (address morphoMarket, MarketParams memory marketParams) {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();
        return (address(S.morphoMarket), MORPHO_MARKET_PARAMS());
    }

    /// @notice Returns the Morpho market parameters struct used for all market interactions.
    function MORPHO_MARKET_PARAMS() public view returns (MarketParams memory) {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();
        return
            MarketParams({
                collateralToken: address(COLLATERAL_TOKEN()),
                loanToken: address(DEBT_TOKEN()),
                oracle: S.morphoOracle,
                irm: S.morphoIrm,
                lltv: uint256(S.morphoLltv)
            });
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             MORPHO MARKET CORE FUNCTIONS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Supplies collateral to the Morpho market.
    /// @param collateralAmount Amount of collateral to supply.
    function _depositCollateral(uint256 collateralAmount) internal override {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();
        IMorpho morphoMarket = S.morphoMarket;
        COLLATERAL_TOKEN().forceApprove(address(morphoMarket), collateralAmount);
        morphoMarket.supplyCollateral(MORPHO_MARKET_PARAMS(), collateralAmount, address(this), "");
    }

    /// @dev Withdraws collateral from the Morpho market.
    /// @param collateralAmount Amount of collateral to withdraw.
    function _withdrawCollateral(uint256 collateralAmount) internal override {
        IMorpho morphoMarket = _getLeveragedMorphoStorage().morphoMarket;
        morphoMarket.withdrawCollateral(MORPHO_MARKET_PARAMS(), collateralAmount, address(this), address(this));
    }

    /// @dev Borrows debt token from the Morpho market.
    /// @param borrowAmount Amount of debt to borrow.
    function _borrowFromMarket(uint256 borrowAmount) internal override {
        IMorpho morphoMarket = _getLeveragedMorphoStorage().morphoMarket;
        morphoMarket.borrow(MORPHO_MARKET_PARAMS(), borrowAmount, 0, address(this), address(this));
    }

    /// @dev Repays debt token to the Morpho market.
    /// @param repayAmount Amount of debt to repay.
    function _repayDebt(uint256 repayAmount) internal override {
        IMorpho morphoMarket = _getLeveragedMorphoStorage().morphoMarket;
        DEBT_TOKEN().forceApprove(address(morphoMarket), repayAmount);
        morphoMarket.repay(MORPHO_MARKET_PARAMS(), repayAmount, 0, address(this), "");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             MORPHO MARKET INTERNAL FUNCTIONS                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Returns the collateral balance from the strategy's Morpho position.
    function _getCollateralAmount() internal view override returns (uint256) {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();
        return S.morphoMarket.position(S.marketId, address(this)).collateral;
    }

    /// @dev Returns the debt amount from the strategy's Morpho position.
    function _getDebtAmount() internal view override returns (uint256) {
        LeveragedMorphoStorage storage S = _getLeveragedMorphoStorage();
        Id marketId = S.marketId;

        Position memory userPosition = S.morphoMarket.position(marketId, address(this));
        if (userPosition.borrowShares == 0) return 0;

        Market memory market = S.morphoMarket.market(marketId);
        return uint256(userPosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    }

    /// @dev Computes the LTV as debt / (collateral converted to debt units), rounding up.
    function _getStrategyLtv() internal view override returns (uint16 ltvBps) {
        uint256 debt = _getDebtAmount();
        if (debt == 0) return 0;

        uint256 collateral = _getCollateralAmount();
        if (collateral == 0) return 0;

        uint256 collateralInDebtToken = oracleAdapter().convertCollateralToDebt(collateral);

        // Round-up the strategy LTV to be on the conservative side
        ltvBps = (debt.mulDiv(BPS_PRECISION, collateralInDebtToken, Math.Rounding.Ceil)).toUint16();
    }

    /// @dev Returns the Morpho market LLTV (liquidation LTV in 18 decimal precision).
    function _getMaxLtv() internal view returns (uint256) {
        // maxLTV and Liquidation LTV are the same in Morpho
        return _getLeveragedMorphoStorage().morphoLltv;
    }

    /// @dev Converts 18-decimal Morpho LLTV to basis points.
    function _getStrategyMaxLtvBps() internal view override returns (uint16 maxLtvBps) {
        // Morpho returns the MAX LTV in 18 decimals points. 1e18 = 100%
        // To convert it to BPS, ltv_bps = (maxLtv * BPS_PRECISION) / 1e18
        uint256 maxLtv = _getMaxLtv();
        maxLtvBps = maxLtv.mulDiv(BPS_PRECISION, 1e18, Math.Rounding.Floor).toUint16();
    }
}
