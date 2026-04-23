// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin-contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {LibError} from "../libraries/LibError.sol";
import {ICeresBaseVault} from "../interfaces/strategies/ICeresBaseVault.sol";

/// @title CeresBaseVault
/// @notice Base contract for all Ceres vaults and strategies supporting synchronous deposits and asynchronous withdrawals
/// inspired by ERC-7540 standard (does not implement all functions from the standard)
/// @dev The contract deliberately does not implement the `operator` logic from the standard
/// as the same can be achieved through ERC20 approval mechanism.
/// The process to claim redeem requests is permissionless once the request is processed.
abstract contract CeresBaseVault is
    Initializable,
    ERC20Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    ICeresBaseVault
{
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Constants
    uint16 internal constant BPS_PRECISION = 100_00; // 100% in basis points
    uint16 internal constant MAX_FEE = 50_00; // 50% in basis points

    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.CeresBaseVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CERES_BASE_VAULT_STORAGE_LOCATION =
        0xcf84ba3d07e58f36788a3ece95d1d2ee3856331b60f515242a4831ba768e4500;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.CeresBaseVault
    // prettier-ignore
    struct CeresBaseVaultStorage {
        // Slot 0
        // Mapping used to store the request ID specific data. Request is considered settled when pricePerShare is non-zero
        mapping(uint256 requestId => RequestDetails) requestDetails;

        // Slot 1
        // Per user redeem request mapping
        mapping(address user => UserRedeemRequest) userRedeemRequests;

        // Slot 2: 160 + 8 + 40 + 16 + 16 + 16 = 256 bits
        IERC20 asset;
        uint8 underlyingDecimals;
        uint40 lastReportTimestamp;
        uint16 maxSlippageBps;  // Used by inherited contracts, added here for tight storage packing
        uint16 performanceFeeBps;
        uint16 maxLossBps;

        // Slot 3: 256 bits
        // Store totalAssets (instead of erc20 balanceOf) to prevent price per share manipulation through airdrops
        uint256 totalAssets;

        // Slot 4: 128 + 128 = 256 bits
        // Assets reserved within the strategy to cover outstanding processed withdrawals.
        uint128 withdrawalReserve;
        uint128 currentRequestId;

        // Slot 5: 128 + 128 = 256 bits
        uint128 depositLimit;
        uint128 redeemLimitShares;

        // Slot 6: 128 + 128 = 256 bits
        // Tracks the cumulative net profit (profits - losses) reported by the strategy.
        // Used alongside snapshotNetProfit to determine chargeable profit for performance fees
        // This approach charges fees only on the net profit, and prevents double-charging fees on the same profit
        // in cases of subsequent losses after a profit is reported.
        int128 cumulativeNetProfit;
        int128 snapshotNetProfit;

        // Slot 7: 160 + 96 = 256 bits
        IAccessControlDefaultAdminRules roleManager;
        uint96 minDepositAmount;

        // Slot 8: 160 bits (96 bits free for future expansion)
        address performanceFeeRecipient;
    }

    function _getCeresBaseVaultStorage() private pure returns (CeresBaseVaultStorage storage S) {
        assembly {
            S.slot := CERES_BASE_VAULT_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        MODIFIERS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    modifier onlyRole(bytes32 role) {
        _validateRole(role, msg.sender);
        _;
    }

    function _validateRole(bytes32 role, address account) internal view {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        if (!S.roleManager.hasRole(role, account)) revert LibError.Unauthorized();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the base vault with asset, ERC20 metadata, and role manager.
    /// @param asset_ The underlying ERC20 deposit token.
    /// @param name_ ERC20 name for the vault share token.
    /// @param symbol_ ERC20 symbol for the vault share token.
    /// @param _roleManager Address of the RoleManager.
    function __CeresBaseVault_init(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address _roleManager
    ) internal onlyInitializing {
        __ERC20_init(name_, symbol_);
        __ReentrancyGuardTransient_init();
        __CeresBaseVault_init_unchained(asset_, _roleManager);
    }

    function __CeresBaseVault_init_unchained(IERC20 asset_, address _roleManager) internal onlyInitializing {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        S.asset = asset_;
        S.underlyingDecimals = IERC20Metadata(address(asset_)).decimals();

        if (_roleManager == address(0)) revert LibError.ZeroAddress();
        S.roleManager = IAccessControlDefaultAdminRules(_roleManager);

        S.currentRequestId = 1; // Start requestIds with 1
        S.lastReportTimestamp = uint40(block.timestamp);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          EXTERNAL FUNCTIONS: ERC4626                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the number of decimals for the vault share token.
    /// @dev Matches underlying asset decimals plus any configured offset.
    /// @return The number of decimals.
    function decimals() public view virtual override(IERC20Metadata, ERC20Upgradeable) returns (uint8) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        return S.underlyingDecimals + _decimalsOffset();
    }

    /// @notice Returns the address of the underlying deposit asset.
    /// @return Address of the underlying asset.
    function asset() public view virtual returns (address) {
        return address(_getCeresBaseVaultStorage().asset);
    }

    /// @notice Returns the total assets tracked by the vault.
    /// @dev Stored explicitly using internal accounting
    /// @return Total assets tracked by the vault.
    function totalAssets() public view virtual returns (uint256) {
        return _getCeresBaseVaultStorage().totalAssets;
    }

    /// @notice Converts an asset amount to vault shares using the current price, rounding down.
    /// @param assets Amount of underlying asset.
    /// @return Equivalent number of vault shares.
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Converts a share amount to underlying assets using the current price, rounding down.
    /// @param shares Number of vault shares.
    /// @return Equivalent amount of underlying asset.
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice Returns the maximum assets that can be deposited for the given receiver.
    /// @dev Bounded by the deposit limit minus current total assets.
    /// param receiver The address receiving the shares (ignored in calculation).
    /// @return Maximum assets that can be deposited.
    function maxDeposit(address /* receiver */) public view virtual returns (uint256) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        uint256 netAssets = totalAssets();
        uint256 _depositLimit = S.depositLimit;
        if (netAssets >= _depositLimit) return 0;

        return (_depositLimit - netAssets);
    }

    /// @notice Returns the maximum shares that can be minted for the given receiver.
    /// @param receiver The address receiving the minted shares.
    /// @return Maximum shares that can be minted.
    function maxMint(address receiver) public view virtual returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice Returns the maximum assets withdrawable by `owner_` from a claimable redeem request.
    /// @dev Calculated using the locked-in price-per-share from the processed request.
    /// @param owner_ The address that owns the claimable request.
    /// @return Maximum assets withdrawable.
    function maxWithdraw(address owner_) public view virtual returns (uint256) {
        (uint256 claimableShares, uint256 pps) = _getClaimableShares(owner_);
        if (claimableShares == 0) return 0;
        return _sharesToAssetsAtPrice(claimableShares, pps, Math.Rounding.Floor);
    }

    /// @notice Returns the maximum shares redeemable by `owner_` from a claimable request.
    /// @dev Capped by `redeemLimitShares` if set.
    /// @param owner_ The address that owns the claimable request.
    /// @return Maximum shares redeemable.
    function maxRedeem(address owner_) public view virtual returns (uint256) {
        (uint256 claimableShares, ) = _getClaimableShares(owner_);
        if (claimableShares == 0) return 0;

        // If there is no redeem limit, user can redeem all requested shares
        // else return the minimum of redeem limit and requested shares
        return Math.min(claimableShares, _getCeresBaseVaultStorage().redeemLimitShares);
    }

    /// @notice Returns the shares that would be minted for `assets` at the current price.
    /// @param assets Amount of assets.
    /// @return Shares that would be minted.
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Returns the assets required to mint `shares` at the current price, rounding up.
    /// @param shares Number of shares.
    /// @return Assets required to mint the shares.
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @notice Always reverts, async withdrawals cannot be previewed.
    /// param assets Ignored parameter.
    /// @return Cannot be evaluated; reverts securely.
    function previewWithdraw(uint256 /* assets */) public pure virtual override returns (uint256) {
        revert LibError.PreviewWithdrawDisabled();
    }

    /// @notice Always reverts, async withdrawals cannot be previewed.
    /// param shares Ignored parameter.
    /// @return Cannot be evaluated; reverts securely.
    function previewRedeem(uint256 /*shares */) public pure virtual override returns (uint256) {
        revert LibError.PreviewRedeemDisabled();
    }

    /// @notice Deposits `assets` and mints vault shares to `receiver`.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Address that receives the minted shares.
    /// @return shares The number of shares minted.
    function deposit(uint256 assets, address receiver) public virtual nonReentrant returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @notice Mints exactly `shares` vault shares to `receiver` by pulling the required assets.
    /// @param shares Number of shares to mint.
    /// @param receiver Address that receives the minted shares.
    /// @return assets The amount of underlying asset pulled from the caller.
    function mint(uint256 shares, address receiver) public virtual nonReentrant returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /// @notice Withdraws `assets` from the vault using a claimable redeem request.
    /// @dev Uses the locked-in price-per-share from the processed request, not the current price.
    /// Permissionless once the request is processed: anyone can call on behalf of `controller`
    /// provided the receiver is the controller when the caller is not the controller.
    /// @param assets The amount of underlying asset to withdraw.
    /// @param receiver Address that receives the assets.
    /// @param controller The address that owns the claimable request.
    /// @return sharesToBurn The number of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public virtual nonReentrant returns (uint256) {
        // When the caller is not the controller, enforce that the controller receives the claim
        // This design lets anyone execute the claim for the controller
        // making the claim process permissionless once it has been processed
        if (msg.sender != controller && receiver != controller) revert LibError.Unauthorized();

        (uint256 claimableShares, uint256 pps) = _getClaimableShares(controller);
        if (claimableShares == 0) revert LibError.WithdrawalNotReady();

        // Calculate shares to burn based on locked-in price
        uint256 sharesToBurn = _assetsToSharesAtPrice(assets, pps, Math.Rounding.Ceil);
        if (sharesToBurn > claimableShares) revert LibError.InsufficientShares();

        _withdraw(msg.sender, receiver, controller, assets, sharesToBurn);
        return sharesToBurn;
    }

    /// @notice Redeems `shares` from a claimable request and sends assets to `receiver`.
    /// @dev Uses the locked-in price-per-share from the processed request.
    /// Permissionless once the request is processed: anyone can call on behalf of `controller`
    /// provided the receiver is the controller when the caller is not the controller.
    /// @param shares Number of shares to redeem.
    /// @param receiver Address that receives the underlying assets.
    /// @param controller The address that owns the claimable request.
    /// @return assets The amount of underlying asset sent to `receiver`.
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public virtual nonReentrant returns (uint256) {
        // When the caller is not the controller, enforce that the controller receives the claim
        // This design lets anyone execute the claim for the controller
        // making the claim process permissionless once it has been processed
        if (msg.sender != controller && receiver != controller) revert LibError.Unauthorized();

        (uint256 claimableShares, uint256 pps) = _getClaimableShares(controller);
        if (claimableShares == 0) revert LibError.WithdrawalNotReady();
        if (shares > claimableShares) revert LibError.InsufficientShares();

        // Calculate assets using LOCKED-IN price from the request
        uint256 assets = _sharesToAssetsAtPrice(shares, pps, Math.Rounding.Floor);

        _withdraw(msg.sender, receiver, controller, assets, shares);
        return assets;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              EXTERNAL FUNCTIONS: ERC7540                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Submits an async withdrawal request for `shares`. Burns caller's shares and locks them
    /// in the vault contract until the request is processed by a keeper.
    /// @dev A user may only have one pending request at a time. Concurrent requests for the same
    /// `currentRequestId` are batched together.
    /// @param shares Number of shares to redeem.
    /// @param controller Address that will be able to claim the redeemed assets.
    /// @param owner_ Address whose shares are burned (caller must be owner or approved).
    /// @return requestId The current batch request ID this submission was added to.
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner_
    ) external virtual nonReentrant returns (uint256 requestId) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        if (shares == 0) revert LibError.ZeroShares();

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        // Lock the requested shares in the strategy contract until the request is processed.
        // Instead of using approve + transferFrom to move and lock the shares,
        // we burn them from the user and mint an equivalent amount to the strategy contract.
        // This approach tracks locked shares without requiring extra approvals or transfers to the vault.
        _burn(owner_, shares);
        _mint(address(this), shares);

        requestId = S.currentRequestId;

        // Update details for the current requestId
        RequestDetails storage details = S.requestDetails[requestId];
        details.totalShares += shares.toUint128();

        // Update user redeem request.
        UserRedeemRequest storage userRequest = S.userRedeemRequests[controller];

        // A user can only have a single pending redeem request at a time
        // userRequest.requestId == 0 -> No pending requests, set the requestId to currentRequestId
        // userRequest.requestId == currentRequestId -> Existing pending request for the same requestId
        // If user has an existing pending redeem request for a different requestId, revert
        if (userRequest.requestId == 0) {
            userRequest.requestId = uint128(requestId);
        }
        if (userRequest.requestId != requestId) revert LibError.ExistingPendingRedeemRequest();

        // Update requested shares for user redeem request
        userRequest.shares += shares.toUint128();

        // Enforce redeem limit per user
        if (userRequest.shares > S.redeemLimitShares) revert LibError.ExceedsRedeemLimit();

        emit RedeemRequest(controller, owner_, requestId, msg.sender, shares);
    }

    /// @notice Returns the number of shares pending (not yet processed) for a given requestId and controller.
    /// @param requestId The batch request ID to check.
    /// @param controller The address whose pending shares are queried.
    /// @return pendingShares The number of shares still pending, or 0 if the request is processed.
    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) external view virtual returns (uint256 pendingShares) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        RequestDetails memory details = S.requestDetails[requestId];
        UserRedeemRequest memory userRequest = S.userRedeemRequests[controller];

        // Return 0 if the controller's request is not for this requestId
        if (userRequest.requestId != requestId) return 0;

        // If pricePerShare for the requestId is zero, it means that the request is not yet processed
        // and all requested shares for this requestId/controller combination are pending
        if (details.pricePerShare == 0) return userRequest.shares;
        pendingShares = 0;
    }

    /// @notice Returns the number of claimable shares for a specific requestId and controller.
    /// @param requestId The batch request ID to check.
    /// @param controller The address to query.
    /// @return claimableShares Number of shares claimable, or 0 if not yet processed.
    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view virtual returns (uint256 claimableShares) {
        (claimableShares, ) = _getClaimableShares(requestId, controller);
    }

    /// @notice Returns the total claimable shares for a controller across their active request.
    /// @param controller The address to query.
    /// @return claimableShares Number of shares claimable by the controller.
    function claimableRedeemRequest(address controller) external view virtual returns (uint256 claimableShares) {
        (claimableShares, ) = _getClaimableShares(controller);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS: STRATEGY OPERATIONS                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Processes the current batch redeem request by setting a price-per-share and reserving assets.
    /// @dev Calls `_onProcessRequest` hook first (harvest/report for strategies, refresh for multi-vault).
    /// Attempts to free funds via `_freeFunds` if insufficient idle assets exist. Validates max loss.
    /// @param extraData Protocol-specific data forwarded to `_freeFunds` (e.g. swap and flash loan calldata).
    function processCurrentRequest(bytes calldata extraData) external virtual nonReentrant onlyRole(KEEPER_ROLE) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        // Pre-Processing Hook
        // Delegates to the child contract to update state before processing the current request.
        // For Yield Strategies: Calls _harvestAndReport() to compound yield and charge performance fees.
        // For Multi-Strategy Vaults: Syncs aggregate TVL or handles custom multi-allocator logic.
        _onProcessRequest(extraData);

        // Cache currentRequestId to avoid multiple SLOADs
        uint256 _currentRequestId = S.currentRequestId;

        RequestDetails storage request = S.requestDetails[_currentRequestId];
        if (request.pricePerShare != 0) revert LibError.AlreadyProcessed();
        if (request.totalShares == 0) revert LibError.NoRequestsToProcess();

        uint256 expectedAssets = _convertToAssets(request.totalShares, Math.Rounding.Floor);

        // Available assets = contract balance minus assets reserved for processed withdrawals
        uint256 availableAssets = _getSelfBalance(S.asset) - S.withdrawalReserve;

        uint256 assetsAllocatedForRequest;

        // For Strategies, if required assets are more than available, try to free the required amount using _freeFunds()
        // otherwise, we have enough available assets to cover the request
        // For a multi-strategy vault, it is dependent on keepers having already pulled funds from allocated strategies
        // into this contract by calling requestRedeem and redeem functions
        // _freeFunds returns 0 for multi-strategy vaults, as it cannot pull funds directly from async strategies

        if (expectedAssets > availableAssets) {
            uint256 amountToFree = expectedAssets - availableAssets;

            // For a multi-strategy async vault, this will return 0 as it cannot synchronously pull funds from allocated strategies
            uint256 actualReceived = _freeFunds(amountToFree, extraData);
            assetsAllocatedForRequest = availableAssets + actualReceived;
        } else {
            assetsAllocatedForRequest = expectedAssets;
        }

        // Max loss check
        // Validate that actual assets allocated for the request is within maxLoss threshold
        if (assetsAllocatedForRequest < expectedAssets) {
            uint256 loss = expectedAssets - assetsAllocatedForRequest;
            if (loss.mulDiv(BPS_PRECISION, expectedAssets) > S.maxLossBps) {
                revert LibError.ExceededMaxLoss();
            }
        }

        // Price per share is calculated based on the total shares and assets allocated for this request
        // Assets allocated to this request = the idle assets allocated + Actual assets freed from the strategy
        // This is because the actual assets freed could be less than required assets due to slippage
        uint256 pps = assetsAllocatedForRequest.mulDiv(10 ** decimals(), request.totalShares, Math.Rounding.Floor);
        if (pps == 0) revert LibError.ExceededMaxLoss();

        request.pricePerShare = pps.toUint128();

        // Calculate the exact assets required to pay out all shares at the floor-rounded PPS.
        // Adding `assetsAllocatedForRequest` directly would trap up to `totalShares / 10**decimals`
        // in the reserve due to truncation (which can be meaningful for low-decimal tokens like USDC).
        // By adding only `exactRequiredAssets`, the dust remains in `totalAssets` as profit.
        uint256 exactRequiredAssets = uint256(request.totalShares).mulDiv(pps, 10 ** decimals(), Math.Rounding.Floor);
        S.withdrawalReserve += exactRequiredAssets.toUint128();

        // The shares for processed requests are burned.
        // The corresponding assets are tracked (and locked) using `S.withdrawalReserve`
        // This makes sure both shares and assets are removed from active calculation
        // as they do not earn yield and are locked at processed price per share.
        _burn(address(this), request.totalShares);

        // requestId cannot realistically overflow uint128, SafeCast.toUint128 is not required here
        S.currentRequestId = uint128(_currentRequestId + 1);
        S.totalAssets = _reportTotalAssets();

        emit RequestProcessed(_currentRequestId, request.totalShares, pps);
    }

    /// @notice Triggers a yield harvest and updates total assets, charging performance fees on net profit.
    /// @return profit Assets gained since the last report.
    /// @return loss Assets lost since the last report.
    function harvestAndReport()
        external
        virtual
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 profit, uint256 loss)
    {
        return _harvestAndReport();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS: ADMIN FUNCTIONS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Updates vault fee and slippage configuration.
    /// @dev Gated by `TIMELOCKED_ADMIN_ROLE`, can only be updated after a delay
    /// @param _maxSlippageBps Maximum allowed swap slippage in basis points.
    /// @param _performanceFeeBps Performance fee rate in basis points.
    /// @param _maxLossBps Maximum tolerated loss when processing a redeem batch, in basis points.
    /// @param _performanceFeeRecipient Address that receives minted performance fee shares (ignored if zero).
    function updateConfig(
        uint16 _maxSlippageBps,
        uint16 _performanceFeeBps,
        uint16 _maxLossBps,
        address _performanceFeeRecipient
    ) external virtual onlyRole(TIMELOCKED_ADMIN_ROLE) {
        if (_maxSlippageBps > MAX_FEE || _performanceFeeBps > MAX_FEE || _maxLossBps > MAX_FEE) {
            revert LibError.InvalidValue();
        }

        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        S.maxSlippageBps = _maxSlippageBps;
        S.performanceFeeBps = _performanceFeeBps;
        S.maxLossBps = _maxLossBps;

        if (_performanceFeeRecipient != address(0)) {
            S.performanceFeeRecipient = _performanceFeeRecipient;
        }

        emit ConfigUpdated();
    }

    /// @notice Sets deposit cap, per-user redeem limit, and minimum deposit amount.
    /// @param _depositLimit Maximum total assets the vault will accept.
    /// @param _redeemLimit Maximum shares a single user can have in a pending redeem request.
    /// @param _minDepositAmount Minimum deposit amount enforced on each deposit call.
    function setDepositWithdrawLimits(
        uint128 _depositLimit,
        uint128 _redeemLimit,
        uint96 _minDepositAmount
    ) external virtual onlyRole(MANAGEMENT_ROLE) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        S.depositLimit = _depositLimit;
        S.redeemLimitShares = _redeemLimit;
        S.minDepositAmount = _minDepositAmount;
        emit ConfigUpdated();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               EXTERNAL FUNCTIONS: GETTERS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the details of a specific batch redeem request.
    /// @param requestId The batch request ID.
    /// @return The RequestDetails struct holding the state of the request.
    function requestDetails(uint256 requestId) public view virtual returns (RequestDetails memory) {
        return _getCeresBaseVaultStorage().requestDetails[requestId];
    }

    /// @notice Returns the pending redeem request details for a given user.
    /// @param user The user whose request is queried.
    /// @return The UserRedeemRequest struct holding the user's requested shares.
    function userRedeemRequests(address user) public view virtual returns (UserRedeemRequest memory) {
        return _getCeresBaseVaultStorage().userRedeemRequests[user];
    }

    /// @notice Returns the amount of assets reserved to cover outstanding processed withdrawal requests.
    /// @return The amount of assets in the reserve.
    function withdrawalReserve() public view virtual returns (uint128) {
        return _getCeresBaseVaultStorage().withdrawalReserve;
    }

    /// @notice Returns the current batch request ID that new redeem requests are added to.
    /// @return The current request ID.
    function currentRequestId() public view virtual returns (uint128) {
        return _getCeresBaseVaultStorage().currentRequestId;
    }

    /// @notice Returns the configured deposit and redeem limits.
    /// @return depositLimit The maximum total assets the vault will accept.
    /// @return redeemLimitShares The maximum shares a user can have pending redemption.
    /// @return minDepositAmount The minimum required deposit.
    function getDepositWithdrawLimits()
        external
        view
        virtual
        returns (uint128 depositLimit, uint128 redeemLimitShares, uint128 minDepositAmount)
    {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        depositLimit = S.depositLimit;
        redeemLimitShares = S.redeemLimitShares;
        minDepositAmount = S.minDepositAmount;
    }

    /// @notice Returns the current vault configuration.
    /// @return maxSlippageBps The maximum allowed slippage.
    /// @return performanceFeeBps The performance fee basis points.
    /// @return maxLossBps The maximum acceptable loss basis points.
    /// @return lastReportTimestamp The timestamp of the last strategy harvest execution.
    /// @return performanceFeeRecipient The receiver address of harvested fees.
    /// @return roleManager Address of the role manager.
    function getConfig()
        external
        view
        virtual
        returns (
            uint16 maxSlippageBps,
            uint16 performanceFeeBps,
            uint16 maxLossBps,
            uint48 lastReportTimestamp,
            address performanceFeeRecipient,
            address roleManager
        )
    {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        maxSlippageBps = S.maxSlippageBps;
        performanceFeeBps = S.performanceFeeBps;
        maxLossBps = S.maxLossBps;
        lastReportTimestamp = S.lastReportTimestamp;
        performanceFeeRecipient = S.performanceFeeRecipient;
        roleManager = address(S.roleManager);
    }

    /// @notice Returns cumulative and snapshot net profit trackers used for performance fee accounting.
    /// @return cumulativeNetProfit The total cumulative net profit.
    /// @return snapshotNetProfit The high water mark net profit.
    function getStats() external view virtual returns (int128 cumulativeNetProfit, int128 snapshotNetProfit) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        cumulativeNetProfit = S.cumulativeNetProfit;
        snapshotNetProfit = S.snapshotNetProfit;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                            INTERNAL FUNCTIONS: ERC4626                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Converts assets to shares using stored totalAssets and totalSupply, with virtual offset protection.
    /// @param assets The amount of underlying assets.
    /// @param rounding The rounding direction.
    /// @return Equivalent number of vault shares.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @dev Converts shares to assets using stored totalAssets and totalSupply, with virtual offset protection.
    /// @param shares The number of vault shares.
    /// @param rounding The rounding direction.
    /// @return Equivalent amount of underlying assets.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev Executes a deposit: transfers assets in, deploys funds, updates totalAssets, and mints shares.
    /// @param caller The address executing the deposit.
    /// @param receiver The address receiving the shares.
    /// @param assets The amount of underlying assets.
    /// @param shares The amount of minted shares.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        if (assets < S.minDepositAmount || assets == 0) revert LibError.BelowMinimumDeposit();
        if (assets > maxDeposit(receiver)) revert LibError.ExceedsDepositLimit();

        S.asset.safeTransferFrom(caller, address(this), assets);

        _deployFunds(assets);
        S.totalAssets += assets;

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Burns locked shares, transfers reserved assets to receiver, and clears the user's redeem request state.
    /// @param caller The address executing the claim.
    /// @param receiver The address receiving the assets.
    /// @param owner_ The address owning the claimable shares.
    /// @param assets The amount of assets to claim.
    /// @param shares The amount of requested shares to resolve and burn.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        // Check if the contract has enough underlying assets to cover the withdrawal
        uint256 currentAssets = _getSelfBalance(S.asset);
        if (currentAssets < assets) revert LibError.InsufficientAssets();

        S.userRedeemRequests[owner_].shares -= shares.toUint128();
        if (S.userRedeemRequests[owner_].shares == 0) {
            // Reset requestId to 0 when there are no pending shares
            S.userRedeemRequests[owner_].requestId = 0;
        }

        S.withdrawalReserve -= assets.toUint128();

        S.asset.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @notice Returns the decimal offset for shares compared to assets, protecting against inflation attacks.
    /// @dev Defaults to 0 for standard setup.
    /// @return The decimal offset.
    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             INTERNAL HELPER FUNCTIONS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Re-reads totalAssets from the underlying protocol and updates stored state.
    /// @return prevAssets The stored total assets before the refresh.
    /// @return currentAssets The newly computed total assets.
    function _refreshTotalAssets() internal virtual returns (uint256 prevAssets, uint256 currentAssets) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        prevAssets = S.totalAssets;
        currentAssets = _reportTotalAssets();

        S.totalAssets = currentAssets;
        S.lastReportTimestamp = uint40(block.timestamp);
    }

    /// @dev Computes profit/loss from an asset change and updates the cumulative net profit tracker.
    /// Returns the chargeable profit (the portion of profit that exceeds the snapshot net profit).
    /// @param prevAssets Total assets before the latest report.
    /// @param currentAssets Total assets after the latest report.
    /// @return profit Gross profit since the last report.
    /// @return chargeableProfit Profit on which performance fees should be charged.
    /// @return loss Gross loss since the last report.
    function _calculateProfitOrLoss(
        uint256 prevAssets,
        uint256 currentAssets
    ) internal virtual returns (uint256 profit, uint256 chargeableProfit, uint256 loss) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        // Cache storage variables
        int128 cumulative = S.cumulativeNetProfit;
        int128 snapshot = S.snapshotNetProfit;

        if (currentAssets > prevAssets) {
            profit = currentAssets - prevAssets;
            cumulative += int128(profit.toUint128());
        } else {
            loss = prevAssets - currentAssets;
            cumulative -= int128(loss.toUint128());
        }

        S.cumulativeNetProfit = cumulative;

        // Only charge fees on profit that takes cumulative net profit above the snapshotNetProfit.
        // This tracks strategy-level performance directly, and ensures that fees are only charged on actual net profits,
        // preventing fee charges on the same profit multiple times in case of subsequent losses after a profit is reported.
        if (cumulative > snapshot) {
            chargeableProfit = uint256(int256(cumulative - snapshot));
            S.snapshotNetProfit = cumulative;
        }
    }

    /// @dev Refreshes total assets, calculates profit/loss, and mints performance fee shares.
    /// @return profit Gross profit since the last report.
    /// @return loss Gross loss since the last report.
    function _harvestAndReport() internal virtual returns (uint256 profit, uint256 loss) {
        (uint256 prevAssets, uint256 currentAssets) = _refreshTotalAssets();

        // Skip profit/loss tracking and fee logic when nothing changed
        if (prevAssets == currentAssets) {
            emit StrategyReported(msg.sender, 0, 0, 0);
            return (0, 0);
        }

        uint256 chargeableProfit;
        (profit, chargeableProfit, loss) = _calculateProfitOrLoss(prevAssets, currentAssets);

        uint256 performanceFees = _chargeFees(chargeableProfit, currentAssets);
        emit StrategyReported(msg.sender, profit, loss, performanceFees);
    }

    /// @dev Mints performance fee shares to the fee recipient proportional to `chargeableProfit`.
    /// @param chargeableProfit Net profit on which fees are charged.
    /// @param currentAssets Current total assets, used to calculate the share dilution.
    /// @return performanceFees Gross asset value of the fees charged.
    function _chargeFees(
        uint256 chargeableProfit,
        uint256 currentAssets
    ) internal virtual returns (uint256 performanceFees) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        uint16 performanceFeeBps = S.performanceFeeBps;

        if (chargeableProfit == 0 || performanceFeeBps == 0 || S.performanceFeeRecipient == address(0)) return 0;

        performanceFees = chargeableProfit.mulDiv(performanceFeeBps, BPS_PRECISION, Math.Rounding.Ceil);

        // Calculate shares to mint such that fee recipient gets performanceFees worth of assets
        uint256 performanceFeeShares = performanceFees.mulDiv(
            totalSupply(),
            currentAssets - performanceFees,
            Math.Rounding.Ceil
        );

        // Mint performance fee shares to the performance fee receiver
        _mint(S.performanceFeeRecipient, performanceFeeShares);
    }

    /// @dev Returns claimable shares and the locked-in price-per-share for a controller's active request.
    /// Returns (0, 0) if the request has not been processed yet.
    /// @param controller The user whose claimable shares are queried.
    /// @return claimableShares The amount of shares claimable.
    /// @return pricePerShare The locked-in price per share.
    function _getClaimableShares(
        address controller
    ) internal view virtual returns (uint256 claimableShares, uint256 pricePerShare) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        UserRedeemRequest memory userRequest = S.userRedeemRequests[controller];
        RequestDetails memory details = S.requestDetails[userRequest.requestId];

        // If pricePerShare for the requestId is not set (zero), it means that the request is not yet processed
        // and no shares are claimable (all shares are still pending or there is no request)
        if (details.pricePerShare == 0) return (0, 0);

        claimableShares = userRequest.shares;
        pricePerShare = details.pricePerShare;
    }

    /// @dev Returns claimable shares and locked-in price-per-share for a specific requestId and controller.
    /// Returns (0, 0) if the controller's request does not match `requestId` or is unprocessed.
    /// @param requestId The ID of the redeem request.
    /// @param controller The user whose claimable shares are queried.
    /// @return claimableShares The amount of shares claimable.
    /// @return pricePerShare The locked-in price per share.
    function _getClaimableShares(
        uint256 requestId,
        address controller
    ) internal view virtual returns (uint256 claimableShares, uint256 pricePerShare) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        // Return 0 if no requestId exists for the user or if the requestId does not match
        if (S.userRedeemRequests[controller].requestId != requestId) return (0, 0);

        return _getClaimableShares(controller);
    }

    /// @dev Converts an asset amount to shares at a specific (locked-in) price-per-share.
    /// @param assets The amount of underlying assets.
    /// @param pricePerShare The locked-in price per share used for conversion.
    /// @param rounding The rounding direction.
    /// @return shares Equivalent number of vault shares.
    function _assetsToSharesAtPrice(
        uint256 assets,
        uint256 pricePerShare,
        Math.Rounding rounding
    ) internal view returns (uint256 shares) {
        shares = assets.mulDiv(10 ** decimals(), pricePerShare, rounding);
    }

    /// @dev Converts a share amount to assets at a specific (locked-in) price-per-share.
    /// @param shares The number of vault shares.
    /// @param pricePerShare The locked-in price per share used for conversion.
    /// @param rounding The rounding direction.
    /// @return assets Equivalent amount of underlying assets.
    function _sharesToAssetsAtPrice(
        uint256 shares,
        uint256 pricePerShare,
        Math.Rounding rounding
    ) internal view returns (uint256 assets) {
        assets = shares.mulDiv(pricePerShare, 10 ** decimals(), rounding);
    }

    /// @dev Returns this contract's balance of `_token`.
    /// @param _token The IERC20 token contract.
    /// @return The token balance of this contract.
    function _getSelfBalance(IERC20 _token) internal view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    /// @dev Applies `maxSlippageBps` to `amount`. If `addBuffer` is true, adds the slippage amount;
    /// otherwise subtracts it, giving a minimum acceptable output.
    /// @param amount Baseline amount.
    /// @param addBuffer If true add the slippage amount, otherwise subtract.
    /// @return The adjusted output amount.
    function _adjustForSlippage(uint256 amount, bool addBuffer) internal view virtual returns (uint256) {
        uint256 slippageAmount = amount.mulDiv(
            uint256(_getCeresBaseVaultStorage().maxSlippageBps),
            uint256(BPS_PRECISION)
        );
        return addBuffer ? amount + slippageAmount : amount - slippageAmount;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   VIRTUAL FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Hook to execute any logic required before processing a batch request.
    /// Inherited contracts should use this to harvest rewards and charge performance fees.
    /// @param extraData Encoded metadata needed for processing.
    function _onProcessRequest(bytes calldata extraData) internal virtual;

    /// @dev Deploys assets into the underlying protocol or child strategies after a deposit.
    /// @param _amount The amount of underlying assets to deploy.
    function _deployFunds(uint256 _amount) internal virtual;

    /// @dev Returns the current total assets of the vault as computed from the underlying protocol.
    /// @dev NOTE: MUST report net assets strictly excluding `withdrawalReserve()`.
    /// The reserve holds finalized, locked funds assigned to pending withdrawals.
    /// @return _totalAssets The newly computed total assets value.
    function _reportTotalAssets() internal virtual returns (uint256 _totalAssets);

    /// @dev Attempts to withdraw `_amount` from the underlying protocol to cover a redeem request.
    /// @param _amount The amount of underlying assets to free.
    /// @param extraData Encoded specific extra instructions / metadata.
    /// @return actualFreed The actual amount freed (may be less than `_amount` due to slippage).
    function _freeFunds(uint256 _amount, bytes calldata extraData) internal virtual returns (uint256 actualFreed);
}
