// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

import {FlashLoanRouter} from "src/periphery/FlashLoanRouter.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {LibError} from "src/libraries/LibError.sol";

import {TimelockTestHelper} from "test/common/TimelockTestHelper.sol";

/// @title TimelockIntegration
/// @notice End-to-end test that asserts the production behaviour for TIMELOCKED_ADMIN_ROLE setters:
/// - Direct EOA calls (even with MANAGEMENT_ROLE) revert with LibError.Unauthorized.
/// - Scheduling and executing through a real OZ TimelockController succeeds.
/// - Executing before the delay elapses reverts.
/// - The CANCELLER_ROLE can stop a scheduled change.
contract TimelockIntegrationTest is Test {
    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");
    uint256 internal constant MIN_DELAY = 1 days;

    address internal admin = address(0xA11CE);
    address internal management = address(0xB0B);
    address internal receiverEOA = address(0x1111);
    address internal lender = address(0x2222);

    RoleManager internal roleManager;
    FlashLoanRouter internal router;
    TimelockController internal timelock;
    TimelockTestHelper internal helper;

    function setUp() public {
        // Deploy role manager with admin as DEFAULT_ADMIN.
        // Constructor grants TIMELOCKED_ADMIN_ROLE to `admin` for the bootstrap window.
        roleManager = new RoleManager(0, admin);

        // Bootstrap roles.
        vm.startPrank(admin);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        vm.stopPrank();

        // Deploy timelock + helper, then grant TIMELOCKED_ADMIN_ROLE to the timelock only.
        helper = new TimelockTestHelper();
        timelock = helper.deployTimelock(MIN_DELAY, admin);

        // Hand off TIMELOCKED_ADMIN_ROLE from the bootstrap admin to the timelock, then renounce
        // the bootstrap grant so direct calls from admin/management are guaranteed to revert.
        vm.startPrank(admin);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
        roleManager.renounceRole(TIMELOCKED_ADMIN_ROLE, admin);
        vm.stopPrank();

        // Deploy the router under test.
        router = new FlashLoanRouter(address(roleManager));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              DIRECT-CALL GATING (M-05 FIX)                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testRevert_SetFlashConfig_DirectFromManagement() public {
        // MANAGEMENT_ROLE is intentionally NOT enough to bypass the timelock.
        vm.prank(management);
        vm.expectRevert(LibError.Unauthorized.selector);
        router.setFlashConfig(receiverEOA, FlashLoanRouter.FlashSource.EULER, lender, true);
    }

    function testRevert_SetFlashConfig_DirectFromAdmin() public {
        // Even DEFAULT_ADMIN cannot call directly; only the timelock holds TIMELOCKED_ADMIN_ROLE.
        vm.prank(admin);
        vm.expectRevert(LibError.Unauthorized.selector);
        router.setFlashConfig(receiverEOA, FlashLoanRouter.FlashSource.EULER, lender, true);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              FULL TIMELOCK FLOW                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_SetFlashConfig_ViaTimelock() public {
        bytes memory data = abi.encodeCall(
            FlashLoanRouter.setFlashConfig,
            (receiverEOA, FlashLoanRouter.FlashSource.EULER, lender, true)
        );

        helper.runViaTimelock(timelock, address(router), data, admin);

        (FlashLoanRouter.FlashSource source, address storedLender, bool enabled) = router.flashConfig(receiverEOA);
        assertEq(uint8(source), uint8(FlashLoanRouter.FlashSource.EULER), "source mismatch");
        assertEq(storedLender, lender, "lender mismatch");
        assertTrue(enabled, "flash loan must be enabled");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          EARLY-EXECUTE REVERTS                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testRevert_Execute_BeforeDelay() public {
        bytes memory data = abi.encodeCall(
            FlashLoanRouter.setFlashConfig,
            (receiverEOA, FlashLoanRouter.FlashSource.EULER, lender, true)
        );

        bytes32 salt = helper.scheduleOnly(timelock, address(router), data, admin);

        // Try to execute immediately — must revert (operation Waiting, not Ready).
        vm.prank(admin);
        vm.expectRevert(); // OZ: TimelockUnexpectedOperationState(id, expectedStates)
        timelock.execute(address(router), 0, data, bytes32(0), salt);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          CANCEL FLOW                                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function test_Cancel_StopsScheduledChange() public {
        bytes memory data = abi.encodeCall(
            FlashLoanRouter.setFlashConfig,
            (receiverEOA, FlashLoanRouter.FlashSource.EULER, lender, true)
        );

        bytes32 salt = helper.scheduleOnly(timelock, address(router), data, admin);
        bytes32 id = timelock.hashOperation(address(router), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id), "operation should be pending after schedule");

        // Cancel via CANCELLER_ROLE (admin holds it via PROPOSER_ROLE constructor wiring).
        vm.prank(admin);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id), "operation should be unset after cancel");

        // Warp past delay — execute still must revert because it was cancelled.
        skip(MIN_DELAY + 1);
        vm.prank(admin);
        vm.expectRevert(); // TimelockUnexpectedOperationState
        timelock.execute(address(router), 0, data, bytes32(0), salt);

        // State is unchanged.
        (, address storedLender, bool enabled) = router.flashConfig(receiverEOA);
        assertEq(storedLender, address(0), "lender must remain unset");
        assertFalse(enabled, "config must remain disabled");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                       BOOTSTRAP-THEN-RENOUNCE FLOW                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Documents the OZ-recommended deployment-day pattern for TIMELOCKED_ADMIN_ROLE
    /// setters (oracle routes, flash configs, strategy wiring):
    ///
    /// 1. Deploy RoleManager — constructor grants TIMELOCKED_ADMIN_ROLE to the deployer for
    ///    the bootstrap window AND sets the role's admin to itself (self-administered).
    /// 2. Deploy TimelockController and app contracts (RoleManager-gated).
    /// 3. Apply day-0 config directly from the deployer (no delay).
    /// 4. Grant TIMELOCKED_ADMIN_ROLE to the TimelockController.
    ///    *** Must happen BEFORE renounce: once the deployer renounces, the role is
    ///    self-administered with zero holders and can never be granted again.
    /// 5. Renounce TIMELOCKED_ADMIN_ROLE from the deployer.
    /// 6. From this point every change MUST go through schedule -> wait -> execute, AND
    ///    no other party (not even DEFAULT_ADMIN) can grant the role to anyone else
    ///    without going through the timelock itself.
    function test_BootstrapThenRenounce_FlowMatchesDocs() public {
        address deployer = address(0x4626);
        RoleManager rm = new RoleManager(0, deployer);
        FlashLoanRouter freshRouter = new FlashLoanRouter(address(rm));
        TimelockController freshTimelock = helper.deployTimelock(MIN_DELAY, deployer);

        // constructor pre-granted TIMELOCKED_ADMIN_ROLE to the deployer and the
        // role is self-administered.
        assertTrue(
            rm.hasRole(TIMELOCKED_ADMIN_ROLE, deployer),
            "constructor must pre-grant TIMELOCKED_ADMIN_ROLE to the bootstrap admin"
        );
        assertEq(
            rm.getRoleAdmin(TIMELOCKED_ADMIN_ROLE),
            TIMELOCKED_ADMIN_ROLE,
            "TIMELOCKED_ADMIN_ROLE must be self-administered"
        );

        // Step 3: day-0 config applied directly, no delay.
        address bootstrapReceiver = address(0xAAA1);
        address bootstrapLender = address(0xAAA2);
        vm.prank(deployer);
        freshRouter.setFlashConfig(bootstrapReceiver, FlashLoanRouter.FlashSource.EULER, bootstrapLender, true);

        {
            (, address storedLender, bool enabled) = freshRouter.flashConfig(bootstrapReceiver);
            assertEq(storedLender, bootstrapLender, "bootstrap lender must be set immediately");
            assertTrue(enabled, "bootstrap config must be enabled immediately");
        }

        // Step 4: grant the role to the timelock BEFORE renouncing.
        vm.prank(deployer);
        rm.grantRole(TIMELOCKED_ADMIN_ROLE, address(freshTimelock));

        // Step 5: renounce the bootstrap grant.
        vm.prank(deployer);
        rm.renounceRole(TIMELOCKED_ADMIN_ROLE, deployer);

        // Step 6a: direct calls from the deployer must now revert.
        vm.prank(deployer);
        vm.expectRevert(LibError.Unauthorized.selector);
        freshRouter.setFlashConfig(bootstrapReceiver, FlashLoanRouter.FlashSource.MORPHO, bootstrapLender, true);

        // Step 6b: future changes MUST go through the timelock.
        address newLender = address(0xAAA3);
        bytes memory data = abi.encodeCall(
            FlashLoanRouter.setFlashConfig,
            (bootstrapReceiver, FlashLoanRouter.FlashSource.MORPHO, newLender, true)
        );
        helper.runViaTimelock(freshTimelock, address(freshRouter), data, deployer);

        (FlashLoanRouter.FlashSource src, address postRenounceLender, bool postRenounceEnabled) = freshRouter
            .flashConfig(bootstrapReceiver);
        assertEq(uint8(src), uint8(FlashLoanRouter.FlashSource.MORPHO), "post-renounce source mismatch");
        assertEq(postRenounceLender, newLender, "post-renounce lender mismatch");
        assertTrue(postRenounceEnabled, "post-renounce config must be enabled");

        bool hasRole = rm.hasRole(TIMELOCKED_ADMIN_ROLE, deployer);
        assertFalse(hasRole, "deployer must no longer hold TIMELOCKED_ADMIN_ROLE");
        assertTrue(
            rm.hasRole(TIMELOCKED_ADMIN_ROLE, address(freshTimelock)),
            "timelock must hold TIMELOCKED_ADMIN_ROLE"
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                  ROLE-ADMIN: SELF-ADMINISTERED TIMELOCKED_ADMIN_ROLE                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice After the bootstrap is renounced (see setUp), even the DEFAULT_ADMIN of
    /// RoleManager cannot grant TIMELOCKED_ADMIN_ROLE directly — the role is self-administered.
    /// The only way to grant it to another address is by scheduling the grant through the
    /// timelock itself.
    function testRevert_DefaultAdminCannotGrantTimelockedAdmin() public {
        // `admin` is DEFAULT_ADMIN of `roleManager` (set in setUp) but no longer holds
        // TIMELOCKED_ADMIN_ROLE (renounced in setUp).
        assertFalse(
            roleManager.hasRole(TIMELOCKED_ADMIN_ROLE, admin),
            "admin must not hold TIMELOCKED_ADMIN_ROLE post-renounce"
        );

        // Direct grant from DEFAULT_ADMIN reverts because the role is self-administered.
        vm.prank(admin);
        vm.expectRevert(); // OZ: AccessControlUnauthorizedAccount(admin, TIMELOCKED_ADMIN_ROLE)
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, admin);
    }

    /// @notice The timelock (which holds the role) CAN grant TIMELOCKED_ADMIN_ROLE to another
    /// address — but only by going through schedule -> wait -> execute. This documents the
    /// emergency / rotation path.
    function test_TimelockCanGrantTimelockedAdminRoleViaItself() public {
        address rotatedTimelock = address(0xC0FFEE);

        bytes memory data = abi.encodeCall(roleManager.grantRole, (TIMELOCKED_ADMIN_ROLE, rotatedTimelock));
        helper.runViaTimelock(timelock, address(roleManager), data, admin);

        assertTrue(
            roleManager.hasRole(TIMELOCKED_ADMIN_ROLE, rotatedTimelock),
            "rotated timelock must hold TIMELOCKED_ADMIN_ROLE after delayed grant"
        );
    }
}
