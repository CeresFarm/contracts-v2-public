// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin-contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin-contracts/interfaces/IERC3156FlashLender.sol";

import {IEVault} from "../interfaces/euler/IEVault.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {IMoolahFlashLenderLike} from "../interfaces/lista/IMoolahFlashLenderLike.sol";
import {IFlashLoanRouter} from "../interfaces/periphery/IFlashLoanRouter.sol";
import {IFlashLoanReceiver} from "../interfaces/periphery/IFlashLoanReceiver.sol";
import {RoleManager} from "./RoleManager.sol";
import {LibError} from "../libraries/LibError.sol";

/// @title FlashLoanRouter
/// @notice Routes flash loans to strategies while decoupling protocol-specific integrations.
/// @dev Supports Euler, Morpho, and ERC3156 flash loan providers.
/// Flow:
/// 1. Receiver (Vault/Strategy) calls `requestFlashLoan` on FlashLoanRouter contract
/// 2. FlashLoanRouter routes the request to the configured lender by calling its flash loan function
/// 3. Lender calls back to FlashLoanRouter via the appropriate callback
/// 4. FlashLoanRouter forwards funds to the receiver and invokes its callback (`onFlashLoanReceived`)
/// 5. Receiver performs logic and repays the flash loan + fee to FlashLoanRouter
/// 6. FlashLoanRouter approves the lender to pull the owed amount
contract FlashLoanRouter is IERC3156FlashBorrower, IFlashLoanRouter {
    using SafeERC20 for IERC20;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    bytes32 private constant FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 private constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 private constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    RoleManager public immutable ROLE_MANAGER;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    enum FlashSource {
        EULER,
        MORPHO,
        MOOLAH,
        ERC3156 // Silo and any generic ERC3156 lender
    }

    struct FlashConfig {
        FlashSource source;
        address lender; // Lender address, eg. Euler, Silo, Morpho market, or any ERC3156 lender
        bool enabled; // Is flash loan enabled for this config
    }

    struct PendingRequest {
        address receiver;
        address token;
        address lender;
        uint256 amount;
    }

    // Mapping to store approved addresses (vaults/strategies) and their flash loan configurations
    mapping(address receiver => FlashConfig) public flashConfig;

    // Internal state for flashloan checks
    PendingRequest private _pending;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        EVENTS                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event FlashConfigUpdated(address indexed receiver, FlashSource source, address indexed lender, bool enabled);
    event FlashLoanRouted(address indexed receiver, FlashSource source, address indexed token, uint256 amount);
    event TokensRecovered(address indexed token, uint256 amount);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      CONSTRUCTOR                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the router with the given role manager.
    /// @param _roleManager Address of the RoleManager for access control.
    constructor(address _roleManager) {
        if (_roleManager == address(0)) revert LibError.ZeroAddress();
        ROLE_MANAGER = RoleManager(_roleManager);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              EXTERNAL FUNCTIONS: ROUTER                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Validates the flash loan request before routing. Reverts if a request is already in-flight,
    /// the token is zero, or the amount is zero.
    /// @param token The token address for the flash loan.
    /// @param amount The amount of tokens to borrow.
    function _validateFlashLoanRequest(address token, uint256 amount) internal view {
        // Validate receiver
        if (_pending.receiver != address(0)) revert LibError.PendingActionExists();

        if (token == address(0)) revert LibError.InvalidToken();
        if (amount == 0) revert LibError.InvalidAmount();
    }

    /// @inheritdoc IFlashLoanRouter
    function requestFlashLoan(address token, uint256 amount, bytes calldata data) external override {
        _validateFlashLoanRequest(token, amount);

        FlashConfig memory cfg = flashConfig[msg.sender];
        if (!cfg.enabled) revert LibError.InvalidAction();

        _pending = PendingRequest({receiver: msg.sender, token: token, lender: cfg.lender, amount: amount});

        bytes memory callbackData = abi.encode(token, amount, data);

        if (cfg.source == FlashSource.EULER) {
            IEVault(cfg.lender).flashLoan(amount, callbackData);
        } else if (cfg.source == FlashSource.MORPHO) {
            IMorpho(cfg.lender).flashLoan(token, amount, callbackData);
        } else if (cfg.source == FlashSource.MOOLAH) {
            IMoolahFlashLenderLike(cfg.lender).flashLoan(token, amount, callbackData);
        } else if (cfg.source == FlashSource.ERC3156) {
            IERC3156FlashLender(cfg.lender).flashLoan(
                IERC3156FlashBorrower(address(this)),
                token,
                amount,
                callbackData
            );
        } else {
            revert LibError.InvalidFlashLoanProvider();
        }

        delete _pending;
        emit FlashLoanRouted(msg.sender, cfg.source, token, amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FLASHLOAN CALLBACKS: EULER                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Euler-specific flash loan callback. Called by the Euler vault after transferring funds.
    /// @dev Validates the caller and pending request, forwards funds to the receiver, invokes
    /// `onFlashLoanReceived`, then pulls the repayment back from the receiver and approves the lender.
    /// @param data ABI-encoded (token, amount, userData) passed through from `requestFlashLoan`.
    function onFlashLoan(bytes calldata data) external {
        PendingRequest memory flRequest = _pending;

        if (msg.sender != flRequest.lender) revert LibError.InvalidAction();
        if (flRequest.receiver == address(0)) revert LibError.InvalidReceiver();

        (address token, uint256 amount, bytes memory userData) = abi.decode(data, (address, uint256, bytes));

        if (token != flRequest.token) revert LibError.InvalidToken();
        if (amount != flRequest.amount) revert LibError.InvalidAmount();

        IERC20(token).safeTransfer(flRequest.receiver, amount);
        bytes32 result = IFlashLoanReceiver(flRequest.receiver).onFlashLoanReceived(token, amount, 0, userData);
        if (result != FLASH_LOAN_SUCCESS) revert LibError.FlashLoanFailed();

        _pullAndApprove(token, flRequest.receiver, amount, msg.sender);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FLASHLOAN CALLBACKS: MORPHO                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Morpho-specific flash loan callback. Called by the Morpho pool after transferring funds.
    /// @dev Validates the caller and pending request, forwards funds to the receiver, invokes
    /// `onFlashLoanReceived`, then pulls the repayment back and approves the lender.
    /// @param assets Amount of tokens received from Morpho.
    /// @param data ABI-encoded (token, amount, userData) passed through from `requestFlashLoan`.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        // Cache storage to memory
        PendingRequest memory flRequest = _pending;

        if (msg.sender != flRequest.lender) revert LibError.InvalidAction();
        if (assets != flRequest.amount) revert LibError.InvalidAmount();
        if (flRequest.receiver == address(0)) revert LibError.InvalidReceiver();

        (address tokenFromData, uint256 amount, bytes memory userData) = abi.decode(data, (address, uint256, bytes));
        if (tokenFromData != flRequest.token) revert LibError.InvalidToken();
        if (amount != flRequest.amount) revert LibError.InvalidAmount();

        IERC20(tokenFromData).safeTransfer(flRequest.receiver, assets);
        bytes32 result = IFlashLoanReceiver(flRequest.receiver).onFlashLoanReceived(tokenFromData, assets, 0, userData);
        if (result != FLASH_LOAN_SUCCESS) revert LibError.FlashLoanFailed();

        _pullAndApprove(tokenFromData, flRequest.receiver, assets, msg.sender);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FLASHLOAN CALLBACKS: MOOLAH                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Moolah-specific callback
    function onMoolahFlashLoan(uint256 assets, bytes calldata data) external {
        PendingRequest memory flRequest = _pending;

        if (msg.sender != flRequest.lender) revert LibError.InvalidAction();
        if (assets != flRequest.amount) revert LibError.InvalidAmount();
        if (flRequest.receiver == address(0)) revert LibError.InvalidReceiver();

        (address tokenFromData, uint256 amount, bytes memory userData) = abi.decode(data, (address, uint256, bytes));
        if (tokenFromData != flRequest.token) revert LibError.InvalidToken();
        if (amount != flRequest.amount) revert LibError.InvalidAmount();

        IERC20(tokenFromData).safeTransfer(flRequest.receiver, assets);
        bytes32 result = IFlashLoanReceiver(flRequest.receiver).onFlashLoanReceived(tokenFromData, assets, 0, userData);
        if (result != FLASH_LOAN_SUCCESS) revert LibError.FlashLoanFailed();

        _pullAndApprove(tokenFromData, flRequest.receiver, assets, msg.sender);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FLASHLOAN CALLBACKS: ERC3156                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice ERC3156-compatible flash loan callback used by Silo and generic ERC3156 lenders.
    /// @dev Validates initiator, caller, token, and amount, then forwards funds to the receiver and
    /// invokes `onFlashLoanReceived`. Pulls repayment (amount + fee) back and approves the lender.
    /// @param initiator Must equal address(this) (the router itself initiated the flash loan).
    /// @param token Token borrowed.
    /// @param amount Amount borrowed.
    /// @param fee Fee charged by the lender.
    /// @param data ABI-encoded (token, amount, userData) passed through from `requestFlashLoan`.
    /// @return The ERC3156 flash loan success constant.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        PendingRequest memory flRequest = _pending;

        if (initiator != address(this)) revert LibError.InvalidInitiator();
        if (msg.sender != flRequest.lender) revert LibError.InvalidAction();
        if (token != flRequest.token) revert LibError.InvalidToken();
        if (amount != flRequest.amount) revert LibError.InvalidAmount();
        if (flRequest.receiver == address(0)) revert LibError.InvalidReceiver();

        (address tokenFromData, uint256 amountFromCallback, bytes memory userData) = abi.decode(
            data,
            (address, uint256, bytes)
        );

        if (tokenFromData != token) revert LibError.InvalidToken();
        if (amountFromCallback != flRequest.amount) revert LibError.InvalidAmount();

        IERC20(token).safeTransfer(flRequest.receiver, amount);
        bytes32 result = IFlashLoanReceiver(flRequest.receiver).onFlashLoanReceived(token, amount, fee, userData);
        if (result != FLASH_LOAN_SUCCESS) revert LibError.FlashLoanFailed();

        _pullAndApprove(token, flRequest.receiver, amount + fee, msg.sender);
        return FLASH_LOAN_SUCCESS;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  EXTERNAL FUNCTIONS: ADMIN                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Configure the flash loan source for a receiver (strategy).
    /// @dev Gated by `TIMELOCKED_ADMIN_ROLE`, so it goes through an external timelock
    /// @param receiver Address of the strategy allowed to call `requestFlashLoan`.
    /// @param source Flash loan provider type (Euler, Morpho, or ERC3156).
    /// @param lender Address of the lending protocol to route the flash loan through.
    /// @param enabled Whether flash loans are enabled for this receiver.
    function setFlashConfig(address receiver, FlashSource source, address lender, bool enabled) external {
        _validateRole(TIMELOCKED_ADMIN_ROLE, msg.sender);
        if (receiver == address(0) || lender == address(0)) revert LibError.InvalidAddress();
        flashConfig[receiver] = FlashConfig({source: source, lender: lender, enabled: enabled});
        emit FlashConfigUpdated(receiver, source, lender, enabled);
    }

    /// @notice Recovers any ERC20 tokens mistakenly sent to the router.
    /// @dev Reverts if a flash loan is currently in-flight. Gated by `MANAGEMENT_ROLE` so it
    /// can be invoked promptly without a timelock delay (mirrors `LeveragedStrategy._rescueTokens`).
    /// Tokens are sent to `msg.sender` so the caller (management EOA / multisig) custodies them
    /// @param _token Address of the token to rescue.
    function rescueTokens(address _token) external {
        _validateRole(MANAGEMENT_ROLE, msg.sender);

        if (_pending.receiver != address(0)) revert LibError.PendingActionExists();

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
        emit TokensRecovered(_token, amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               INTERNAL FUNCTIONS: HELPERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Pulls `repayAmount` of `token` from `from`, then approves `spender` to pull that amount.
    /// Used to pass the flash loan repayment from the receiver back to the underlying lender.
    function _pullAndApprove(address token, address from, uint256 repayAmount, address spender) private {
        // Transfer tokens from the receiver to the router, then approve the lender to pull the owed amount
        IERC20(token).safeTransferFrom(from, address(this), repayAmount);
        IERC20(token).forceApprove(spender, repayAmount);
    }

    /// @dev Reverts if the role manager is not set or the account does not hold the required role.
    /// @param role The role identifier to check.
    /// @param account The account to validate.
    function _validateRole(bytes32 role, address account) internal view {
        if (address(ROLE_MANAGER) == address(0)) revert LibError.RoleManagerNotSet();
        if (!ROLE_MANAGER.hasRole(role, account)) revert LibError.Unauthorized();
    }
}
