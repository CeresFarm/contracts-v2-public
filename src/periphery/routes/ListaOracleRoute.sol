// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {IOracleRoute} from "../../interfaces/periphery/IOracleRoute.sol";
import {IListaOracle} from "../../interfaces/lista/IListaOracle.sol";
import {LibError} from "../../libraries/LibError.sol";

/// @notice Lista-specific oracle route adapting `IListaOracle` into the unified IOracleRoute.
/// @dev Lista oracle returns USD prices with 8 decimals via `peek(asset)`.
/// This route supports quoting between any two tokens priced by the same oracle,
/// as well as conversions to/from the router's VIRTUAL_USD (18 decimals).
contract ListaOracleRoute is IOracleRoute {
    using Math for uint256;

    IListaOracle public immutable ORACLE;

    /// @notice The standard virtual USD address used by the UniversalOracleRouter
    address public constant VIRTUAL_USD = address(840);

    /// @notice Used to scale Lista's 8-decimal USD feed to the router's 18-decimal VIRTUAL_USD requirement
    uint256 public constant VIRTUAL_USD_SCALER = 1e10;

    /// @notice Deploys the route with the given Lista price oracle.
    /// @param _oracle Address of the Lista oracle contract.
    constructor(address _oracle) {
        if (_oracle == address(0)) revert LibError.ZeroAddress();
        ORACLE = IListaOracle(_oracle);
    }

    /// @notice Converts `amount` of `base` token into `quote` token using Lista's USD price oracle.
    /// @dev Lista oracle `peek(asset)` returns the USD price of 1 whole token with 8 decimal precision.
    /// To convert between two tokens we route through USD:
    ///
    ///   outAmount = amount * basePrice * quoteUnit / (baseUnit * quotePrice)
    ///
    /// where baseUnit and quoteUnit are 10**decimals of the respective tokens, and basePrice /
    /// quotePrice are the raw 8-decimal USD prices from the oracle.
    ///
    /// Example: 1 WETH (1e18 atoms) -> USDC, ETH=$3000, USDC=$1:
    ///   1e18 * 3000e8 * 1e6 / (1e18 * 1e8) = 3000e6 (3000 USDC)
    function _quoteLista(
        uint256 amount,
        address base,
        address quote,
        uint256 baseUnit,
        uint256 quoteUnit
    ) internal view returns (uint256) {
        uint256 basePrice = _peek(base);
        uint256 quotePrice = _peek(quote);

        if (basePrice == 0 || quotePrice == 0) revert LibError.InvalidPrice();

        uint256 outAmount = amount.mulDiv(basePrice * quoteUnit, baseUnit * quotePrice);
        if (outAmount == 0) revert LibError.ZeroOutputAmount();

        return outAmount;
    }

    /// @inheritdoc IOracleRoute
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256) {
        if (amountIn == 0) return 0;

        // Scenario A: Token -> VIRTUAL_USD
        if (tokenOut == VIRTUAL_USD) {
            uint256 baseUnit = 10 ** IERC20Metadata(tokenIn).decimals();
            uint256 basePrice = _peek(tokenIn);
            if (basePrice == 0) revert LibError.InvalidPrice();

            uint256 amountOut = amountIn.mulDiv(basePrice * VIRTUAL_USD_SCALER, baseUnit);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Scenario B: VIRTUAL_USD -> Token
        if (tokenIn == VIRTUAL_USD) {
            uint256 quoteUnit = 10 ** IERC20Metadata(tokenOut).decimals();
            uint256 quotePrice = _peek(tokenOut);
            if (quotePrice == 0) revert LibError.InvalidPrice();

            uint256 amountOut = amountIn.mulDiv(quoteUnit, quotePrice * VIRTUAL_USD_SCALER);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Scenario C: Direct Token-to-Token via Lista's USD intermediary
        uint256 bUnit = 10 ** IERC20Metadata(tokenIn).decimals();
        uint256 qUnit = 10 ** IERC20Metadata(tokenOut).decimals();
        uint256 amtOut = _quoteLista(amountIn, tokenIn, tokenOut, bUnit, qUnit);
        if (amtOut == 0) revert LibError.ZeroOutputAmount();
        return amtOut;
    }

    function _peek(address asset) internal view returns (uint256) {
        try ORACLE.peek(asset) returns (uint256 price) {
            return price;
        } catch {
            revert LibError.OracleError();
        }
    }
}
