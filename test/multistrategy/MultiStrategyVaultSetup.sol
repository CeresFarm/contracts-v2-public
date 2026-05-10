// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {MultiStrategyVault} from "src/strategies/MultiStrategyVault.sol";
import {IMultiStrategyVault} from "src/interfaces/strategies/IMultiStrategyVault.sol";
import {ICeresBaseVault} from "src/interfaces/strategies/ICeresBaseVault.sol";
import {ILeveragedStrategy} from "src/interfaces/strategies/ILeveragedStrategy.sol";

import {RoleManager} from "src/periphery/RoleManager.sol";

import {MockERC20} from "../mock/common/MockERC20.sol";
import {MinimalCeresStrategy} from "../mock/common/MinimalCeresStrategy.sol";

/// @title MultiStrategyVaultSetup
/// @notice Common setup for MultiStrategyVault tests.
/// Vault (MultiStrategyVault): Two child strategies (MinimalCeresStrategy) with same asset and no-op market operations.
abstract contract MultiStrategyVaultSetup is Test {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 internal constant BPS_PRECISION = 10_000;
    uint128 internal constant DEPOSIT_LIMIT = 100_000_000 * 1e18;
    uint128 internal constant REDEEM_LIMIT = type(uint128).max;
    uint128 internal constant ALLOCATION_CAP_A = 50_000_000 * 1e18;
    uint128 internal constant ALLOCATION_CAP_B = 50_000_000 * 1e18;

    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONTRACTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    IMultiStrategyVault internal vault;
    MinimalCeresStrategy internal childA;
    MinimalCeresStrategy internal childB;

    RoleManager internal roleManager;
    MockERC20 internal asset;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     TEST ACCOUNTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    address internal management;
    address internal keeper;
    address internal curator;
    address internal user1;
    address internal user2;
    address internal feeReceiver;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                         SETUP                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function setUp() public virtual {
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        curator = makeAddr("curator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        feeReceiver = makeAddr("feeReceiver");

        // Deploy asset token
        asset = new MockERC20("Test USDC", "USDC", 6);

        // Deploy role manager and grant roles
        roleManager = new RoleManager(2 days, management);
        vm.startPrank(management);
        roleManager.grantRole(MANAGEMENT_ROLE, management);
        roleManager.grantRole(KEEPER_ROLE, keeper);
        roleManager.grantRole(CURATOR_ROLE, curator);
        vm.stopPrank();

        // Deploy child strategy A
        address proxyA = Upgrades.deployTransparentProxy(
            "MinimalCeresStrategy.sol:MinimalCeresStrategy",
            management,
            abi.encodeCall(MinimalCeresStrategy.initialize, (address(asset), makeAddr("debtA"), address(roleManager)))
        );
        childA = MinimalCeresStrategy(proxyA);

        // Deploy child strategy B
        address proxyB = Upgrades.deployTransparentProxy(
            "MinimalCeresStrategy.sol:MinimalCeresStrategy",
            management,
            abi.encodeCall(MinimalCeresStrategy.initialize, (address(asset), makeAddr("debtB"), address(roleManager)))
        );
        childB = MinimalCeresStrategy(proxyB);

        // Configure children: large deposit limit, no redeem limit
        vm.startPrank(management);
        childA.setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT, 0);
        childB.setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT, 0);
        // Disable the linear profit-unlock buffer on the child strategies so that yield is
        // visible immediately to the parent vault's `IERC4626(child).convertToAssets(...)`
        // reads. With the default `profitUnlockPeriod = 1 days` the child's `totalAssets()`
        // would hide harvested yield until decayed, breaking the MSV report-strategy tests.
        childA.updateConfig(0, 0, 0, address(0), uint32(0));
        childB.updateConfig(0, 0, 0, address(0), uint32(0));
        vm.stopPrank();

        // Deploy MultiStrategyVault
        address vaultProxy = Upgrades.deployTransparentProxy(
            "MultiStrategyVault.sol:MultiStrategyVault",
            management,
            abi.encodeCall(
                MultiStrategyVault.initialize,
                (address(asset), "Ceres Multi-Strategy USDC", "ceres-USDC", address(roleManager))
            )
        );
        vault = IMultiStrategyVault(vaultProxy);

        // Configure vault limits
        vm.startPrank(management);
        vault.setDepositWithdrawLimits(DEPOSIT_LIMIT, REDEEM_LIMIT, 0);
        // Disable profit-unlock buffer on the vault so that reportStrategy immediately
        // updates totalAssets() (same reasoning as for child strategies above).
        vault.updateConfig(0, 0, 0, address(0), uint32(0));

        // Register child strategies and set allocation caps
        vault.addStrategy(address(childA));
        vault.addStrategy(address(childB));
        vault.setAllocationCap(address(childA), ALLOCATION_CAP_A);
        vault.setAllocationCap(address(childB), ALLOCATION_CAP_B);
        vm.stopPrank();

        // Labels for trace readability
        vm.label(address(vault), "MultiStrategyVault");
        vm.label(address(childA), "ChildStrategyA");
        vm.label(address(childB), "ChildStrategyB");
        vm.label(address(asset), "USDC");
        vm.label(address(roleManager), "RoleManager");
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(curator, "curator");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     HELPER FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _mintAndApprove(address token, address owner, address spender, uint256 amount) internal {
        MockERC20(token).mint(owner, amount);
        vm.prank(owner);
        IERC20(token).approve(spender, amount);
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove(address(asset), user, address(vault), amount);
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }

    function _allocateToChild(address child, uint256 assets) internal {
        vm.prank(curator);
        vault.allocate(child, assets);
    }

    function _requestDeallocateFromChild(address child, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(curator);
        requestId = vault.requestDeallocate(child, shares);
    }

    function _claimDeallocatedFromChild(address child) internal returns (uint256 assets) {
        uint256 claimableShares = ILeveragedStrategy(child).claimableRedeemRequest(address(vault));
        vm.prank(curator);
        assets = vault.claimDeallocated(child, claimableShares);
    }

    /// @dev Processes the child strategy's current request so claimDeallocated can be called.
    ///      MinimalCeresStrategy has no leverage, so extraData = 0 flash loan + empty swap.
    function _processChildRequest(MinimalCeresStrategy child) internal {
        vm.prank(keeper);
        child.processCurrentRequest(abi.encode(uint256(0), bytes(""), bytes("")));
    }

    function _processVaultRequest() internal {
        vm.prank(keeper);
        vault.processCurrentRequest(abi.encode(uint256(0), bytes(""), bytes("")));
    }

    function _reportStrategy(address child) internal {
        vm.prank(keeper);
        vault.reportStrategy(child);
    }

    function _harvestVault() internal {
        vm.prank(keeper);
        vault.harvestAndReport();
    }
}
