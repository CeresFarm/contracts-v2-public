// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {ICeresBaseVault} from "./ICeresBaseVault.sol";

import {IFlashLoanRouter} from "../periphery/IFlashLoanRouter.sol";
import {IFlashLoanReceiver} from "../periphery/IFlashLoanReceiver.sol";
import {IOracleAdapter} from "../periphery/IOracleAdapter.sol";
import {ICeresSwapper} from "../periphery/ICeresSwapper.sol";

interface ILeveragedStrategy is ICeresBaseVault, IFlashLoanReceiver {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         EVENTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    event TokensRecovered(address indexed token, uint256 amount);
    event SwapDepositCollateral(uint256 assetAmount, uint256 collateralReceived);
    event Rebalance(address indexed keeper, uint256 debtAmount, bool isLeverageUp, bool useFlashLoan);
    event MarketOperationExecuted(uint8 operationType, uint256 amount);
    event SwapExecuted(address indexed srcToken, address indexed destToken, uint256 srcAmount, uint256 destAmount);

    // Config events
    event TargetLtvUpdated(uint16 newTargetLtv, uint16 newLtvBuffer);
    event OracleAdapterUpdated(address indexed oldAddress, address indexed newAddress);
    event SwapperUpdated(address indexed oldAddress, address indexed newAddress);
    event FlashLoanRouterUpdated(address indexed oldAddress, address indexed newAddress);
    event KeeperDelayUpdated(uint48 oldDelay, uint48 newDelay);
    event SetExactOutSwapEnabled(bool enabled);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    STATE VARIABLES                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function COLLATERAL_TOKEN() external view returns (IERC20);
    function DEBT_TOKEN() external view returns (IERC20);

    function oracleAdapter() external view returns (IOracleAdapter);

    function keeperDelay() external view returns (uint48);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getLeveragedStrategyConfig()
        external
        view
        returns (
            bool isExactOutSwapEnabled,
            uint16 targetLtvBps,
            uint16 ltvBufferBps,
            address oracleAdapter_,
            address swapper,
            address flashLoanRouter
        );

    /// @notice Returns a full breakdown of the strategy's net asset value.
    /// @dev NOTE: It MUST strictly deduct `withdrawalReserve()` from actually held gross
    /// assets to ensure pending withdrawers' liquidity isn't mixed into total equity
    /// calculations, preventing yield dilution attacks.
    function getNetAssets()
        external
        view
        returns (
            uint256 assetBalance,
            uint256 netAssets,
            uint256 marketCollateral,
            uint256 totalCollateral,
            uint256 marketDebt,
            uint256 netDebt
        );

    function getStrategyLtv() external view returns (uint16 currentLtvBps);

    function getCollateralAmount() external view returns (uint256);

    function getDebtAmount() external view returns (uint256);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CORE FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function swapAndDepositCollateral(uint256 assetAmount, bytes calldata swapData) external;

    function rebalance(uint256 amount, bool isLeverageUp, bool useFlashLoan, bytes calldata swapData) external;

    function onFlashLoanReceived(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function executeOperation(uint8 operationType, uint256 amount, address token) external;

    function executeSwapOperation(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 srcAmount,
        uint256 srcAmountInDestToken,
        bool useExactOut,
        bytes calldata swapData
    ) external returns (uint256 destAmount);

    function setTargetLtv(uint16 _ltvBps, uint16 _ltvBuffer) external;

    function setExactOutSwapEnabled(bool _enabled) external;

    // Direct setters gated by `TIMELOCKED_ADMIN_ROLE` (delay enforced by external TimelockController).
    function setOracleAdapter(address _oracleAdapter) external;
    function setSwapper(address _swapper) external;
    function setFlashLoanRouter(address _flashLoanRouter) external;
    function setKeeperDelay(uint48 _keeperDelay) external;
}
