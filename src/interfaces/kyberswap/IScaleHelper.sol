// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IScaleHelper {
    function getScaledInputData(
        bytes calldata inputData,
        uint256 newAmount
    ) external view returns (bool isSuccess, bytes memory data);
}
