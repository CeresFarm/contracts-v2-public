// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MultiStrategyVaultSetup} from "./MultiStrategyVaultSetup.sol";
import {IMultiStrategyVault} from "src/interfaces/strategies/IMultiStrategyVault.sol";
import {ICeresBaseVault} from "src/interfaces/strategies/ICeresBaseVault.sol";
import {LibError} from "src/libraries/LibError.sol";

import {MockERC20} from "test/mock/common/MockERC20.sol";
import {MinimalCeresStrategy} from "../mock/common/MinimalCeresStrategy.sol";

contract MultiStrategyVaultTest is MultiStrategyVaultSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  EVENTS (re-declared for expectEmit)                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyAllocationCapUpdated(address indexed strategy, uint128 newCap);
    event FundsAllocated(address indexed strategy, uint256 assets, uint256 sharesReceived);
    event DeallocateRequested(address indexed strategy, uint256 shares, uint256 requestId);
    event FundsClaimed(address indexed strategy, uint256 assets, uint256 sharesBurned);
    event StrategyReportedFromVault(address indexed strategy, uint256 previousDebt, uint256 newDebt);
    event SupplyQueueUpdated(address[] newQueue);
    event WithdrawQueueUpdated(address[] newQueue);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    INITIAL STATE TESTS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_InitialState() public view {
        assertEq(vault.asset(), address(asset), "asset mismatch");
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0");
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0");
        assertEq(vault.totalAllocated(), 0, "totalAllocated should be 0");
        assertEq(vault.currentRequestId(), 1, "first requestId should be 1");
    }

    function test_InitialState_StrategiesAdded() public view {
        IMultiStrategyVault.StrategyConfig memory configA = vault.getStrategyConfig(address(childA));
        IMultiStrategyVault.StrategyConfig memory configB = vault.getStrategyConfig(address(childB));

        assertGt(configA.activatedAt, 0, "childA should be active");
        assertGt(configB.activatedAt, 0, "childB should be active");
        assertEq(configA.currentAllocated, 0, "childA allocated should be 0");
        assertEq(configB.currentAllocated, 0, "childB allocated should be 0");
        assertEq(configA.allocationCap, ALLOCATION_CAP_A, "childA cap mismatch");
        assertEq(configB.allocationCap, ALLOCATION_CAP_B, "childB cap mismatch");
    }

    function test_InitialState_Queues() public view {
        address[] memory supplyQueue = vault.getSupplyQueue();
        address[] memory withdrawQueue = vault.getWithdrawQueue();

        assertEq(supplyQueue.length, 2, "supply queue should have 2 entries");
        assertEq(withdrawQueue.length, 2, "withdraw queue should have 2 entries");
        assertEq(supplyQueue[0], address(childA), "supply queue[0] mismatch");
        assertEq(supplyQueue[1], address(childB), "supply queue[1] mismatch");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               STRATEGY MANAGEMENT TESTS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_AddStrategy_Success() public {
        // Deploy a third child
        address debtC = makeAddr("debtC");
        address proxyC = _deployChildProxy(address(asset), debtC);

        vm.expectEmit(true, false, false, false);
        emit StrategyAdded(proxyC);

        vm.prank(management);
        vault.addStrategy(proxyC);

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(proxyC);
        assertGt(config.activatedAt, 0, "strategy should be activated");
        assertEq(config.allocationCap, 0, "new strategy cap should default to 0");

        address[] memory queue = vault.getSupplyQueue();
        assertEq(queue.length, 3, "supply queue should have 3 entries after add");
    }

    function testRevert_AddStrategy_ZeroAddress() public {
        vm.prank(management);
        vm.expectRevert(LibError.InvalidAddress.selector);
        vault.addStrategy(address(0));
    }

    function testRevert_AddStrategy_SelfAddress() public {
        vm.prank(management);
        vm.expectRevert(LibError.InvalidAddress.selector);
        vault.addStrategy(address(vault));
    }

    function testRevert_AddStrategy_DuplicateStrategy() public {
        vm.prank(management);
        vm.expectRevert(LibError.StrategyAlreadyActive.selector);
        vault.addStrategy(address(childA));
    }

    function testRevert_AddStrategy_AssetMismatch() public {
        // Deploy a strategy with a different asset
        MockERC20 otherAsset = new MockERC20("Other", "OTH", 18);
        address proxyOther = _deployChildProxy(address(otherAsset), makeAddr("debtOther"));

        vm.prank(management);
        vm.expectRevert(LibError.StrategyAssetMismatch.selector);
        vault.addStrategy(proxyOther);
    }

    function testRevert_AddStrategy_Unauthorized() public {
        address proxyC = _deployChildProxy(address(asset), makeAddr("debtC2"));
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        vault.addStrategy(proxyC);
    }

    function test_RemoveStrategy_Success() public {
        // childA has no debt and no shares outstanding, so it can be removed
        vm.expectEmit(true, false, false, false);
        emit StrategyRemoved(address(childA));

        vm.prank(management);
        vault.removeStrategy(address(childA));

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        assertEq(config.activatedAt, 0, "strategy should be inactive after removal");

        address[] memory queue = vault.getSupplyQueue();
        assertEq(queue.length, 1, "supply queue should shrink after removal");
    }

    function testRevert_RemoveStrategy_NotActive() public {
        vm.prank(management);
        vm.expectRevert(LibError.StrategyNotActive.selector);
        vault.removeStrategy(makeAddr("nonExistent"));
    }

    function testRevert_RemoveStrategy_HasDebt() public {
        uint256 depositAmount = 1_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // childA now has debt from auto-allocation

        vm.prank(management);
        vm.expectRevert(LibError.StrategyHasAllocation.selector);
        vault.removeStrategy(address(childA));
    }

    function test_SetAllocationCap_Success() public {
        uint128 newCap = 75_000_000 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit StrategyAllocationCapUpdated(address(childA), newCap);

        vm.prank(management);
        vault.setAllocationCap(address(childA), newCap);

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        assertEq(config.allocationCap, newCap, "cap should be updated");
    }

    function testRevert_SetAllocationCap_StrategyNotActive() public {
        vm.prank(management);
        vm.expectRevert(LibError.StrategyNotActive.selector);
        vault.setAllocationCap(makeAddr("notAStrategy"), 1e18);
    }

    function test_SetSupplyQueue_Success() public {
        address[] memory newQueue = new address[](2);
        newQueue[0] = address(childB);
        newQueue[1] = address(childA);

        vm.expectEmit(false, false, false, true);
        emit SupplyQueueUpdated(newQueue);

        vm.prank(management);
        vault.setSupplyQueue(newQueue);

        address[] memory stored = vault.getSupplyQueue();
        assertEq(stored[0], address(childB), "queue[0] should be childB");
        assertEq(stored[1], address(childA), "queue[1] should be childA");
    }

    function testRevert_SetSupplyQueue_LengthMismatch() public {
        address[] memory badQueue = new address[](1);
        badQueue[0] = address(childA);

        vm.prank(management);
        vm.expectRevert(LibError.InvalidQueueLength.selector);
        vault.setSupplyQueue(badQueue);
    }

    function testRevert_SetSupplyQueue_DuplicateStrategy() public {
        address[] memory badQueue = new address[](2);
        badQueue[0] = address(childA);
        badQueue[1] = address(childA);

        vm.prank(management);
        vm.expectRevert(LibError.DuplicateStrategy.selector);
        vault.setSupplyQueue(badQueue);
    }

    function test_SetWithdrawQueue_Success() public {
        address[] memory newQueue = new address[](2);
        newQueue[0] = address(childB);
        newQueue[1] = address(childA);

        vm.expectEmit(false, false, false, true);
        emit WithdrawQueueUpdated(newQueue);

        vm.prank(management);
        vault.setWithdrawQueue(newQueue);

        address[] memory stored = vault.getWithdrawQueue();
        assertEq(stored[0], address(childB), "queue[0] should be childB");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ALLOCATION TESTS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Allocate_Success() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 allocAmount = 5_000 * 1e6;

        // Prevent auto-allocation during deposit
        vm.prank(management);
        vault.setAllocationCap(address(childA), 0);

        _depositToVault(user1, depositAmount);

        // Restore cap for explicit allocate
        vm.prank(management);
        vault.setAllocationCap(address(childA), ALLOCATION_CAP_A);

        uint256 preAlloc = vault.totalAllocated();

        vm.expectEmit(true, false, false, false);
        emit FundsAllocated(address(childA), allocAmount, 0); // shares not checked

        _allocateToChild(address(childA), allocAmount);

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        assertEq(config.currentAllocated, allocAmount, "childA currentAllocated should equal allocated assets");
        assertEq(vault.totalAllocated(), preAlloc + allocAmount, "totalAllocated should increase");

        // The vault must have approved and transferred tokens to childA
        assertEq(asset.balanceOf(address(vault)), depositAmount - allocAmount, "vault idle should decrease");
        assertGt(childA.balanceOf(address(vault)), 0, "vault should hold childA shares");
    }

    function test_Allocate_TotalAssetsUnchanged() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA
        _reportStrategy(address(childA));
        _harvestVault();

        // totalAssets = idle (0) + totalAllocated (depositAmount)
        assertApproxEqAbs(vault.totalAssets(), depositAmount, 1, "totalAssets should be unchanged after auto-allocate");
    }

    function testRevert_Allocate_ExceedsAllocationCap() public {
        // Set a small cap so auto-allocation fills it, leaving idle for the allocate call
        uint128 smallCap = 1_000 * 1e6;
        vm.prank(management);
        vault.setAllocationCap(address(childA), smallCap);

        _depositToVault(user1, 2_000 * 1e6);
        // Auto-alloc puts 1,000 in childA, 1,000 stays idle

        vm.prank(curator);
        vm.expectRevert(LibError.ExceedsAllocationCap.selector);
        vault.allocate(address(childA), 1); // childA is already at cap
    }

    function testRevert_Allocate_InsufficientIdleAssets() public {
        uint256 depositAmount = 1_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // All funds auto-allocated to childA; idle = 0

        vm.prank(curator);
        vm.expectRevert(LibError.InsufficientAvailableAssets.selector);
        vault.allocate(address(childB), 1);
    }

    function testRevert_Allocate_Unauthorized() public {
        _depositToVault(user1, 1_000 * 1e6);

        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        vault.allocate(address(childA), 100 * 1e6);
    }

    function testRevert_Allocate_StrategyNotActive() public {
        _depositToVault(user1, 1_000 * 1e6);

        vm.prank(curator);
        vm.expectRevert(LibError.StrategyNotActive.selector);
        vault.allocate(makeAddr("unknown"), 100 * 1e6);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  DEALLOCATION TESTS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_RequestDeallocate_Success() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        uint256 sharesToRedeem = childA.balanceOf(address(vault));
        assertGt(sharesToRedeem, 0, "vault should hold shares");

        vm.expectEmit(true, false, false, false);
        emit DeallocateRequested(address(childA), sharesToRedeem, 0); // requestId not checked

        uint256 requestId = _requestDeallocateFromChild(address(childA), sharesToRedeem);
        assertGt(requestId, 0, "requestId should be non-zero");

        // Vault's childA shares should have moved to childA (held as pending)
        assertEq(childA.balanceOf(address(vault)), 0, "vault's direct shares should be 0 after request");
    }

    function testRevert_RequestDeallocate_ZeroShares() public {
        _depositToVault(user1, 10_000 * 1e6);
        // Funds auto-allocated to childA

        vm.prank(curator);
        vm.expectRevert(LibError.ZeroShares.selector);
        vault.requestDeallocate(address(childA), 0);
    }

    function testRevert_RequestDeallocate_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        vault.requestDeallocate(address(childA), 1);
    }

    function test_ClaimDeallocated_Success() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        uint256 sharesToRedeem = childA.balanceOf(address(vault));
        _requestDeallocateFromChild(address(childA), sharesToRedeem);

        // Process childA's request as keeper
        _processChildRequest(childA);

        uint256 preVaultBalance = asset.balanceOf(address(vault));

        vm.expectEmit(true, false, false, false);
        emit FundsClaimed(address(childA), 0, 0); // values not checked

        uint256 assets = _claimDeallocatedFromChild(address(childA));

        assertGt(assets, 0, "should receive assets after claim");
        assertEq(asset.balanceOf(address(vault)), preVaultBalance + assets, "vault idle should increase");

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        assertEq(config.currentAllocated, 0, "childA allocated should be 0 after full deallocation");
        assertEq(vault.totalAllocated(), 0, "totalAllocated should be 0 after full deallocation");
    }

    function testRevert_ClaimDeallocated_ZeroShares() public {
        // No request pending
        vm.prank(curator);
        vm.expectRevert(LibError.ZeroShares.selector);
        vault.claimDeallocated(address(childA));
    }

    function testRevert_ClaimDeallocated_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        vault.claimDeallocated(address(childA));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   REPORT STRATEGY TESTS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_ReportStrategy_NoYield() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        uint256 allocBefore = vault.getStrategyConfig(address(childA)).currentAllocated;

        vm.expectEmit(true, false, false, false);
        emit StrategyReportedFromVault(address(childA), 0, 0); // values not checked

        _reportStrategy(address(childA));

        uint256 allocAfter = vault.getStrategyConfig(address(childA)).currentAllocated;
        assertApproxEqAbs(allocAfter, allocBefore, 1, "allocated should be unchanged with no yield");
    }

    function test_ReportStrategy_YieldIncreasesTotalAllocated() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        // Simulate yield: airdrop assets into childA (MinimalCeresStrategy's _reportTotalAssets
        // reads balanceOf, so minting directly to the child increases its totalAssets)
        uint256 yieldAmount = 100 * 1e6;
        asset.mint(address(childA), yieldAmount);

        // Keeper harvests the child so its stored totalAssets reflects the yield
        vm.prank(keeper);
        childA.harvestAndReport();

        uint256 totalAllocatedBefore = vault.totalAllocated();
        _reportStrategy(address(childA));

        assertGt(vault.totalAllocated(), totalAllocatedBefore, "totalAllocated should increase after yield");
    }

    /// @notice Test that `_reportStrategy` MUST refresh the vault's `totalAssets` so that the very next `deposit` 
    /// mints shares at the post-yield PPS.
    /// Without the trailing `_refreshTotalAssets()` an attacker could observe child yield,
    /// deposit at the stale (pre-yield) PPS, then immediately request redeem after the
    /// next refresh to extract a riskless premium proportional to the realized child yield.
    function test_ReportStrategy_RefreshesVaultTotalAssets_ClosesDepositMEV() public {
        // Seed the vault and auto-allocate to childA.
        uint256 seed = 10_000 * 1e6;
        _depositToVault(user1, seed);
        assertEq(vault.totalAssets(), seed, "totalAssets should equal seed pre-yield");

        // Simulate child yield and harvest the child so its stored totalAssets reflects it.
        uint256 yieldAmount = 1_000 * 1e6; // 10% yield
        asset.mint(address(childA), yieldAmount);
        vm.prank(keeper);
        childA.harvestAndReport();

        _reportStrategy(address(childA));

        uint256 totalAssetsAfterReport = vault.totalAssets();
        assertGt(totalAssetsAfterReport, seed, "vault.totalAssets must reflect child yield after reportStrategy");

        // A fresh depositor deposits immediately after `_reportStrategy`.
        // The depositor's shares correspond to the POST-yield PPS so an immediate
        // requestRedeem cannot extract any of the realized yield. This is also prevented
        // partially by async withdrawals
        uint256 attackerDeposit = 1_000 * 1e6;
        _depositToVault(user2, attackerDeposit);

        uint256 attackerShares = vault.balanceOf(user2);
        uint256 attackerEntitledAssets = vault.convertToAssets(attackerShares);

        // Allow 1 wei of rounding from the +1 virtual offset in _convertToShares.
        assertApproxEqAbs(
            attackerEntitledAssets,
            attackerDeposit,
            1,
            "attacker share value must equal deposit"
        );
    }

    function testRevert_ReportStrategy_NotActive() public {
        vm.prank(keeper);
        vm.expectRevert(LibError.StrategyNotActive.selector);
        vault.reportStrategy(makeAddr("unknown"));
    }

    function testRevert_ReportStrategy_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(LibError.Unauthorized.selector);
        vault.reportStrategy(address(childA));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                               TOTAL ASSETS ACCOUNTING                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_TotalAssets_PureIdle() public {
        uint256 depositAmount = 5_000 * 1e6;
        _depositToVault(user1, depositAmount);
        _harvestVault();

        assertEq(vault.totalAssets(), depositAmount, "totalAssets should equal deposit (auto-allocated as debt)");
    }

    function test_TotalAssets_IdlePlusDebt() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint128 childACap = 6_000 * 1e6;

        // Limit childA cap so auto-allocation only takes 6,000; 4,000 stays idle
        vm.prank(management);
        vault.setAllocationCap(address(childA), childACap);

        _depositToVault(user1, depositAmount);
        _reportStrategy(address(childA));
        _harvestVault();

        uint256 expectedTotal = depositAmount; // idle(4000) + debt(6000)
        assertApproxEqAbs(vault.totalAssets(), expectedTotal, 1, "totalAssets should equal idle + debt");
    }

    function test_TotalAssets_MultiBothStrategies() public {
        uint256 depositAmount = 20_000 * 1e6;
        uint128 allocA = 8_000 * 1e6;
        uint256 allocB = 8_000 * 1e6;

        // Limit childA cap so auto-allocation only takes 8,000; 12,000 stays idle
        vm.prank(management);
        vault.setAllocationCap(address(childA), allocA);

        _depositToVault(user1, depositAmount);
        // Explicitly allocate 8,000 to childB from idle
        _allocateToChild(address(childB), allocB);
        _reportStrategy(address(childA));
        _reportStrategy(address(childB));
        _harvestVault();

        assertApproxEqAbs(
            vault.totalAssets(),
            depositAmount,
            2,
            "totalAssets should equal depositAmount across both strategies"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    NO PERFORMANCE FEE                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_NoPerformanceFee_OnHarvest() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        _harvestVault();
        uint256 sharesBefore = vault.totalSupply();

        // Simulate yield by minting directly to vault (idle assets)
        asset.mint(address(vault), 1_000 * 1e6);
        _harvestVault();

        // Performance fee is 0 for MultiStrategyVault, so no new fee shares
        assertEq(vault.totalSupply(), sharesBefore, "no fee shares should be minted");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 FULL USER LIFECYCLE TEST                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_FullLifecycle_DepositAllocateDeallcateRedeem() public {
        // 1. User deposits, auto-allocated to childA
        uint256 depositAmount = 10_000 * 1e6;
        uint256 userShares = _depositToVault(user1, depositAmount);
        assertEq(vault.balanceOf(user1), userShares, "user should hold shares");

        // 2. Verify auto-allocation sent funds to childA
        assertEq(vault.totalAllocated(), depositAmount, "totalAllocated should match deposit (auto-allocated)");
        assertEq(asset.balanceOf(address(vault)), 0, "vault should have no idle after auto-allocation");

        // 3. User requests redeem (all shares)
        vm.prank(user1);
        uint256 requestId = vault.requestRedeem(userShares, user1, user1);
        assertEq(requestId, vault.currentRequestId(), "request should be in current batch");

        // 4. Curator deallocates from childA to recover assets
        uint256 childShares = childA.balanceOf(address(vault));
        _requestDeallocateFromChild(address(childA), childShares);

        // 5. Child keeper processes the child's request
        _processChildRequest(childA);

        // 6. Curator claims funds back to vault
        _claimDeallocatedFromChild(address(childA));
        assertGt(asset.balanceOf(address(vault)), 0, "vault should have idle assets after claim");

        // 7. Vault keeper processes vault's request
        _processVaultRequest();

        ICeresBaseVault.RequestDetails memory req = vault.requestDetails(requestId);
        assertGt(req.pricePerShare, 0, "request should be processed");

        // 8. User redeems
        vm.prank(user1);
        uint256 assetsReceived = vault.redeem(userShares, user1, user1);
        assertApproxEqAbs(assetsReceived, depositAmount, 1, "user should receive their full deposit");
        assertEq(vault.balanceOf(user1), 0, "user shares should be 0 after redeem");
    }

    function test_FullLifecycle_MultiUser() public {
        uint256 deposit1 = 6_000 * 1e6;
        uint256 deposit2 = 4_000 * 1e6;

        uint256 shares1 = _depositToVault(user1, deposit1);
        uint256 shares2 = _depositToVault(user2, deposit2);
        // Both deposits auto-allocated to childA

        // Both users request redeem
        vm.prank(user1);
        vault.requestRedeem(shares1, user1, user1);
        vm.prank(user2);
        vault.requestRedeem(shares2, user2, user2);

        // Deallocate, process child, claim
        _requestDeallocateFromChild(address(childA), childA.balanceOf(address(vault)));
        _processChildRequest(childA);
        _claimDeallocatedFromChild(address(childA));

        // Process vault request
        _processVaultRequest();

        // Both users redeem
        vm.prank(user1);
        uint256 assets1 = vault.redeem(shares1, user1, user1);

        vm.prank(user2);
        uint256 assets2 = vault.redeem(shares2, user2, user2);

        assertApproxEqAbs(assets1, deposit1, 1, "user1 should receive deposit1");
        assertApproxEqAbs(assets2, deposit2, 1, "user2 should receive deposit2");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                        REPORT STRATEGY — PROCESSED PENDING SHARES                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_ReportStrategy_ProcessedPendingUsesLockedPPS() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        // Vault holds child shares; request deallocation
        uint256 childShares = childA.balanceOf(address(vault));
        _requestDeallocateFromChild(address(childA), childShares);

        // Process child request, locks in PPS at current rate
        _processChildRequest(childA);

        // Simulate yield arriving in childA *after* processing (so current convertToAssets
        // diverges from the locked-in PPS)
        uint256 yieldAmount = 500 * 1e6;
        asset.mint(address(childA), yieldAmount);
        vm.prank(keeper);
        childA.harvestAndReport();

        // Report strategy — should value pending shares at locked-in PPS, not current rate
        _reportStrategy(address(childA));

        // The locked-in PPS was set when no yield existed, so pending value ~= depositAmount.
        // If the bug were present, it would use convertToAssets which includes the new yield,
        // overstating the debt.
        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        assertApproxEqAbs(
            config.currentAllocated,
            depositAmount,
            1e15,
            "currentAllocated should reflect locked-in PPS, not inflated convertToAssets"
        );
    }

    function test_ReportStrategy_UnprocessedPendingUsesConvertToAssets() public {
        uint256 depositAmount = 10_000 * 1e6;
        _depositToVault(user1, depositAmount);
        // Funds auto-allocated to childA

        // Request deallocation but do NOT process child request
        uint256 childShares = childA.balanceOf(address(vault));
        _requestDeallocateFromChild(address(childA), childShares);

        // Simulate yield
        uint256 yieldAmount = 200 * 1e6;
        asset.mint(address(childA), yieldAmount);
        vm.prank(keeper);
        childA.harvestAndReport();

        // Report strategy — pending shares not processed, should use convertToAssets for all
        _reportStrategy(address(childA));

        IMultiStrategyVault.StrategyConfig memory config = vault.getStrategyConfig(address(childA));
        // convertToAssets includes the yield, so debt should be higher than depositAmount
        assertGt(config.currentAllocated, depositAmount, "currentAllocated should include yield via convertToAssets");
        assertApproxEqAbs(
            config.currentAllocated,
            depositAmount + yieldAmount,
            2,
            "currentAllocated should reflect full value including yield"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    HELPER FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _deployChildProxy(address assetToken, address debtToken) internal returns (address proxy) {
        proxy = Upgrades.deployTransparentProxy(
            "MinimalCeresStrategy.sol:MinimalCeresStrategy",
            management,
            abi.encodeCall(MinimalCeresStrategy.initialize, (assetToken, debtToken, address(roleManager)))
        );
        vm.startPrank(management);
        MinimalCeresStrategy(proxy).setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT, 0);
        vm.stopPrank();
    }
}
