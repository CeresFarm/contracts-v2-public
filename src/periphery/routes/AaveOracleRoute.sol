// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAaveOracle} from "../../interfaces/aave/IAaveOracle.sol";
import {IOracleRoute} from "../../interfaces/periphery/IOracleRoute.sol";
import {LibError} from "../../libraries/LibError.sol";

/// @notice Aave-specific wrapper adapting the Aave USD-based oracle into the unified IOracleRoute.
/// @dev Aave provides prices exclusively denominated in USD (with 8 decimals).
/// This adapter cleanly interfaces standard tokens and the router's VIRTUAL_USD standard.
contract AaveOracleRoute is IOracleRoute {
    using Math for uint256;

    IAaveOracle public immutable ORACLE;

    /// @notice The standard virtual USD address used by the UniversalOracleRouter
    address public constant VIRTUAL_USD = address(840);

    /// @notice Used to scale Aave's 8-decimal USD feed to the router's 18-decimal VIRTUAL_USD requirement
    uint256 public constant VIRTUAL_USD_SCALER = 1e10;

    /// @notice Deploys the route with the given Aave price oracle.
    /// @param _oracle Address of the Aave oracle contract.
    constructor(address _oracle) {
        if (_oracle == address(0)) revert LibError.ZeroAddress();
        ORACLE = IAaveOracle(_oracle);
    }

    /// @notice Converts `amount` of `base` token into `quote` token using Aave's USD price oracle.
    /// @dev AaveOracle.getAssetPrice returns the USD price of 1 whole token with 8 decimal precision
    /// (BASE_CURRENCY_UNIT = 1e8). To convert between two tokens we route through USD:
    ///
    ///   outAmount = amount * basePrice * quoteUnit / (baseUnit * quotePrice)
    ///
    /// where baseUnit and quoteUnit are 10**decimals of the respective tokens, and basePrice /
    /// quotePrice are the raw 8-decimal USD prices from the oracle.
    ///
    /// Example: 1 WETH (1e18 atoms) -> USDC, ETH=$3000, USDC=$1:
    ///   1e18 * 3000e8 * 1e6 / (1e18 * 1e8) = 3000e6 (3000 USDC)
    function _quoteAave(
        uint256 amount,
        address base,
        address quote,
        uint256 baseUnit,
        uint256 quoteUnit
    ) internal view returns (uint256) {
        uint256 basePrice = 0;
        uint256 quotePrice = 0;

        try ORACLE.getAssetPrice(base) returns (uint256 price) {
            basePrice = price;
        } catch {
            revert LibError.OracleError();
        }

        try ORACLE.getAssetPrice(quote) returns (uint256 price) {
            quotePrice = price;
        } catch {
            revert LibError.OracleError();
        }

        if (basePrice == 0 || quotePrice == 0) revert LibError.InvalidPrice();

        uint256 outAmount = amount.mulDiv(basePrice * quoteUnit, baseUnit * quotePrice);
        if (outAmount == 0) revert LibError.ZeroOutputAmount();

        return outAmount;
    }

    /// @inheritdoc IOracleRoute
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view override returns (uint256) {
        if (amountIn == 0) return 0;

        // Scenario A: Converting from a Token to VIRTUAL_USD
        if (tokenOut == VIRTUAL_USD) {
            uint256 baseUnit = 10 ** IERC20Metadata(tokenIn).decimals();
            uint256 basePrice = 0;
            try ORACLE.getAssetPrice(tokenIn) returns (uint256 price) {
                basePrice = price;
            } catch {
                revert LibError.OracleError();
            }
            if (basePrice == 0) revert LibError.InvalidPrice();

            // amountIn * basePrice / baseUnit gives the 8-decimal USD value for amountIn.
            // Multiply by VIRTUAL_USD_SCALER to get the router's 18-decimal VIRTUAL_USD value of amountIn.
            // For example, if tokenIn is WETH with 18 decimals and a price of $2000, then:
            // amountIn = 2 * 1e18 (2 WETH)
            // basePrice = 2000 * 1e8
            // baseUnit = 1e18
            // amountIn * basePrice / baseUnit = 2 * 1e18 * 2000 * 1e8 / 1e18 = 4000 * 1e8 (4000 USD with 8 decimals)
            // Scaling up to VIRTUAL_USD: 4000 * 1e8 * 1e10 = 4000 * 1e18 (4000 VIRTUAL_USD with 18 decimals)
            uint256 amountOut = amountIn.mulDiv(basePrice * VIRTUAL_USD_SCALER, baseUnit);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Scenario B: Converting from VIRTUAL_USD to a Token
        if (tokenIn == VIRTUAL_USD) {
            uint256 quoteUnit = 10 ** IERC20Metadata(tokenOut).decimals();
            uint256 quotePrice = 0;
            try ORACLE.getAssetPrice(tokenOut) returns (uint256 price) {
                quotePrice = price;
            } catch {
                revert LibError.OracleError();
            }
            if (quotePrice == 0) revert LibError.InvalidPrice();

            // Divide 18-decimal VIRTUAL_USD by the 8-decimal USD price
            // For example, if tokenOut is USDC with a price of $1, then:
            // amountIn = 4000 * 1e18 (4000 VIRTUAL_USD with 18 decimals)
            // quoteUnit = 1e6 (USDC has 6 decimals)
            // quotePrice = 1e8
            // amountIn * quoteUnit / (quotePrice * VIRTUAL_USD_SCALER) = 4000 * 1e18 * 1e6 / (1e8 * 1e10) = 4000 * 1e6 (4000 USDC with 6 decimals)
            uint256 amountOut = amountIn.mulDiv(quoteUnit, quotePrice * VIRTUAL_USD_SCALER);
            if (amountOut == 0) revert LibError.ZeroOutputAmount();
            return amountOut;
        }

        // Scenario C: Direct Token-to-Token via Aave's USD intermediary
        uint256 bUnit = 10 ** IERC20Metadata(tokenIn).decimals();
        uint256 qUnit = 10 ** IERC20Metadata(tokenOut).decimals();
        uint256 amtOut = _quoteAave(amountIn, tokenIn, tokenOut, bUnit, qUnit);
        if (amtOut == 0) revert LibError.ZeroOutputAmount();
        return amtOut;
    }
}
