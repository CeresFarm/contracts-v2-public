// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {UniversalOracleRouter} from "src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "src/interfaces/periphery/IUniversalOracleRouter.sol";
import {IOracleRoute} from "src/interfaces/periphery/IOracleRoute.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";
import {LibError} from "src/libraries/LibError.sol";

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

    function setUp() public {
        roleManager = new RoleManager(0, owner);
        vm.prank(owner);
        roleManager.grantRole(MANAGEMENT_ROLE, owner);

        router = new UniversalOracleRouter(address(roleManager));

        tokenA = new MockERC20("Token A", "TKN_A", 6);
        tokenB = new MockERC20("Token B", "TKN_B", 8); // e.g. Virtual USD scale intermediary
        tokenC = new MockERC20("Token C", "TKN_C", 18);

        mockRouteAB = new MockOracleRoute();
        mockRouteBC = new MockOracleRoute();
    }

    /// @notice Test Track 1: First principles valid quote logic (fuzzing)
    function testFuzz_ValidQuote(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, type(uint128).max);

        mockRouteAB.setPrice(2e8);
        mockRouteAB.setExpectedDecimals(8); // Price has 8 decs

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        vm.prank(owner);
        router.setRoute(address(tokenA), address(tokenB), path);

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

        vm.prank(owner);
        router.setRoute(address(tokenA), address(tokenC), path);

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

        vm.prank(owner);
        router.setRoute(address(tokenA), address(tokenB), path);

        vm.expectRevert(LibError.InvalidPrice.selector);
        router.quote(address(tokenA), address(tokenB), 1e6);
    }

    function testRevert_OracleReverts() public {
        mockRouteAB.setShouldRevert(true);

        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({targetToken: address(tokenB), oracleRoute: address(mockRouteAB)});

        vm.prank(owner);
        router.setRoute(address(tokenA), address(tokenB), path);

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

        vm.prank(owner);
        vm.expectRevert(LibError.InvalidToken.selector);
        // Trying to map A -> B, but path ends at C!
        router.setRoute(address(tokenA), address(tokenB), path);
    }

    function testRevert_SetRoute_ZeroAddressNode() public {
        IUniversalOracleRouter.RouteStep[] memory path = new IUniversalOracleRouter.RouteStep[](1);
        path[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(tokenB),
            oracleRoute: address(0) // Malicious / Invalid Admin Check
        });

        vm.prank(owner);
        vm.expectRevert(LibError.InvalidOracleRoute.selector);
        router.setRoute(address(tokenA), address(tokenB), path);
    }
}
