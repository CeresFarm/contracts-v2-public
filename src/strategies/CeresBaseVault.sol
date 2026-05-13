// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

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
    uint32 internal constant MAX_PROFIT_UNLOCK_PERIOD = 30 days;

    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");
    bytes32 internal constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

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
        // Store realizedAssets (instead of real-time erc20 balanceOf)
        // Represents the raw, last-reported asset value of the vault. The user-visible totalAssets() view
        // subtracts any still-locked profit from this baseline
        uint256 realizedAssets;

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

        // Slot 9: 128 + 40 + 32 = 200 bits (56 bits free for future expansion)
        // Linear profit unlock buffer (Yearn V2 style). Reported profit (net of performance fees)
        // is added to lockedProfit and decays linearly over profitUnlockPeriod, prevents against
        // Just-In-Time (JIT) deposit-redeem extraction of yield.
        uint128 lockedProfit;
        uint40 lastProfitReport;
        uint32 profitUnlockPeriod;
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
        S.profitUnlockPeriod = uint32(1 days);
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

    /// @notice Returns the total assets tracked by the vault, net of any still-locked profit buffer.
    /// @dev Returns `realizedAssets - currentlyLockedProfit`. The locked profit decays linearly to zero
    /// over `profitUnlockPeriod`, smoothing yield into price-per-share and defending against JIT
    /// deposit-redeem extraction of harvested yield.
    /// @return Total assets attributable to share holders at the current block.
    function totalAssets() public view virtual returns (uint256) {
        // Invariant maintained by _updateLockedProfit: realizedAssets >= _calculateLockedProfit().
        // Relying on checked arithmetic ensures any future refactor that breaks this invariant
        // surfaces immediately as a revert rather than silently corrupting price-per-share.
        return _getCeresBaseVaultStorage().realizedAssets - _calculateLockedProfit();
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
    /// @dev Bounded by the deposit limit minus current realized assets.
    /// Reads `realizedAssets` directly (NOT the unlocked `totalAssets()` view) so that the
    /// configured `depositLimit` enforces a cap on the vault's actual holdings. Using the
    /// unlocked view would let depositors mint over the cap during a profit-unlock window
    /// because the view temporarily understates holdings by the still-locked amount.
    /// param receiver The address receiving the shares (ignored in calculation).
    /// @return Maximum assets that can be deposited.
    function maxDeposit(address /* receiver */) public view virtual returns (uint256) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        uint256 realized = S.realizedAssets;
        uint256 _depositLimit = S.depositLimit;
        if (realized >= _depositLimit) return 0;

        return (_depositLimit - realized);
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
        return _sharesToAssetsAtPrice(claimableShares, pps, Math.Rounding.Floor);
    }

    /// @notice Returns the maximum shares redeemable by `owner_` from a claimable request.
    /// @param owner_ The address that owns the claimable request.
    /// @return claimableShares Maximum shares redeemable.
    function maxRedeem(address owner_) public view virtual returns (uint256 claimableShares) {
        (claimableShares, ) = _getClaimableShares(owner_);
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
    /// @param assets The amount of underlying asset to withdraw.
    /// @param receiver Address that receives the assets.
    /// @param controller The address that owns the claimable request.
    /// @return sharesToBurn The number of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public virtual nonReentrant returns (uint256) {
        // Enforce that only the controller can claim their processed withdrawal
        if (msg.sender != controller) revert LibError.Unauthorized();

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
    /// @param shares Number of shares to redeem.
    /// @param receiver Address that receives the underlying assets.
    /// @param controller The address that owns the claimable request.
    /// @return assets The amount of underlying asset sent to `receiver`.
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public virtual nonReentrant returns (uint256) {
        // Enforce that only the controller can claim their processed withdrawal
        if (msg.sender != controller) revert LibError.Unauthorized();

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
    /// @dev Capped by `redeemLimitShares` if set.
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

        // Transfer the shares from the user address to the contract to lock them until the request is processed.
        _transfer(owner_, address(this), shares);

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
    /// @dev Calls `_beforeProcessReport()` hook first (used in LeveragedStrategy child contract to implement keeper delay)
    ///  and then `_processReport()` to refresh accounting, charge performance fees, and update the profit-unlock
    /// buffer before settlement. Attempts to free funds via `_freeFunds` if insufficient idle assets
    /// exist. Validates max loss.
    /// @param extraData Protocol-specific data forwarded to `_freeFunds` (e.g. swap and flash loan calldata).
    /// In case of leveraged strategy, this is
    /// extraData: abi.encode(uint256 flashLoanAmount, bytes flashLoanSwapData, bytes collateralToAssetSwapData)
    function processCurrentRequest(bytes calldata extraData) external virtual nonReentrant onlyRole(KEEPER_ROLE) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        // Pre-report hook: (LeveragedStrategy implements the keeper delay here).
        // Default implementation is a no-op.
        _beforeProcessReport();

        // Unified report: refreshes realizedAssets, computes profit/loss, charges performance
        // fees, and updates the profit-unlock buffer.
        _processReport();

        // Cache currentRequestId to avoid multiple SLOADs
        uint256 _currentRequestId = S.currentRequestId;

        RequestDetails storage request = S.requestDetails[_currentRequestId];
        if (request.pricePerShare != 0) revert LibError.AlreadyProcessed();
        if (request.totalShares == 0) revert LibError.NoRequestsToProcess();

        uint256 expectedAssets = _convertToAssets(request.totalShares, Math.Rounding.Floor);
        uint256 grossAssetBalance = _getSelfBalance(S.asset);

        // Available assets = contract balance minus assets reserved for processed withdrawals
        uint256 availableAssets = grossAssetBalance - S.withdrawalReserve;

        uint256 assetsAllocatedForRequest;
        // Use Top-Down accounting for loss-calculation during unwind:
        // Any drop in net assets across `_freeFunds` (slippage, FL fees, oracle/AMM divergence, deleveraging cost)
        //  is borne by the withdrawing user, not the remaining holders.
        // The baseline (`realizedAssets`) is then reduced by the exact change
        // so the next `_processReport` reports zero phantom PnL.
        uint256 unwindLoss;

        // For Strategies, if required assets are more than available, try to free the required amount using _freeFunds()
        // otherwise, we have enough available assets to cover the request
        // For a multi-strategy vault, it is dependent on keepers having already pulled funds from allocated strategies
        // into this contract by calling requestRedeem and redeem functions
        // _freeFunds is a no-op for multi-strategy vaults, as it cannot pull funds directly from async strategies

        if (expectedAssets > availableAssets) {
            uint256 amountToFree = expectedAssets - availableAssets;

            // `netAssetsBefore` is the just-refreshed `realizedAssets` from `_processReport()` above;
            // reusing it avoids a redundant oracle/market read.
            uint256 netAssetsBefore = S.realizedAssets;
            uint256 assetBalanceBefore = grossAssetBalance;

            // For a multi-strategy async vault, this is a no-op as it cannot synchronously pull funds from allocated strategies.
            // Return value is intentionally ignored: net asset and balance deltas below are the source of truth.
            _freeFunds(amountToFree, extraData);

            uint256 netAssetsAfter = _reportTotalAssets();
            uint256 assetBalanceAfter = _getSelfBalance(S.asset);

            // Total cost of the unwind in net-asset terms (slippage + FL fees(if any) + oracle/AMM divergence).
            // A profitable unwind (e.g. positive slippage, exactIn buffer or favorable oracle move)
            // contributes 0 here and surfaces as positive PnL on the next harvest.
            unwindLoss = netAssetsBefore > netAssetsAfter ? netAssetsBefore - netAssetsAfter : 0;

            // Assets actually freed into idle balance during this call.
            // `withdrawalReserve` does not mutate between snapshots, so the raw balance delta is correct.
            uint256 actualFreed = assetBalanceAfter - assetBalanceBefore;

            // Withdrawing user absorbs `unwindLoss` from their expectation.
            uint256 expectedAfterLoss = expectedAssets > unwindLoss ? expectedAssets - unwindLoss : 0;

            // Cap by physical cash on hand (LTV/partial-unwind paths may free less than `expectedAfterLoss`).
            assetsAllocatedForRequest = Math.min(availableAssets + actualFreed, expectedAfterLoss);
        } else {
            assetsAllocatedForRequest = expectedAssets;
        }

        // Max loss check
        // Validate that actual assets allocated for the request is within maxLoss threshold.
        // The gap below `expectedAssets` reflects the full cost the user needs to absorb
        // (slippage + FL fees + oracle/AMM divergence).
        if (assetsAllocatedForRequest < expectedAssets) {
            uint256 loss = expectedAssets - assetsAllocatedForRequest;
            if (loss.mulDiv(BPS_PRECISION, expectedAssets) > S.maxLossBps) {
                revert LibError.ExceededMaxLoss();
            }
        }

        uint256 ONE_TOKEN_UNIT = 10 ** decimals();

        // Price per share is calculated based on the total shares and assets allocated for this request
        // Assets allocated to this request = the idle assets allocated + Actual assets freed from the strategy
        // This is because the actual assets freed could be less than required assets due to slippage
        uint256 pps = assetsAllocatedForRequest.mulDiv(ONE_TOKEN_UNIT, request.totalShares, Math.Rounding.Floor);
        if (pps == 0) revert LibError.ExceededMaxLoss();

        request.pricePerShare = pps.toUint128();

        // Calculate the exact assets required to pay out all shares at the floor-rounded PPS.
        // Adding `assetsAllocatedForRequest` directly would trap up to `totalShares / 10**decimals`
        // in the reserve due to truncation (which can be meaningful for low-decimal tokens like USDC).
        // By adding only `exactRequiredAssets`, the dust remains in `totalAssets` as profit.
        uint256 exactRequiredAssets = uint256(request.totalShares).mulDiv(pps, ONE_TOKEN_UNIT, Math.Rounding.Floor);
        S.withdrawalReserve += exactRequiredAssets.toUint128();

        // The shares for processed requests are burned.
        // The corresponding assets are tracked (and locked) using `S.withdrawalReserve`
        // This makes sure both shares and assets are removed from active calculation
        // as they do not earn yield and are locked at processed price per share.
        _burn(address(this), request.totalShares);

        // requestId cannot realistically overflow uint128, SafeCast.toUint128 is not required here
        S.currentRequestId = uint128(_currentRequestId + 1);

        // Reduce `realizedAssets` by the exact net-asset change caused by
        // this request:
        // - The assets allocated to the user (now sitting in `withdrawalReserve` and
        // outside `_reportTotalAssets`)
        // - The `unwindLoss` consumed by the unwind.
        // This makes the next `_processReport` see a baseline that matches actuals,
        // so no phantom profit/loss is reported.
        S.realizedAssets -= (assetsAllocatedForRequest + unwindLoss).toUint128();

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
        return _processReport();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS: ADMIN FUNCTIONS                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Updates vault fee, slippage, and profit-unlock configuration.
    /// @dev Gated by `TIMELOCKED_ADMIN_ROLE`, can only be updated after a delay.
    /// Before updating `profitUnlockPeriod`, the still-locked portion of `lockedProfit` is
    /// settled via `_settleLockedProfit()` so that already-unlocked yield stays unlocked
    /// and the remaining buffer simply re-decays from `block.timestamp` over the new
    /// period. This eliminates both flash-up (period decrease/disable) and flash-down (period
    /// increase) jumps in `totalAssets()` across the config change.
    /// For instant unlocks for future harvests, set the `_profitUnlockPeriod = 0`
    /// To avoid a JIT-attackable yield bump from any in-flight buffer, admins should ramp the
    /// period down gradually rather than jumping straight to 0
    /// @param _maxSlippageBps Maximum allowed swap slippage in basis points.
    /// @param _performanceFeeBps Performance fee rate in basis points.
    /// @param _maxLossBps Maximum tolerated loss when processing a redeem batch, in basis points.
    ///        This bounds the *total* user-visible shortfall: swap slippage + flashloan fees + oracle/AMM
    ///        divergence (e.g., Oracle lag vs AMM execution price). Must be set to cover all three components
    /// @param _performanceFeeRecipient Address that receives minted performance fee shares. Set to address(0) to disable fees.
    /// @param _profitUnlockPeriod Linear decay period (seconds) for harvested profit. Must not exceed `MAX_PROFIT_UNLOCK_PERIOD`. Set to 0 to disable the unlock buffer (instant unlocks).
    function updateConfig(
        uint16 _maxSlippageBps,
        uint16 _performanceFeeBps,
        uint16 _maxLossBps,
        address _performanceFeeRecipient,
        uint32 _profitUnlockPeriod
    ) external virtual onlyRole(TIMELOCKED_ADMIN_ROLE) {
        if (
            _maxSlippageBps > MAX_FEE ||
            _performanceFeeBps > MAX_FEE ||
            _maxLossBps > MAX_FEE ||
            _profitUnlockPeriod > MAX_PROFIT_UNLOCK_PERIOD
        ) {
            revert LibError.InvalidValue();
        }

        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        S.maxSlippageBps = _maxSlippageBps;
        S.performanceFeeBps = _performanceFeeBps;
        S.maxLossBps = _maxLossBps;
        S.performanceFeeRecipient = _performanceFeeRecipient;

        if (_profitUnlockPeriod != S.profitUnlockPeriod) {
            _settleLockedProfit();
            S.profitUnlockPeriod = _profitUnlockPeriod;
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
    /// @return profitUnlockPeriod Linear decay period (seconds) for harvested profit.
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
            address roleManager,
            uint32 profitUnlockPeriod
        )
    {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        maxSlippageBps = S.maxSlippageBps;
        performanceFeeBps = S.performanceFeeBps;
        maxLossBps = S.maxLossBps;
        lastReportTimestamp = S.lastReportTimestamp;
        performanceFeeRecipient = S.performanceFeeRecipient;
        roleManager = address(S.roleManager);
        profitUnlockPeriod = S.profitUnlockPeriod;
    }

    /// @notice Returns the current state of the linear profit-unlock buffer.
    /// @return lockedProfit The full buffer recorded at the last report (uint128).
    /// @return lastProfitReport The timestamp of the last `_updateLockedProfit` write.
    /// @return profitUnlockPeriod The configured linear decay window in seconds.
    /// @return currentlyLocked The portion of `lockedProfit` still locked at the current block.
    function getProfitUnlockState()
        external
        view
        virtual
        returns (uint128 lockedProfit, uint40 lastProfitReport, uint32 profitUnlockPeriod, uint256 currentlyLocked)
    {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        lockedProfit = S.lockedProfit;
        lastProfitReport = S.lastProfitReport;
        profitUnlockPeriod = S.profitUnlockPeriod;
        currentlyLocked = _calculateLockedProfit();
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
        S.realizedAssets += assets;

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

        UserRedeemRequest storage userRequest = S.userRedeemRequests[owner_];

        userRequest.shares -= shares.toUint128();
        if (userRequest.shares == 0) {
            // Reset requestId to 0 when there are no pending shares
            userRequest.requestId = 0;
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

    /// @dev Returns the portion of the most recently locked profit that is still locked at the current
    /// block, decaying linearly from `lockedProfit` at `lastProfitReport` to zero at
    /// `lastProfitReport + profitUnlockPeriod`.
    /// Returns 0 in the disabled state (`profitUnlockPeriod == 0`) and after full decay.
    /// @return The amount of profit still locked, denominated in underlying assets.
    function _calculateLockedProfit() internal view returns (uint256) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        uint256 locked = S.lockedProfit;
        uint256 period = S.profitUnlockPeriod;

        // Disabled (period == 0) results in instant profit unlocks.
        if (locked == 0 || period == 0) return 0;

        // lastProfitReport is only ever set to block.timestamp by _updateLockedProfit, so
        // (block.timestamp - lastProfitReport) cannot underflow.
        uint256 elapsed = block.timestamp - S.lastProfitReport;
        if (elapsed >= period) return 0;

        // remaining = locked * (period - elapsed) / period
        return locked.mulDiv(period - elapsed, period);
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
            cumulative += SafeCast.toInt128(SafeCast.toInt256(profit));
        } else {
            loss = prevAssets - currentAssets;
            cumulative -= SafeCast.toInt128(SafeCast.toInt256(loss));
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

    /// @dev Refreshes the stored `realizedAssets` value and updates `lastReportTimestamp` to `block.timestamp`.
    /// Returns the previous and newly stored asset values so callers can compute their own profit/loss.
    /// @return prevAssets The `realizedAssets` value before the refresh.
    /// @return currentAssets The newly stored `realizedAssets` value.
    function _refreshRealizedAssets() internal returns (uint256 prevAssets, uint256 currentAssets) {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        prevAssets = S.realizedAssets;
        currentAssets = _reportTotalAssets();
        S.realizedAssets = currentAssets;
        S.lastReportTimestamp = uint40(block.timestamp);
    }

    /// @dev Unified reporting pipeline. Refreshes realizedAssets from the underlying protocol,
    /// computes profit/loss against the prior baseline, and charges performance fees on chargeable
    /// profit. Invoked by the external `harvestAndReport()` keeper entrypoint and by `processCurrentRequest()`
    /// after `_beforeProcessReport()` and before settlement. Inherited contracts MAY override the body (e.g.
    /// MultiStrategyVault skips PnL accumulation).
    /// @return profit Gross profit since the last report.
    /// @return loss Gross loss since the last report.
    function _processReport() internal virtual returns (uint256 profit, uint256 loss) {
        (uint256 prevAssets, uint256 currentAssets) = _refreshRealizedAssets();

        // Skip profit/loss tracking and fee logic when nothing changed
        if (prevAssets == currentAssets) {
            emit Reported(msg.sender, 0, 0, 0);
            return (0, 0);
        }

        uint256 chargeableProfit;
        (profit, chargeableProfit, loss) = _calculateProfitOrLoss(prevAssets, currentAssets);

        uint256 performanceFees = _chargeFees(chargeableProfit, currentAssets);
        _updateLockedProfit(profit, performanceFees, loss);
        emit Reported(msg.sender, profit, loss, performanceFees);
    }

    /// @dev Updates the still-locked portion of `lockedProfit` to its current decayed value and
    /// refreshes the `lastProfitReport` to `block.timestamp`. Safe to call when no profit is locked
    /// Used by `updateConfig` before updating the setting `profitUnlockPeriod` so that:
    ///   - Already-unlocked yield (visible in `totalAssets()`) stays unlocked.
    ///   - The remaining buffer re-decays linearly from `now` over the new period.
    function _settleLockedProfit() internal {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();
        if (S.lockedProfit == 0) return;

        uint128 stillLocked = uint128(_calculateLockedProfit());
        S.lockedProfit = stillLocked;
        S.lastProfitReport = uint40(block.timestamp);
        emit ProfitLocked(stillLocked);
    }

    /// @dev Updates the linear profit unlock buffer to absorb the loss against any still-locked
    /// profit first, then adds profitAfterFees to the buffer and resets the linear-decay clock.
    /// When `profitUnlockPeriod == 0`, profit is never locked (instant unlock); this function still
    /// runs the loss-absorption math harmlessly because `_calculateLockedProfit` returns 0.
    /// @param profit Gross profit reported by `_processReport`.
    /// @param performanceFees Asset-denominated fees minted as shares to the fee recipient.
    /// @param loss Gross loss reported by `_processReport`.
    function _updateLockedProfit(uint256 profit, uint256 performanceFees, uint256 loss) internal virtual {
        CeresBaseVaultStorage storage S = _getCeresBaseVaultStorage();

        uint256 currentLockedProfit = _calculateLockedProfit();

        if (loss > 0) {
            uint256 lossAbsorbed = loss < currentLockedProfit ? loss : currentLockedProfit;
            currentLockedProfit -= lossAbsorbed;
        }

        uint256 profitAfterFees;
        if (profit > 0) {
            // performanceFees <= chargeableProfit <= profit, so this never underflows.
            profitAfterFees = profit - performanceFees;
        }

        uint256 newLockedProfit = currentLockedProfit + profitAfterFees;

        // Weighted re-anchor: instead of pinning `lastProfitReport = now` on every call (which results in the unlock
        // clock indefinitely refreshed with harvests), advance the anchor partially using weighted approach
        // The updated value is based on the proportion of how much *new* profit is being mixed into the
        // existing still-decaying buffer.
        //
        //     newElapsed = currentLockedProfit * (now - lastProfitReport) / newLockedProfit
        //     newAnchor  = now - newElapsed
        //
        // Properties:
        //   - profitAfterFees == 0           -> newElapsed = (now - lastProfitReport), anchor unchanged
        //                                       (loss-only and dust-only calls cannot grief the clock).
        //   - currentLockedProfit == 0       -> newElapsed = 0, anchor = now (first harvest / fully
        //                                       decayed buffer / disabled period: same as before).
        //   - profitAfterFees is very small vs currentLockedProfit -> newElapsed ~ elapsed,
        //                       anchor barely moves (old residue dominates, decay continues undisturbed).
        //   - profitAfterFees >> currentLockedProfit -> newElapsed ~ 0, anchor ~ now (big harvest dominates).
        //   - Old residue's unlock end-time can extend by at most
        //     `(now - lastProfitReport) * profitAfterFees / newLockedProfit`,
        //     strictly less than the current code's full `(now - lastProfitReport)` extension.
        if (newLockedProfit == 0) {
            // No need to update `lastProfitReport`: `_calculateLockedProfit` returns early
            // when `lockedProfit == 0`, so the anchor is never read until the next profitable harvest,
            // which will write it fresh.
            S.lockedProfit = 0;
        } else {
            uint256 elapsed = block.timestamp - S.lastProfitReport;
            uint256 newElapsed = currentLockedProfit.mulDiv(elapsed, newLockedProfit);

            S.lockedProfit = newLockedProfit.toUint128();
            S.lastProfitReport = uint40(block.timestamp - newElapsed);
        }

        emit ProfitLocked(newLockedProfit);
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
        // Underflow or Division by 0 is highly unlikely.
        // If it happens (edge case), tx reverts safely and can be mitigated by MANAGEMENT
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
    /// @dev Capped by `redeemLimitShares`
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

        // User can redeem the minimum of redeem limit and requested shares
        // `redeemLimitShares` is a hard per-controller cap on claimable shares.
        // A value of 0 is contract default, and can also be used later to pause claims
        claimableShares = Math.min(userRequest.shares, S.redeemLimitShares);
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

    /// @dev Hook invoked at the start of `processCurrentRequest`, immediately before
    /// the `_processReport()` call. Default implementation is a no-op.
    function _beforeProcessReport() internal virtual {}

    /// @dev Deploys assets into the underlying protocol or child strategies after a deposit.
    /// @param _amount The amount of underlying assets to deploy.
    function _deployFunds(uint256 _amount) internal virtual;

    /// @dev Returns the current total assets of the vault as computed from the underlying protocol.
    /// @dev NOTE: MUST report net assets strictly excluding `withdrawalReserve()`.
    /// The reserve holds finalized, locked funds assigned to pending withdrawals.
    /// @return _totalAssets The newly computed total assets value.
    function _reportTotalAssets() internal virtual returns (uint256 _totalAssets);

    /// @dev Attempts to withdraw `_amount` from the underlying protocol to cover a redeem request.
    /// @dev NOTE: Implementations are blind execution hooks. The actual cash freed and any
    /// associated unwind cost are measured top-down by `processCurrentRequest` via
    /// `_reportTotalAssets()` and idle-balance snapshots taken around this call. Implementations
    /// MUST NOT mutate `withdrawalReserve` or `realizedAssets` and SHOULD avoid emitting any
    /// state that the top-down accounting depends on.
    /// @param _amount The amount of underlying assets to free.
    /// @param extraData Encoded specific extra instructions / metadata.
    function _freeFunds(uint256 _amount, bytes calldata extraData) internal virtual;
}
