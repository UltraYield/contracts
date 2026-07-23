// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title AnyERC4626VaultRateProvider
/// @notice Adapter turning any ERC-4626 vault into an IRateProvider, converting between
///         the vault's shares and its OWN underlying asset.
/// @dev convertToUnderlying = convertToAssets (shares -> underlying assets);
///      convertFromUnderlying = convertToShares (underlying assets -> shares).
///      Returned amounts are denominated in the vault's underlying asset, NOT an UltraVault
///      base asset. This is a building block: compose it inside another rate provider to add
///      any underlying->base conversion (e.g. USDe->USDC). Do NOT register it directly in
///      UltraVaultRateProvider unless the vault's underlying == the UltraVault base asset.
/// @dev SECURITY: convertToAssets/convertToShares reflect the wrapped vault's SPOT exchange
///      rate. If that vault derives its share price from on-chain spot balances, the rate is
///      manipulable within a single transaction (e.g. flash loans, asset donations). Only wrap
///      ERC-4626 vaults whose share price is manipulation-resistant, and account for this when
///      configuring assets in the UltraYield system.
contract AnyERC4626VaultRateProvider is IRateProvider {
    ////////////////
    // Immutables //
    ////////////////

    /// @notice The wrapped ERC-4626 vault (the supported asset)
    IERC4626 public immutable ASSET;

    ////////////
    // Errors //
    ////////////

    error InvalidAsset();
    error ZeroAddress();

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize the rate provider
    /// @param vault The address of the wrapped ERC-4626 vault
    constructor(address vault) {
        require(vault != address(0), ZeroAddress());
        ASSET = IERC4626(vault);
    }

    ///////////////////////
    // IRateProvider API //
    ///////////////////////

    /// @inheritdoc IRateProvider
    /// @notice Convert wrapped vault shares to its underlying asset amount
    /// @param asset The asset to convert (must be the wrapped vault)
    /// @param assets Amount of shares to convert
    /// @return Amount in the vault's underlying asset
    /// @dev Returns the wrapped vault's spot rate; see contract-level SECURITY note on manipulability.
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256) {
        require(asset == address(ASSET), InvalidAsset());
        return ASSET.convertToAssets(assets);
    }

    /// @inheritdoc IRateProvider
    /// @notice Convert underlying asset amount to wrapped vault shares
    /// @param asset The asset to convert to (must be the wrapped vault)
    /// @param underlyingAssets Amount of the vault's underlying asset to convert
    /// @return Amount of shares
    /// @dev Returns the wrapped vault's spot rate; see contract-level SECURITY note on manipulability.
    function convertFromUnderlying(address asset, uint256 underlyingAssets) external view returns (uint256) {
        require(asset == address(ASSET), InvalidAsset());
        return ASSET.convertToShares(underlyingAssets);
    }
}
