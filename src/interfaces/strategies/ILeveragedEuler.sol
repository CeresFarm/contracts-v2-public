// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IEVC} from "../euler/IEVC.sol";
import {IEVault} from "../euler/IEVault.sol";
import {ILeveragedStrategy} from "./ILeveragedStrategy.sol";

interface ILeveragedEuler is ILeveragedStrategy {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    STATE VARIABLES                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getMarketDetails() external view returns (address collateralVault, address borrowVault);
}
