// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IFlashLoanRouter {
    /// @notice Request a flash loan routed through the router.
    /// @param token The token to borrow.
    /// @param amount The amount to borrow.
    /// @param data Arbitrary data forwarded to the receiver callback.
    function requestFlashLoan(address token, uint256 amount, bytes calldata data) external;

    function rescueTokens(address token) external;
}
