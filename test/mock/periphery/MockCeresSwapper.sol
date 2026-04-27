// SPDX-License-Identifier: BUSL
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ICeresSwapper} from "src/interfaces/periphery/ICeresSwapper.sol";

/// @title MockCeresSwapper
/// @notice Mock implementation of ICeresSwapper for testing purposes
/// @dev Simulates swaps with configurable exchange rates and slippage
contract MockCeresSwapper is ICeresSwapper {
    using SafeERC20 for IERC20;

    // Exchange rate: how many toTokens you get per fromToken (in 1e18 precision)
    mapping(address => mapping(address => uint256)) public exchangeRates;

    // Slippage percentage (in basis points, e.g., 50 = 0.5%)
    uint256 public slippageBps = 0;

    // If true, the next swap will revert
    bool public shouldRevert;

    // If true, the next swap will return less than minAmountOut
    bool public shouldFailSlippage;

    uint256 public constant BPS_PRECISION = 10000;
    uint256 public constant ORACLE_PRECISION = 1e18;

    event SwapExecuted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);

    /// @notice Set the exchange rate between two tokens
    /// @param fromToken Token to swap from
    /// @param toToken Token to swap to
    /// @param rate Exchange rate in 1e18 precision (e.g., 1e18 = 1:1)
    function setExchangeRate(address fromToken, address toToken, uint256 rate) external {
        exchangeRates[fromToken][toToken] = rate;
    }

    /// @notice Set slippage percentage
    /// @param bps Slippage in basis points (e.g., 50 = 0.5%)
    function setSlippage(uint256 bps) external {
        require(bps < BPS_PRECISION, "Slippage too high");
        slippageBps = bps;
    }

    /// @notice Set if the next swap should revert
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Set if the next swap should fail slippage check
    function setShouldFailSlippage(bool _shouldFail) external {
        shouldFailSlippage = _shouldFail;
    }

    function setSwapProvider(address fromToken, address toToken, SwapProvider calldata provider) external {
        // No-op for mock
    }

    /// @notice Swap exact amount of fromToken for at least minAmountOut of toToken
    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata /* extraData */
    ) external override returns (uint256 tokensReceived) {
        if (shouldRevert) {
            revert("MockSwapper: Forced revert");
        }

        require(amountIn > 0, "MockSwapper: Zero amount");
        require(exchangeRates[fromToken][toToken] > 0, "MockSwapper: No rate set");

        // Transfer tokens from sender
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        // Calculate output amount based on exchange rate and decimals of each tokne
        uint8 fromDecimals = IERC20Metadata(fromToken).decimals();
        uint8 toDecimals = IERC20Metadata(toToken).decimals();

        tokensReceived =
            (amountIn * exchangeRates[fromToken][toToken] * (10 ** toDecimals)) /
            (ORACLE_PRECISION * 10 ** fromDecimals);

        // Apply slippage
        if (slippageBps > 0 && !shouldFailSlippage) {
            tokensReceived = (tokensReceived * (BPS_PRECISION - slippageBps)) / BPS_PRECISION;
        } else if (shouldFailSlippage) {
            tokensReceived = minAmountOut - 1; // Force failure
        }

        require(tokensReceived >= minAmountOut, "MockSwapper: Insufficient output amount");

        // Transfer tokens to receiver
        IERC20(toToken).safeTransfer(receiver, tokensReceived);

        emit SwapExecuted(fromToken, toToken, amountIn, tokensReceived);
    }

    /// @notice Swap tokens to get exact amountOut of toToken using at most maxAmountIn of fromToken
    function swapTo(
        address fromToken,
        address toToken,
        uint256 maxAmountIn,
        uint256 amountOut,
        address receiver,
        bytes calldata /* extraData */
    ) external override returns (uint256 actualAmountIn) {
        if (shouldRevert) {
            revert("MockSwapper: Forced revert");
        }

        require(amountOut > 0, "MockSwapper: Zero amount");
        require(exchangeRates[fromToken][toToken] > 0, "MockSwapper: No rate set");

        // Calculate output amount based on exchange rate and decimals of each tokne
        uint8 fromDecimals = IERC20Metadata(fromToken).decimals();
        uint8 toDecimals = IERC20Metadata(toToken).decimals();

        actualAmountIn =
            (amountOut * ORACLE_PRECISION * (10 ** fromDecimals)) /
            (exchangeRates[fromToken][toToken] * (10 ** toDecimals));

        // Apply slippage (need more input tokens when there's slippage)
        if (slippageBps > 0 && !shouldFailSlippage) {
            actualAmountIn = (actualAmountIn * (BPS_PRECISION + slippageBps)) / BPS_PRECISION;
        } else if (shouldFailSlippage) {
            actualAmountIn = maxAmountIn + 1; // Force failure
        }

        require(actualAmountIn <= maxAmountIn, "MockSwapper: Insufficient input amount");

        // Transfer tokens from sender
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), actualAmountIn);

        // Transfer tokens to receiver
        IERC20(toToken).safeTransfer(receiver, amountOut);

        emit SwapExecuted(fromToken, toToken, actualAmountIn, amountOut);
    }

    /// @notice Fund the swapper with tokens for testing
    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function getTokenPairHash(address fromToken, address toToken) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(fromToken, toToken));
    }
}
