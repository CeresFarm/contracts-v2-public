// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Minimal interface for Moolah flash loan.
interface IMoolahFlashLenderLike {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}
