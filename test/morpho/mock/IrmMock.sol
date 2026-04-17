// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IIrm} from "morpho-blue/interfaces/IIrm.sol";
import {MarketParams, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

/// @notice Local IRM mock that allows tests to override the annual borrow rate directly.
contract IrmMock is IIrm {
    using MathLib for uint128;

    /// @dev Annual borrow rate expressed in WAD (e.g. 10% = 0.1e18). Zero means use utilization model.
    uint256 public annualBorrowRateWadOverride;

    /// @notice Set the annualized borrow rate in basis points (e.g. 1000 = 10%).
    function setAnnualBorrowRateBps(uint256 rateBps) external {
        annualBorrowRateWadOverride = rateBps * 1e14; // bps -> wad
    }

    /// @notice Set the annualized borrow rate directly in WAD precision.
    function setAnnualBorrowRateWad(uint256 rateWad) external {
        annualBorrowRateWadOverride = rateWad;
    }

    function borrowRateView(MarketParams memory, Market memory market) public view returns (uint256) {
        if (annualBorrowRateWadOverride != 0) return annualBorrowRateWadOverride / 365 days;
        if (market.totalSupplyAssets == 0) return 0;

        uint256 utilization = market.totalBorrowAssets.wDivDown(market.totalSupplyAssets);
        return utilization / 365 days;
    }

    function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return borrowRateView(marketParams, market);
    }
}
