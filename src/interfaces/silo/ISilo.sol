// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 ^0.8.20;

///////////////////////////////////////////////////////////////////////////////
// Flattened ISilo contract interface and dependencies
// Source: https://github.com/silo-finance/silo-contracts-v2/blob/develop/silo-core/contracts/interfaces/ISilo.sol
///////////////////////////////////////////////////////////////////////////////

// lib/silo-contracts-v2/silo-core/contracts/interfaces/ICrossReentrancyGuard.sol

interface ICrossReentrancyGuard {
    error CrossReentrantCall();
    error CrossReentrancyNotActive();

    /// @notice only silo method for cross Silo reentrancy
    function turnOnReentrancyProtection() external;

    /// @notice only silo method for cross Silo reentrancy
    function turnOffReentrancyProtection() external;

    /// @notice view method for checking cross Silo reentrancy flag
    /// @return entered true if the reentrancy guard is currently set to "entered", which indicates there is a
    /// `nonReentrant` function in the call stack.
    function reentrancyGuardEntered() external view returns (bool entered);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// lib/silo-contracts-v2/silo-core/contracts/interfaces/IERC3156FlashBorrower.sol

interface IERC3156FlashBorrower {
    /// @notice During the execution of the flashloan, Silo methods are not taking into consideration the fact,
    /// that some (or all) tokens were transferred as flashloan, therefore some methods can return invalid state
    /// eg. maxWithdraw can return amount that are not available to withdraw during flashlon.
    /// @dev Receive a flash loan.
    /// @param _initiator The initiator of the loan.
    /// @param _token The loan currency.
    /// @param _amount The amount of tokens lent.
    /// @param _fee The additional amount of tokens to repay.
    /// @param _data Arbitrary data structure, intended to contain user-defined parameters.
    /// @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
    function onFlashLoan(
        address _initiator,
        address _token,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _data
    ) external returns (bytes32);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// lib/silo-contracts-v2/silo-core/contracts/interfaces/IERC3156FlashLender.sol

/// @notice https://eips.ethereum.org/EIPS/eip-3156
interface IERC3156FlashLender {
    /// @notice Protected deposits are not available for a flash loan.
    /// During the execution of the flashloan, Silo methods are not taking into consideration the fact,
    /// that some (or all) tokens were transferred as flashloan, therefore some methods can return invalid state
    /// eg. maxWithdraw can return amount that are not available to withdraw during flashlon.
    /// @dev Initiate a flash loan.
    /// @param _receiver The receiver of the tokens in the loan, and the receiver of the callback.
    /// @param _token The loan currency.
    /// @param _amount The amount of tokens lent.
    /// @param _data Arbitrary data structure, intended to contain user-defined parameters.
    function flashLoan(
        IERC3156FlashBorrower _receiver,
        address _token,
        uint256 _amount,
        bytes calldata _data
    ) external returns (bool);

    /// @dev The amount of currency available to be lent.
    /// @param _token The loan currency.
    /// @return The amount of `token` that can be borrowed.
    function maxFlashLoan(address _token) external view returns (uint256);

    /// @dev The fee to be charged for a given loan.
    /// @param _token The loan currency.
    /// @param _amount The amount of tokens lent.
    /// @return The amount of `token` to be charged for the loan, on top of the returned principal.
    function flashFee(address _token, uint256 _amount) external view returns (uint256);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/token/ERC721/IERC721.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC721/IERC721.sol)

/**
 * @dev Required interface of an ERC-721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC-721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must have been allowed to move this token by either {approve} or
     *   {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Note that the caller is responsible to confirm that the recipient is capable of receiving ERC-721
     * or else they may be permanently lost. Usage of {safeTransferFrom} prevents loss, though the caller must
     * understand this adds an external call which potentially creates a reentrancy vulnerability.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the address zero.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/interfaces/IERC4626.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC4626.sol)

/**
 * @dev Interface of the ERC-4626 "Tokenized Vault Standard", as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[ERC-4626].
 */
interface IERC4626 is IERC20, IERC20Metadata {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /**
     * @dev Returns the address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
     *
     * - MUST be an ERC-20 token contract.
     * - MUST NOT revert.
     */
    function asset() external view returns (address assetTokenAddress);

