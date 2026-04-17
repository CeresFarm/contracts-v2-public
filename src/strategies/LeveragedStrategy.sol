// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {CeresBaseVault} from "./CeresBaseVault.sol";

import {LibError} from "../libraries/LibError.sol";

import {ILeveragedStrategy} from "../interfaces/strategies/ILeveragedStrategy.sol";
import {IFlashLoanRouter} from "../interfaces/periphery/IFlashLoanRouter.sol";
import {IOracleAdapter} from "../interfaces/periphery/IOracleAdapter.sol";
import {ICeresSwapper} from "../interfaces/periphery/ICeresSwapper.sol";

abstract contract LeveragedStrategy is CeresBaseVault, ILeveragedStrategy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 internal constant DELAY = 2 days;

    // Keys for pending updates mapping
    bytes32 internal constant ORACLE_KEY = keccak256("ORACLE");
    bytes32 internal constant SWAPPER_KEY = keccak256("SWAPPER");
    bytes32 internal constant FLASH_LOAN_ROUTER_KEY = keccak256("FLASH_LOAN_ROUTER");
    bytes32 private constant FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.LeveragedStrategy
    // prettier-ignore
    struct LeveragedStrategyStorage {
        mapping(bytes32 key => PendingUpdate) pendingUpdatesByKey;

        IERC20 collateralToken;
        IERC20 debtToken;

        bool isAssetCollateral;

        // Flag to indicate if exactOut swap is available in the swapper for collateral-> debt route
        bool isExactOutSwapEnabled;

        uint16 targetLtvBps;
        IOracleAdapter oracleAdapter;
        ICeresSwapper swapper;
        IFlashLoanRouter flashLoanRouter;

        uint16 ltvBufferBps;
    }

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.LeveragedStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LEVERAGED_STRATEGY_STORAGE_LOCATION =
        0xdf5835635f9c63f5038c3c39a3e8c20793eb241995cc033746644d7d39feeb00;

    function _getLeveragedStrategyStorage() private pure returns (LeveragedStrategyStorage storage S) {
        assembly {
            S.slot := LEVERAGED_STRATEGY_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               CONSTRUCTOR/INITIALIZERS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the leveraged strategy.
    /// @param _assetToken The deposit asset (e.g. USDC).
    /// @param _name ERC20 name for the vault share token.
    /// @param _symbol ERC20 symbol for the vault share token.
    /// @param _collateralToken The token supplied as collateral in the lending market.
    /// @param _debtToken The token borrowed from the lending market.
    /// @param _roleManager Address of the RoleManager.
    function __LeveragedStrategy_init(
        address _assetToken,
        string memory _name,
        string memory _symbol,
        address _collateralToken,
        address _debtToken,
        address _roleManager
    ) internal onlyInitializing {
        __CeresBaseVault_init(IERC20(_assetToken), _name, _symbol, _roleManager);
        __LeveragedStrategy_init_unchained(_assetToken, _collateralToken, _debtToken);
    }

    /// @notice Unchained initializer for LeveragedStrategy.
    /// @dev Initializes the collateral token, debt token, and asset mapping.
    /// @param _assetToken The asset token of the strategy.
    /// @param _collateralToken The collateral token of the strategy.
    /// @param _debtToken The debt token of the strategy.
    function __LeveragedStrategy_init_unchained(
        address _assetToken,
        address _collateralToken,
        address _debtToken
    ) internal onlyInitializing {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        if (_collateralToken == address(0) || _debtToken == address(0)) {
            revert LibError.ZeroAddress();
        }

        // Set to true if the asset is the collateral token
        S.isAssetCollateral = (_assetToken == _collateralToken);

        S.collateralToken = IERC20(_collateralToken);
        S.debtToken = IERC20(_debtToken);

        S.targetLtvBps = 50_00; // 50%
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CORE FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Swaps idle asset-token balance into collateral and deposits it into the lending market.
    /// @dev Only valid when asset != collateral. Uses the oracle adapter for the minimum output calculation.
    /// @param assetAmount Amount of asset token to swap and deposit.
    /// @param swapData Encoded swap calldata for the configured swapper.
    function swapAndDepositCollateral(
        uint256 assetAmount,
        bytes calldata swapData
    ) external nonReentrant onlyRole(KEEPER_ROLE) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        // Revert if the asset and collateral is the same
        // As asset(collateral) is supplied during deposit and no swap is required
        if (S.isAssetCollateral) revert LibError.InvalidAction();

        // Validate that assets marked for withdrawals are not used
        if (assetAmount > _getSelfBalance(IERC20(asset())) - withdrawalReserve()) revert LibError.InsufficientAssets();

        uint256 amountInCollateral = S.oracleAdapter.convertAssetsToCollateral(assetAmount);
        uint256 collateralReceived = _executeSwap(
            IERC20(asset()),
            S.collateralToken,
            assetAmount,
            amountInCollateral,
            false,
            swapData
        );
        _depositCollateral(_getSelfBalance(S.collateralToken));

        _harvestAndReport();
        emit SwapDepositCollateral(assetAmount, collateralReceived);
    }

    /// @notice Adjusts leverage by either borrowing more debt and depositing collateral (leverage up)
    /// or repaying debt and withdrawing collateral (leverage down).
    /// @dev Can optionally use a flash loan to avoid needing pre-funded capital.
    /// Validates that strategy LTV remains within bounds after the rebalance.
    /// @param amount Amount of debt token to use for the leverage adjustment.
    /// @param isLeverageUp True to increase leverage; false to decrease.
    /// @param useFlashLoan True to source the debt token via a flash loan.
    /// @param swapData Encoded swap calldata for the configured swapper.
    function rebalance(
        uint256 amount,
        bool isLeverageUp,
        bool useFlashLoan,
        bytes calldata swapData
    ) external nonReentrant onlyRole(KEEPER_ROLE) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        if (useFlashLoan) {
            if (address(S.flashLoanRouter) == address(0)) revert LibError.InvalidAddress();
            bytes memory userData = abi.encode(isLeverageUp, swapData);
            S.flashLoanRouter.requestFlashLoan(address(S.debtToken), amount, userData);
            // Flash loan callback continues the rebalance process in `onFlashLoanReceived`
        } else {
            IERC20 debtToken = S.debtToken;
            debtToken.safeTransferFrom(msg.sender, address(this), amount);

            if (isLeverageUp) {
                _leverageUp(amount, swapData);
            } else {
                _leverageDown(amount, swapData);
            }

            debtToken.safeTransfer(msg.sender, amount);
        }

        // Validate that strategy LTV is within limits after rebalance
        _validateStrategyLtv();

        _harvestAndReport();
        emit Rebalance(msg.sender, amount, isLeverageUp, useFlashLoan);
    }

    /// @notice Flash loan callback invoked by the FlashLoanRouter after funds are transferred.
    /// @dev Executes the leverage-up or leverage-down logic and repays the flash loan.
    /// Borrows additional debt if the strategy does not hold enough to cover repayment + fee.
    /// @param token The borrowed token address.
    /// @param amount The borrowed amount.
    /// @param fee The flash loan fee (0 for Euler and Morpho).
    /// @param data ABI-encoded (isLeverageUp, swapData).
    /// @return The ERC3156 flash loan success constant.
    function onFlashLoanReceived(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        if (msg.sender != address(S.flashLoanRouter)) revert LibError.InvalidAddress();
        if (token != address(S.debtToken)) revert LibError.InvalidToken();

        (bool isLeverageUp, bytes memory swapData) = abi.decode(data, (bool, bytes));

        if (isLeverageUp) {
            _leverageUp(amount, swapData);
        } else {
            _leverageDown(amount, swapData);
        }

        uint256 repayAmount = amount + fee;
        uint256 debtTokenBalance = _getSelfBalance(S.debtToken);

        // Handle scenario where strategy doesn't have enough debt tokens to repay flash loan
        // Could happen because of slippage during swap, or dust token amounts, or when exactOut swap is not available
        if (repayAmount > debtTokenBalance) {
            _borrowFromMarket(repayAmount - debtTokenBalance); // Borrow additional amount if there's a shortfall of debt tokens
        }

        // Approve FlashLoan Router to pull repayment and pass it back to the underlying lender
        S.debtToken.forceApprove(address(S.flashLoanRouter), repayAmount);
        return FLASH_LOAN_SUCCESS;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns a full breakdown of the strategy's net asset value.
    /// @dev All amounts are in their respective token decimals. Debt token balance offsets market debt.
    /// @return assetBalance Current idle balance of the asset token held by this contract.
    /// @return netAssets Net asset value in asset-token terms (collateral value + asset balance - net debt).
    /// @return marketCollateral Collateral deposited into the lending market.
    /// @return totalCollateral Total collateral including any balance held by the contract.
    /// @return marketDebt Outstanding debt in the lending market.
    /// @return netDebt Market debt minus any debt tokens held by the contract.
    function getNetAssets()
        public
        view
        returns (
            uint256 assetBalance,
            uint256 netAssets,
            uint256 marketCollateral,
            uint256 totalCollateral,
            uint256 marketDebt,
            uint256 netDebt
        )
    {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        IOracleAdapter oracle = S.oracleAdapter;

        // Cache storage variables
        address assetToken = asset();
        address debtToken = address(S.debtToken);

        marketCollateral = _getCollateralAmount();
        marketDebt = _getDebtAmount();

        assetBalance = _getSelfBalance(IERC20(assetToken));

        if (S.isAssetCollateral) {
            // If asset and collateral token are the same, assetToken == collateralToken
            totalCollateral = marketCollateral + assetBalance;
            netAssets += totalCollateral;
        } else {
            totalCollateral = _getSelfBalance(S.collateralToken) + marketCollateral;

            uint256 collateralInAssets = oracle.convertCollateralToAssets(totalCollateral);
            netAssets += assetBalance + collateralInAssets;
        }

        uint256 debtTokenBalance = 0;
        // When asset == debtToken, the balance is already counted as assetBalance above.
        // When collateral == debtToken(highly unlikely), the balance is already counted in totalCollateral above.
        if (debtToken != assetToken && debtToken != address(S.collateralToken)) {
            debtTokenBalance = _getSelfBalance(IERC20(debtToken));
        }

        if (debtTokenBalance > marketDebt) {
            // If we hold more debt tokens than we owe,
            // convert only the surplus to assets and zero the debt(liability)
            netAssets += oracle.convertDebtToAssets(debtTokenBalance - marketDebt);
            netDebt = 0;
        } else {
            // Available debt tokens partially/fully offset the outstanding debt (borrowed amount)
            netDebt = marketDebt - debtTokenBalance;
        }

        uint256 netDebtInAssets = netDebt > 0 ? oracle.convertDebtToAssets(netDebt) : 0;
        if (netAssets > netDebtInAssets) {
            netAssets -= netDebtInAssets;
        } else {
            netAssets = 0;
        }
    }

    /// @notice Returns the strategy's current loan-to-value ratio in basis points.
    /// @return currentLtvBps The current LTV in basis points.
    function getStrategyLtv() public view virtual returns (uint16 currentLtvBps) {
        return _getStrategyLtv();
    }

    /// @notice Returns the collateral amount deposited in the lending market.
    /// @return The amount of collateral.
    function getCollateralAmount() external view returns (uint256) {
        return _getCollateralAmount();
    }

    /// @notice Returns the outstanding debt amount in the lending market.
    /// @return The amount of debt.
    function getDebtAmount() external view returns (uint256) {
        return _getDebtAmount();
    }

    /// @notice Returns the collateral token used by this strategy.
    /// @return The collateral IERC20 instance.
    function COLLATERAL_TOKEN() public view returns (IERC20) {
        return _getLeveragedStrategyStorage().collateralToken;
    }

    /// @notice Returns the debt token used by this strategy.
    /// @return The debt IERC20 instance.
    function DEBT_TOKEN() public view returns (IERC20) {
        return _getLeveragedStrategyStorage().debtToken;
    }

    /// @notice Returns the pending update details for a given key (oracle, swapper, or flash loan router).
    /// @param key One of the ORACLE_KEY, SWAPPER_KEY, or FLASH_LOAN_ROUTER_KEY constants.
    /// @return implementation The proposed new address.
    /// @return readyTimestamp The timestamp after which the update can be executed.
    function pendingUpdates(bytes32 key) external view returns (address implementation, uint64 readyTimestamp) {
        PendingUpdate memory pending = _getLeveragedStrategyStorage().pendingUpdatesByKey[key];
        implementation = pending.implementation;
        readyTimestamp = pending.readyTimestamp;
    }

    /// @notice Returns the full leveraged strategy configuration.
    /// @return isExactOutSwapEnabled True if exact-output swaps are allowed.
    /// @return targetLtvBps The target loan-to-value ratio.
    /// @return ltvBufferBps The buffer below target LTV inside which no rebalancing is needed.
    /// @return oracleAdapter_ Address of the oracle adapter.
    /// @return swapper Address of the Ceres swapper.
    /// @return flashLoanRouter Address of the flash loan router.
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
        )
    {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        isExactOutSwapEnabled = S.isExactOutSwapEnabled;
        targetLtvBps = S.targetLtvBps;
        ltvBufferBps = S.ltvBufferBps;
        oracleAdapter_ = address(S.oracleAdapter);
        swapper = address(S.swapper);
        flashLoanRouter = address(S.flashLoanRouter);
    }

    /// @notice Returns the oracle adapter used by the strategy.
    /// @return The configured IOracleAdapter instance.
    function oracleAdapter() public view returns (IOracleAdapter) {
        return _getLeveragedStrategyStorage().oracleAdapter;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                ADMIN FUNCTIONS: SETTERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Enables or disables exact-output swaps for the collateral-to-debt route.
    /// @param _enabled True to use exact-output swaps when available.
    function setExactOutSwapEnabled(bool _enabled) external onlyRole(MANAGEMENT_ROLE) {
        _getLeveragedStrategyStorage().isExactOutSwapEnabled = _enabled;
        emit SetExactOutSwapEnabled(_enabled);
    }

    /// @notice Sets the target LTV and the safety buffer above which rebalances are blocked.
    /// @dev Both values combined must be below 100% and below the market's max LTV.
    /// @param _ltvBps Target LTV in basis points.
    /// @param _ltvBufferBps Safety buffer added to `_ltvBps` for the LTV ceiling check.
    function setTargetLtv(uint16 _ltvBps, uint16 _ltvBufferBps) external onlyRole(MANAGEMENT_ROLE) {
        if (_ltvBps + _ltvBufferBps >= BPS_PRECISION) revert LibError.InvalidLtv();
        if (_ltvBps + _ltvBufferBps >= _getStrategyMaxLtvBps()) revert LibError.AboveMaxLtv();

        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        S.targetLtvBps = _ltvBps;
        S.ltvBufferBps = _ltvBufferBps;

        _validateStrategyLtv();

        emit TargetLtvUpdated(_ltvBps, _ltvBufferBps);
    }

    /// @notice Unified 2-step update management for oracle, swapper, and flash loan router.
    /// @dev For existing addresses, a 2-day timelock applies before the update can be executed.
    /// If no address is currently set, the update is applied immediately.
    /// @param action Request, Execute, or Cancel the pending update.
    /// @param key One of ORACLE_KEY, SWAPPER_KEY, or FLASH_LOAN_ROUTER_KEY.
    /// @param newAddress The proposed replacement address.
    function manageUpdate(UpdateAction action, bytes32 key, address newAddress) external onlyRole(MANAGEMENT_ROLE) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        if (action == UpdateAction.Request) {
            // Request
            if (newAddress == address(0)) revert LibError.InvalidAddress();
            if (S.pendingUpdatesByKey[key].implementation != address(0)) revert LibError.PendingActionExists();

            address currentAddress = _getCurrentAddress(key);

            // If current implementation is not set, allow immediate update
            if (currentAddress == address(0)) {
                _setImplementation(key, newAddress);
                emit UpdateExecuted(key, address(0), newAddress);
            } else {
                uint64 readyAt = (block.timestamp + DELAY).toUint64();
                S.pendingUpdatesByKey[key] = PendingUpdate(newAddress, readyAt);
                emit UpdateRequested(key, newAddress, readyAt);
            }
        } else if (action == UpdateAction.Execute) {
            // Execute
            PendingUpdate memory pending = S.pendingUpdatesByKey[key];
            if (pending.implementation == address(0)) revert LibError.NoPendingActionExists();
            if (block.timestamp < pending.readyTimestamp) revert LibError.NotReady();

            address oldAddress = _getCurrentAddress(key);
            _setImplementation(key, pending.implementation);
            delete S.pendingUpdatesByKey[key];
            emit UpdateExecuted(key, oldAddress, pending.implementation);
        } else if (action == UpdateAction.Cancel) {
            // Cancel
            address proposed = S.pendingUpdatesByKey[key].implementation;
            if (proposed == address(0)) revert LibError.NoPendingActionExists();
            delete S.pendingUpdatesByKey[key];
            emit UpdateCancelled(key, proposed);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          ADMIN FUNCTIONS: EMERGENCY ACTIONS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Directly executes a market operation for emergency use or rescues stuck tokens.
    /// @dev Validates LTV after market operations and triggers a harvest/report.
    /// @param operationType 0 = deposit collateral, 1 = withdraw collateral, 2 = borrow, 3 = repay, 4 = rescue tokens.
    /// @param amount The amount to execute with
    /// @param token Address used only for rescue (operationType 4); pass address(0) otherwise.
    function executeOperation(
        uint8 operationType,
        uint256 amount,
        address token
    ) external nonReentrant onlyRole(MANAGEMENT_ROLE) {
        if (operationType == 0) {
            _depositCollateral(amount);
        } else if (operationType == 1) {
            _withdrawCollateral(amount);
        } else if (operationType == 2) {
            _borrowFromMarket(amount);
        } else if (operationType == 3) {
            _repayDebt(amount);
        } else if (operationType == 4) {
            _rescueTokens(token, amount);
            return; // skip LTV validation and harvest for rescue
        } else {
            revert LibError.InvalidAction();
        }

        _validateStrategyLtv();
        _harvestAndReport();
        emit MarketOperationExecuted(operationType, amount);
    }

    /// @notice Executes a swap between two tokens held by the strategy for emergency re-balancing.
    /// @dev Validates by triggering harvest/report after the swap.
    /// @param tokenIn The token to sell.
    /// @param tokenOut The token to receive.
    /// @param srcAmount Amount of `tokenIn` to sell.
    /// @param srcAmountInDestToken Oracle-estimated equivalent of `srcAmount` in `tokenOut` terms.
    /// @param useExactOut True to use exact-output swap mode.
    /// @param swapData Encoded swap calldata.
    /// @return destAmount The actual amount of `tokenOut` received.
    function executeSwapOperation(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 srcAmount,
        uint256 srcAmountInDestToken,
        bool useExactOut,
        bytes calldata swapData
    ) external nonReentrant onlyRole(MANAGEMENT_ROLE) returns (uint256 destAmount) {
        destAmount = _executeSwap(tokenIn, tokenOut, srcAmount, srcAmountInDestToken, useExactOut, swapData);

        _harvestAndReport();
        emit SwapExecuted(address(tokenIn), address(tokenOut), srcAmount, destAmount);
    }

    /// @dev Transfers any ERC20 tokens accidentally sent to the strategy to the admin.
    function _rescueTokens(address _token, uint256 _amount) internal {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        if (
            _token == asset() ||
            _token == address(S.collateralToken) ||
            _token == address(S.debtToken) ||
            _token == address(this)
        ) {
            revert LibError.InvalidToken();
        }

        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit TokensRecovered(_token, _amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      INTERNAL OVERRIDES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _onProcessRequest(bytes calldata /* extraData */) internal virtual override {
        _harvestAndReport();
    }

    /// @dev If asset == collateral, deposits directly into the lending market. Otherwise,
    /// collateral must be acquired via a keeper-initiated swap-and-deposit.
    /// @param _amount Target asset-token amount to deposit.
    function _deployFunds(uint256 _amount) internal override {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        // If asset is the collateral token, deposit directly
        // else the deposit is handled during the rebalance process after swap
        if (S.isAssetCollateral) {
            _depositCollateral(_amount);
        }
    }

    /// @dev Delegates to `getNetAssets` and returns the net asset value.
    /// @return netAssets The current total net asset value of the strategy.
    function _reportTotalAssets() internal view virtual override returns (uint256 netAssets) {
        (, netAssets, , , , ) = getNetAssets();
    }

    /// @dev Unwinds the strategy's leverage to free `_amount` of asset tokens.
    /// Uses a flash loan to repay outstanding debt, then withdraws collateral.
    /// @param _amount Target asset-token amount to free.
    /// @param extraData ABI-encoded (flashLoanAmount, flashLoanSwapData, collateralToAssetSwapData).
    /// @return actualFreed Actual asset tokens freed (may be less than `_amount` due to slippage).
    function _freeFunds(
        uint256 _amount,
        bytes calldata extraData
    ) internal virtual override returns (uint256 actualFreed) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        uint256 assetBalance = _getSelfBalance(IERC20(asset()));

        // extraData: (uint256 flashLoanAmount, bytes flashLoanSwapData, bytes collateralToAssetSwapData)
        // For isAssetCollateral strategies, collateralToAssetSwapData is empty bytes and unused
        (uint256 flashLoanAmount, bytes memory flashLoanSwapData, bytes memory collateralToAssetSwapData) = abi.decode(
            extraData,
            (uint256, bytes, bytes)
        );

        if (S.isAssetCollateral) {
            _unwindCollateral(_amount, flashLoanAmount, flashLoanSwapData);
        } else {
            uint256 collateralToFree = S.oracleAdapter.convertAssetsToCollateral(_amount);
            uint256 collateralFreed = _unwindCollateral(collateralToFree, flashLoanAmount, flashLoanSwapData);

            if (collateralFreed > 0) {
                uint256 amountInAsset = S.oracleAdapter.convertCollateralToAssets(collateralFreed);
                _executeSwap(
                    S.collateralToken,
                    IERC20(asset()),
                    collateralFreed,
                    amountInAsset,
                    false,
                    collateralToAssetSwapData
                );
            }
        }

        // Validate LTV to ensure the strategy is not pushed into an unsafe state
        // if the keeper provided an insufficient flashLoanAmount for deleveraging.
        _validateStrategyLtv();

        actualFreed = _getSelfBalance(IERC20(asset())) - assetBalance;
    }

    /// @dev Uses a flash loan to repay debt and release collateral. With exact-output swaps enabled,
    /// the swapper may refund unused collateral which is credited against the remaining withdrawal target.
    /// @param collateralToFree Target collateral amount to release.
    /// @param flashLoanAmount Debt token amount to flash-borrow for the leverage-down.
    /// @param flashLoanSwapData Swap calldata for the collateral-to-debt swap inside the flash loan.
    /// @return collateralFreed The actual collateral freed.
    function _unwindCollateral(
        uint256 collateralToFree,
        uint256 flashLoanAmount,
        bytes memory flashLoanSwapData
    ) internal returns (uint256 collateralFreed) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        // Snapshot before FL so we can measure only what this call contributes.
        uint256 collateralBefore = _getSelfBalance(S.collateralToken);

        if (flashLoanAmount > 0 && _getDebtAmount() > 0) {
            // FL callback handles only debt repayment. Any unused collateral from the
            // exactOut swap inside the FL is refunded to the strategy by the swapper.
            S.flashLoanRouter.requestFlashLoan(
                address(S.debtToken),
                flashLoanAmount,
                abi.encode(false, flashLoanSwapData)
            );
        }

        // With exactOut, the `swapTo` during the FL may refund unused collateral.
        // Without exactOut, swapFrom consumes all collateral, skip accounting for refunded collateral.
        uint256 remainingToWithdraw = collateralToFree;

        if (S.isExactOutSwapEnabled) {
            uint256 collateralAfterFL = _getSelfBalance(S.collateralToken);
            if (collateralAfterFL > collateralBefore) {
                uint256 flRefund = collateralAfterFL - collateralBefore;
                remainingToWithdraw = collateralToFree > flRefund ? collateralToFree - flRefund : 0;
            }
        }

        if (remainingToWithdraw > 0) {
            uint256 toWithdraw = Math.min(remainingToWithdraw, _getCollateralAmount());
            if (toWithdraw > 0) _withdrawCollateral(toWithdraw);
        }

        // flRefund + toWithdraw can revert in _executeSwap (collateral->asset) if there is precision loss
        // during withdrawal. We measure actual exact balance delta.
        uint256 collateralFinal = _getSelfBalance(S.collateralToken);
        collateralFreed = collateralFinal > collateralBefore ? collateralFinal - collateralBefore : 0;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             INTERNAL HELPERS: SWAPPER                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Routes a swap through the configured swapper. Uses exact-output mode when enabled
    /// (via `swapTo`), otherwise falls back to exact-input mode (via `swapFrom`) with slippage applied.
    /// @param tokenIn Source token.
    /// @param tokenOut Destination token.
    /// @param srcAmount Amount of `tokenIn` to sell.
    /// @param srcAmountInDestToken Oracle estimate of `srcAmount` expressed in `tokenOut`.
    /// @param useExactOut Request exact-output mode when the flag and strategy config allow it.
    /// @param swapData Encoded swap calldata.
    /// @return destAmount The actual amount of `tokenOut` received.
    function _executeSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 srcAmount,
        uint256 srcAmountInDestToken,
        bool useExactOut,
        bytes memory swapData
    ) internal returns (uint256 destAmount) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        tokenIn.forceApprove(address(S.swapper), srcAmount);

        if (useExactOut && S.isExactOutSwapEnabled) {
            S.swapper.swapTo(
                address(tokenIn),
                address(tokenOut),
                srcAmount,
                srcAmountInDestToken,
                address(this),
                swapData
            );
            destAmount = srcAmountInDestToken;
        } else {
            destAmount = S.swapper.swapFrom(
                address(tokenIn),
                address(tokenOut),
                srcAmount,
                _adjustForSlippage(srcAmountInDestToken, false),
                address(this),
                swapData
            );
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             INTERNAL HELPER FUNCTIONS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Reverts if current LTV plus the buffer exceeds the market's max LTV.
    function _validateStrategyLtv() internal view {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        // Validate that strategy LTV is within limits after applying buffer
        if (_getStrategyLtv() + S.ltvBufferBps > _getStrategyMaxLtvBps()) revert LibError.AboveMaxLtv();
    }

    /// @dev Swaps `debtAmount` of debt token into collateral, deposits it, then borrows `debtAmount`.
    /// Intended to be called with flash-loaned funds.
    /// @param debtAmount The amount of debt to take out.
    /// @param swapData Encoded swap data.
    function _leverageUp(uint256 debtAmount, bytes memory swapData) internal {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();

        // swap debt to collateral -> deposit collateral -> borrow debt -> repay flash loan
        uint256 debtInCollateral = S.oracleAdapter.convertDebtToCollateral(debtAmount);
        uint256 tokensReceived = _executeSwap(
            S.debtToken,
            S.collateralToken,
            debtAmount,
            debtInCollateral,
            false,
            swapData
        );

        _depositCollateral(tokensReceived);
        _borrowFromMarket(debtAmount);
    }

    /// @dev Repays `debtAmount` of debt, withdraws the equivalent collateral with a slippage buffer,
    /// then swaps collateral back to debt token to repay the flash loan.
    /// @param debtAmount The amount of debt to repay.
    /// @param swapData Encoded swap data.
    function _leverageDown(uint256 debtAmount, bytes memory swapData) internal {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        if (debtAmount == 0) return;

        uint256 marketDebt = _getDebtAmount();
        if (marketDebt == 0) return;

        // If amount to repay is more than current debt, set repay amount to current debt
        if (debtAmount > marketDebt) debtAmount = marketDebt;

        // repay debt -> withdraw collateral -> swap collateral to debt -> repay flash loan
        _repayDebt(debtAmount);

        // Withdraw collateral to repay the flash loan with slippage buffer.
        // If `toWithdraw` exceeds max withdrawable amount and reverts,
        // the keeper must adjust the flash loan debt to avoid LTV check failure.
        uint256 collateralForFlashLoan = _adjustForSlippage(S.oracleAdapter.convertDebtToCollateral(debtAmount), true);
        uint256 toWithdraw = Math.min(collateralForFlashLoan, _getCollateralAmount());

        if (toWithdraw > 0) {
            _withdrawCollateral(toWithdraw);
            _executeSwap(S.collateralToken, S.debtToken, toWithdraw, debtAmount, true, swapData);
        }
    }

    /// @dev Returns the current address for a given configuration key.
    /// @param key The configuration key.
    /// @return The current implementation address.
    function _getCurrentAddress(bytes32 key) internal view returns (address) {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        if (key == ORACLE_KEY) return address(S.oracleAdapter);
        if (key == SWAPPER_KEY) return address(S.swapper);
        if (key == FLASH_LOAN_ROUTER_KEY) return address(S.flashLoanRouter);
        revert LibError.InvalidKey();
    }

    /// @dev Updates the storage slot for a given configuration key to `newAddress`.
    /// @param key The configuration key.
    /// @param newAddress The new address to set.
    function _setImplementation(bytes32 key, address newAddress) internal {
        LeveragedStrategyStorage storage S = _getLeveragedStrategyStorage();
        if (key == ORACLE_KEY) {
            S.oracleAdapter = IOracleAdapter(newAddress);
        } else if (key == SWAPPER_KEY) {
            S.swapper = ICeresSwapper(newAddress);
        } else if (key == FLASH_LOAN_ROUTER_KEY) {
            S.flashLoanRouter = IFlashLoanRouter(newAddress);
        } else {
            revert LibError.InvalidKey();
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                         ABSTRACT MARKET SPECIFIC FUNCTIONS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Supplies `collateralAmount` of collateral token into the lending market.
    /// @param collateralAmount The amount of collateral to deposit.
    function _depositCollateral(uint256 collateralAmount) internal virtual;

    /// @dev Withdraws `collateralAmount` of collateral token from the lending market.
    /// @param collateralAmount The amount of collateral to withdraw.
    function _withdrawCollateral(uint256 collateralAmount) internal virtual;

    /// @dev Borrows `borrowAmount` of debt token from the lending market.
    /// @param borrowAmount The amount of debt to borrow.
    function _borrowFromMarket(uint256 borrowAmount) internal virtual;

    /// @dev Repays `repayAmount` of debt token to the lending market.
    /// @param repayAmount The amount of debt to repay.
    function _repayDebt(uint256 repayAmount) internal virtual;

    /// @dev Returns the collateral balance deposited in the lending market.
    /// @return The amount of collateral.
    function _getCollateralAmount() internal view virtual returns (uint256);

    /// @dev Returns the outstanding debt in the lending market.
    /// @return The amount of debt.
    function _getDebtAmount() internal view virtual returns (uint256);

    /// @dev Returns the market's maximum LTV in basis points.
    /// @return The max LTV in basis points.
    function _getStrategyMaxLtvBps() internal view virtual returns (uint16);

    /// @dev Returns the strategy's current LTV in basis points.
    /// @return ltvBps The current LTV in basis points.
    function _getStrategyLtv() internal view virtual returns (uint16 ltvBps);
}
