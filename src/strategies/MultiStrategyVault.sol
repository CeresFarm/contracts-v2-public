// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {CeresBaseVault} from "./CeresBaseVault.sol";
import {LibError} from "../libraries/LibError.sol";

import {ICeresBaseVault} from "../interfaces/strategies/ICeresBaseVault.sol";
import {IMultiStrategyVault} from "../interfaces/strategies/IMultiStrategyVault.sol";

/// @title MultiStrategyVault
/// @notice A standalone ERC-4626 / ERC-7540 compliant multi-strategy vault that allocates user
/// deposits across multiple child strategies (e.g. LeveragedAave, LeveragedSilo).
/// @dev The vault acts as the single entry point for users of a specific deposit asset (e.g. USDC).
/// A curator allocates idle assets to child strategies, each with an allocation cap.
/// Because child strategies use async (ERC-7540) withdrawals, fund deallocation is a
/// multi-step keeper-driven process rather than an atomic operation.
///
/// Flow:
///   Deposit:  User -> deposit -> assets sit idle -> Curator calls allocate to child strategies
///   Withdraw: User -> requestRedeem -> Keeper deallocates from children -> processCurrentRequest -> User redeems
contract MultiStrategyVault is CeresBaseVault, IMultiStrategyVault {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTANTS/IMMUTABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 internal constant MAX_STRATEGIES = 10;
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    // keccak256(abi.encode(uint256(keccak256("ceres.storage.MultiStrategyVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MULTISTRATEGY_VAULT_STORAGE_LOCATION =
        0xec419cbfd5c3ba05e0e140d724d3979ed64708595283fbb576f70849e3c9b300;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         STATE                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:storage-location erc7201:ceres.storage.MultiStrategyVault
    struct MultiStrategyVaultStorage {
        // Strategy registry
        mapping(address => StrategyConfig) strategyConfig;
        // Ordered queues for deposit/withdrawal priority
        address[] supplyQueue; // Order for deposits into strategies
        address[] withdrawQueue; // Order for withdrawals from strategies
        // Aggregate accounting
        uint256 totalAllocated; // Sum of all currentAllocated across strategies
    }

    function _getMultiStrategyVaultStorage() private pure returns (MultiStrategyVaultStorage storage S) {
        assembly {
            S.slot := MULTISTRATEGY_VAULT_STORAGE_LOCATION
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR/INITIALIZERS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the MultiStrategyVault with its asset token, share metadata, and role manager.
    /// @param _asset The ERC-20 token accepted as the vault's deposit asset.
    /// @param _name ERC-20 name of the vault share token.
    /// @param _symbol ERC-20 symbol of the vault share token.
    /// @param _roleManager Address of the RoleManager contract controlling access roles.
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager
    ) external initializer {
        __CeresBaseVault_init(IERC20(_asset), _name, _symbol, _roleManager);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     VIEW FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the total assets allocated across all active child strategies.
    /// @return Sum of currentAllocated recorded for every active strategy.
    function totalAllocated() external view returns (uint256) {
        return _getMultiStrategyVaultStorage().totalAllocated;
    }

    /// @notice Returns the configuration record for a specific child strategy.
    /// @param strategy Address of the child strategy.
    /// @return The StrategyConfig struct storing allocation cap, current allocation, and activation timestamp.
    function getStrategyConfig(address strategy) external view returns (StrategyConfig memory) {
        return _getMultiStrategyVaultStorage().strategyConfig[strategy];
    }

    /// @notice Returns the ordered list of strategies used when allocating idle assets.
    /// @return Ordered array of strategy addresses for deposit allocation.
    function getSupplyQueue() external view returns (address[] memory) {
        return _getMultiStrategyVaultStorage().supplyQueue;
    }

    /// @notice Returns the ordered list of strategies used when deallocating assets for withdrawals.
    /// @dev Off-chain hint only. The contract does not consume this queue: keepers reference it
    /// to decide the order of `requestDeallocate` calls on child strategies prior to invoking
    /// `processCurrentRequest`. `_freeFunds` returns 0 on this vault by design (async children).
    /// @return Ordered array of strategy addresses for withdrawal deallocation.
    function getWithdrawQueue() external view returns (address[] memory) {
        return _getMultiStrategyVaultStorage().withdrawQueue;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          STRATEGY MANAGEMENT (MANAGEMENT_ROLE)                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Register a new child strategy.
    /// @dev The strategy must use the same underlying asset as this vault.
    /// Adds the strategy to both supply and withdraw queues.
    /// Supply and withdrawal queues are updated using a gas efficient approach,
    /// the queues must be adjusted manually after adding/removing strategies to ensure
    ///  the desired allocation/deallocation order.
    /// @param strategy Address of the ERC-7540 child strategy.
    function addStrategy(address strategy) external nonReentrant onlyRole(MANAGEMENT_ROLE) {
        if (strategy == address(0) || strategy == address(this)) revert LibError.InvalidAddress();

        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();

        if (S.strategyConfig[strategy].activatedAt != 0) revert LibError.StrategyAlreadyActive();
        if (IERC4626(strategy).asset() != asset()) revert LibError.StrategyAssetMismatch();
        if (S.supplyQueue.length >= MAX_STRATEGIES) revert LibError.MaxQueueLengthExceeded();

        S.strategyConfig[strategy] = StrategyConfig({
            allocationCap: 0,
            currentAllocated: 0,
            activatedAt: uint64(block.timestamp),
            lastReport: uint64(block.timestamp)
        });

        S.supplyQueue.push(strategy);
        S.withdrawQueue.push(strategy);

        emit StrategyAdded(strategy);
    }

    /// @notice Remove a child strategy from the vault.
    /// @dev Strategy must have zero allocation (all funds deallocated and claimed).
    /// Supply and withdrawal queues are updated using a gas efficient approach,
    /// the queues must be adjusted manually after adding/removing strategies to ensure
    ///  the desired allocation/deallocation order.
    /// @param strategy Address of the strategy to remove.
    function removeStrategy(address strategy) external nonReentrant onlyRole(MANAGEMENT_ROLE) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();

        StrategyConfig storage config = S.strategyConfig[strategy];
        if (config.activatedAt == 0) revert LibError.StrategyNotActive();
        if (config.currentAllocated != 0) revert LibError.StrategyHasAllocation();

        // Ensure we don't hold any shares of the strategy (no active, pending or claimable shares)
        if (IERC20(strategy).balanceOf(address(this)) != 0) revert LibError.StrategyHasPendingRequest();

        ICeresBaseVault.UserRedeemRequest memory redeemRequest = ICeresBaseVault(strategy).userRedeemRequests(
            address(this)
        );
        if (redeemRequest.shares != 0) revert LibError.StrategyHasPendingRequest();

        delete S.strategyConfig[strategy];

        _removeFromQueue(S.supplyQueue, strategy);
        _removeFromQueue(S.withdrawQueue, strategy);

        emit StrategyRemoved(strategy);
    }

    /// @notice Set the allocation cap for a strategy.
    /// @param strategy Address of the registered strategy.
    /// @param newCap Maximum assets that can be allocated to this strategy.
    function setAllocationCap(address strategy, uint128 newCap) external onlyRole(MANAGEMENT_ROLE) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        if (S.strategyConfig[strategy].activatedAt == 0) revert LibError.StrategyNotActive();

        S.strategyConfig[strategy].allocationCap = newCap;

        emit StrategyAllocationCapUpdated(strategy, newCap);
    }

    /// @notice Set the supply (deposit) queue ordering.
    /// @dev All strategies in the queue must be active. No duplicates allowed.
    /// @param newQueue Ordered array of strategy addresses.
    function setSupplyQueue(address[] calldata newQueue) external onlyRole(MANAGEMENT_ROLE) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();

        if (newQueue.length != S.supplyQueue.length) revert LibError.InvalidQueueLength();
        _validateQueue(S, newQueue);

        S.supplyQueue = newQueue;

        emit SupplyQueueUpdated(newQueue);
    }

    /// @notice Set the withdrawal queue ordering.
    /// @dev All strategies in the queue must be active. No duplicates allowed.
    /// @param newQueue Ordered array of strategy addresses.
    function setWithdrawQueue(address[] calldata newQueue) external onlyRole(MANAGEMENT_ROLE) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();

        if (newQueue.length != S.withdrawQueue.length) revert LibError.InvalidQueueLength();
        _validateQueue(S, newQueue);

        S.withdrawQueue = newQueue;

        emit WithdrawQueueUpdated(newQueue);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FUND ALLOCATION (CURATOR_ROLE)                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit idle vault assets into a child strategy.
    /// @dev The allocation must not exceed the strategy's cap. Assets used for allocation
    ///      cannot come from the withdrawalReserve.
    /// @param strategy Address of the target strategy.
    /// @param assets Amount of underlying asset to allocate.
    function allocate(address strategy, uint256 assets) external nonReentrant onlyRole(CURATOR_ROLE) {
        if (assets == 0) revert LibError.InvalidAmount();

        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        StrategyConfig storage config = S.strategyConfig[strategy];
        if (config.activatedAt == 0) revert LibError.StrategyNotActive();

        // Must not allocate withdrawal-reserved assets
        uint256 availableAssets = _getSelfBalance(IERC20(asset())) - withdrawalReserve();
        if (assets > availableAssets) revert LibError.InsufficientAvailableAssets();

        // Enforce allocation cap
        uint256 newAllocation = uint256(config.currentAllocated) + assets;
        if (newAllocation > config.allocationCap) revert LibError.ExceedsAllocationCap();

        // Deposit into the child strategy
        IERC20(asset()).forceApprove(strategy, assets);
        uint256 sharesReceived = IERC4626(strategy).deposit(assets, address(this));

        // Update accounting
        config.currentAllocated = newAllocation.toUint128();
        S.totalAllocated += assets;

        emit FundsAllocated(strategy, assets, sharesReceived);
    }

    /// @notice Begin an async withdrawal from a child strategy.
    /// @dev Calls requestRedeem() on the child strategy. The child keeper must
    /// process the request before funds can be claimed.
    /// @param strategy Address of the child strategy.
    /// @param shares Number of strategy shares to redeem.
    /// @return requestId The request ID returned by the child strategy.
    function requestDeallocate(
        address strategy,
        uint256 shares
    ) external nonReentrant onlyRole(CURATOR_ROLE) returns (uint256 requestId) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        if (S.strategyConfig[strategy].activatedAt == 0) revert LibError.StrategyNotActive();
        if (shares == 0) revert LibError.ZeroShares();

        requestId = ICeresBaseVault(strategy).requestRedeem(shares, address(this), address(this));

        emit DeallocateRequested(strategy, shares, requestId);
    }

    /// @notice Claim assets from a child strategy after its async withdrawal has been processed.
    /// @dev Calls redeem() on the child strategy. Updates debt accounting based on
    ///      the actual assets received.
    /// @param strategy Address of the child strategy.
    /// @param shares Number of strategy shares to redeem. Curator should get this amount off-chain
    ///               by calling `claimableShares` on the child strategy after the redeem request is processed.
    /// @return assetsClaimed Amount of underlying assets received.
    function claimDeallocated(
        address strategy,
        uint256 shares
    ) external nonReentrant onlyRole(CURATOR_ROLE) returns (uint256 assetsClaimed) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        StrategyConfig storage config = S.strategyConfig[strategy];
        if (config.activatedAt == 0) revert LibError.StrategyNotActive();
        if (shares == 0) revert LibError.ZeroShares();

        // The child strategy enforces that `shares <= claimableShares` and reverts otherwise
        assetsClaimed = IERC4626(strategy).redeem(shares, address(this), address(this));

        // Update allocation accounting using cuurent valuation
        _reportStrategy(strategy);

        emit FundsClaimed(strategy, assetsClaimed, shares);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              REPORTING (KEEPER_ROLE)                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Report the current value of a child strategy and update allocation accounting.
    /// @dev Reads the strategy's convertToAssets for the vault's share position and
    ///      adjusts currentAllocated accordingly. This updates totalAssets without moving funds.
    /// @param strategy Address of the strategy to report.
    function reportStrategy(address strategy) external nonReentrant onlyRole(KEEPER_ROLE) {
        _reportStrategy(strategy);
    }

    /// @dev Internal reporting logic to update allocation accounting.
    function _reportStrategy(address strategy) internal {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        StrategyConfig storage config = S.strategyConfig[strategy];
        if (config.activatedAt == 0) revert LibError.StrategyNotActive();

        // Get current value of our position in the strategy
        uint256 sharesOwned = IERC20(strategy).balanceOf(address(this));
        ICeresBaseVault.UserRedeemRequest memory pending = ICeresBaseVault(strategy).userRedeemRequests(address(this));

        uint256 actualValue;
        if (pending.shares > 0) {
            ICeresBaseVault.RequestDetails memory details = ICeresBaseVault(strategy).requestDetails(pending.requestId);
            if (details.pricePerShare > 0) {
                // Pending shares already processed: use the locked-in PPS
                uint256 pendingValue = uint256(pending.shares).mulDiv(
                    details.pricePerShare,
                    10 ** IERC4626(strategy).decimals(),
                    Math.Rounding.Floor
                );
                actualValue = IERC4626(strategy).convertToAssets(sharesOwned) + pendingValue;
            } else {
                // Pending shares not yet processed: use current convertToAssets for all
                actualValue = IERC4626(strategy).convertToAssets(sharesOwned + pending.shares);
            }
        } else {
            actualValue = IERC4626(strategy).convertToAssets(sharesOwned);
        }

        // Update strategy specific allocation
        uint256 previousAllocated = config.currentAllocated;
        config.currentAllocated = actualValue.toUint128();
        config.lastReport = uint64(block.timestamp);

        // Update aggregate totalAllocated
        if (actualValue > previousAllocated) {
            uint256 profit = actualValue - previousAllocated;
            S.totalAllocated += profit;
        } else if (actualValue < previousAllocated) {
            uint256 loss = previousAllocated - actualValue;
            S.totalAllocated -= loss;
        }

        _processReport();
        emit StrategyReportedFromVault(strategy, previousAllocated, actualValue);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              CERES BASE VAULT OVERRIDES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Auto-allocate deposited funds to the first strategy in the supply queue.
    /// Respects both the vault's allocation cap and the child strategy's deposit limit.
    /// If the strategy is at capacity or no strategies exist, funds remain idle.
    /// By design, only `supplyQueue[0]` is targeted: any overflow stays idle in the vault
    /// and the curator must call `allocate(strategy, assets)` to spread across other queue
    /// entries. This keeps the deposit path bounded in gas regardless of queue length.
    function _deployFunds(uint256 _amount) internal virtual override {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();
        if (S.supplyQueue.length == 0) return;

        address strategy = S.supplyQueue[0];
        StrategyConfig storage config = S.strategyConfig[strategy];

        uint256 currentAllocated = config.currentAllocated;
        uint256 cap = config.allocationCap;

        // Skip if strategy is at or above cap
        if (currentAllocated >= cap) return;

        // Respect both allocation cap and child strategy's deposit limit
        uint256 capRoom = cap - currentAllocated;
        uint256 strategyRoom = IERC4626(strategy).maxDeposit(address(this));
        uint256 toAllocate = Math.min(_amount, Math.min(capRoom, strategyRoom));

        if (toAllocate == 0) return;

        IERC20(asset()).forceApprove(strategy, toAllocate);
        uint256 sharesReceived = IERC4626(strategy).deposit(toAllocate, address(this));

        config.currentAllocated = (currentAllocated + toAllocate).toUint128();
        S.totalAllocated += toAllocate;

        emit FundsAllocated(strategy, toAllocate, sharesReceived);
    }

    /// @dev Cannot implement instant free funds from async strategies. No-op.
    /// The keeper must have already claimed funds from child strategies before
    /// calling processCurrentRequest. Top-down accounting in `processCurrentRequest`
    /// observes zero balance/asset deltas and proceeds with `availableAssets` only.
    function _freeFunds(uint256 /* amountToFree */, bytes calldata /* extraData */) internal pure override {}

    /// @dev MultiStrategyVault does not charge performance fees.
    function _chargeFees(uint256 /* profit */, uint256 /* totalAssets */) internal pure override returns (uint256) {
        return 0;
    }

    /// @dev Computes the total assets held by this vault: idle balance + totalAllocated across strategies.
    /// @dev NOTE: Actively subtracts the `withdrawalReserve()` from the raw idle balance.
    /// Because pending share claims are finalized into this reserve, including it in equity
    /// calculations would falsely inflate total vault assets.
    /// Uses the accounting-tracked totalAllocated rather than live on-chain queries for gas efficiency.
    /// The keeper should call reportStrategy() beforehand to keep totalAllocated accurate.
    function _reportTotalAssets() internal view virtual override returns (uint256 _totalAssets) {
        MultiStrategyVaultStorage storage S = _getMultiStrategyVaultStorage();

        // Raw vault balance (includes withdrawal reserve)
        uint256 grossIdle = _getSelfBalance(IERC20(asset()));
        uint128 reserve = withdrawalReserve();

        // Actively strip out `withdrawalReserve` so that pending share claims held in
        // the vault don't factor back into total vault equity and dilute yields.
        uint256 activeIdle = grossIdle > reserve ? grossIdle - reserve : 0;

        _totalAssets = activeIdle + S.totalAllocated;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             INTERNAL HELPER FUNCTIONS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Remove a strategy address from a queue array.
    function _removeFromQueue(address[] storage queue, address strategy) internal {
        uint256 length = queue.length;
        for (uint256 i; i < length; ++i) {
            if (queue[i] == strategy) {
                // Move the last element to the removed position and pop
                queue[i] = queue[length - 1];
                queue.pop();
                return;
            }
        }
    }

    /// @dev Validate a new queue: all strategies must be active, no duplicates, within max length.
    function _validateQueue(MultiStrategyVaultStorage storage S, address[] calldata queue) internal view {
        uint256 length = queue.length;
        if (length > MAX_STRATEGIES) revert LibError.MaxQueueLengthExceeded();

        // Use a bitmap-like approach: check each pair for duplicates
        for (uint256 i; i < length; ++i) {
            if (S.strategyConfig[queue[i]].activatedAt == 0) revert LibError.StrategyNotActive();
            for (uint256 j = i + 1; j < length; ++j) {
                if (queue[i] == queue[j]) revert LibError.DuplicateStrategy();
            }
        }
    }
}
