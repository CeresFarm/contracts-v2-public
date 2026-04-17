// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICeresSwapper {
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

    function getTokenPairHash(address fromToken, address toToken) external pure returns (bytes32);
}
