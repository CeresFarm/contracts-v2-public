// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IOracle as IMorphoOracle} from "morpho-blue/interfaces/IOracle.sol";

import {IOracleRoute} from "../../interfaces/periphery/IOracleRoute.sol";
import {LibError} from "../../libraries/LibError.sol";

/// @notice Morpho-specific wrapper adapting pair oracles into the unified IOracleRoute.
contract MorphoOracleRoute is IOracleRoute {
    using Math for uint256;

    uint256 internal constant MORPHO_ORACLE_PRECISION = 1e36;

    IMorphoOracle public immutable ORACLE;
    address public immutable COLLATERAL_TOKEN;
    address public immutable LOAN_TOKEN;

    /// @notice Deploys the route with the given Morpho pair oracle and the collateral/loan token addresses.
    /// @param _oracle Address of the Morpho oracle (implements `IOracle.price()`).
    /// @param _collateralToken Address of the collateral token in the Morpho market.
    /// @param _loanToken Address of the loan token in the Morpho market.
    constructor(address _oracle, address _collateralToken, address _loanToken) {
        if (_oracle == address(0) || _collateralToken == address(0) || _loanToken == address(0)) {
            revert LibError.ZeroAddress();
        }

        ORACLE = IMorphoOracle(_oracle);
        COLLATERAL_TOKEN = _collateralToken;
        LOAN_TOKEN = _loanToken;
    }

    /// @notice Fetches the Morpho oracle price and converts between collateral and loan tokens.
    /// @dev From IOracle interface documentation:
    /// ORACLE.price() corresponds to the price of 10**(collateral token decimals) assets of collateral token
    /// quoted in 10**(loan token decimals) assets of loan token with `36 + loan token decimals - collateral token decimals` decimals of precision.
    ///
    /// For example, if collateral is sUSDe and debt is USDC, and 1 sUSDe = 1.21 USDC
    /// then price() returns 1.21 * 1e36 * 10 ** DEBT_DECIMALS / 10 ** COLLATERAL_DECIMALS
    /// Example implementation: https://etherscan.io/address/0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87
    /// ORACLE.price() = 1212724452751377388000000
    ///
    /// Forward (collateral to loan): amountOut = amountIn * price / MORPHO_ORACLE_PRECISION
    /// Inverse (loan to collateral): amountOut = amountIn * MORPHO_ORACLE_PRECISION / price
    /// @inheritdoc IOracleRoute
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256) {
        // Forward quote: Collateral to Loan
        if (tokenIn == COLLATERAL_TOKEN && tokenOut == LOAN_TOKEN) {
            uint256 price = _fetchPrice();

            uint256 amountOut = amountIn.mulDiv(price, MORPHO_ORACLE_PRECISION);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Inverse quote: Loan to Collateral
        if (tokenIn == LOAN_TOKEN && tokenOut == COLLATERAL_TOKEN) {
            uint256 price = _fetchPrice();

            uint256 amountOut = amountIn.mulDiv(MORPHO_ORACLE_PRECISION, price);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        revert LibError.InvalidOracleRoute();
    }

    /// @dev Wraps `ORACLE.price()` in try/catch and converts any revert to `LibError.OracleError`
    function _fetchPrice() internal view returns (uint256) {
        try ORACLE.price() returns (uint256 price) {
            if (price == 0) revert LibError.InvalidPrice();
            return price;
        } catch {
            revert LibError.OracleError();
        }
    }
}
