// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ISiloOracle} from "../../interfaces/silo/ISiloOracle.sol";
import {IOracleRoute} from "../../interfaces/periphery/IOracleRoute.sol";
import {LibError} from "../../libraries/LibError.sol";

/// @notice Silo-specific wrapper adapting Silo oracles into the unified IOracleRoute.
/// @dev A Silo oracle handles conversion from any supported `baseToken` to the `quoteToken`.
/// The quoted amount is ALWAYS returned with 18 decimals of precision, regardless of the `quoteToken`s actual decimals.
contract SiloOracleRoute is IOracleRoute {
    using Math for uint256;

    ISiloOracle public immutable ORACLE;
    address public immutable BASE_TOKEN;
    address public immutable QUOTE_TOKEN;
    uint256 public immutable BASE_UNIT;
    uint256 public immutable QUOTE_UNIT;

    uint256 internal constant SILO_ORACLE_PRECISION = 1e18;

    /// @notice Deploys the route with the given Silo oracle and the base/quote token pair.
    /// @param _oracle Address of the Silo oracle.
    /// @param _baseToken Address of the base token (collateral side).
    /// @param _quoteToken Address of the quote token (debt side).
    constructor(address _oracle, address _baseToken, address _quoteToken) {
        if (_oracle == address(0)) revert LibError.ZeroAddress();

        ORACLE = ISiloOracle(_oracle);
        BASE_TOKEN = _baseToken;
        QUOTE_TOKEN = _quoteToken;
        BASE_UNIT = 10 ** IERC20Metadata(_baseToken).decimals();
        QUOTE_UNIT = 10 ** IERC20Metadata(_quoteToken).decimals();
    }

    /// @notice Returns the Silo oracle quote for `amount` of `baseToken`.
    /// @dev The Silo oracle always returns with 18 decimal precision regardless of quoteToken decimals.
    /// @param amount Amount of `baseToken` to quote.
    /// @param baseToken The token being priced.
    /// @return The priced amount in 18-decimal precision.
    function _quoteSilo(uint256 amount, address baseToken) internal view returns (uint256) {
        try ORACLE.quote(amount, baseToken) returns (uint256 outAmount) {
            if (outAmount == 0) revert LibError.ZeroOutputAmount();
            return outAmount;
        } catch {
            revert LibError.OracleError();
        }
    }

    /// @inheritdoc IOracleRoute
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256) {
        if (amountIn == 0) return 0;

        // Forward Quote: BASE_TOKEN -> QUOTE_TOKEN
        if (tokenIn == BASE_TOKEN && tokenOut == QUOTE_TOKEN) {
            // Silo oracle returns price in 18 decimals. We scale it to QUOTE_UNIT.
            uint256 quoteAmount = _quoteSilo(amountIn, BASE_TOKEN);
            uint256 amountOut = quoteAmount.mulDiv(QUOTE_UNIT, SILO_ORACLE_PRECISION);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Inverse Quote: QUOTE_TOKEN -> BASE_TOKEN
        if (tokenIn == QUOTE_TOKEN && tokenOut == BASE_TOKEN) {
            // Get the value of 1 whole target token (BASE_TOKEN) in terms of 18 decimal precision
            uint256 priceOfOneBase = _quoteSilo(BASE_UNIT, BASE_TOKEN);

            // Invert the price securely while maintaining maximum precision.
            // Since the Silo oracle always returns with 18 decimal precision, priceOfOneBase
            // is always large enough to avoid truncation, even for 6-decimal tokens.

            // Mathematical break-down:
            // amountOut = amountIn * BASE_UNIT / truePriceInQuoteDecimals
            // truePriceInQuoteDecimals = (priceOfOneBase * QUOTE_UNIT) / 1e18
            // Combined: amountOut = (amountIn * BASE_UNIT * 1e18) / (priceOfOneBase * QUOTE_UNIT)
            //
            // Example: Converting 1500 USDC -> WETH. WETH price = $3000.
            // amountIn = 1500 * 1e6 (1500 USDC)
            // priceOfOneBase = 3000 * 1e18 (Silo always returns 18 decimals)
            // BASE_UNIT = 1e18 (WETH)
            // QUOTE_UNIT = 1e6 (USDC)
            //
            // (1500 * 1e6 * 1e18 * 1e18) / (3000 * 1e18 * 1e6) = 0.5 * 1e18 (0.5 WETH)
            uint256 amountOut = amountIn.mulDiv(BASE_UNIT * SILO_ORACLE_PRECISION, priceOfOneBase * QUOTE_UNIT);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        revert LibError.InvalidOracleRoute();
    }
}
