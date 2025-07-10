// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "../interfaces/IRateProvider.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InitializableOwnable } from "../utils/InitializableOwnable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

struct AssetData {
    bool isPegged;  // If true, asset is 1:1 with base asset
    uint8 decimals;
    address rateProvider;  // External rate provider if not pegged
}

/**
 * @title IUltraVaultRateProvider
 * @notice Handles rate calculations between assets for UltraVault
 */
interface IUltraVaultRateProvider {

    /**
     * @notice Add a new supported asset
     * @param asset The asset to add
     * @param isPegged Whether the asset is pegged to base asset
     * @param rateProvider External rate provider if not pegged
     */
    function addAsset(address asset, bool isPegged, address rateProvider) external;

    /**
     * @notice Remove a supported asset
     * @param asset The asset to remove
     */
    function removeAsset(address asset) external;

    /**
     * @notice Update rate provider for an asset
     * @param asset The asset to update
     * @param rateProvider New rate provider
     */
    function updateRateProvider(address asset, address rateProvider) external;

    /**
     * @notice Get the rate between an asset and the base asset
     * @param asset The asset to get rate for
     * @param assets Amount to covert
     * @return result The rate in terms of base asset (18 decimals)
     */
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result);

    /**
     * @notice Convert from base asset to specific asset
     * @param asset The asset to convert to
     * @param baseAssets Amount in base asset units
     * @return result The amount in asset units
     */
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256 result);

    /**
     * @notice Check if an asset is supported
     * @param asset The asset to check
     * @return True if asset is supported
     */
    function isSupported(address asset) external view returns (bool);
} 