    /**
     * @dev Returns the total amount of the underlying asset that is “managed” by Vault.
     *
     * - SHOULD include any compounding that occurs from yield.
     * - MUST be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT revert.
     */
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /**
     * @dev Returns the amount of shares that the Vault would exchange for the amount of assets provided, in an ideal
     * scenario where all the conditions are met.
     *
     * - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT show any variations depending on the caller.
     * - MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
     * - MUST NOT revert.
     *
     * NOTE: This calculation MAY NOT reflect the “per-user” price-per-share, and instead should reflect the
     * “average-user’s” price-per-share, meaning what the average user should expect to see when exchanging to and
     * from.
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of assets that the Vault would exchange for the amount of shares provided, in an ideal
     * scenario where all the conditions are met.
     *
     * - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT show any variations depending on the caller.
     * - MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
     * - MUST NOT revert.
     *
     * NOTE: This calculation MAY NOT reflect the “per-user” price-per-share, and instead should reflect the
     * “average-user’s” price-per-share, meaning what the average user should expect to see when exchanging to and
     * from.
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of the underlying asset that can be deposited into the Vault for the receiver,
     * through a deposit call.
     *
     * - MUST return a limited value if receiver is subject to some deposit limit.
     * - MUST return 2 ** 256 - 1 if there is no limit on the maximum amount of assets that may be deposited.
     * - MUST NOT revert.
     */
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given
     * current on-chain conditions.
     *
     * - MUST return as close to and no more than the exact amount of Vault shares that would be minted in a deposit
     *   call in the same transaction. I.e. deposit should return the same or more shares as previewDeposit if called
     *   in the same transaction.
     * - MUST NOT account for deposit limits like those returned from maxDeposit and should always act as though the
     *   deposit would be accepted, regardless if the user has enough tokens approved, etc.
     * - MUST be inclusive of deposit fees. Integrators should be aware of the existence of deposit fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToShares and previewDeposit SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by depositing.
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Mints shares Vault shares to receiver by depositing exactly amount of underlying tokens.
     *
     * - MUST emit the Deposit event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   deposit execution, and are accounted for during deposit.
     * - MUST revert if all of assets cannot be deposited (due to deposit limit being reached, slippage, the user not
     *   approving enough underlying tokens to the Vault contract, etc).
     *
     * NOTE: most implementations will require pre-approval of the Vault with the Vault’s underlying asset token.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of the Vault shares that can be minted for the receiver, through a mint call.
     * - MUST return a limited value if receiver is subject to some mint limit.
     * - MUST return 2 ** 256 - 1 if there is no limit on the maximum amount of shares that may be minted.
     * - MUST NOT revert.
     */
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, given
     * current on-chain conditions.
     *
     * - MUST return as close to and no fewer than the exact amount of assets that would be deposited in a mint call
     *   in the same transaction. I.e. mint should return the same or fewer assets as previewMint if called in the
     *   same transaction.
     * - MUST NOT account for mint limits like those returned from maxMint and should always act as though the mint
     *   would be accepted, regardless if the user has enough tokens approved, etc.
     * - MUST be inclusive of deposit fees. Integrators should be aware of the existence of deposit fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToAssets and previewMint SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by minting.
     */
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
     *
     * - MUST emit the Deposit event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the mint
     *   execution, and are accounted for during mint.
     * - MUST revert if all of shares cannot be minted (due to deposit limit being reached, slippage, the user not
     *   approving enough underlying tokens to the Vault contract, etc).
     *
     * NOTE: most implementations will require pre-approval of the Vault with the Vault’s underlying asset token.
     */
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, through a withdraw call.
     *
     * - MUST return a limited value if owner is subject to some withdrawal limit or timelock.
     * - MUST NOT revert.
     */
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     *
     * - MUST return as close to and no fewer than the exact amount of Vault shares that would be burned in a withdraw
     *   call in the same transaction. I.e. withdraw should return the same or fewer shares as previewWithdraw if
     *   called
     *   in the same transaction.
     * - MUST NOT account for withdrawal limits like those returned from maxWithdraw and should always act as though
     *   the withdrawal would be accepted, regardless if the user has enough shares, etc.
     * - MUST be inclusive of withdrawal fees. Integrators should be aware of the existence of withdrawal fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToShares and previewWithdraw SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by depositing.
     */
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Burns shares from owner and sends exactly assets of underlying tokens to receiver.
     *
     * - MUST emit the Withdraw event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   withdraw execution, and are accounted for during withdraw.
     * - MUST revert if all of assets cannot be withdrawn (due to withdrawal limit being reached, slippage, the owner
     *   not having enough shares, etc).
     *
     * Note that some implementations will require pre-requesting to the Vault before a withdrawal may be performed.
     * Those methods should be performed separately.
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of Vault shares that can be redeemed from the owner balance in the Vault,
     * through a redeem call.
     *
     * - MUST return a limited value if owner is subject to some withdrawal limit or timelock.
     * - MUST return balanceOf(owner) if owner is not subject to any withdrawal limit or timelock.
     * - MUST NOT revert.
     */
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their redeemption at the current block,
     * given current on-chain conditions.
     *
     * - MUST return as close to and no more than the exact amount of assets that would be withdrawn in a redeem call
     *   in the same transaction. I.e. redeem should return the same or more assets as previewRedeem if called in the
     *   same transaction.
     * - MUST NOT account for redemption limits like those returned from maxRedeem and should always act as though the
     *   redemption would be accepted, regardless if the user has enough shares, etc.
     * - MUST be inclusive of withdrawal fees. Integrators should be aware of the existence of withdrawal fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToAssets and previewRedeem SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by redeeming.
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     *
     * - MUST emit the Withdraw event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   redeem execution, and are accounted for during redeem.
     * - MUST revert if all of shares cannot be redeemed (due to withdrawal limit being reached, slippage, the owner
     *   not having enough shares, etc).
     *
     * NOTE: some implementations will require pre-requesting to the Vault before a withdrawal may be performed.
     * Those methods should be performed separately.
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

// lib/silo-contracts-v2/gitmodules/openzeppelin-contracts-5/contracts/interfaces/IERC721.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC721.sol)

// lib/silo-contracts-v2/silo-core/contracts/interfaces/IHookReceiver.sol

interface IHookReceiver {
    struct HookConfig {
        uint24 hooksBefore;
        uint24 hooksAfter;
    }

    event HookConfigured(address silo, uint24 hooksBefore, uint24 hooksAfter);

    /// @dev Revert if provided silo configuration during initialization is empty
    error EmptySiloConfig();
    /// @dev Revert if the hook receiver is already configured/initialized
    error AlreadyConfigured();

    /// @notice Initialize a hook receiver
    /// @param _siloConfig Silo configuration with all the details about the silo
    /// @param _data Data to initialize the hook receiver (if needed)
    function initialize(ISiloConfig _siloConfig, bytes calldata _data) external;

    /// @notice state of Silo before action, can be also without interest, if you need them, call silo.accrueInterest()
    function beforeAction(address _silo, uint256 _action, bytes calldata _input) external;

    function afterAction(address _silo, uint256 _action, bytes calldata _inputAndOutput) external;

