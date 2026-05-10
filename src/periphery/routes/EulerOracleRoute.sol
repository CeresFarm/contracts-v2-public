// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {IEulerOracle} from "../../interfaces/euler/IEulerOracle.sol";
import {IOracleRoute} from "../../interfaces/periphery/IOracleRoute.sol";
import {LibError} from "../../libraries/LibError.sol";

/// @notice Euler-specific wrapper adapting the Euler Oracle to the unified IOracleRoute.
contract EulerOracleRoute is IOracleRoute {
    IEulerOracle public immutable ORACLE;

    /// @notice The standard virtual USD address used by the UniversalOracleRouter
    /// Euler uses the exact same address (0x348 in hex) to represent synthetic USD,
    /// which is the official ISO 4217 numeric currency code for the US Dollar (USD)
    address public constant VIRTUAL_USD = address(840);

    /// @notice Deploys the route with the given Euler oracle.
    /// @param _oracle Address of the Euler oracle contract.
    constructor(address _oracle) {
        if (_oracle == address(0)) revert LibError.ZeroAddress();
        ORACLE = IEulerOracle(_oracle);
    }

    /// @notice Returns the amount of `quote` equivalent to `amount` of `base` using the Euler oracle.
    /// @param amount Amount of `base` token (in its native decimals).
    /// @param base Source token address.
    /// @param quote Target token address.
    /// @return The equivalent amount in `quote` token decimals.
    function _quoteEuler(uint256 amount, address base, address quote) internal view returns (uint256) {
        try ORACLE.getQuote(amount, base, quote) returns (uint256 outAmount) {
            if (outAmount == 0) revert LibError.ZeroOutputAmount();
            return outAmount;
        } catch {
            revert LibError.OracleError();
        }
    }

    /// @inheritdoc IOracleRoute
    function getQuote(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256) {
        if (amountIn == 0) return 0;

        // Euler handles all decimal normalization internally based on the token addresses passed.
        uint256 amountOut = _quoteEuler(amountIn, tokenIn, tokenOut);
        if (amountOut == 0) revert LibError.ZeroOutputAmount();
        return amountOut;
    }
}
