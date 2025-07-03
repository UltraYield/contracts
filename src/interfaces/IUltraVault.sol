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
     * @notice Helper to deposit assets for msg.sender
     * @param assets Amount to deposit
     * @param receiver One to get the assets
     * @return shares Amount of shares received
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Request redeem for msg.sender
     * @param shares Amount to redeem
     * @return requestId Request identifier
     */
    function requestRedeem(uint256 shares) external returns (uint256 requestId);

    /**
     * @notice Fulfill redeem request
     * @param shares Amount to redeem
     * @param controller Controller to redeem for
     * @return assets Amount of assets received
     * @dev Reverts if shares < minAmount
     * @dev Collects withdrawal fee to incentivize manager
     */
    function fulfillRedeem(
        uint256 shares,
        address controller
    ) external returns (uint256 assets);

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
