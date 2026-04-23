// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {OracleAdapter} from "../../src/periphery/OracleAdapter.sol";
import {UniversalOracleRouter} from "../../src/periphery/UniversalOracleRouter.sol";
import {IUniversalOracleRouter} from "../../src/interfaces/periphery/IUniversalOracleRouter.sol";
import {IOracleRoute} from "../../src/interfaces/periphery/IOracleRoute.sol";
import {RoleManager} from "../../src/periphery/RoleManager.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";
import {LibError} from "../../src/libraries/LibError.sol";
import {TimelockTestHelper} from "test/common/TimelockTestHelper.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

contract MockOracleRoute is IOracleRoute {
    uint256 public price = 1e18; // Default 1:1

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getQuote(uint256 amountIn, address, address) external view returns (uint256) {
        if (price == 0) revert LibError.InvalidPrice();
        return (amountIn * price) / 1e18;
    }
}

contract OracleAdapterTest is Test {
    using Math for uint256;

    OracleAdapter public adapter;
    UniversalOracleRouter public router;

    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockERC20 public debtToken;

    MockOracleRoute public mockRoute;
    RoleManager public roleManager;
    address public admin = address(0xABCD);

    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant TIMELOCKED_ADMIN_ROLE = keccak256("TIMELOCKED_ADMIN_ROLE");

    TimelockController public timelock;
    TimelockTestHelper public timelockHelper;
    uint256 public constant TIMELOCK_MIN_DELAY = 1 days;

    function setUp() public {
        roleManager = new RoleManager(0, admin);
        vm.prank(admin);
        roleManager.grantRole(MANAGEMENT_ROLE, admin);

        // Real timelock contract holds TIMELOCKED_ADMIN_ROLE
        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, admin);
        vm.startPrank(admin);
        roleManager.grantRole(TIMELOCKED_ADMIN_ROLE, address(timelock));
        // Renounce the constructor-bootstrap grant so admin can't bypass the timelock.
        roleManager.renounceRole(TIMELOCKED_ADMIN_ROLE, admin);
        vm.stopPrank();

        router = new UniversalOracleRouter(address(roleManager));

        assetToken = new MockERC20("Asset", "ASSET", 18);
        collateralToken = new MockERC20("Collateral", "COLL", 6);
        debtToken = new MockERC20("Debt", "DEBT", 8);

        mockRoute = new MockOracleRoute();

        adapter = new OracleAdapter(address(router), address(assetToken), address(collateralToken), address(debtToken));

        _setupRoutes();
    }

    function _setupRoutes() internal {
        mockRoute.setPrice(1e18); // Default to a 1:1 price bridging

        // Set path for ROUTER.quote(COLLATERAL, ASSET) and (COLLATERAL, DEBT) via the timelock.
        IUniversalOracleRouter.RouteStep[] memory collToAsset = new IUniversalOracleRouter.RouteStep[](1);
        collToAsset[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(assetToken),
            oracleRoute: address(mockRoute)
        });
        timelockHelper.runViaTimelock(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (address(collateralToken), address(assetToken), collToAsset)),
            admin
        );

        IUniversalOracleRouter.RouteStep[] memory collToDebt = new IUniversalOracleRouter.RouteStep[](1);
        collToDebt[0] = IUniversalOracleRouter.RouteStep({
            targetToken: address(debtToken),
            oracleRoute: address(mockRoute)
        });
        timelockHelper.runViaTimelock(
            timelock,
            address(router),
            abi.encodeCall(router.setRoute, (address(collateralToken), address(debtToken), collToDebt)),
            admin
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        FUZZ TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testFuzz_ConvertCollateralToAssets(uint256 amountIn, uint256 simulatedPrice) public {
        amountIn = bound(amountIn, 1, type(uint128).max);
        simulatedPrice = bound(simulatedPrice, 1, 1e24);

        mockRoute.setPrice(simulatedPrice);

        uint256 expected = (amountIn * simulatedPrice) / 1e18;
        uint256 result = adapter.convertCollateralToAssets(amountIn);

        assertEq(result, expected, "Raw Math mismatch inside adapter wrapper");
    }

    /// @notice Test bidirectional conversions.
    function testFuzz_BidirectionalConversion(uint256 collateralInput, uint256 priceChange) public {
        // Fuzz huge input and an extreme price (representing a sudden crash or pump)
        collateralInput = bound(collateralInput, 1, type(uint128).max);
        priceChange = bound(priceChange, 1, 50 * 1e24);

        mockRoute.setPrice(priceChange);

        // Forward conversion
        uint256 assetEquivalent = adapter.convertCollateralToAssets(collateralInput);

        // Sometimes extreme drop of `amountIn` results to 0, ignore such values
        if (assetEquivalent == 0) return;

        // Convert the exact asset equivalent back to collateral
        uint256 collConvertedResult = adapter.convertAssetsToCollateral(assetEquivalent);

        if (assetEquivalent > 10 ** assetToken.decimals()) {
            // For large amounts, we can expect some slippage due to rounding, but it should be minimal
            assertApproxEqRel(collConvertedResult, collateralInput, 1e15, "Asymmetrical Reverse Route Issue!");
        } else {
            // For small amounts, we allow a higher absolute slippage due to the nature of inverse quoting and rounding
            uint256 maxError = (1e18 / priceChange) + 1;
            assertApproxEqAbs(collConvertedResult, collateralInput, maxError, "Asymmetrical Reverse Route Issue!");
        }
    }

    function test_Revert_ConvertZeroAmounts() public view {
        assertEq(adapter.convertCollateralToAssets(0), 0);
        assertEq(adapter.convertAssetsToCollateral(0), 0);

        assertEq(adapter.convertAssetsToDebt(0), 0);
        assertEq(adapter.convertDebtToAssets(0), 0);

        assertEq(adapter.convertCollateralToDebt(0), 0);
        assertEq(adapter.convertDebtToCollateral(0), 0);
    }
}
