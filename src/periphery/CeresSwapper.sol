// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {LibError} from "../libraries/LibError.sol";
import {ICeresSwapper} from "../interfaces/periphery/ICeresSwapper.sol";

import {IScaleHelper} from "../interfaces/kyberswap/IScaleHelper.sol";

import {IParaSwapAugustus} from "../interfaces/paraswap/IParaSwapAugustus.sol";
import {IParaSwapAugustusRegistry} from "../interfaces/paraswap/IParaSwapAugustusRegistry.sol";
import {IPendleRouter} from "../interfaces/pendle/IPendleRouter.sol";

contract CeresSwapper is ReentrancyGuardTransient, ICeresSwapper {
    using SafeERC20 for IERC20;

    enum SwapType {
        KYBERSWAP_AGGREGATOR,
        PARASWAP_AGGREGATOR,
        PENDLE_ROUTER
    }

    struct SwapProvider {
        SwapType swapType;
        address router;
    }

    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant VAULT_OR_STRATEGY = keccak256("VAULT_OR_STRATEGY");
    IAccessControlDefaultAdminRules public immutable ROLE_MANAGER;

    // tokenPairHash is a keccack256 hash of fromToken and toToken
    mapping(bytes32 tokenPairHash => SwapProvider) public swapProvider;

    IScaleHelper public immutable KYBERSWAP_SCALE_HELPER;
    IParaSwapAugustusRegistry public immutable AUGUSTUS_REGISTRY;

    event SwapExecuted(
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 amountOut,
        address indexed receiver
    );

    event SwapProviderSet(address indexed tokenIn, address indexed tokenOut, SwapProvider provider);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        MODIFIERS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    modifier onlyRole(bytes32 role) {
        _validateRole(role, msg.sender);
        _;
    }

    /// @dev Reverts if the account does not hold the required role.
    /// @param role The role identifier to check.
    /// @param account The account to validate.
    function _validateRole(bytes32 role, address account) internal view {
        if (!ROLE_MANAGER.hasRole(role, account)) revert LibError.Unauthorized();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the swapper with role manager and swap provider integrations.
    /// @param _roleManager Address of the RoleManager for access control.
    /// @param _kyberScaleHelper Address of the KyberSwap ScaleHelper contract.
    /// @param _augustusRegistry Address of the ParaSwap AugustusRegistry.
    constructor(address _roleManager, address _kyberScaleHelper, address _augustusRegistry) {
        if (_roleManager == address(0)) revert LibError.ZeroAddress();
        ROLE_MANAGER = IAccessControlDefaultAdminRules(_roleManager);

        KYBERSWAP_SCALE_HELPER = IScaleHelper(_kyberScaleHelper);

        if (IParaSwapAugustusRegistry(_augustusRegistry).isValidAugustus(address(0))) revert LibError.InvalidAddress();

        AUGUSTUS_REGISTRY = IParaSwapAugustusRegistry(_augustusRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                        External/Public Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Swaps `fromToken` to `toToken` using a configured swap provider.
    /// @param fromToken The address of the token to swap from.
    /// @param toToken The address of the token to swap to.
    /// @param amountIn The amount of `fromToken` to swap.
    /// @param minAmountOut The minimum amount of `toToken` expected after the swap.
    /// @param receiver The address to send the received tokens to.
    /// @param swapData Bytes data for executing the swap
    /// @return tokensReceived The amount of `toToken` received after the swap.
    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata swapData
    ) external onlyRole(VAULT_OR_STRATEGY) nonReentrant returns (uint256 tokensReceived) {
        if (amountIn == 0) return 0;

        // Determine the swap provider and router for the swap
        bytes32 tokenPairHash = getTokenPairHash(fromToken, toToken);
        SwapProvider memory provider = swapProvider[tokenPairHash];
        if (provider.router == address(0)) revert LibError.InvalidSwapConfig();

        // Used to calculate the amount of tokens received after the swap
        uint256 balanceBefore = IERC20(toToken).balanceOf(address(this));
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        if (provider.swapType == SwapType.KYBERSWAP_AGGREGATOR) {
            _kyberswapAggregatorExactIn(provider.router, fromToken, amountIn, swapData);
        } else if (provider.swapType == SwapType.PARASWAP_AGGREGATOR) {
            uint256 fromAmountOffset = _calculateParaswapAmountOffset(bytes4(swapData[:4]));
            _paraswapAggregatorExactIn(provider.router, fromToken, amountIn, fromAmountOffset, swapData);
        } else if (provider.swapType == SwapType.PENDLE_ROUTER) {
            _pendleRouterSwap(provider.router, fromToken, amountIn, swapData);
        } else {
            revert LibError.NotImplemented();
        }

        tokensReceived = IERC20(toToken).balanceOf(address(this)) - balanceBefore;
        if (tokensReceived < minAmountOut) revert LibError.SlippageLimitExceeded(tokensReceived, minAmountOut);

        IERC20(toToken).safeTransfer(receiver, tokensReceived);
        emit SwapExecuted(fromToken, toToken, amountIn, tokensReceived, receiver);
    }

    /// @notice Swaps tokens to receive an exact amount of output tokens (exact output swap).
    /// It transfers the maximum input amount from the caller, executes the swap, and refunds any unused input tokens.
    /// @param fromToken The address of the input token to swap from
    /// @param toToken The address of the output token to swap to
    /// @param maxAmountIn The maximum amount of input tokens willing to spend
    /// @param amountOut The exact amount of output tokens desired
    /// @param receiver The address that will receive the output tokens
    /// @param swapData Bytes data for executing the swap
    /// @return actualAmountIn The actual amount of input tokens used for the swap (may be less than maxAmountIn)
    function swapTo(
        address fromToken,
        address toToken,
        uint256 maxAmountIn,
        uint256 amountOut,
        address receiver,
        bytes calldata swapData
    ) external onlyRole(VAULT_OR_STRATEGY) nonReentrant returns (uint256 actualAmountIn) {
        if (amountOut == 0 || maxAmountIn == 0) return 0;

        SwapProvider memory provider;
        {
            bytes32 tokenPairHash = getTokenPairHash(fromToken, toToken);
            provider = swapProvider[tokenPairHash];
            if (provider.router == address(0)) revert LibError.InvalidSwapConfig();
        }

        // Used to validate the actual tokens received and actual amount used for the swap
        uint256 fromTokenBalanceBefore = IERC20(fromToken).balanceOf(address(this));
        uint256 toTokenBalanceBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), maxAmountIn);

        if (provider.swapType == SwapType.PARASWAP_AGGREGATOR) {
            uint256 toAmountOffset = _calculateParaswapAmountOffset(bytes4(swapData[:4]));
            _paraswapAggregatorExactOut(provider.router, fromToken, maxAmountIn, amountOut, toAmountOffset, swapData);
        } else if (provider.swapType == SwapType.PENDLE_ROUTER) {
            _pendleRouterSwap(provider.router, fromToken, maxAmountIn, swapData);
        } else {
            revert LibError.InvalidSwapConfig();
        }

        {
            // Validate the actual tokens received and transfer tokens to the receiver
            uint256 tokensReceived = IERC20(toToken).balanceOf(address(this)) - toTokenBalanceBefore;
            if (tokensReceived < amountOut) revert LibError.SlippageLimitExceeded(tokensReceived, amountOut);
            IERC20(toToken).safeTransfer(receiver, tokensReceived);
        }

        // Calculate the refund amount of `fromToken` if any
        uint256 refundAmount = IERC20(fromToken).balanceOf(address(this)) - fromTokenBalanceBefore;
        actualAmountIn = maxAmountIn - refundAmount;

        if (refundAmount > 0) {
            // Transfer the extra tokens if the swap was executed with a lower amount than `maxAmountIn`
            IERC20(fromToken).safeTransfer(msg.sender, refundAmount);
        }
        emit SwapExecuted(fromToken, toToken, actualAmountIn, amountOut, receiver);
    }

    /// @notice Sets the swap provider for a given token pair.
    /// @param _fromToken The address of the input token.
    /// @param _toToken The address of the output token.
    /// @param _provider The swap provider details.
    function setSwapProvider(
        address _fromToken,
        address _toToken,
        SwapProvider calldata _provider
    ) external onlyRole(MANAGEMENT_ROLE) {
        if (_fromToken == address(0) || _toToken == address(0)) revert LibError.InvalidAddress();
        if (_provider.router == address(0)) revert LibError.InvalidSwapConfig();
        bytes32 tokenPairHash = getTokenPairHash(_fromToken, _toToken);

        swapProvider[tokenPairHash] = _provider;
        emit SwapProviderSet(_fromToken, _toToken, _provider);
    }

    /// @notice Calculates the keccak256 hash of a token pair.
    /// @param _fromToken The address of the input token.
    /// @param _toToken The address of the output token.
    /// @return The keccak256 hash of the token pair.
    function getTokenPairHash(address _fromToken, address _toToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_fromToken, _toToken));
    }

    /*//////////////////////////////////////////////////////////////
                        Kyberswap Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to swap tokens using Kyberswap's aggregator.
    /// @dev This function uses the ScaleHelper to scale the provided swap data for the actual amount,
    /// then executes the swap via a low-level call to the router
    /// @param router The address of the Kyberswap router.
    /// @param fromToken The address of the token to swap from.
    /// @param amountIn The amount of `fromToken` to swap.
    /// @param encodedSwapData The encoded swap data for the aggregator.
    function _kyberswapAggregatorExactIn(
        address router,
        address fromToken,
        uint256 amountIn,
        bytes memory encodedSwapData
    ) internal {
        IERC20(fromToken).forceApprove(router, amountIn);

        (bool canBeScaled, bytes memory updatedSwapData) = IScaleHelper(KYBERSWAP_SCALE_HELPER).getScaledInputData(
            encodedSwapData,
            amountIn
        );

        if (canBeScaled) {
            (bool success, ) = router.call(updatedSwapData);
            if (!success) {
                // Copy revert reason from call
                assembly {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            revert LibError.ScaledInputFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Paraswap Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the calldata byte offset of the amount field for a given Paraswap function selector.
    /// @dev Used to overwrite the encoded amount in Paraswap calldata with the actual runtime amount.
    /// @param selector The 4-byte function selector from the Paraswap calldata.
    /// @return The byte offset of the amount field within the calldata.
    function _calculateParaswapAmountOffset(bytes4 selector) public pure returns (uint256) {
        // Function Selectors from documentation
        // https://paraswap.notion.site/Dynamic-src-dest-amounts-on-AugustusV6-d23ad8f05e4f402aa906ab3f59763a87
        bytes4 PARASWAP_SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;
        bytes4 PARASWAP_SWAP_EXACT_AMOUNT_OUT = 0x7f457675;

        if (selector == PARASWAP_SWAP_EXACT_AMOUNT_IN) {
            return 100;
        } else if (selector == PARASWAP_SWAP_EXACT_AMOUNT_OUT) {
            return 132;
        } else {
            revert LibError.InvalidSwapSelector();
        }
    }

    /// @notice Internal function to swap tokens using Paraswap aggregator.
    /// @param router The address of the Paraswap router.
    /// @param fromToken The address of the token to swap from.
    /// @param amountIn The amount of `fromToken` to swap.
    /// @param fromAmountOffset Byte offset in the calldata where the input amount is located.
    /// @param encodedSwapData The encoded swap data for the aggregator.
    function _paraswapAggregatorExactIn(
        address router,
        address fromToken,
        uint256 amountIn,
        uint256 fromAmountOffset,
        bytes memory encodedSwapData
    ) internal {
        if (!AUGUSTUS_REGISTRY.isValidAugustus(router)) revert LibError.InvalidSwapConfig();
        IParaSwapAugustus augustus = IParaSwapAugustus(router);

        address tokenTransferProxy = augustus.getTokenTransferProxy();
        IERC20(fromToken).forceApprove(tokenTransferProxy, amountIn);

        // Update `amountIn` if fromAmountOffset is provided
        if (fromAmountOffset != 0) {
            // Ensure 256 bit (32 bytes) fromAmount value is within bounds of the
            // calldata, not overlapping with the first 4 bytes (function selector).
            require(
                fromAmountOffset >= 4 && fromAmountOffset <= encodedSwapData.length - 32,
                LibError.OffsetOutOfRange()
            );
            // Overwrite the fromAmount with the correct amount for the swap.
            // In memory, encodedSwapData consists of a 256 bit length field, followed by
            // the actual bytes data, that is why 32 is added to the byte offset.
            assembly {
                mstore(add(encodedSwapData, add(fromAmountOffset, 32)), amountIn)
            }
        }

        (bool success, ) = address(augustus).call(encodedSwapData);
        if (!success) {
            // Copy revert reason from call
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @notice swapExactOut function using Velora(Paraswap) aggregator
    /// @param router Paraswap Augustus router address
    /// @param fromToken The address of the input token to swap from
    /// @param maxAmountIn The maximum amount of input tokens willing to spend
    /// @param amountOut The exact amount of output tokens desired
    /// @param toAmountOffset Byte offset in the calldata where the output amount is located.
    /// @param encodedSwapData Bytes data for executing the swap
    function _paraswapAggregatorExactOut(
        address router,
        address fromToken,
        uint256 maxAmountIn,
        uint256 amountOut,
        uint256 toAmountOffset,
        bytes memory encodedSwapData
    ) internal {
        if (!AUGUSTUS_REGISTRY.isValidAugustus(router)) revert LibError.InvalidSwapConfig();
        IParaSwapAugustus augustus = IParaSwapAugustus(router);

        address tokenTransferProxy = augustus.getTokenTransferProxy();
        IERC20(fromToken).forceApprove(tokenTransferProxy, maxAmountIn);

        // Update `amountOut` if toAmountOffset is provided
        if (toAmountOffset != 0) {
            // Ensure 256 bit (32 bytes) toAmountOffset value is within bounds of the
            // calldata, not overlapping with the first 4 bytes (function selector).
            require(toAmountOffset >= 4 && toAmountOffset <= encodedSwapData.length - 32, LibError.OffsetOutOfRange());
            // Overwrite the toAmount with the correct amount for the buy.
            // In memory, encodedSwapData consists of a 256 bit length field, followed by
            // the actual bytes data, that is why 32 is added to the byte offset.
            assembly {
                mstore(add(encodedSwapData, add(toAmountOffset, 32)), amountOut)
            }
        }

        (bool success, ) = address(augustus).call(encodedSwapData);
        if (!success) {
            // Copy revert reason from call
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Pendle Router Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a Pendle Router V4 swap with on-chain amount scaling.
    /// @dev The off-chain Pendle API embeds an amount in the calldata that may differ from
    /// `amountIn` (for example, in case of CeresSwapper when the actual amount could be adjusted by slippage,
    /// or if the actual amount is calculated on-chain.
    /// The function decodes the calldata, replaces the outer amount field with the actual
    /// `amountIn`, and calls the router via the typed IPendleRouter interface so that:
    ///     - The approval matches the actual amount used.
    ///     - The router pulls exactly `amountIn` tokens from this contract.
    ///     - Revert reasons propagate automatically without assembly.
    /// Note: The inner aggregator scaling is handled by the Pendle router itself when `needScale = true` in the SwapData.
    /// @param router Pendle Router address.
    /// @param fromToken The token being sold (PT for swapExactPtForToken, input token for swapExactTokenForPt)
    /// @param amountIn The actual amount of `fromToken` to sell (overrides the amount in calldata)
    /// @param encodedSwapData ABI-encoded Pendle router calldata (4-byte selector + encoded args).
    function _pendleRouterSwap(
        address router,
        address fromToken,
        uint256 amountIn,
        bytes calldata encodedSwapData
    ) internal {
        if (encodedSwapData.length < 4) revert LibError.InvalidSwapSelector();

        bytes4 selector = bytes4(encodedSwapData[:4]);
        bytes calldata args = encodedSwapData[4:];

        IERC20(fromToken).forceApprove(router, amountIn);

        if (selector == IPendleRouter.swapExactPtForToken.selector) {
            // Decode all args, replace `exactPtIn` with the actual `amountIn`, and receiver with address(this)
            // prettier-ignore
            (
                /* address receiver */, 
                address market,
                /* uint256 exactPtIn */,
                IPendleRouter.TokenOutput memory output,
                IPendleRouter.LimitOrderData memory limit
            ) = abi.decode(args, (address, address, uint256, IPendleRouter.TokenOutput, IPendleRouter.LimitOrderData));

            IPendleRouter(router).swapExactPtForToken(address(this), market, amountIn, output, limit);
        } else if (selector == IPendleRouter.swapExactTokenForPt.selector) {
            // Decode all args, replacing `input.netTokenIn` with the actual `amountIn`, and receiver with address(this)
            // prettier-ignore
            (
                /* address receiver */,
                address market,
                uint256 minPtOut,
                IPendleRouter.ApproxParams memory guessPtOut,
                IPendleRouter.TokenInput memory input,
                IPendleRouter.LimitOrderData memory limit
            ) = abi.decode(
                    args,
                    (
                        address,
                        address,
                        uint256,
                        IPendleRouter.ApproxParams,
                        IPendleRouter.TokenInput,
                        IPendleRouter.LimitOrderData
                    )
                );

            input.netTokenIn = amountIn;

            IPendleRouter(router).swapExactTokenForPt(address(this), market, minPtOut, guessPtOut, input, limit);
        } else {
            revert LibError.InvalidSwapSelector();
        }
    }
}