    /// @notice return hooksBefore and hooksAfter configuration
    function hookReceiverConfig(address _silo) external view returns (uint24 hooksBefore, uint24 hooksAfter);
}

// lib/silo-contracts-v2/silo-core/contracts/interfaces/ISiloConfig.sol

interface ISiloConfig is ICrossReentrancyGuard {
    struct InitData {
        /// @notice Can be address zero if deployer fees are not to be collected. If deployer address is zero then
        /// deployer fee must be zero as well. Deployer will be minted an NFT that gives the right to claim deployer
        /// fees. NFT can be transferred with the right to claim.
        address deployer;
        /// @notice Address of the hook receiver called on every before/after action on Silo. Hook contract also
        /// implements liquidation logic and veSilo gauge connection.
        address hookReceiver;
        /// @notice Deployer's fee in 18 decimals points. Deployer will earn this fee based on the interest earned
        /// by the Silo. Max deployer fee is set by the DAO. At deployment it is 15%.
        uint256 deployerFee;
        /// @notice DAO's fee in 18 decimals points. DAO will earn this fee based on the interest earned
        /// by the Silo. Acceptable fee range fee is set by the DAO. Default at deployment is 5% - 50%.
        uint256 daoFee;
        /// @notice Address of the first token
        address token0;
        /// @notice Address of the solvency oracle. Solvency oracle is used to calculate LTV when deciding if borrower
        /// is solvent or should be liquidated. Solvency oracle is optional and if not set price of 1 will be assumed.
        address solvencyOracle0;
        /// @notice Address of the maxLtv oracle. Max LTV oracle is used to calculate LTV when deciding if borrower
        /// can borrow given amount of assets. Max LTV oracle is optional and if not set it defaults to solvency
        /// oracle. If neither is set price of 1 will be assumed.
        address maxLtvOracle0;
        /// @notice Address of the interest rate model
        address interestRateModel0;
        /// @notice Maximum LTV for first token. maxLTV is in 18 decimals points and is used to determine, if borrower
        /// can borrow given amount of assets. MaxLtv is in 18 decimals points. MaxLtv must be lower or equal to LT.
        uint256 maxLtv0;
        /// @notice Liquidation threshold for first token. LT is used to calculate solvency. LT is in 18 decimals
        /// points. LT must not be lower than maxLTV.
        uint256 lt0;
        /// @notice minimal acceptable LTV after liquidation, in 18 decimals points
        uint256 liquidationTargetLtv0;
        /// @notice Liquidation fee for the first token in 18 decimals points. Liquidation fee is what liquidator earns
        /// for repaying insolvent loan.
        uint256 liquidationFee0;
        /// @notice Flashloan fee sets the cost of taking a flashloan in 18 decimals points
        uint256 flashloanFee0;
        /// @notice Indicates if a beforeQuote on oracle contract should be called before quoting price
        bool callBeforeQuote0;
        /// @notice Address of the second token
        address token1;
        /// @notice Address of the solvency oracle. Solvency oracle is used to calculate LTV when deciding if borrower
        /// is solvent or should be liquidated. Solvency oracle is optional and if not set price of 1 will be assumed.
        address solvencyOracle1;
        /// @notice Address of the maxLtv oracle. Max LTV oracle is used to calculate LTV when deciding if borrower
        /// can borrow given amount of assets. Max LTV oracle is optional and if not set it defaults to solvency
        /// oracle. If neither is set price of 1 will be assumed.
        address maxLtvOracle1;
        /// @notice Address of the interest rate model
        address interestRateModel1;
        /// @notice Maximum LTV for first token. maxLTV is in 18 decimals points and is used to determine,
        /// if borrower can borrow given amount of assets. maxLtv is in 18 decimals points
        uint256 maxLtv1;
        /// @notice Liquidation threshold for first token. LT is used to calculate solvency. LT is in 18 decimals points
        uint256 lt1;
        /// @notice minimal acceptable LTV after liquidation, in 18 decimals points
        uint256 liquidationTargetLtv1;
        /// @notice Liquidation fee is what liquidator earns for repaying insolvent loan.
        uint256 liquidationFee1;
        /// @notice Flashloan fee sets the cost of taking a flashloan in 18 decimals points
        uint256 flashloanFee1;
        /// @notice Indicates if a beforeQuote on oracle contract should be called before quoting price
        bool callBeforeQuote1;
    }

    struct ConfigData {
        uint256 daoFee;
        uint256 deployerFee;
        address silo;
        address token;
        address protectedShareToken;
        address collateralShareToken;
        address debtShareToken;
        address solvencyOracle;
        address maxLtvOracle;
        address interestRateModel;
        uint256 maxLtv;
        uint256 lt;
        uint256 liquidationTargetLtv;
        uint256 liquidationFee;
        uint256 flashloanFee;
        address hookReceiver;
        bool callBeforeQuote;
    }

    struct DepositConfig {
        address silo;
        address token;
        address collateralShareToken;
        address protectedShareToken;
        uint256 daoFee;
        uint256 deployerFee;
        address interestRateModel;
    }

    error OnlySilo();
    error OnlySiloOrTokenOrHookReceiver();
    error WrongSilo();
    error OnlyDebtShareToken();
    error DebtExistInOtherSilo();
    error FeeTooHigh();

    /// @dev It should be called on debt transfer (debt share token transfer).
    /// In the case if the`_recipient` doesn't have configured a collateral silo,
    /// it will be set to the collateral silo of the `_sender`.
    /// @param _sender sender address
    /// @param _recipient recipient address
    function onDebtTransfer(address _sender, address _recipient) external;

    /// @notice Set collateral silo.
    /// @dev Revert if msg.sender is not a SILO_0 or SILO_1.
    /// @dev Always set collateral silo the same as msg.sender.
    /// @param _borrower borrower address
    /// @return collateralSiloChanged TRUE if collateral silo changed
    function setThisSiloAsCollateralSilo(address _borrower) external returns (bool collateralSiloChanged);

    /// @notice Set collateral silo
    /// @dev Revert if msg.sender is not a SILO_0 or SILO_1.
    /// @dev Always set collateral silo opposite to the msg.sender.
    /// @param _borrower borrower address
    /// @return collateralSiloChanged TRUE if collateral silo changed
    function setOtherSiloAsCollateralSilo(address _borrower) external returns (bool collateralSiloChanged);

    /// @notice Accrue interest for the silo
    /// @param _silo silo for which accrue interest
    function accrueInterestForSilo(address _silo) external;

    /// @notice Accrue interest for both silos (SILO_0 and SILO_1 in a config)
    function accrueInterestForBothSilos() external;

    /// @notice Retrieves the collateral silo for a specific borrower.
    /// @dev As a user can deposit into `Silo0` and `Silo1`, this property specifies which Silo
    /// will be used as collateral for the debt. Later on, it will be used for max LTV and solvency checks.
    /// After being set, the collateral silo is never set to `address(0)` again but such getters as
    /// `getConfigsForSolvency`, `getConfigsForBorrow`, `getConfigsForWithdraw` will return empty
    /// collateral silo config if borrower doesn't have debt.
    ///
    /// In the SiloConfig collateral silo is set by the following functions:
    /// `onDebtTransfer` - only if the recipient doesn't have collateral silo set (inherits it from the sender)
    /// This function is called on debt share token transfer (debt transfer).
    /// `setThisSiloAsCollateralSilo` - sets the same silo as the one that calls the function.
    /// `setOtherSiloAsCollateralSilo` - sets the opposite silo as collateral from the one that calls the function.
    ///
    /// In the Silo collateral silo is set by the following functions:
    /// `borrow` - always sets opposite silo as collateral.
    /// If Silo0 borrows, then Silo1 will be collateral and vice versa.
    /// `borrowSameAsset` - always sets the same silo as collateral.
    /// `switchCollateralToThisSilo` - always sets the same silo as collateral.
    /// @param _borrower The address of the borrower for which the collateral silo is being retrieved
    /// @return collateralSilo The address of the collateral silo for the specified borrower
    function borrowerCollateralSilo(address _borrower) external view returns (address collateralSilo);

