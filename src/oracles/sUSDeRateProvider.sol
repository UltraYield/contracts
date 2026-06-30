// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title sUSDeRateProvider
/// @notice Rate provider for sUSDe (Staked USDe)
/// @dev sUSDe is an ERC4626 vault where USDe is the underlying asset
contract sUSDeRateProvider is IRateProvider {
    ///////////////
    // Constants //
    ///////////////

    /// @notice The sUSDe token contract (ERC4626 vault)
    IERC4626 public immutable ASSET;

    /// @notice sUSDe token decimals
    uint8 public immutable ASSET_DECIMALS;

    /// @notice Base asset decimals
    uint8 public immutable BASE_DECIMALS;

    ////////////
    // Errors //
    ////////////

    error InvalidAsset();
    error ZeroAddress();

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize the rate provider
    /// @param asset The address of sUSDe ERC-4626 vault
    /// @param vault The address of Ultra vault to work with
    constructor(address asset, address vault) {
        require(asset != address(0), ZeroAddress());
        require(vault != address(0), ZeroAddress());

        ASSET = IERC4626(asset);
        ASSET_DECIMALS = ASSET.decimals();
        address baseAsset = IERC4626(vault).asset();
        BASE_DECIMALS = IERC20Metadata(baseAsset).decimals();
    }

    ///////////////////////
    // IRateProvider API //
    ///////////////////////

    /// @inheritdoc IRateProvider
    /// @notice Convert sUSDe amount to USDe amount
    /// @param asset The asset to convert (must be sUSDe)
    /// @param assets Amount of sUSDe to convert
    /// @return result Amount of USDe (in 18 decimals)
    function convertToUnderlying(
        address asset,
        uint256 assets
    ) external view returns (uint256 result) {
        require(asset == address(ASSET), InvalidAsset());
        
        // Use ERC4626's convertToAssets to get the underlying USDe amount
        uint256 USDeAmount = ASSET.convertToAssets(assets);
        
        // Normalize decimals from 18 decimals (USDe) to 6 decimals (USDC)
        // Assume 1 USDe = 1 USD = 1 base token (USDC)
        result = _normalizeDecimals(USDeAmount, ASSET_DECIMALS, BASE_DECIMALS);
    }

    /// @inheritdoc IRateProvider
    /// @notice Convert base asset amount to sUSDe amount
    /// @param asset The asset to convert to (must be sUSDe)
    /// @param baseAssets Amount of base asset to convert
    /// @return result Amount of sUSDe
    function convertFromUnderlying(
        address asset,
        uint256 baseAssets
    ) external view returns (uint256 result) {
        require(asset == address(ASSET), InvalidAsset());
        
        // Normalize decimals from 6 decimals (USDC) to 18 decimals (sUSDe)
        uint256 normalizedBaseAssets = _normalizeDecimals(baseAssets, BASE_DECIMALS, ASSET_DECIMALS);
        
        // Assume 1 base token (USDC) = 1 USD = 1 USDe
        // Use ERC4626's convertToShares to get the sUSDe amount
        uint256 sUSDeAmount = ASSET.convertToShares(normalizedBaseAssets);
        result = sUSDeAmount;
    }

    //////////////////////
    // Internal Helpers //
    //////////////////////

    /// @dev Normalize decimals between different decimal representations
    /// @param amount The amount to normalize
    /// @param fromDecimals Source decimals
    /// @param toDecimals Target decimals
    /// @return Normalized amount
    function _normalizeDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            uint8 diff;
            unchecked { diff = toDecimals - fromDecimals; }
            return amount * 10 ** diff;
        } else {
            uint8 diff;
            unchecked { diff = fromDecimals - toDecimals; }
            return amount / 10 ** diff;
        }
    }
}
