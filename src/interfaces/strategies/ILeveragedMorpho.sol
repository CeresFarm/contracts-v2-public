// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {ILeveragedStrategy} from "./ILeveragedStrategy.sol";

interface ILeveragedMorpho is ILeveragedStrategy {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getMarketDetails() external view returns (address morphoMarket, MarketParams memory marketParams);

    function MORPHO_MARKET_PARAMS() external view returns (MarketParams memory);
}