    /// @notice Retrieves the silo ID
    /// @dev Each silo is assigned a unique ID. ERC-721 token is minted with identical ID to deployer.
    /// An owner of that token receives the deployer fees.
    /// @return siloId The ID of the silo
    function SILO_ID() external view returns (uint256 siloId); // solhint-disable-line func-name-mixedcase

    /// @notice Retrieves the addresses of the two silos
    /// @return silo0 The address of the first silo
    /// @return silo1 The address of the second silo
    function getSilos() external view returns (address silo0, address silo1);

    /// @notice Retrieves the asset associated with a specific silo
    /// @dev This function reverts for incorrect silo address input
    /// @param _silo The address of the silo for which the associated asset is being retrieved
    /// @return asset The address of the asset associated with the specified silo
    function getAssetForSilo(address _silo) external view returns (address asset);

    /// @notice Verifies if the borrower has debt in other silo by checking the debt share token balance
    /// @param _thisSilo The address of the silo in respect of which the debt is checked
    /// @param _borrower The address of the borrower for which the debt is checked
    /// @return hasDebt true if the borrower has debt in other silo
    function hasDebtInOtherSilo(address _thisSilo, address _borrower) external view returns (bool hasDebt);

    /// @notice Retrieves the debt silo associated with a specific borrower
    /// @dev This function reverts if debt present in two silo (should not happen)
    /// @param _borrower The address of the borrower for which the debt silo is being retrieved
    function getDebtSilo(address _borrower) external view returns (address debtSilo);

    /// @notice Retrieves configuration data for both silos. First config is for the silo that is asking for configs.
    /// @param borrower borrower address for which debtConfig will be returned
    /// @return collateralConfig The configuration data for collateral silo (empty if there is no debt).
    /// @return debtConfig The configuration data for debt silo (empty if there is no debt).
    function getConfigsForSolvency(
        address borrower
    ) external view returns (ConfigData memory collateralConfig, ConfigData memory debtConfig);

    /// @notice Retrieves configuration data for a specific silo
    /// @dev This function reverts for incorrect silo address input.
    /// @param _silo The address of the silo for which configuration data is being retrieved
    /// @return config The configuration data for the specified silo
    function getConfig(address _silo) external view returns (ConfigData memory config);

    /// @notice Retrieves configuration data for a specific silo for withdraw fn.
    /// @dev This function reverts for incorrect silo address input.
    /// @param _silo The address of the silo for which configuration data is being retrieved
    /// @return depositConfig The configuration data for the specified silo (always config for `_silo`)
    /// @return collateralConfig The configuration data for the collateral silo (empty if there is no debt)
    /// @return debtConfig The configuration data for the debt silo (empty if there is no debt)
    function getConfigsForWithdraw(
        address _silo,
        address _borrower
    )
        external
        view
        returns (DepositConfig memory depositConfig, ConfigData memory collateralConfig, ConfigData memory debtConfig);

    /// @notice Retrieves configuration data for a specific silo for borrow fn.
    /// @dev This function reverts for incorrect silo address input.
    /// @param _debtSilo The address of the silo for which configuration data is being retrieved
    /// @return collateralConfig The configuration data for the collateral silo (always other than `_debtSilo`)
    /// @return debtConfig The configuration data for the debt silo (always config for `_debtSilo`)
    function getConfigsForBorrow(
        address _debtSilo
    ) external view returns (ConfigData memory collateralConfig, ConfigData memory debtConfig);

    /// @notice Retrieves fee-related information for a specific silo
    /// @dev This function reverts for incorrect silo address input
    /// @param _silo The address of the silo for which fee-related information is being retrieved.
    /// @return daoFee The DAO fee percentage in 18 decimals points.
    /// @return deployerFee The deployer fee percentage in 18 decimals points.
    /// @return flashloanFee The flashloan fee percentage in 18 decimals points.
    /// @return asset The address of the asset associated with the specified silo.
    function getFeesWithAsset(
        address _silo
    ) external view returns (uint256 daoFee, uint256 deployerFee, uint256 flashloanFee, address asset);

    /// @notice Retrieves share tokens associated with a specific silo
    /// @dev This function reverts for incorrect silo address input
    /// @param _silo The address of the silo for which share tokens are being retrieved
    /// @return protectedShareToken The address of the protected (non-borrowable) share token
    /// @return collateralShareToken The address of the collateral share token
    /// @return debtShareToken The address of the debt share token
    function getShareTokens(
        address _silo
    ) external view returns (address protectedShareToken, address collateralShareToken, address debtShareToken);

    /// @notice Retrieves the share token and the silo token associated with a specific silo
    /// @param _silo The address of the silo for which the share token and silo token are being retrieved
    /// @param _collateralType The type of collateral
    /// @return shareToken The address of the share token (collateral or protected collateral)
    /// @return asset The address of the silo token
    function getCollateralShareTokenAndAsset(
        address _silo,
        ISilo.CollateralType _collateralType
    ) external view returns (address shareToken, address asset);

    /// @notice Retrieves the share token and the silo token associated with a specific silo
    /// @param _silo The address of the silo for which the share token and silo token are being retrieved
    /// @return shareToken The address of the share token (debt)
    /// @return asset The address of the silo token
    function getDebtShareTokenAndAsset(address _silo) external view returns (address shareToken, address asset);
}

// lib/silo-contracts-v2/silo-core/contracts/interfaces/ISiloFactory.sol

interface ISiloFactory is IERC721 {
    struct Range {
        uint128 min;
        uint128 max;
    }

    /// @notice Emitted on the creation of a Silo.
    /// @param implementation Address of the Silo implementation.
    /// @param token0 Address of the first Silo token.
    /// @param token1 Address of the second Silo token.
    /// @param silo0 Address of the first Silo.
    /// @param silo1 Address of the second Silo.
    /// @param siloConfig Address of the SiloConfig.
    event NewSilo(
        address indexed implementation,
        address indexed token0,
        address indexed token1,
        address silo0,
        address silo1,
        address siloConfig
    );

    event BaseURI(string newBaseURI);

    /// @notice Emitted on the update of DAO fee.
    /// @param minDaoFee Value of the new minimal DAO fee.
    /// @param maxDaoFee Value of the new maximal DAO fee.
    event DaoFeeChanged(uint128 minDaoFee, uint128 maxDaoFee);

    /// @notice Emitted on the update of max deployer fee.
    /// @param maxDeployerFee Value of the new max deployer fee.
    event MaxDeployerFeeChanged(uint256 maxDeployerFee);

    /// @notice Emitted on the update of max flashloan fee.
    /// @param maxFlashloanFee Value of the new max flashloan fee.
    event MaxFlashloanFeeChanged(uint256 maxFlashloanFee);

