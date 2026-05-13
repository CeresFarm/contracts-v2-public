// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPendleRouter
/// @notice Minimal interface for Pendle Router V4 swap functions used by CeresSwapper.
/// @dev Source: https://github.com/pendle-finance/pendle-core-v2-public
interface IPendleRouter {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           ENUMS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    enum SwapType {
        NONE,
        ETH_WETH,
        AGGREGATOR
    }

    enum OrderType {
        SY_FOR_PT,
        PT_FOR_SY,
        SY_FOR_YT,
        YT_FOR_SY
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STRUCTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Used in TokenInput/TokenOutput to describe the aggregator hop
    ///      (e.g. USDC -> SY or SY -> USDC).
    ///      `needScale` = true tells the Pendle router to proportionally rescale the
    ///      aggregator calldata at execution time based on the ACTUAL SY amount in/out,
    ///      NOTE: needScale only affects this inner aggregator step, it does NOT rescale
    ///      the outer `exactPtIn` / `netTokenIn` amounts. The swapData should be obtained by
    ///      requesting the Pendle API with `needScale=true` to ensure the tx goes through
    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn; // how many `tokenIn` the router pulls from caller
        address tokenMintSy;
        // Aggregator data
        address pendleSwap;
        SwapData swapData;
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        // Aggregator data
        address pendleSwap;
        SwapData swapData;
    }

    /// @dev Offchain-computed guesses to help the router's binary search
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        OrderType orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    struct FillOrderParams {
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        FUNCTIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Buy PT tokens using an input token (for example, USDC -> PT).
    /// The router pulls exactly `input.netTokenIn` of `input.tokenIn` from the caller.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Sell PT tokens for an output token (for example, PT -> USDC).
    /// The router pulls exactly `exactPtIn` PT from the caller.
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}
