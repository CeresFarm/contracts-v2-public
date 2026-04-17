// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISilo} from "../silo/ISilo.sol";
import {ILeveragedStrategy} from "./ILeveragedStrategy.sol";

interface ILeveragedSilo is ILeveragedStrategy {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getMarketDetails()
        external
        view
        returns (
            address siloLens,
            address siloConfig,
            address depositSilo,
            address borrowSilo,
            ISilo.CollateralType collateralType
        );
}
