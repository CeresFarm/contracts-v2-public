// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CeresSwapper} from "src/periphery/CeresSwapper.sol";
import {ICeresSwapper} from "src/interfaces/periphery/ICeresSwapper.sol";
import {IParaSwapAugustusRegistry} from "src/interfaces/paraswap/IParaSwapAugustusRegistry.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {LibError} from "src/libraries/LibError.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";

/// @dev Minimal Augustus registry mock that always reports the queried address as invalid.
/// The constructor only checks `isValidAugustus(address(0)) == false`; the call sites that
/// validate per-swap routers are unreachable in these tests because the selector validation
/// reverts first (which is exactly what we are exercising).
contract MockAugustusRegistry is IParaSwapAugustusRegistry {
    function isValidAugustus(address) external pure returns (bool) {
        return false;
    }
}

/// @title CeresSwapperTest
/// @notice Focused tests for the Paraswap selector / direction-mismatch protection added to
/// `CeresSwapper.swapFrom` and `CeresSwapper.swapTo`.
contract CeresSwapperTest is Test {
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant VAULT_OR_STRATEGY = keccak256("VAULT_OR_STRATEGY");

    bytes4 internal constant PARASWAP_SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;
    bytes4 internal constant PARASWAP_SWAP_EXACT_AMOUNT_OUT = 0x7f457675;

    CeresSwapper internal swapper;
    RoleManager internal roleManager;
    MockAugustusRegistry internal augustusRegistry;

    MockERC20 internal fromToken;
    MockERC20 internal toToken;

    address internal fakeRouter = address(0xA0A0);
    address internal caller = address(this); // also bootstrap admin

    function setUp() public {
        roleManager = new RoleManager(0, address(this));
        augustusRegistry = new MockAugustusRegistry();

        swapper = new CeresSwapper(address(roleManager), address(0), address(augustusRegistry));

        // The test contract receives MANAGEMENT_ROLE from the RoleManager constructor; grant the
        // VAULT_OR_STRATEGY role explicitly so it can call `swapFrom` / `swapTo`.
        roleManager.grantRole(VAULT_OR_STRATEGY, address(this));

        fromToken = new MockERC20("From", "FROM", 18);
        toToken = new MockERC20("To", "TO", 18);

        // Configure a Paraswap provider for the (fromToken, toToken) pair in both directions.
        swapper.setSwapProvider(
            address(fromToken),
            address(toToken),
            ICeresSwapper.SwapProvider({swapType: ICeresSwapper.SwapType.PARASWAP_AGGREGATOR, router: fakeRouter})
        );
        swapper.setSwapProvider(
            address(toToken),
            address(fromToken),
            ICeresSwapper.SwapProvider({swapType: ICeresSwapper.SwapType.PARASWAP_AGGREGATOR, router: fakeRouter})
        );
    }

    /// @dev Builds a calldata blob with the supplied 4-byte selector followed by enough zero
    ///      padding so the offset bounds-check inside the contract would pass if reached.
    function _swapDataWith(bytes4 selector) internal pure returns (bytes memory data) {
        data = new bytes(256);
        assembly {
            mstore(add(data, 32), selector)
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          PARASWAP SELECTOR / DIRECTION MISMATCH                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice `swapFrom` (exact-in path) must reject the `swapExactAmountOut` selector so a keeper
    ///         cannot inject exact-out semantics through the exact-in entry point.
    function testRevert_SwapFrom_RejectsExactOutSelector() public {
        uint256 amountIn = 1_000 ether;
        fromToken.mint(address(this), amountIn);
        fromToken.approve(address(swapper), amountIn);

        bytes memory swapData = _swapDataWith(PARASWAP_SWAP_EXACT_AMOUNT_OUT);

        vm.expectRevert(LibError.InvalidSwapSelector.selector);
        swapper.swapFrom(address(fromToken), address(toToken), amountIn, 0, address(this), swapData);
    }

    /// @notice `swapFrom` must also reject any unknown selector.
    function testRevert_SwapFrom_RejectsUnknownSelector() public {
        uint256 amountIn = 1_000 ether;
        fromToken.mint(address(this), amountIn);
        fromToken.approve(address(swapper), amountIn);

        bytes memory swapData = _swapDataWith(bytes4(0xdeadbeef));

        vm.expectRevert(LibError.InvalidSwapSelector.selector);
        swapper.swapFrom(address(fromToken), address(toToken), amountIn, 0, address(this), swapData);
    }

    /// @notice `swapTo` (exact-out path) must reject the `swapExactAmountIn` selector so a keeper
    ///         cannot inject exact-in semantics through the exact-out entry point.
    function testRevert_SwapTo_RejectsExactInSelector() public {
        uint256 maxAmountIn = 1_000 ether;
        uint256 amountOut = 500 ether;
        toToken.mint(address(this), maxAmountIn);
        toToken.approve(address(swapper), maxAmountIn);

        bytes memory swapData = _swapDataWith(PARASWAP_SWAP_EXACT_AMOUNT_IN);

        vm.expectRevert(LibError.InvalidSwapSelector.selector);
        swapper.swapTo(address(toToken), address(fromToken), maxAmountIn, amountOut, address(this), swapData);
    }

    /// @notice `swapTo` must also reject any unknown selector.
    function testRevert_SwapTo_RejectsUnknownSelector() public {
        uint256 maxAmountIn = 1_000 ether;
        uint256 amountOut = 500 ether;
        toToken.mint(address(this), maxAmountIn);
        toToken.approve(address(swapper), maxAmountIn);

        bytes memory swapData = _swapDataWith(bytes4(0x12345678));

        vm.expectRevert(LibError.InvalidSwapSelector.selector);
        swapper.swapTo(address(toToken), address(fromToken), maxAmountIn, amountOut, address(this), swapData);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       RESCUE TOKENS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice `rescueTokens` sweeps the swapper's full balance of the requested token to the
    ///         management caller and emits `TokensRecovered`.
    function test_RescueTokens_SweepsBalanceToCaller() public {
        uint256 stuck = 1_234 ether;
        fromToken.mint(address(swapper), stuck);

        uint256 callerBalanceBefore = fromToken.balanceOf(address(this));

        vm.expectEmit(true, false, false, true, address(swapper));
        emit CeresSwapper.TokensRecovered(address(fromToken), stuck);

        swapper.rescueTokens(address(fromToken));

        assertEq(fromToken.balanceOf(address(swapper)), 0, "swapper balance must be zero after rescue");
        assertEq(
            fromToken.balanceOf(address(this)),
            callerBalanceBefore + stuck,
            "caller must receive the full rescued balance"
        );
    }

    /// @notice `rescueTokens` is a no-op (zero transfer, zero-amount event) when the swapper holds
    ///         no balance of the requested token.
    function test_RescueTokens_ZeroBalanceIsNoop() public {
        uint256 callerBalanceBefore = toToken.balanceOf(address(this));

        vm.expectEmit(true, false, false, true, address(swapper));
        emit CeresSwapper.TokensRecovered(address(toToken), 0);

        swapper.rescueTokens(address(toToken));

        assertEq(toToken.balanceOf(address(this)), callerBalanceBefore, "caller balance must be unchanged");
    }

    /// @notice Only `MANAGEMENT_ROLE` may invoke `rescueTokens`.
    function testRevert_RescueTokens_Unauthorized() public {
        address attacker = address(0xBEEF);
        fromToken.mint(address(swapper), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(LibError.Unauthorized.selector);
        swapper.rescueTokens(address(fromToken));
    }
}
