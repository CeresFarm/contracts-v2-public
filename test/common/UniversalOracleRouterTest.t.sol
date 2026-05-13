// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {UniversalOracleRouter} from "src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "src/interfaces/periphery/IUniversalOracleRouter.sol";
import {IOracleRoute} from "src/interfaces/periphery/IOracleRoute.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";
import {LibError} from "src/libraries/LibError.sol";
import {TimelockTestHelper} from "test/common/TimelockTestHelper.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

contract MockOracleRoute is IOracleRoute {
    uint256 public price;
    uint256 public expectedDecimals;
    bool public shouldRevert;

    function setPrice(uint256 _price) external {
        price = _price;
    }
    function setExpectedDecimals(uint256 _dec) external {
        expectedDecimals = _dec;
    }
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getQuote(uint256 amountIn, address /* tokenIn */, address /* tokenOut */) external view returns (uint256) {
        if (shouldRevert) revert LibError.OracleError();
        if (price == 0) revert LibError.InvalidPrice(); // mimic our lib enforcing non-zero

        // Simulating the mulDiv operation for scaling
        return (amountIn * price) / (10 ** expectedDecimals);
    }
}

contract UniversalOracleRouterTest is Test {
    UniversalOracleRouter public router;
    RoleManager public roleManager;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    MockOracleRoute public mockRouteAB;
    MockOracleRoute public mockRouteBC;

    address public owner = address(0xABCD);

    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    TimelockController public timelock;
    TimelockTestHelper public timelockHelper;
    uint256 public constant TIMELOCK_MIN_DELAY = 1 days;

    function setUp() public {
        roleManager = new RoleManager(0, owner);
        vm.prank(owner);
        roleManager.grantRole(MANAGEMENT_ROLE, owner);

        // Deploy real timelock and grant it the TIMELOCKED_ADMIN_ROLE so route updates
        // exercise the production schedule -> wait -> execute path.
        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, owner);
        vm.startPrank(owner);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
        // Renounce the constructor-bootstrap grant so owner can't bypass the timelock.
        roleManager.renounceRole(TIMELOCKED_ADMIN_ROLE, owner);
        vm.stopPrank();

        router = new UniversalOracleRouter(address(roleManager));

        tokenA = new MockERC20("Token A", "TKN_A", 6);
        tokenB = new MockERC20("Token B", "TKN_B", 8); // e.g. Virtual USD scale intermediary
        tokenC = new MockERC20("Token C", "TKN_C", 18);

        mockRouteAB = new MockOracleRoute();
        mockRouteBC = new MockOracleRoute();
    }

    /// @dev Routes a setRoute call through the real timelock, pranking `owner` as proposer/executor.
    function _setRoute(address tokenIn, address tokenOut, IUniversalOracleRouter.RouteStep[] memory path) internal {
        timelockHelper.runViaTimelock(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (tokenIn, tokenOut, path)),
            owner
        );
    }

    /// @notice Test Track 1: First principles valid quote logic (fuzzing)
    function testFuzz_ValidQuote(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, type(uint128).max);

        mockRouteAB.setPrice(2e8);
        mockRouteAB.setExpectedDecimals(8); // Price has 8 decs

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        _setRoute(address(tokenA), address(tokenB), path);

        uint256 result = router.quote(address(tokenA), address(tokenB), amountIn);
        uint256 expected = (amountIn * 2e8) / 1e8;
        assertEq(result, expected, "Fuzz direct quote mismatch");
    }

    /// @notice Test Track 2: Test Multi Hop with extensive decimal mismatches
    function testFuzz_MultiHopPrecision(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, type(uint128).max);

        // A -> B (price: 5, expected 8 dec)
        mockRouteAB.setPrice(5e8);
        mockRouteAB.setExpectedDecimals(8);

        // B -> C (price: 2, expected 18 dec)
        mockRouteBC.setPrice(2e18);
        mockRouteBC.setExpectedDecimals(18);

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](2);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});
        path[1] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenC), oracleRoute: address(mockRouteBC)});

        _setRoute(address(tokenA), address(tokenC), path);

        uint256 result = router.quote(address(tokenA), address(tokenC), amountIn);

        uint256 step1 = (amountIn * 5e8) / 1e8;
        uint256 finalExpected = (step1 * 2e18) / 1e18;

        assertEq(result, finalExpected, "MultiHop precision drop");
    }

    /// @notice Test Track 3: Malicious Oracle / Edge Case Returns
    function testRevert_ZeroAmount() public view {
        uint256 result = router.quote(address(tokenA), address(tokenB), 0);
        assertEq(result, 0, "Zero amount must safely return 0 without routing");
    }

    function testRevert_MaliciousZeroPrice() public {
        mockRouteAB.setPrice(0); // Attack vector: Oracle drops to 0

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        _setRoute(address(tokenA), address(tokenB), path);

        vm.expectRevert(LibError.InvalidPrice.selector);
        router.quote(address(tokenA), address(tokenB), 1e6);
    }

    function testRevert_OracleReverts() public {
        mockRouteAB.setShouldRevert(true);

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        _setRoute(address(tokenA), address(tokenB), path);

        vm.expectRevert(LibError.OracleError.selector);
        router.quote(address(tokenA), address(tokenB), 1e6);
    }

    /// @notice Test Track 4: Route Validation (Admin Misconfiguration)
    function testRevert_SetRoute_NotOwner() public {
        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        vm.prank(address(0xBEEF));
        vm.expectRevert(LibError.Unauthorized.selector);
        router.setRoute(address(tokenA), address(tokenB), path);
    }

    function testRevert_SetRoute_InvalidFinalToken() public {
        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        // Intentionally setting the target token incorrectly vs expected final out mapping
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenC), oracleRoute: address(mockRouteAB)});

        // Trying to map A -> B, but path ends at C. Inner revert bubbles up from `execute`.
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (address(tokenA), address(tokenB), path)),
            owner,
            LibError.InvalidToken.selector
        );
    }

    function testRevert_SetRoute_ZeroAddressNode() public {
        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(tokenB),
            oracleRoute: address(0) // Malicious / Invalid Admin Check
        });

        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (address(tokenA), address(tokenB), path)),
            owner,
            LibError.InvalidOracleRoute.selector
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SET ROUTE TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice setRoute applies the change atomically and emits RouteUpdated.
    function test_SetRoute_AppliesAtomically() public {
        mockRouteAB.setPrice(1e8);
        mockRouteAB.setExpectedDecimals(8);

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        vm.expectEmit(true, true, false, false);
        emit IUniversalOracleRouter.RouteUpdated(address(tokenA), address(tokenB), path);
        _setRoute(address(tokenA), address(tokenB), path);

        // Route is live immediately after execute
        assertGt(router.quote(address(tokenA), address(tokenB), 1e6), 0);
        assertEq(router.getRoute(address(tokenA), address(tokenB))[0].oracleRoute, address(mockRouteAB));
    }

    /// @notice setRoute called twice replaces the route.
    function test_SetRoute_Replaces() public {
        mockRouteAB.setPrice(1e8);
        mockRouteAB.setExpectedDecimals(8);

        IUniversalOracleRouter.RouteStep[] memory initialPath = new IUniversalOracleRouter.RouteStep[](1);
        initialPath[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(tokenB),
            oracleRoute: address(mockRouteAB)
        });

        _setRoute(address(tokenA), address(tokenB), initialPath);

        MockOracleRoute newRoute = new MockOracleRoute();
        newRoute.setPrice(2e8);
        newRoute.setExpectedDecimals(8);

        IUniversalOracleRouter.RouteStep[] memory newPath = new IUniversalOracleRouter.RouteStep[](1);
        newPath[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(newRoute)});

        _setRoute(address(tokenA), address(tokenB), newPath);

        assertEq(router.getRoute(address(tokenA), address(tokenB))[0].oracleRoute, address(newRoute));
    }

    /// @notice setRoute reverts on empty path.
    function testRevert_SetRoute_EmptyPath() public {
        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](0);

        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (address(tokenA), address(tokenB), path)),
            owner,
            LibError.InvalidOracleRoute.selector
        );
    }
}