    /// @notice Emitted on the update of max liquidation fee.
    /// @param maxLiquidationFee Value of the new max liquidation fee.
    event MaxLiquidationFeeChanged(uint256 maxLiquidationFee);

    /// @notice Emitted on the change of DAO fee receiver.
    /// @param daoFeeReceiver Address of the new DAO fee receiver.
    event DaoFeeReceiverChanged(address daoFeeReceiver);

    /// @notice Emitted on the change of DAO fee receiver for particular silo
    /// @param silo Address for which new DAO fee receiver is set.
    /// @param daoFeeReceiver Address of the new DAO fee receiver.
    event DaoFeeReceiverChangedForSilo(address silo, address daoFeeReceiver);

    /// @notice Emitted on the change of DAO fee receiver for particular asset
    /// @param asset Address for which new DAO fee receiver is set.
    /// @param daoFeeReceiver Address of the new DAO fee receiver.
    event DaoFeeReceiverChangedForAsset(address asset, address daoFeeReceiver);

    error MissingHookReceiver();
    error ZeroAddress();
    error DaoFeeReceiverZeroAddress();
    error SameDaoFeeReceiver();
    error EmptyToken0();
    error EmptyToken1();
    error MaxFeeExceeded();
    error InvalidFeeRange();
    error SameAsset();
    error SameRange();
    error InvalidIrm();
    error InvalidMaxLtv();
    error InvalidLt();
    error InvalidDeployer();
    error DaoMinRangeExceeded();
    error DaoMaxRangeExceeded();
    error MaxDeployerFeeExceeded();
    error MaxFlashloanFeeExceeded();
    error MaxLiquidationFeeExceeded();
    error InvalidCallBeforeQuote();
    error OracleMisconfiguration();
    error InvalidQuoteToken();
    error HookIsZeroAddress();
    error LiquidationTargetLtvTooHigh();
    error NotYourSilo();
    error ConfigMismatchSilo();
    error ConfigMismatchShareProtectedToken();
    error ConfigMismatchShareDebtToken();
    error ConfigMismatchShareCollateralToken();

    /// @notice Create a new Silo.
    /// @param _siloConfig Silo configuration.
    /// @param _siloImpl Address of the `Silo` implementation.
    /// @param _shareProtectedCollateralTokenImpl Address of the `ShareProtectedCollateralToken` implementation.
    /// @param _shareDebtTokenImpl Address of the `ShareDebtToken` implementation.
    /// @param _deployer Address of the deployer.
    /// @param _creator Address of the creator.
    function createSilo(
        ISiloConfig _siloConfig,
        address _siloImpl,
        address _shareProtectedCollateralTokenImpl,
        address _shareDebtTokenImpl,
        address _deployer,
        address _creator
    ) external;

    /// @notice NFT ownership represents the deployer fee receiver for the each Silo ID.  After burning,
    /// the deployer fee is sent to the DAO. Burning doesn't affect Silo's behavior. It is only about fee distribution.
    /// @param _siloIdToBurn silo ID to burn.
    function burn(uint256 _siloIdToBurn) external;

    /// @notice Update the value of DAO fee. Updated value will be used only for a new Silos.
    /// Previously deployed SiloConfigs are immutable.
    /// @param _minFee Value of the new DAO minimal fee.
    /// @param _maxFee Value of the new DAO maximal fee.
    function setDaoFee(uint128 _minFee, uint128 _maxFee) external;

    /// @notice Set the default DAO fee receiver.
    /// @param _newDaoFeeReceiver Address of the new DAO fee receiver.
    function setDaoFeeReceiver(address _newDaoFeeReceiver) external;

    /// @notice Set the new DAO fee receiver for asset, this setup will be used when fee receiver for silo is empty.
    /// @param _asset Address for which new DAO fee receiver is set.
    /// @param _newDaoFeeReceiver Address of the new DAO fee receiver.
    function setDaoFeeReceiverForAsset(address _asset, address _newDaoFeeReceiver) external;

    /// @notice Set the new DAO fee receiver for silo. This setup has highest priority.
    /// @param _silo Address for which new DAO fee receiver is set.
    /// @param _newDaoFeeReceiver Address of the new DAO fee receiver.
    function setDaoFeeReceiverForSilo(address _silo, address _newDaoFeeReceiver) external;

    /// @notice Update the value of max deployer fee. Updated value will be used only for a new Silos max deployer
    /// fee validation. Previously deployed SiloConfigs are immutable.
    /// @param _newMaxDeployerFee Value of the new max deployer fee.
    function setMaxDeployerFee(uint256 _newMaxDeployerFee) external;

    /// @notice Update the value of max flashloan fee. Updated value will be used only for a new Silos max flashloan
    /// fee validation. Previously deployed SiloConfigs are immutable.
    /// @param _newMaxFlashloanFee Value of the new max flashloan fee.
    function setMaxFlashloanFee(uint256 _newMaxFlashloanFee) external;

    /// @notice Update the value of max liquidation fee. Updated value will be used only for a new Silos max
    /// liquidation fee validation. Previously deployed SiloConfigs are immutable.
    /// @param _newMaxLiquidationFee Value of the new max liquidation fee.
    function setMaxLiquidationFee(uint256 _newMaxLiquidationFee) external;

    /// @notice Update the base URI.
    /// @param _newBaseURI Value of the new base URI.
    function setBaseURI(string calldata _newBaseURI) external;

    /// @notice Acceptable DAO fee range for new Silos. Denominated in 18 decimals points. 1e18 == 100%.
    function daoFeeRange() external view returns (Range memory);

    /// @notice Max deployer fee for a new Silos. Denominated in 18 decimals points. 1e18 == 100%.
    function maxDeployerFee() external view returns (uint256);

    /// @notice Max flashloan fee for a new Silos. Denominated in 18 decimals points. 1e18 == 100%.
    function maxFlashloanFee() external view returns (uint256);

    /// @notice Max liquidation fee for a new Silos. Denominated in 18 decimals points. 1e18 == 100%.
    function maxLiquidationFee() external view returns (uint256);

    /// @notice The recipient of DAO fees.
    function daoFeeReceiver() external view returns (address);

    /// @notice Get SiloConfig address by Silo id.
    function idToSiloConfig(uint256 _id) external view returns (address);

    /// @notice Get the counter of silos created by the wallet.
    function creatorSiloCounter(address _creator) external view returns (uint256);

