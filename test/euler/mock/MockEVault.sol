// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IEVault} from "src/interfaces/euler/IEVault.sol";
import {IEVC} from "src/interfaces/euler/IEVC.sol";
import {IEulerOracle} from "src/interfaces/euler/IEulerOracle.sol";

/// @title MockEVault
/// @notice Minimal mock implementation of Euler EVault for testing purposes
/// @dev Only implements the essential functions needed by LeveragedEulerStrategy
contract MockEVault is IEVault {
    address public immutable override asset;
    string public override name;
    string public override symbol;
    uint8 public override decimals;

    // ERC20 state
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 public override totalSupply;

    // Debt tracking
    mapping(address => uint256) private _debts;
    uint256 public override totalBorrows;

    /// @notice Tracks the vault's direct holdings of the underlying asset
    /// @dev In Euler's model, cash represents the actual tokens held by the vault (available liquidity),
    /// while totalAssets = cash + totalBorrows represents the total value including lent out funds.
    /// This distinction is important for:
    /// - Calculating share conversion rates (totalAssets is used)
    /// - Determining available liquidity for withdrawals and borrows (cash is used)
    /// - Interest accrual calculations
    uint256 public override cash;

    // Flash loan callback tracking
    bytes32 private constant FLASH_LOAN_CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Risk config for accountLiquidity (set via setRiskConfig after deployment)
    IEVC public evc;
    IEulerOracle private _oracle;
    address public unitOfAccount;

    constructor(address _asset, string memory _name, string memory _symbol) {
        asset = _asset;
        name = _name;
        symbol = _symbol;
        decimals = IERC20Metadata(_asset).decimals();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  ERC20 FUNCTIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address holder, address spender) external view override returns (uint256) {
        return _allowances[holder][spender];
    }

    function transferFromMax(address from, address to) external override returns (bool) {
        uint256 amount = _balances[from];
        if (msg.sender != from) {
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  ERC4626 FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function totalAssets() public view override returns (uint256) {
        return cash + totalBorrows;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return convertToAssets(_balances[owner]);
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 amount, address receiver) external override returns (uint256 shares) {
        shares = convertToShares(amount);

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _balances[receiver] += shares;
        totalSupply += shares;
        cash += amount;

        return shares;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 amount) {
        amount = convertToAssets(shares);

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _balances[receiver] += shares;
        totalSupply += shares;
        cash += amount;

        return amount;
    }

    function withdraw(uint256 amount, address receiver, address owner) external override returns (uint256 shares) {
        shares = convertToShares(amount);

        if (msg.sender != owner) {
            uint256 allowed = _allowances[owner][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[owner][msg.sender] = allowed - shares;
            }
        }

        _balances[owner] -= shares;
        totalSupply -= shares;
        cash -= amount;

        IERC20(asset).transfer(receiver, amount);

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 amount) {
        if (msg.sender != owner) {
            uint256 allowed = _allowances[owner][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[owner][msg.sender] = allowed - shares;
            }
        }

        amount = convertToAssets(shares);

        _balances[owner] -= shares;
        totalSupply -= shares;
        cash -= amount;

        IERC20(asset).transfer(receiver, amount);

        return amount;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  BORROWING FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function borrow(uint256 amount, address receiver) external override returns (uint256) {
        _debts[msg.sender] += amount;
        totalBorrows += amount;
        cash -= amount;

        IERC20(asset).transfer(receiver, amount);

        return amount;
    }

    function repay(uint256 amount, address receiver) external override returns (uint256) {
        if (amount == type(uint256).max) {
            amount = _debts[receiver];
        }

        uint256 actualAmount = amount > _debts[receiver] ? _debts[receiver] : amount;

        IERC20(asset).transferFrom(msg.sender, address(this), actualAmount);

        _debts[receiver] -= actualAmount;
        totalBorrows -= actualAmount;
        cash += actualAmount;

        return actualAmount;
    }

    function debtOf(address account) external view override returns (uint256) {
        return _debts[account];
    }

    function flashLoan(uint256 amount, bytes calldata data) external override {
        IERC20(asset).transfer(msg.sender, amount);

        // Call the flash loan callback
        (bool success, ) = msg.sender.call(abi.encodeWithSignature("onFlashLoan(bytes)", data));

        require(success, "Flash loan callback failed");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  RISK MANAGER FUNCTIONS                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Set the EVC, oracle, and unit-of-account needed to simulate Euler's real accountLiquidity
    /// @dev Only the borrow vault needs this. Call once after deploying the vault in test setup.
    function setRiskConfig(address _evc, address oracle_, address _unitOfAccount) external {
        evc = IEVC(_evc);
        _oracle = IEulerOracle(oracle_);
        unitOfAccount = _unitOfAccount;
    }

    function accountLiquidity(
        address account,
        bool /* liquidation */
    ) external view override returns (uint256 collateralValue, uint256 liabilityValue) {
        if (address(evc) != address(0) && address(_oracle) != address(0)) {
            // Mirror real Euler: sum risk-adjusted USD values across all enabled collateral vaults,
            // and express the liability in the same unit-of-account denomination.
            address[] memory collaterals = evc.getCollaterals(account);
            for (uint256 i = 0; i < collaterals.length; i++) {
                IEVault cv = IEVault(collaterals[i]);
                uint256 rawAssets = cv.convertToAssets(cv.balanceOf(account));
                if (rawAssets == 0) continue;
                uint256 usdValue = _oracle.getQuote(rawAssets, cv.asset(), unitOfAccount);
                uint256 ltvFactor = this.LTVBorrow(collaterals[i]);
                collateralValue += (usdValue * ltvFactor) / 10000;
            }
            if (_debts[account] > 0) {
                liabilityValue = _oracle.getQuote(_debts[account], asset, unitOfAccount);
            }
        } else {
            // Fallback for vaults that don't have risk config (e.g. collateral-only vaults in tests)
            collateralValue = (convertToAssets(_balances[account]) * 8000) / 10000;
            liabilityValue = _debts[account];
        }
    }

    function accountLiquidityFull(
        address account,
        bool /* liquidation */
    )
        external
        view
        override
        returns (address[] memory collaterals, uint256[] memory collateralValues, uint256 liabilityValue)
    {
        collaterals = new address[](0);
        collateralValues = new uint256[](0);
        liabilityValue = _debts[account];
    }

    function checkAccountStatus(address, address[] calldata) external pure override returns (bytes4) {
        return this.checkAccountStatus.selector;
    }

    function checkVaultStatus() external pure override returns (bytes4) {
        return this.checkVaultStatus.selector;
    }

    function disableController() external override {}

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  GOVERNANCE FUNCTIONS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function LTVBorrow(address) external pure override returns (uint16) {
        return 8000; // 80%
    }

    function LTVLiquidation(address) external pure override returns (uint16) {
        return 8500; // 85%
    }

    function LTVFull(
        address
    )
        external
        pure
        override
        returns (
            uint16 borrowLTV,
            uint16 liquidationLTV,
            uint16 initialLiquidationLTV,
            uint48 targetTimestamp,
            uint32 rampDuration
        )
    {
        return (8000, 8500, 8500, 0, 0);
    }

    function LTVList() external pure override returns (address[] memory) {
        return new address[](0);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  TESTING HELPERS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Helper function to simulate interest accrual for testing
    /// @dev This manually increases a specific account's debt and totalBorrows
    /// @param account The account whose debt to increase
    /// @param interestAmount The amount of interest/debt to add
    function accrueInterest(address account, uint256 interestAmount) external {
        if (interestAmount == 0) return;

        _debts[account] += interestAmount;
        totalBorrows += interestAmount;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                              STUB IMPLEMENTATIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Vault module stubs
    function accumulatedFees() external pure override returns (uint256) {
        return 0;
    }
    function accumulatedFeesAssets() external pure override returns (uint256) {
        return 0;
    }
    function creator() external pure override returns (address) {
        return address(0);
    }
    function skim(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    // Borrowing module stubs
    function totalBorrowsExact() external view override returns (uint256) {
        return totalBorrows;
    }
    function debtOfExact(address account) external view override returns (uint256) {
        return _debts[account];
    }
    function interestRate() external pure override returns (uint256) {
        return 0;
    }
    function interestAccumulator() external pure override returns (uint256) {
        return 1e27;
    }
    function dToken() external pure override returns (address) {
        return address(0);
    }
    function repayWithShares(uint256, address) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
    function pullDebt(uint256, address) external pure override {}
    function touch() external pure override {}

    // Liquidation module stubs
    function checkLiquidation(address, address, address) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
    function liquidate(address, address, uint256, uint256) external pure override {}

    // Balance forwarder stubs
    function balanceTrackerAddress() external pure override returns (address) {
        return address(0);
    }
    function balanceForwarderEnabled(address) external pure override returns (bool) {
        return false;
    }
    function enableBalanceForwarder() external pure override {}
    function disableBalanceForwarder() external pure override {}

    // Governance stubs
    function governorAdmin() external pure override returns (address) {
        return address(0);
    }
    function feeReceiver() external pure override returns (address) {
        return address(0);
    }
    function interestFee() external pure override returns (uint16) {
        return 0;
    }
    function interestRateModel() external pure override returns (address) {
        return address(0);
    }
    function protocolConfigAddress() external pure override returns (address) {
        return address(0);
    }
    function protocolFeeShare() external pure override returns (uint256) {
        return 0;
    }
    function protocolFeeReceiver() external pure override returns (address) {
        return address(0);
    }
    function caps() external pure override returns (uint16, uint16) {
        return (0, 0);
    }
    function maxLiquidationDiscount() external pure override returns (uint16) {
        return 0;
    }
    function liquidationCoolOffTime() external pure override returns (uint16) {
        return 0;
    }
    function hookConfig() external pure override returns (address, uint32) {
        return (address(0), 0);
    }
    function configFlags() external pure override returns (uint32) {
        return 0;
    }
    function EVC() external pure override returns (address) {
        return address(0);
    }

    function oracle() external pure override returns (address) {
        return address(0);
    }
    function permit2Address() external pure override returns (address) {
        return address(0);
    }
    function convertFees() external pure override {}
    function setGovernorAdmin(address) external pure override {}
    function setFeeReceiver(address) external pure override {}
    function setLTV(address, uint16, uint16, uint32) external pure override {}
    function setMaxLiquidationDiscount(uint16) external pure override {}
    function setLiquidationCoolOffTime(uint16) external pure override {}
    function setInterestRateModel(address) external pure override {}
    function setHookConfig(address, uint32) external pure override {}
    function setConfigFlags(uint32) external pure override {}
    function setCaps(uint16, uint16) external pure override {}
    function setInterestFee(uint16) external pure override {}

    // Module addresses
    function MODULE_INITIALIZE() external pure override returns (address) {
        return address(0);
    }
    function MODULE_TOKEN() external pure override returns (address) {
        return address(0);
    }
    function MODULE_VAULT() external pure override returns (address) {
        return address(0);
    }
    function MODULE_BORROWING() external pure override returns (address) {
        return address(0);
    }
    function MODULE_LIQUIDATION() external pure override returns (address) {
        return address(0);
    }
    function MODULE_RISKMANAGER() external pure override returns (address) {
        return address(0);
    }
    function MODULE_BALANCE_FORWARDER() external pure override returns (address) {
        return address(0);
    }
    function MODULE_GOVERNANCE() external pure override returns (address) {
        return address(0);
    }

    // Initialize module stub
    function initialize(address) external pure override {}
}
