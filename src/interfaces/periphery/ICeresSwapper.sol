// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICeresSwapper {
    /// @notice Supported aggregator / router back-ends a token pair can be routed through.
    enum SwapType {
        KYBERSWAP_AGGREGATOR,
        PARASWAP_AGGREGATOR,
        PENDLE_ROUTER
    }

    /// @notice Per-pair routing configuration.
    /// @param swapType The aggregator family that handles this pair.
    /// @param router The aggregator router address invoked at swap time.
    struct SwapProvider {
        SwapType swapType;
        address router;
    }

    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata extraData
    ) external returns (uint256 tokensReceived);

    function swapTo(
        address fromToken,
        address toToken,
        uint256 maxAmountIn,
        uint256 amountOut,
        address receiver,
        bytes calldata extraData
    ) external returns (uint256 actualAmountIn);

    function setSwapProvider(address fromToken, address toToken, SwapProvider calldata provider) external;

    function getTokenPairHash(address fromToken, address toToken) external pure returns (bytes32);
}
