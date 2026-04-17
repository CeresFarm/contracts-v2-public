// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ISilo, ISiloConfig, IERC3156FlashBorrower} from "src/interfaces/silo/ISilo.sol";

/// @title MockSilo
/// @notice Mock implementation of ISilo for testing purposes
/// @dev Simplified version of the real Silo contract that uses ERC20 for share tracking
///      The real Silo uses separate ShareToken contracts, but for testing we track shares internally
contract MockSilo is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable asset;
    ISiloConfig internal _siloConfig;

    // Share balances for different collateral types (internal tracking, not separate tokens in mock)
    mapping(address => mapping(ISilo.CollateralType => uint256)) public collateralShares;
    mapping(address => uint256) public debtShares;

    // Total shares for different types
    mapping(ISilo.CollateralType => uint256) public totalCollateralShares;
    uint256 public totalDebtShares;

    // Total assets (underlying) for different types - this is the key storage like real Silo
    mapping(ISilo.CollateralType => uint256) public totalCollateralAssets;
    uint256 public totalDebtAssets;

    // Flash loan fee (in 1e18 precision, e.g., 0.001e18 = 0.1%)
    uint256 public flashLoanFee = 0;

    // Interest rate timestamp
    uint256 public interestRateTimestamp;

    // Protected shares (non-borrowable collateral)
    mapping(address => uint256) public protectedShares;
    uint256 public totalProtectedShares;
    uint256 public totalProtectedAssets;

    bool public shouldRevertOnDeposit;
    bool public shouldRevertOnWithdraw;
    bool public shouldRevertOnBorrow;
    bool public shouldRevertOnRepay;
    bool public shouldRevertOnFlashLoan;

    event Deposited(address indexed user, uint256 amount, ISilo.CollateralType collateralType);
    event Withdrawn(address indexed user, uint256 amount, ISilo.CollateralType collateralType);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);

    constructor(
        address _asset
    )
        ERC20(
            string(abi.encodePacked("Mock Silo ", ERC20(_asset).name())),
            string(abi.encodePacked("ms", ERC20(_asset).symbol()))
        )
    {
        asset = _asset;
        interestRateTimestamp = block.timestamp;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   DEPOSIT FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit assets and receive shares (ERC4626-like with CollateralType)
    /// @dev Mimics the real Silo deposit logic with proper share conversion
    function deposit(
        uint256 amount,
        address receiver,
        ISilo.CollateralType collateralType
    ) external returns (uint256 shares) {
        require(!shouldRevertOnDeposit, "MockSilo: Deposit reverted");
        require(amount > 0, "MockSilo: Zero amount");

        // Transfer tokens from sender
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Convert assets to shares using proper ERC4626-like logic
        shares = _convertToShares(amount, collateralType);

        if (collateralType == ISilo.CollateralType.Collateral) {
            collateralShares[receiver][collateralType] += shares;
            totalCollateralShares[collateralType] += shares;
            totalCollateralAssets[collateralType] += amount;
            // For Collateral type, also mint ERC20 shares (mimicking collateral share token)
            _mint(receiver, shares);
        } else {
            // Protected collateral
            protectedShares[receiver] += shares;
            totalProtectedShares += shares;
            totalProtectedAssets += amount;
        }

        emit Deposited(receiver, amount, collateralType);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   WITHDRAW FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Withdraw assets by burning shares
    function withdraw(
        uint256 amount,
        address receiver,
        address owner,
        ISilo.CollateralType collateralType
    ) external returns (uint256 shares) {
        require(!shouldRevertOnWithdraw, "MockSilo: Withdraw reverted");
        require(amount > 0, "MockSilo: Zero amount");

        // Convert assets to shares (round up for withdrawals to favor protocol)
        shares = _convertToSharesRoundUp(amount, collateralType);

        if (collateralType == ISilo.CollateralType.Collateral) {
            require(collateralShares[owner][collateralType] >= shares, "MockSilo: Insufficient shares");

            collateralShares[owner][collateralType] -= shares;
            totalCollateralShares[collateralType] -= shares;
            totalCollateralAssets[collateralType] -= amount;

            // For Collateral type, also burn ERC20 shares
            _burn(owner, shares);
        } else {
            // Protected collateral
            require(protectedShares[owner] >= shares, "MockSilo: Insufficient protected shares");

            protectedShares[owner] -= shares;
            totalProtectedShares -= shares;
            totalProtectedAssets -= amount;
        }

        // Transfer tokens to receiver
        IERC20(asset).safeTransfer(receiver, amount);

        emit Withdrawn(owner, amount, collateralType);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   BORROW FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Borrow assets (creates debt shares)
    function borrow(uint256 amount, address receiver, address borrower) external returns (uint256 shares) {
        require(!shouldRevertOnBorrow, "MockSilo: Borrow reverted");
        require(amount > 0, "MockSilo: Zero amount");

        // Convert assets to debt shares (round up to favor protocol)
        shares = _convertToDebtSharesRoundUp(amount);

        debtShares[borrower] += shares;
        totalDebtShares += shares;
        totalDebtAssets += amount;

        // Transfer tokens to receiver
        IERC20(asset).safeTransfer(receiver, amount);

        emit Borrowed(borrower, amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   REPAY FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Repay borrowed assets (burns debt shares)
    function repay(uint256 amount, address borrower) external returns (uint256 shares) {
        require(!shouldRevertOnRepay, "MockSilo: Repay reverted");
        require(amount > 0, "MockSilo: Zero amount");

        // Transfer tokens from sender
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Convert assets to debt shares (round down for repay to favor user)
        shares = _convertToDebtShares(amount);

        require(debtShares[borrower] >= shares, "MockSilo: Insufficient debt shares");

        debtShares[borrower] -= shares;
        totalDebtShares -= shares;
        totalDebtAssets -= amount;

        emit Repaid(borrower, amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   FLASH LOAN FUNCTIONS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Flash loan implementation
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(!shouldRevertOnFlashLoan, "MockSilo: FlashLoan reverted");
        require(token == asset, "MockSilo: Invalid token");
        require(amount > 0, "MockSilo: Zero amount");

        uint256 fee = (amount * flashLoanFee) / 1e18;

        // Transfer tokens to receiver
        IERC20(asset).safeTransfer(address(receiver), amount);

        // Call the receiver
        bytes32 result = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "MockSilo: Invalid return value");

        // Get tokens back with fee
        IERC20(asset).safeTransferFrom(address(receiver), address(this), amount + fee);

        return true;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              INTERNAL CONVERSION FUNCTIONS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Convert assets to shares for deposit/borrow (rounds down)
    /// @dev Mimics the real Silo's SiloMathLib.convertToShares with DEPOSIT_TO_SHARES rounding
    function _convertToShares(uint256 assets, ISilo.CollateralType collateralType) internal view returns (uint256) {
        uint256 totalAssets;
        uint256 totalShares;

        if (collateralType == ISilo.CollateralType.Collateral) {
            totalAssets = totalCollateralAssets[collateralType];
            totalShares = totalCollateralShares[collateralType];
        } else {
            totalAssets = totalProtectedAssets;
            totalShares = totalProtectedShares;
        }

        // If no shares exist yet, 1:1 ratio
        if (totalShares == 0 || totalAssets == 0) {
            return assets;
        }

        // shares = assets * totalShares / totalAssets (rounded down)
        return (assets * totalShares) / totalAssets;
    }

    /// @notice Convert assets to shares for withdraw (rounds up to favor protocol)
    /// @dev Mimics WITHDRAW_TO_SHARES rounding
    function _convertToSharesRoundUp(
        uint256 assets,
        ISilo.CollateralType collateralType
    ) internal view returns (uint256) {
        uint256 totalAssets;
        uint256 totalShares;

        if (collateralType == ISilo.CollateralType.Collateral) {
            totalAssets = totalCollateralAssets[collateralType];
            totalShares = totalCollateralShares[collateralType];
        } else {
            totalAssets = totalProtectedAssets;
            totalShares = totalProtectedShares;
        }

        if (totalShares == 0 || totalAssets == 0) {
            return assets;
        }

        // shares = (assets * totalShares + totalAssets - 1) / totalAssets (rounded up)
        return (assets * totalShares + totalAssets - 1) / totalAssets;
    }

    /// @notice Convert assets to debt shares (rounds down - for repay, favors user)
    function _convertToDebtShares(uint256 assets) internal view returns (uint256) {
        if (totalDebtShares == 0 || totalDebtAssets == 0) {
            return assets;
        }

        return (assets * totalDebtShares) / totalDebtAssets;
    }

    /// @notice Convert assets to debt shares (rounds up - for borrow, favors protocol)
    function _convertToDebtSharesRoundUp(uint256 assets) internal view returns (uint256) {
        if (totalDebtShares == 0 || totalDebtAssets == 0) {
            return assets;
        }

        // Round up for borrows
        return (assets * totalDebtShares + totalDebtAssets - 1) / totalDebtAssets;
    }

    /// @notice Convert shares to assets
    function _convertToAssets(uint256 shares, ISilo.CollateralType collateralType) internal view returns (uint256) {
        uint256 totalAssets;
        uint256 totalShares;

        if (collateralType == ISilo.CollateralType.Collateral) {
            totalAssets = totalCollateralAssets[collateralType];
            totalShares = totalCollateralShares[collateralType];
        } else {
            totalAssets = totalProtectedAssets;
            totalShares = totalProtectedShares;
        }

        if (totalShares == 0 || totalAssets == 0) {
            return shares;
        }

        return (shares * totalAssets) / totalShares;
    }

    /// @notice Convert debt shares to assets
    function _convertDebtSharesToAssets(uint256 shares) internal view returns (uint256) {
        if (totalDebtShares == 0 || totalDebtAssets == 0) {
            return shares;
        }

        return (shares * totalDebtAssets) / totalDebtShares;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SETTER FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Set collateral balance for testing (shares and assets)
    function setCollateralBalance(address user, uint256 amount, ISilo.CollateralType collateralType) external {
        if (collateralType == ISilo.CollateralType.Collateral) {
            collateralShares[user][collateralType] = amount;
            totalCollateralAssets[collateralType] = amount;
            totalCollateralShares[collateralType] = amount;
            _mint(user, amount);
        } else {
            protectedShares[user] = amount;
            totalProtectedAssets = amount;
            totalProtectedShares = amount;
        }
    }

    /// @notice Set debt balance for testing
    function setDebtBalance(address user, uint256 amount) external {
        debtShares[user] = amount;
        totalDebtAssets = amount;
        totalDebtShares = amount;
    }

    /// @notice Simulate interest accrual by increasing total assets
    /// @dev This is the key to testing - interest increases totalAssets without changing totalShares
    ///      This makes the exchange rate increase (more assets per share)
    /// @param collateralType The type of collateral
    /// @param additionalAssets Amount of assets to add (simulating interest accrual)
    function accrueInterest(ISilo.CollateralType collateralType, uint256 additionalAssets) external {
        if (collateralType == ISilo.CollateralType.Collateral) {
            totalCollateralAssets[collateralType] += additionalAssets;
        } else {
            totalProtectedAssets += additionalAssets;
        }
        interestRateTimestamp = block.timestamp;
    }

    /// @notice Simulate debt interest accrual
    /// @dev Increases debt assets, making each debt share worth more
    /// @param additionalDebt Amount of debt to add (simulating interest accrual)
    function accrueDebtInterest(uint256 additionalDebt) external {
        totalDebtAssets += additionalDebt;
        interestRateTimestamp = block.timestamp;
    }

    function setFlashLoanFee(uint256 fee) external {
        flashLoanFee = fee;
    }

    function setShouldRevertOnDeposit(bool shouldRevert) external {
        shouldRevertOnDeposit = shouldRevert;
    }

    function setShouldRevertOnWithdraw(bool shouldRevert) external {
        shouldRevertOnWithdraw = shouldRevert;
    }

    function setShouldRevertOnBorrow(bool shouldRevert) external {
        shouldRevertOnBorrow = shouldRevert;
    }

    function setShouldRevertOnRepay(bool shouldRevert) external {
        shouldRevertOnRepay = shouldRevert;
    }

    function setShouldRevertOnFlashLoan(bool shouldRevert) external {
        shouldRevertOnFlashLoan = shouldRevert;
    }

    /// @notice Set the silo configuration contract
    /// @param siloConfig_ The address of the ISiloConfig contract
    function setSiloConfig(ISiloConfig siloConfig_) external {
        _siloConfig = siloConfig_;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    VIEW FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Get the silo configuration contract
    /// @return siloConfig The ISiloConfig contract
    function config() external view returns (ISiloConfig siloConfig) {
        return _siloConfig;
    }

    function getCollateralShares(address user, ISilo.CollateralType collateralType) external view returns (uint256) {
        if (collateralType == ISilo.CollateralType.Collateral) {
            return collateralShares[user][collateralType];
        } else {
            return protectedShares[user];
        }
    }

    function getDebtShares(address user) external view returns (uint256) {
        return debtShares[user];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                         IERC4626 / ISILO VIEW FUNCTIONS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Maximum amount that can be deposited
    function maxDeposit(address /* receiver */) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Preview how many shares would be received for an asset amount (deposit)
    function previewDeposit(uint256 assets, ISilo.CollateralType collateralType) external view returns (uint256) {
        return _convertToShares(assets, collateralType);
    }

    /// @notice Maximum amount of shares that can be minted
    function maxMint(address /* receiver */) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Preview how many assets are needed to mint specified shares
    function previewMint(uint256 shares, ISilo.CollateralType collateralType) external view returns (uint256) {
        return _convertToAssets(shares, collateralType);
    }

    /// @notice Maximum amount that can be withdrawn by owner
    function maxWithdraw(address owner, ISilo.CollateralType collateralType) external view returns (uint256) {
        if (collateralType == ISilo.CollateralType.Collateral) {
            return _convertToAssets(collateralShares[owner][collateralType], collateralType);
        } else {
            return _convertToAssets(protectedShares[owner], collateralType);
        }
    }

    /// @notice Preview how many shares would be burned for withdrawing specified assets
    function previewWithdraw(uint256 assets, ISilo.CollateralType collateralType) external view returns (uint256) {
        return _convertToSharesRoundUp(assets, collateralType);
    }

    /// @notice Maximum shares that can be redeemed by owner
    function maxRedeem(address owner, ISilo.CollateralType collateralType) external view returns (uint256) {
        if (collateralType == ISilo.CollateralType.Collateral) {
            return collateralShares[owner][collateralType];
        } else {
            return protectedShares[owner];
        }
    }

    /// @notice Preview how many assets would be received for share amount (redeem)
    function previewRedeem(uint256 shares, ISilo.CollateralType collateralType) external view returns (uint256) {
        return _convertToAssets(shares, collateralType);
    }

    /// @notice Maximum amount that can be borrowed
    function maxBorrow(address /* borrower */) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Preview borrow (assets to debt shares conversion)
    function previewBorrow(uint256 assets) external view returns (uint256) {
        return _convertToDebtSharesRoundUp(assets);
    }

    /// @notice Maximum shares that can be borrowed
    function maxBorrowShares(address /* borrower */) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Preview borrow shares (debt shares to assets conversion)
    function previewBorrowShares(uint256 shares) external view returns (uint256) {
        return _convertDebtSharesToAssets(shares);
    }

    /// @notice Maximum amount that can be borrowed for same asset
    function maxBorrowSameAsset(address /* borrower */) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Preview repay (assets to debt shares conversion)
    function previewRepay(uint256 assets) external view returns (uint256) {
        return _convertToDebtShares(assets);
    }

    /// @notice Get the maximum amount of assets that can be repaid by a borrower
    function maxRepay(address _borrower) external view returns (uint256 assets) {
        return _convertDebtSharesToAssets(debtShares[_borrower]);
    }

    /// @notice Get the maximum amount of shares that can be repaid by a borrower
    function maxRepayShares(address _borrower) external view returns (uint256 shares) {
        return debtShares[_borrower];
    }

    /// @notice Preview repay shares (debt shares to assets conversion)
    function previewRepayShares(uint256 shares) external view returns (uint256) {
        return _convertDebtSharesToAssets(shares);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                ADDITIONAL VIEW FUNCTIONS                                 //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Get the current exchange rate (assets per share) in 1e18 precision
    /// @dev This is what increases when interest accrues
    function getExchangeRate(ISilo.CollateralType collateralType) external view returns (uint256) {
        uint256 totalAssets;
        uint256 totalShares;

        if (collateralType == ISilo.CollateralType.Collateral) {
            totalAssets = totalCollateralAssets[collateralType];
            totalShares = totalCollateralShares[collateralType];
        } else {
            totalAssets = totalProtectedAssets;
            totalShares = totalProtectedShares;
        }

        if (totalShares == 0 || totalAssets == 0) {
            return 1e18; // 1:1 ratio
        }

        return (totalAssets * 1e18) / totalShares;
    }

    /// @notice Get the current debt exchange rate (assets per share) in 1e18 precision
    /// @dev This increases when debt interest accrues
    function getDebtExchangeRate() external view returns (uint256) {
        if (totalDebtShares == 0 || totalDebtAssets == 0) {
            return 1e18; // 1:1 ratio
        }

        return (totalDebtAssets * 1e18) / totalDebtShares;
    }

    /// @notice Get collateral balance in underlying assets
    function collateralBalanceOfUnderlying(
        address user,
        ISilo.CollateralType collateralType
    ) external view returns (uint256) {
        if (collateralType == ISilo.CollateralType.Collateral) {
            return _convertToAssets(collateralShares[user][collateralType], collateralType);
        } else {
            uint256 shares = protectedShares[user];
            if (totalProtectedShares == 0) return 0;
            return (shares * totalProtectedAssets) / totalProtectedShares;
        }
    }

    /// @notice Get debt balance in underlying assets
    function debtBalanceOfUnderlying(address user) external view returns (uint256) {
        return _convertDebtSharesToAssets(debtShares[user]);
    }
}
