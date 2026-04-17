// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEulerOracle} from "src/interfaces/euler/IEulerOracle.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

import {LibError} from "src/libraries/LibError.sol";

/// @title MockEulerOracle
/// @notice Minimal mock implementation of Euler Oracle for testing purposes
/// @dev Allows setting custom prices for token pairs and simulating oracle failures
contract MockEulerOracle is IEulerOracle {
    string public constant override name = "Mock Euler Oracle";
    
    /// @notice Precision used for price quotes (1e18)
    uint256 public constant ORACLE_PRECISION = 1e18;

    /// @notice Mapping to store prices: base token => quote token => price
    /// @dev Price represents how much quote token you get for 1 unit of base token (scaled by ORACLE_PRECISION)
    mapping(address => mapping(address => uint256)) public prices;
    
    /// @notice Flag to simulate oracle failures
    bool public shouldRevert;

    /// @notice Set the price for a token pair
    /// @param base The base token being priced
    /// @param quote The quote token (unit of account)
    /// @param price The price in quote token terms (scaled by base token decimals)
    function setPrice(address base, address quote, uint256 price) external {
        prices[base][quote] = price;
    }

    /// @notice Enable or disable oracle reversion for testing failure scenarios
    /// @param _shouldRevert Whether the oracle should revert
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Get a one-sided price quote
    /// @param inAmount The amount of base token to convert
    /// @param base The token being priced
    /// @param quote The token that is the unit of account
    /// @return outAmount The equivalent amount in quote token
    function getQuote(uint256 inAmount, address base, address quote) external view override returns (uint256 outAmount) {
        if (shouldRevert) revert LibError.OracleError();

        // If base and quote are the same, return the same amount
        if (base == quote) {
            return inAmount;
        }

        uint256 price = prices[base][quote];
        if (price == 0) revert LibError.InvalidPrice();

        // VIRTUAL_USD (0x0000000000000000000000000000000000000348) is a synthetic token
        // with no on-chain contract. Return it as an 18-decimal token.
        uint8 baseDecimals = base == address(840) ? 18 : ERC20(base).decimals();

        // Formula: outAmount = (inAmount * price) / (10 ** baseDecimals)
        // This gives us the quote amount for the given base amount
        outAmount = (inAmount * price) / (10 ** baseDecimals);
    }

    /// @notice Get a two-sided price quote (bid/ask spread)
    /// @dev For simplicity in testing, both bid and ask return the same price
    /// @param inAmount The amount of base token to convert
    /// @param base The token being priced
    /// @param quote The token that is the unit of account
    /// @return bidOutAmount The amount you would get for selling base
    /// @return askOutAmount The amount you would spend for buying base
    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        override
        returns (uint256 bidOutAmount, uint256 askOutAmount)
    {
        if (shouldRevert) revert LibError.OracleError();

        // If base and quote are the same, return the same amount for both
        if (base == quote) {
            return (inAmount, inAmount);
        }

        uint256 price = prices[base][quote];
        if (price == 0) revert LibError.InvalidPrice();

        uint8 baseDecimals = base == address(840) ? 18 : ERC20(base).decimals();

        // For testing purposes, we use the same price for both bid and ask
        uint256 outAmount = (inAmount * price) / (10 ** baseDecimals);
        bidOutAmount = outAmount;
        askOutAmount = outAmount;
    }
}