    /// @notice Do not use this method to check if silo is secure. Anyone can deploy silo with any configuration
    /// and implementation. Most critical part of verification would be to check who deployed it.
    /// @dev True if the address was deployed using SiloFactory.
    function isSilo(address _silo) external view returns (bool);

    /// @notice Id of a next Silo to be deployed. This is an ID of non-existing Silo outside of createSilo
    /// function call. ID of a first Silo is 1.
    function getNextSiloId() external view returns (uint256);

    /// @notice Get the DAO and deployer fee receivers for a particular Silo address.
    /// @param _silo Silo address.
    /// @return dao DAO fee receiver.
    /// @return deployer Deployer fee receiver.
    function getFeeReceivers(address _silo) external view returns (address dao, address deployer);

    /// @notice Validate InitData for a new Silo. Config will be checked for the fee limits, missing parameters.
    /// @param _initData Silo init data.
    function validateSiloInitData(ISiloConfig.InitData memory _initData) external view returns (bool);
}

// lib/silo-contracts-v2/silo-core/contracts/interfaces/ISilo.sol

// solhint-disable ordering
interface ISilo is IERC20, IERC4626, IERC3156FlashLender {
    /// @dev Interest accrual happens on each deposit/withdraw/borrow/repay. View methods work on storage that might be
    ///      outdate. Some calculations require accrued interest to return current state of Silo. This struct is used
    ///      to make a decision inside functions if interest should be accrued in memory to work on updated values.
    enum AccrueInterestInMemory {
        No,
        Yes
    }

    /// @dev Silo has two separate oracles for solvency and maxLtv calculations. MaxLtv oracle is optional. Solvency
    ///      oracle can also be optional if asset is used as denominator in Silo config. For example, in ETH/USDC Silo
    ///      one could setup only solvency oracle for ETH that returns price in USDC. Then USDC does not need an oracle
    ///      because it's used as denominator for ETH and it's "price" can be assume as 1.
    enum OracleType {
        Solvency,
        MaxLtv
    }

    /// @dev There are 3 types of accounting in the system: for non-borrowable collateral deposit called "protected",
    ///      for borrowable collateral deposit called "collateral" and for borrowed tokens called "debt". System does
    ///      identical calculations for each type of accounting but it uses different data. To avoid code duplication
    ///      this enum is used to decide which data should be read.
    enum AssetType {
        Protected, // default
        Collateral,
        Debt
    }

    /// @dev There are 2 types of accounting in the system: for non-borrowable collateral deposit called "protected" and
    ///      for borrowable collateral deposit called "collateral". System does
    ///      identical calculations for each type of accounting but it uses different data. To avoid code duplication
    ///      this enum is used to decide which data should be read.
    enum CollateralType {
        Protected, // default
        Collateral
    }

    /// @dev Types of calls that can be made by the hook receiver on behalf of Silo via `callOnBehalfOfSilo` fn
    enum CallType {
        Call, // default
        Delegatecall
    }

    /// @param _assets Amount of assets the user wishes to withdraw. Use 0 if shares are provided.
    /// @param _shares Shares the user wishes to burn in exchange for the withdrawal. Use 0 if assets are provided.
    /// @param _receiver Address receiving the withdrawn assets
    /// @param _owner Address of the owner of the shares being burned
    /// @param _spender Address executing the withdrawal; may be different than `_owner` if an allowance was set
    /// @param _collateralType Type of the asset being withdrawn (Collateral or Protected)
    struct WithdrawArgs {
        uint256 assets;
        uint256 shares;
        address receiver;
        address owner;
        address spender;
        ISilo.CollateralType collateralType;
    }

    /// @param assets Number of assets the borrower intends to borrow. Use 0 if shares are provided.
    /// @param shares Number of shares corresponding to the assets that the borrower intends to borrow. Use 0 if
    /// assets are provided.
    /// @param receiver Address that will receive the borrowed assets
    /// @param borrower The user who is borrowing the assets
    struct BorrowArgs {
        uint256 assets;
        uint256 shares;
        address receiver;
        address borrower;
    }

    /// @param shares Amount of shares the user wishes to transit.
    /// @param owner owner of the shares after transition.
    /// @param transitionFrom type of collateral that will be transitioned.
    struct TransitionCollateralArgs {
        uint256 shares;
        address owner;
        ISilo.CollateralType transitionFrom;
    }

    struct UtilizationData {
        /// @dev COLLATERAL: Amount of asset token that has been deposited to Silo plus interest earned by depositors.
        /// It also includes token amount that has been borrowed.
        uint256 collateralAssets;
        /// @dev DEBT: Amount of asset token that has been borrowed plus accrued interest.
        uint256 debtAssets;
        /// @dev timestamp of the last interest accrual
        uint64 interestRateTimestamp;
    }

    /// @dev Interest and revenue may be rounded down to zero if the underlying token's decimal is low.
    /// Because of that, we need to store fractions for further calculation to minimize losses.
    struct Fractions {
        /// @dev interest value that we could not convert to full token in 36 decimals, max value for it is 1e18.
        /// this value was not yet apply as interest for borrowers
        uint64 interest;
        /// @dev revenue value that we could not convert to full token in 36 decimals, max value for it is 1e18.
        uint64 revenue;
    }

    struct SiloStorage {
        /// @param daoAndDeployerRevenue Current amount of assets (fees) accrued by DAO and Deployer
        /// but not yet withdrawn
        uint192 daoAndDeployerRevenue;
        /// @dev timestamp of the last interest accrual
        uint64 interestRateTimestamp;
        /// @dev Interest and revenue fractions for more precise calculations
        Fractions fractions;
        /// @dev silo is just for one asset,
        /// but this one asset can be of three types: mapping key is uint256(AssetType), so we store `assets` by type.
        /// Assets based on type:
        /// - PROTECTED COLLATERAL: Amount of asset token that has been deposited to Silo that can be ONLY used
        /// as collateral. These deposits do NOT earn interest and CANNOT be borrowed.
        /// - COLLATERAL: Amount of asset token that has been deposited to Silo plus interest earned by depositors.
        /// It also includes token amount that has been borrowed.
        /// - DEBT: Amount of asset token that has been borrowed plus accrued interest.
        /// `totalAssets` can have outdated value (without interest), if you doing view call (of off-chain call)
        /// please use getters eg `getCollateralAssets()` to fetch value that includes interest.
        mapping(AssetType assetType => uint256 assets) totalAssets;
    }

