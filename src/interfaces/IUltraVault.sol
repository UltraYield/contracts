// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title IUltraVault
 * @notice A simplified interface for use in other contracts
 */
interface IUltraVault {

    /**
     * @notice Returns the address of the underlying token used for the Vault
     * @return assetTokenAddress The address of the underlying asset
     */
    function asset() external view returns (address);

    /**
     * @notice Returns the address of the rate provider
     */
    function rateProvider() external view returns (address);

    /**
     * @notice Preview shares for deposit
     * @param assets Amount to deposit
     * @return shares Amount of shares received
     * @dev Returns 0 if vault is paused
     */
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256);

    /**
     * @notice Preview assets for mint
     * @param shares Amount to mint
     * @return assets Amount of assets required
     * @dev Returns 0 if vault is paused
     */
    function previewMint(
        uint256 shares
    ) external view returns (uint256);

    /**
     * @notice Get max assets for deposit
     * @return assets Maximum deposit amount
     * @dev Returns 0 if vault is paused
     */
    function maxDeposit(
        address
    ) external view returns (uint256);

    /**
     * @notice Get max shares for mint
     * @return shares Maximum mint amount
     * @dev Returns 0 if vault is paused
     */
    function maxMint(
        address
    ) external view returns (uint256);

    /**
     * @notice Deposit assets for receiver
     * @param asset Asset
     * @param assets Amount to deposit
     * @param receiver Share recipient
     * @return shares Amount of shares received
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before transferring assets
     */
    function depositAsset(
        address asset,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /**
     * @notice Mint shares for receiver with specific asset
     * @param asset Asset to mint with
     * @param shares Amount to mint
     * @param receiver Share recipient
     * @return assets Amount of assets required
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before minting shares
     */
    function mintWithAsset(
        address asset,
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    /**
     * @notice Request redeem of shares
     * @param asset Asset
     * @param shares Amount to redeem
     * @param controller Share recipient
     * @param owner Share owner
     * @return requestId Request identifier
     * @dev Adds to controller's pending redeem requests
     */
    function requestRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    /**
     * @notice Fulfill redeem request
     * @param asset Asset
     * @param shares Amount to redeem
     * @param controller Controller address
     * @return assets Amount of claimable assets
     */
    function fulfillRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller
    ) external returns (uint256);

    /**
     * @notice Redeem shares from fulfilled requests
     * @param asset Asset
     * @param shares Amount to redeem
     * @param receiver Asset recipient
     * @param controller Controller address
     * @return assets Amount of assets received
     * @dev Asynchronous function, works when paused
     * @dev Caller must be controller or operator
     * @dev Requires sufficient claimable shares
     */
    function redeemAsset(
        address asset,
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets);

    /**
     * @notice Cancel redeem request for controller
     * @param controller Controller address
     * @dev Transfers pending shares back to msg.sender
     */
    function cancelRedeemRequest(address controller) external;

    /**
     * @notice Cancel redeem request for controller
     * @param controller Controller address
     * @param receiver Share recipient
     * @dev Transfers pending shares back to receiver
     */
    function cancelRedeemRequest(
        address controller,
        address receiver
    ) external;

    /**
     * @notice Cancel redeem request for controller
     * @param asset Asset
     * @param controller Controller address
     * @param receiver Share recipient
     * @dev Transfers pending shares back to receiver
     */
    function cancelRedeemRequestOfAsset(
        address asset,
        address controller,
        address receiver
    ) external;

    /**
     * @dev Returns the oracle address of the vault.
     */
    function oracle() external view returns (address);

    /**
     * @dev Returns the paused status of the vault.
     */
    function paused() external view returns (bool);    

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
} 
