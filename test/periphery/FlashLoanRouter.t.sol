// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {FlashLoanRouter} from "src/periphery/FlashLoanRouter.sol";
import {IFlashLoanRouter} from "src/interfaces/periphery/IFlashLoanRouter.sol";
import {IFlashLoanReceiver} from "src/interfaces/periphery/IFlashLoanReceiver.sol";
import {IERC3156FlashBorrower} from "@openzeppelin-contracts/interfaces/IERC3156FlashBorrower.sol";
import {RoleManager} from "src/periphery/RoleManager.sol";
import {MockERC20} from "test/mock/common/MockERC20.sol";
import {LibError} from "src/libraries/LibError.sol";
import {TimelockTestHelper} from "test/common/TimelockTestHelper.sol";
import {TimelockController} from "@openzeppelin-contracts/governance/TimelockController.sol";

/// @title FlashLoanRouterTest
/// @notice Comprehensive test suite for FlashLoanRouter contract
/// @dev Tests cover all flash loan sources (Euler, Morpho, ERC3156), access control, validation, and edge cases
contract FlashLoanRouterTest is Test {
    using SafeERC20 for IERC20;

    FlashLoanRouter public router;
    RoleManager public roleManager;
    MockERC20 public token;
    MockReceiver public receiver;

    MockEulerVault public eulerLender;
    MockERC3156Lender public erc3156Lender;
    MockMorphoMarket public morphoLender;

    address public admin = address(this);
    address public unauthorizedUser = address(0x1234);

    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");

    TimelockController public timelock;
    TimelockTestHelper public timelockHelper;
    uint256 public constant TIMELOCK_MIN_DELAY = 1 days;

    event FlashConfigUpdated(
        address indexed receiver,
        FlashLoanRouter.FlashSource source,
        address indexed lender,
        bool enabled
    );
    event FlashLoanRouted(
        address indexed receiver,
        FlashLoanRouter.FlashSource source,
        address indexed token,
        uint256 amount
    );
    event TokensRecovered(address indexed token, uint256 amount);

    function setUp() public {
        roleManager = new RoleManager(0, address(this));
        // Deploy a real TimelockController and grant it TIMELOCKED_ADMIN_ROLE so setFlashConfig/
        // rescueTokens are exercised through the production schedule -> wait -> execute flow.
        timelockHelper = new TimelockTestHelper();
        timelock = timelockHelper.deployTimelock(TIMELOCK_MIN_DELAY, address(this));
        roleManager.grantRole(keccak256("TIMELOCKED_ADMIN_ROLE"), address(timelock));
        // Renounce the constructor-bootstrap grant so address(this) cannot bypass the timelock.
        roleManager.renounceRole(keccak256("TIMELOCKED_ADMIN_ROLE"), address(this));
        router = new FlashLoanRouter(address(roleManager));
        token = new MockERC20("Mock Debt", "DEBT", 18);
        receiver = new MockReceiver(address(router), address(token));

        eulerLender = new MockEulerVault(token);
        erc3156Lender = new MockERC3156Lender(token);
        morphoLender = new MockMorphoMarket(token);
    }

    /// @dev Routes a `setFlashConfig` call through the real timelock with `address(this)` as proposer/executor.
    function _setFlashConfig(
        address _receiver,
        FlashLoanRouter.FlashSource source,
        address lender,
        bool enabled
    ) internal {
        timelockHelper.runViaTimelock(
            timelock,
            address(router),
            abi.encodeCall(router.setFlashConfig, (_receiver, source, lender, enabled)),
            address(this)
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 CONSTRUCTOR TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(LibError.ZeroAddress.selector);
        new FlashLoanRouter(address(0));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                            FLASH LOAN ROUTING TESTS - EULER                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test successful Euler flash loan with fee collection
    function testEulerRouteAndRepayWithFee() public {
        uint256 amount = 1_000e18;
        uint256 fee = 5e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
        eulerLender.setFee(fee);

        // Lender needs liquidity to loan out
        token.mint(address(eulerLender), amount);

        // MockReceiver needs fee amount to repay on top of the borrowed amount
        token.mint(address(receiver), fee);

        receiver.initiate(address(token), amount, hex"");

        assertEq(token.balanceOf(address(eulerLender)), amount + fee, "lender should have principal + fee");
        assertEq(token.balanceOf(address(receiver)), 0, "receiver should have zero after repayment");
    }

    /// @notice Test Euler flash loan with zero fee
    function testEulerRouteZeroFee() public {
        uint256 amount = 1_000e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        token.mint(address(eulerLender), amount);

        receiver.initiate(address(token), amount, hex"");

        assertEq(token.balanceOf(address(eulerLender)), amount, "lender repaid principal");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                            FLASH LOAN ROUTING TESTS - MORPHO                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test successful Morpho flash loan with zero fee (Morpho doesn't charge fees)
    function testMorphoRouteZeroFee() public {
        uint256 amount = 2_000e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.MORPHO, address(morphoLender), true);

        token.mint(address(morphoLender), amount);

        receiver.initiate(address(token), amount, hex"");

        assertEq(token.balanceOf(address(morphoLender)), amount, "morpho lender repaid principal");
        assertEq(token.balanceOf(address(receiver)), 0, "receiver repaid");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                            FLASH LOAN ROUTING TESTS - ERC3156                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test ERC3156 flash loan with fee (e.g., Silo)
    function testERC3156RouteWithFee() public {
        uint256 amount = 1_500e18;
        uint256 fee = 10e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.ERC3156, address(erc3156Lender), true);
        erc3156Lender.setFee(fee);

        // Lender needs liquidity to loan out
        token.mint(address(erc3156Lender), amount);

        // MockReceiver needs fee amount to repay on top of the borrowed amount
        token.mint(address(receiver), fee);

        receiver.initiate(address(token), amount, hex"");

        assertEq(token.balanceOf(address(erc3156Lender)), amount + fee, "lender should have principal + fee");
        assertEq(token.balanceOf(address(receiver)), 0, "receiver should have zero after repayment");
    }

    /// @notice Test ERC3156 flash loan with zero fee
    function testERC3156RouteZeroFee() public {
        uint256 amount = 1_500e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.ERC3156, address(erc3156Lender), true);

        token.mint(address(erc3156Lender), amount);

        receiver.initiate(address(token), amount, hex"");

        assertEq(token.balanceOf(address(erc3156Lender)), amount, "lender repaid principal");
    }

    /// @notice Test ERC3156 validation - rejects corrupted token in callback
    function testERC3156GuardRevertsOnWrongToken() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.ERC3156, address(erc3156Lender), true);

        // Lender needs liquidity
        token.mint(address(erc3156Lender), 500e18);

        erc3156Lender.setInvalidToken(address(0xBEEF));
        vm.expectRevert(LibError.InvalidToken.selector);
        receiver.initiate(address(token), 500e18, hex"");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 VALIDATION TESTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test flash loan request with zero amount is rejected
    function testRequestFlashLoanRevertsOnZeroAmount() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        vm.expectRevert(LibError.InvalidAmount.selector);
        receiver.initiate(address(token), 0, hex"");
    }

    /// @notice Test flash loan request with zero token address is rejected
    function testRequestFlashLoanRevertsOnZeroToken() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        vm.expectRevert(LibError.InvalidToken.selector);
        receiver.initiate(address(0), 1000e18, hex"");
    }

    /// @notice Test flash loan request when config is disabled
    function testRequestFlashLoanRevertsWhenDisabled() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), false);

        token.mint(address(eulerLender), 1000e18);

        vm.expectRevert(LibError.InvalidAction.selector);
        receiver.initiate(address(token), 1000e18, hex"");
    }

    /// @notice Test flash loan request when no config is set
    function testRequestFlashLoanRevertsWhenNoConfig() public {
        token.mint(address(eulerLender), 1000e18);

        vm.expectRevert(LibError.InvalidAction.selector);
        receiver.initiate(address(token), 1000e18, hex"");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              CALLBACK SECURITY TESTS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test Euler callback rejects wrong lender
    function testEulerCallbackRevertsOnWrongLender() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        MockEulerVault fakeLender = new MockEulerVault(token);
        token.mint(address(fakeLender), 1000e18);

        // Directly call the Euler callback from wrong lender - should revert
        vm.expectRevert(LibError.InvalidAction.selector);
        vm.prank(address(fakeLender));
        router.onFlashLoan(abi.encode(address(token), 1000e18, hex""));
    }

    /// @notice Test Morpho callback rejects wrong lender
    function testMorphoCallbackRevertsOnWrongLender() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.MORPHO, address(morphoLender), true);

        MockMorphoMarket fakeLender = new MockMorphoMarket(token);
        token.mint(address(fakeLender), 1000e18);

        // Directly call the Morpho callback from wrong lender - should revert
        vm.expectRevert(LibError.InvalidAction.selector);
        vm.prank(address(fakeLender));
        router.onMorphoFlashLoan(1000e18, abi.encode(address(token), 1000e18, hex""));
    }

    /// @notice Test ERC3156 callback rejects wrong initiator
    function testERC3156CallbackRevertsOnWrongInitiator() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.ERC3156, address(erc3156Lender), true);
        erc3156Lender.setWrongInitiator(address(0xBEEF));

        token.mint(address(erc3156Lender), 1000e18);

        vm.expectRevert(LibError.InvalidInitiator.selector);
        receiver.initiate(address(token), 1000e18, hex"");
    }

    /// @notice Test receiver revert is properly handled
    function testReceiverRevert() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        token.mint(address(eulerLender), 1000e18);
        receiver.setShouldRevert(true);

        vm.expectRevert("receiver revert");
        receiver.initiate(address(token), 1000e18, hex"");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              REENTRANCE PROTECTION TESTS                                  //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test that concurrent flash loans are prevented
    function testReentrancyProtection() public {
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        MockReentrantReceiver reentrantReceiver = new MockReentrantReceiver(
            address(router),
            address(token),
            address(eulerLender)
        );
        _setFlashConfig(address(reentrantReceiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        token.mint(address(eulerLender), 2000e18);

        vm.expectRevert(LibError.PendingActionExists.selector);
        reentrantReceiver.initiate(address(token), 1000e18, hex"");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              ACCESS CONTROL TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test only TIMELOCKED_ADMIN_ROLE can set flash config. Direct call from a
    /// non-role-holder must revert without going through the timelock.
    function testSetFlashConfigRequiresManagementRole() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(LibError.Unauthorized.selector);
        router.setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
    }

    /// @notice Test setFlashConfig reverts on zero receiver address (assertion runs through the timelock).
    function testSetFlashConfigRevertsOnZeroReceiver() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(router),
            abi.encodeCall(
                router.setFlashConfig,
                (address(0), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true)
            ),
            address(this),
            LibError.InvalidAddress.selector
        );
    }

    /// @notice Test setFlashConfig reverts on zero lender address (assertion runs through the timelock).
    function testSetFlashConfigRevertsOnZeroLender() public {
        timelockHelper.runViaTimelockExpectRevert(
            timelock,
            address(router),
            abi.encodeCall(
                router.setFlashConfig,
                (address(receiver), FlashLoanRouter.FlashSource.EULER, address(0), true)
            ),
            address(this),
            LibError.InvalidAddress.selector
        );
    }

    /// @notice Test only MANAGEMENT_ROLE can rescue tokens. Direct call from a non-role-holder must revert.
    function testRescueTokensRequiresManagementRole() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(LibError.Unauthorized.selector);
        router.rescueTokens(address(token));
    }

    /// @notice Test rescue tokens works when no flash loan is pending
    function testRescueTokensSucceedsWhenNoPending() public {
        uint256 amount = 100e18;
        token.mint(address(router), amount);

        router.rescueTokens(address(token));

        assertEq(token.balanceOf(address(router)), 0);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   EVENT TESTS                                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test FlashConfigUpdated event is emitted
    function testFlashConfigUpdatedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit FlashConfigUpdated(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
    }

    /// @notice Test FlashLoanRouted event is emitted
    function testFlashLoanRoutedEvent() public {
        uint256 amount = 1_000e18;

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
        token.mint(address(eulerLender), amount);

        vm.expectEmit(true, true, true, true);
        emit FlashLoanRouted(address(receiver), FlashLoanRouter.FlashSource.EULER, address(token), amount);

        receiver.initiate(address(token), amount, hex"");
    }

    /// @notice Test TokensRecovered event is emitted
    function testTokensRecoveredEvent() public {
        uint256 amount = 100e18;
        token.mint(address(router), amount);

        vm.expectEmit(true, false, false, true);
        emit TokensRecovered(address(token), amount);

        router.rescueTokens(address(token));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   EDGE CASE TESTS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Test updating flash config from one source to another
    function testUpdateFlashConfig() public {
        // Initially set to Euler
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
        (FlashLoanRouter.FlashSource source, address lender, bool enabled) = router.flashConfig(address(receiver));
        assertEq(uint256(source), uint256(FlashLoanRouter.FlashSource.EULER));
        assertEq(lender, address(eulerLender));
        assertTrue(enabled);

        // Update to Morpho
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.MORPHO, address(morphoLender), true);
        (source, lender, enabled) = router.flashConfig(address(receiver));
        assertEq(uint256(source), uint256(FlashLoanRouter.FlashSource.MORPHO));
        assertEq(lender, address(morphoLender));
        assertTrue(enabled);
    }

    /// @notice Test disabling and re-enabling flash config
    function testDisableAndReenableFlashConfig() public {
        uint256 amount = 1_000e18;

        // Enable config
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
        token.mint(address(eulerLender), amount * 2);

        // Should work
        receiver.initiate(address(token), amount, hex"");

        // Disable config
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), false);

        // Should fail
        vm.expectRevert(LibError.InvalidAction.selector);
        receiver.initiate(address(token), amount, hex"");

        // Re-enable
        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);

        // Should work again
        receiver.initiate(address(token), amount, hex"");
    }

    /// @notice Test rescue tokens functionality
    function testRescueTokens() public {
        uint256 amount = 100e18;
        token.mint(address(router), amount);

        // rescueTokens is MANAGEMENT_ROLE-gated (no timelock) and sends to msg.sender, so the
        // admin EOA receives the rescued tokens directly.
        uint256 adminBalanceBefore = token.balanceOf(admin);

        router.rescueTokens(address(token));

        assertEq(token.balanceOf(address(router)), 0, "router should have zero balance");
        assertEq(token.balanceOf(admin), adminBalanceBefore + amount, "admin should receive tokens");
    }

    /// @notice Test flash loan with custom data passed through
    function testFlashLoanWithCustomData() public {
        uint256 amount = 1_000e18;
        bytes memory customData = abi.encode("custom", uint256(42), address(0xABCD));

        _setFlashConfig(address(receiver), FlashLoanRouter.FlashSource.EULER, address(eulerLender), true);
        token.mint(address(eulerLender), amount);

        receiver.initiate(address(token), amount, customData);

        // Verify the custom data was passed through correctly
        (bool called, address lastToken, uint256 lastAmount, uint256 lastFee, bytes memory lastData) = receiver.last();
        assertTrue(called, "callback should have been called");
        assertEq(lastToken, address(token));
        assertEq(lastAmount, amount);
        assertEq(lastFee, 0);
        assertEq(keccak256(lastData), keccak256(customData), "custom data should match");
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////
//                                      MOCK CONTRACTS                                       //
///////////////////////////////////////////////////////////////////////////////////////////////

/// @notice Mock receiver for testing flash loan callbacks
contract MockReceiver is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    address public immutable router;
    IERC20 public immutable token;
    bool public shouldRevert;

    struct CallbackData {
        bool called;
        address token;
        uint256 amount;
        uint256 fee;
        bytes data;
    }

    CallbackData public last;

    constructor(address _router, address _token) {
        router = _router;
        token = IERC20(_token);
    }

    function setShouldRevert(bool flag) external {
        shouldRevert = flag;
    }

    function initiate(address debtToken, uint256 amount, bytes memory data) external {
        IFlashLoanRouter(router).requestFlashLoan(debtToken, amount, data);
    }

    function onFlashLoanReceived(
        address _token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == router, "invalid router");
        if (shouldRevert) revert("receiver revert");

        last = CallbackData({called: true, token: _token, amount: amount, fee: fee, data: data});

        uint256 repayAmount = amount + fee;
        token.forceApprove(router, repayAmount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Mock receiver that attempts reentrancy
contract MockReentrantReceiver is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    address public immutable router;
    IERC20 public immutable token;
    address public immutable lender;

    constructor(address _router, address _token, address _lender) {
        router = _router;
        token = IERC20(_token);
        lender = _lender;
    }

    function initiate(address debtToken, uint256 amount, bytes memory data) external {
        IFlashLoanRouter(router).requestFlashLoan(debtToken, amount, data);
    }

    function onFlashLoanReceived(
        address _token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == router, "invalid router");

        // Attempt reentrancy - this should revert with PendingActionExists
        IFlashLoanRouter(router).requestFlashLoan(_token, amount / 2, data);

        uint256 repayAmount = amount + fee;
        token.forceApprove(router, repayAmount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Mock Euler vault for testing
contract MockEulerVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint256 public fee;

    constructor(IERC20 _token) {
        token = _token;
    }

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function flashLoan(uint256 amount, bytes calldata data) external {
        token.safeTransfer(msg.sender, amount);

        bytes32 result = IERC3156FlashBorrower(msg.sender).onFlashLoan(msg.sender, address(token), amount, fee, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "bad callback");

        uint256 repayAmount = amount + fee;
        token.safeTransferFrom(msg.sender, address(this), repayAmount);
    }
}

/// @notice Mock ERC3156 lender (e.g., Silo)
contract MockERC3156Lender {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint256 public fee;
    address public corruptToken;
    address public wrongInitiator;

    constructor(IERC20 _token) {
        token = _token;
    }

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function setInvalidToken(address t) external {
        corruptToken = t;
    }

    function setWrongInitiator(address initiator) external {
        wrongInitiator = initiator;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address _token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        address callbackToken = corruptToken != address(0) ? corruptToken : _token;
        address callbackInitiator = wrongInitiator != address(0) ? wrongInitiator : msg.sender;

        token.safeTransfer(address(receiver), amount);

        bytes32 result = receiver.onFlashLoan(callbackInitiator, callbackToken, amount, fee, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "bad callback");

        uint256 repayAmount = amount + fee;
        token.safeTransferFrom(address(receiver), address(this), repayAmount);
        return true;
    }
}

contract MockMorphoMarket {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    constructor(IERC20 _token) {
        token = _token;
    }

    function flashLoan(address _token, uint256 assets, bytes calldata data) external {
        require(_token == address(token), "token mismatch");

        token.safeTransfer(msg.sender, assets);

        FlashLoanRouter(msg.sender).onMorphoFlashLoan(assets, data);

        token.safeTransferFrom(msg.sender, address(this), assets);
    }
}