    /// @notice Emitted on protected deposit
    /// @param sender wallet address that deposited asset
    /// @param owner wallet address that received shares in Silo
    /// @param assets amount of asset that was deposited
    /// @param shares amount of shares that was minted
    event DepositProtected(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted on protected withdraw
    /// @param sender wallet address that sent transaction
    /// @param receiver wallet address that received asset
    /// @param owner wallet address that owned asset
    /// @param assets amount of asset that was withdrew
    /// @param shares amount of shares that was burn
    event WithdrawProtected(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted on borrow
    /// @param sender wallet address that sent transaction
    /// @param receiver wallet address that received asset
    /// @param owner wallet address that owes assets
    /// @param assets amount of asset that was borrowed
    /// @param shares amount of shares that was minted
    event Borrow(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted on repayment
    /// @param sender wallet address that repaid asset
    /// @param owner wallet address that owed asset
    /// @param assets amount of asset that was repaid
    /// @param shares amount of shares that was burn
    event Repay(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice emitted only when collateral has been switched to other one
    event CollateralTypeChanged(address indexed borrower);

    event HooksUpdated(uint24 hooksBefore, uint24 hooksAfter);

    event AccruedInterest(uint256 hooksBefore);

    event FlashLoan(uint256 amount);

    event WithdrawnFees(uint256 daoFees, uint256 deployerFees, bool redirectedDeployerFees);

    event DeployerFeesRedirected(uint256 deployerFees);

    error UnsupportedFlashloanToken();
    error FlashloanAmountTooBig();
    error NothingToWithdraw();
    error ProtectedProtection();
    error NotEnoughLiquidity();
    error NotSolvent();
    error BorrowNotPossible();
    error EarnedZero();
    error FlashloanFailed();
    error AboveMaxLtv();
    error SiloInitialized();
    error OnlyHookReceiver();
    error NoLiquidity();
    error InputCanBeAssetsOrShares();
    error CollateralSiloAlreadySet();
    error RepayTooHigh();
    error ZeroAmount();
    error InputZeroShares();
    error ReturnZeroAssets();
    error ReturnZeroShares();

    /// @return siloFactory The associated factory of the silo
    function factory() external view returns (ISiloFactory siloFactory);

    /// @notice Method for HookReceiver only to call on behalf of Silo
    /// @param _target address of the contract to call
    /// @param _value amount of ETH to send
    /// @param _callType type of the call (Call or Delegatecall)
    /// @param _input calldata for the call
    function callOnBehalfOfSilo(
        address _target,
        uint256 _value,
        CallType _callType,
        bytes calldata _input
    ) external payable returns (bool success, bytes memory result);

    /// @notice Initialize Silo
    /// @param _siloConfig address of ISiloConfig with full config for this Silo
    function initialize(ISiloConfig _siloConfig) external;

    /// @notice Update hooks configuration for Silo
    /// @dev This function must be called after the hooks configuration is changed in the hook receiver
    function updateHooks() external;

    /// @notice Fetches the silo configuration contract
    /// @return siloConfig Address of the configuration contract associated with the silo
    function config() external view returns (ISiloConfig siloConfig);

    /// @notice Fetches the utilization data of the silo used by IRM
    function utilizationData() external view returns (UtilizationData memory utilizationData);

    /// @notice Fetches the real (available to borrow) liquidity in the silo, it does include interest
    /// @return liquidity The amount of liquidity
    function getLiquidity() external view returns (uint256 liquidity);

    /// @notice Determines if a borrower is solvent
    /// @param _borrower Address of the borrower to check for solvency
    /// @return True if the borrower is solvent, otherwise false
    function isSolvent(address _borrower) external view returns (bool);

    /// @notice Retrieves the raw total amount of assets based on provided type (direct storage access)
    function getTotalAssetsStorage(AssetType _assetType) external view returns (uint256);

    /// @notice Direct storage access to silo storage
    /// @dev See struct `SiloStorage` for more details
    function getSiloStorage()
        external
        view
        returns (
            uint192 daoAndDeployerRevenue,
            uint64 interestRateTimestamp,
            uint256 protectedAssets,
            uint256 collateralAssets,
            uint256 debtAssets
        );

    /// @notice Direct access to silo storage fractions variables
    function getFractionsStorage() external view returns (Fractions memory fractions);

    /// @notice Retrieves the total amount of collateral (borrowable) assets with interest
    /// @return totalCollateralAssets The total amount of assets of type 'Collateral'
    function getCollateralAssets() external view returns (uint256 totalCollateralAssets);

    /// @notice Retrieves the total amount of debt assets with interest
    /// @return totalDebtAssets The total amount of assets of type 'Debt'
    function getDebtAssets() external view returns (uint256 totalDebtAssets);

    /// @notice Retrieves the total amounts of collateral and protected (non-borrowable) assets
    /// @return totalCollateralAssets The total amount of assets of type 'Collateral'
    /// @return totalProtectedAssets The total amount of protected (non-borrowable) assets
    function getCollateralAndProtectedTotalsStorage()
        external
        view
        returns (uint256 totalCollateralAssets, uint256 totalProtectedAssets);

    /// @notice Retrieves the total amounts of collateral and debt assets
    /// @return totalCollateralAssets The total amount of assets of type 'Collateral'
    /// @return totalDebtAssets The total amount of debt assets of type 'Debt'
    function getCollateralAndDebtTotalsStorage()
        external
        view
        returns (uint256 totalCollateralAssets, uint256 totalDebtAssets);

    /// @notice Implements IERC4626.convertToShares for each asset type
    function convertToShares(uint256 _assets, AssetType _assetType) external view returns (uint256 shares);

    /// @notice Implements IERC4626.convertToAssets for each asset type
    function convertToAssets(uint256 _shares, AssetType _assetType) external view returns (uint256 assets);

    /// @notice Implements IERC4626.previewDeposit for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function previewDeposit(uint256 _assets, CollateralType _collateralType) external view returns (uint256 shares);

    /// @notice Implements IERC4626.deposit for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function deposit(
        uint256 _assets,
        address _receiver,
        CollateralType _collateralType
    ) external returns (uint256 shares);

    /// @notice Implements IERC4626.previewMint for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function previewMint(uint256 _shares, CollateralType _collateralType) external view returns (uint256 assets);

    /// @notice Implements IERC4626.mint for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function mint(uint256 _shares, address _receiver, CollateralType _collateralType) external returns (uint256 assets);

    /// @notice Implements IERC4626.maxWithdraw for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function maxWithdraw(address _owner, CollateralType _collateralType) external view returns (uint256 maxAssets);

    /// @notice Implements IERC4626.previewWithdraw for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function previewWithdraw(uint256 _assets, CollateralType _collateralType) external view returns (uint256 shares);

    /// @notice Implements IERC4626.withdraw for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner,
        CollateralType _collateralType
    ) external returns (uint256 shares);

    /// @notice Implements IERC4626.maxRedeem for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function maxRedeem(address _owner, CollateralType _collateralType) external view returns (uint256 maxShares);

    /// @notice Implements IERC4626.previewRedeem for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function previewRedeem(uint256 _shares, CollateralType _collateralType) external view returns (uint256 assets);

    /// @notice Implements IERC4626.redeem for protected (non-borrowable) collateral and collateral
    /// @dev Reverts for debt asset type
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner,
        CollateralType _collateralType
    ) external returns (uint256 assets);

    /// @notice Calculates the maximum amount of assets that can be borrowed by the given address
    /// @param _borrower Address of the potential borrower
    /// @return maxAssets Maximum amount of assets that the borrower can borrow, this value is underestimated
    /// That means, in some cases when you borrow maxAssets, you will be able to borrow again eg. up to 2wei
    /// Reason for underestimation is to return value that will not cause borrow revert
    function maxBorrow(address _borrower) external view returns (uint256 maxAssets);

    /// @notice Previews the amount of shares equivalent to the given asset amount for borrowing
    /// @param _assets Amount of assets to preview the equivalent shares for
    /// @return shares Amount of shares equivalent to the provided asset amount
    function previewBorrow(uint256 _assets) external view returns (uint256 shares);

    /// @notice Allows an address to borrow a specified amount of assets
    /// @param _assets Amount of assets to borrow
    /// @param _receiver Address receiving the borrowed assets
    /// @param _borrower Address responsible for the borrowed assets
    /// @return shares Amount of shares equivalent to the borrowed assets
    function borrow(uint256 _assets, address _receiver, address _borrower) external returns (uint256 shares);

    /// @notice Calculates the maximum amount of shares that can be borrowed by the given address
    /// @param _borrower Address of the potential borrower
    /// @return maxShares Maximum number of shares that the borrower can borrow
    function maxBorrowShares(address _borrower) external view returns (uint256 maxShares);

    /// @notice Previews the amount of assets equivalent to the given share amount for borrowing
    /// @param _shares Amount of shares to preview the equivalent assets for
    /// @return assets Amount of assets equivalent to the provided share amount
    function previewBorrowShares(uint256 _shares) external view returns (uint256 assets);

    /// @notice Calculates the maximum amount of assets that can be borrowed by the given address
    /// @param _borrower Address of the potential borrower
    /// @return maxAssets Maximum amount of assets that the borrower can borrow, this value is underestimated
    /// That means, in some cases when you borrow maxAssets, you will be able to borrow again eg. up to 2wei
    /// Reason for underestimation is to return value that will not cause borrow revert
    function maxBorrowSameAsset(address _borrower) external view returns (uint256 maxAssets);

    /// @notice Allows an address to borrow a specified amount of assets that will be back up with deposit made with the
    /// same asset
    /// @param _assets Amount of assets to borrow
    /// @param _receiver Address receiving the borrowed assets
    /// @param _borrower Address responsible for the borrowed assets
    /// @return shares Amount of shares equivalent to the borrowed assets
    function borrowSameAsset(uint256 _assets, address _receiver, address _borrower) external returns (uint256 shares);

    /// @notice Allows a user to borrow assets based on the provided share amount
    /// @param _shares Amount of shares to borrow against
    /// @param _receiver Address to receive the borrowed assets
    /// @param _borrower Address responsible for the borrowed assets
    /// @return assets Amount of assets borrowed
    function borrowShares(uint256 _shares, address _receiver, address _borrower) external returns (uint256 assets);

    /// @notice Calculates the maximum amount an address can repay based on their debt shares
    /// @param _borrower Address of the borrower
    /// @return assets Maximum amount of assets the borrower can repay
    function maxRepay(address _borrower) external view returns (uint256 assets);

    /// @notice Provides an estimation of the number of shares equivalent to a given asset amount for repayment
    /// @param _assets Amount of assets to be repaid
    /// @return shares Estimated number of shares equivalent to the provided asset amount
    function previewRepay(uint256 _assets) external view returns (uint256 shares);

    /// @notice Repays a given asset amount and returns the equivalent number of shares
    /// @param _assets Amount of assets to be repaid
    /// @param _borrower Address of the borrower whose debt is being repaid
    /// @return shares The equivalent number of shares for the provided asset amount
    function repay(uint256 _assets, address _borrower) external returns (uint256 shares);

    /// @notice Calculates the maximum number of shares that can be repaid for a given borrower
    /// @param _borrower Address of the borrower
    /// @return shares The maximum number of shares that can be repaid for the borrower
    function maxRepayShares(address _borrower) external view returns (uint256 shares);

    /// @notice Provides a preview of the equivalent assets for a given number of shares to repay
    /// @param _shares Number of shares to preview repayment for
    /// @return assets Equivalent assets for the provided shares
    function previewRepayShares(uint256 _shares) external view returns (uint256 assets);

    /// @notice Allows a user to repay a loan using shares instead of assets
    /// @param _shares The number of shares the borrower wants to repay with
    /// @param _borrower The address of the borrower for whom to repay the loan
    /// @return assets The equivalent assets amount for the provided shares
    function repayShares(uint256 _shares, address _borrower) external returns (uint256 assets);

    /// @notice Transitions assets between borrowable (collateral) and non-borrowable (protected) states
    /// @dev This function allows assets to move between collateral and protected (non-borrowable) states without
    /// leaving the protocol
    /// @param _shares Amount of shares to be transitioned
    /// @param _owner Owner of the assets being transitioned
    /// @param _transitionFrom Specifies if the transition is from collateral or protected assets
    /// @return assets Amount of assets transitioned
    function transitionCollateral(
        uint256 _shares,
        address _owner,
        CollateralType _transitionFrom
    ) external returns (uint256 assets);

    /// @notice Switches the collateral silo to this silo
    /// @dev Revert if the collateral silo is already set
    function switchCollateralToThisSilo() external;

    /// @notice Accrues interest for the asset and returns the accrued interest amount
    /// @return accruedInterest The total interest accrued during this operation
    function accrueInterest() external returns (uint256 accruedInterest);

    /// @notice only for SiloConfig
    function accrueInterestForConfig(address _interestRateModel, uint256 _daoFee, uint256 _deployerFee) external;

    /// @notice Withdraws earned fees and distributes them to the DAO and deployer fee receivers
    function withdrawFees() external;
}
