// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

interface IFlashLoanReceiver {
    /// @notice Callback invoked by the flash loan provider after it receives funds from the underlying protocol.
    /// @param token The token that was flash-loaned.
    /// @param amount The amount borrowed.
    /// @param fee The fee to repay alongside the principal.
    /// @param data Arbitrary data supplied by the initiator.
    /// @return magicValue Must return keccak256("ERC3156FlashBorrower.onFlashLoan") on success.
    function onFlashLoanReceived(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32 magicValue);
}
