// SPDX-License-Identifier: BUSL
pragma solidity 0.8.35;

import {ISiloOracle} from "src/interfaces/silo/ISiloOracle.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

import {LibError} from "src/libraries/LibError.sol";

contract MockSiloOracle is ISiloOracle {
    address public quoteToken;
    uint256 public constant ORACLE_PRECISION = 1e18;

    mapping(address => uint256) public prices; // token => price in 18 decimals
    bool public shouldRevert;

    constructor(address _quoteToken) {
        quoteToken = _quoteToken;
    }

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function beforeQuote(address) external view {
        if (shouldRevert) revert LibError.OracleError();
    }

    function quote(uint256 _baseAmount, address _baseToken) external view returns (uint256) {
        if (shouldRevert) revert LibError.OracleError();

        uint256 price = prices[_baseToken];
        if (price == 0) revert LibError.InvalidPrice();

        uint8 baseTokenDecimals = ERC20(_baseToken).decimals();

        return (_baseAmount * price) / (10 ** baseTokenDecimals);
    }
}
