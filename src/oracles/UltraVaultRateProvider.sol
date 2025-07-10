// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "../interfaces/IRateProvider.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { InitializableOwnable } from "../utils/InitializableOwnable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AssetData } from "../interfaces/IUltraVaultRateProvider.sol";

/**
 * @title UltraVaultRateProvider
 * @notice Handles rate calculations between assets for UltraVault
 */
contract UltraVaultRateProvider is InitializableOwnable, Initializable {
    // Events
    event AssetAdded(address indexed asset, bool isPegged);
    event AssetRemoved(address indexed asset);
    event RateProviderUpdated(address indexed asset, address rateProvider);

    // Errors
    error AssetNotSupported();
    error InvalidRateProvider();
    error AssetAlreadySupported();

    address public baseAsset;
    uint8 public decimals;

    // State
    mapping(address => AssetData) public supportedAssets;

    // V0: 3 total: baseAsset, decimals, supportedAssets
    uint256[47] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _baseAsset) external initializer {
        initOwner(_owner);
        baseAsset = _baseAsset;
        decimals = IERC20Metadata(_baseAsset).decimals();
        // Base asset is always supported and pegged to itself
        supportedAssets[_baseAsset] = AssetData({
            isPegged: true,
            decimals: decimals,
            rateProvider: address(0)
        });
    }

    /**
     * @notice Add a new supported asset
     * @param asset The asset to add
     * @param isPegged Whether the asset is pegged to base asset
     * @param rateProvider External rate provider if not pegged
     */
    function addAsset(address asset, bool isPegged, address rateProvider) external onlyOwner {
        AssetData memory data = supportedAssets[asset];
        if (data.isPegged || data.rateProvider != address(0)) 
            revert AssetAlreadySupported();
        if (!isPegged && rateProvider == address(0))
            revert InvalidRateProvider();

        supportedAssets[asset] = AssetData({
            isPegged: isPegged,
            decimals: IERC20Metadata(asset).decimals(),
            rateProvider: rateProvider
        });

        emit AssetAdded(address(asset), isPegged);
        if (!isPegged) {
            emit RateProviderUpdated(address(asset), rateProvider);
        }
    }

    /**
     * @notice Remove a supported asset
     * @param asset The asset to remove
     */
    function removeAsset(address asset) external onlyOwner {
        if (asset == baseAsset) revert AssetNotSupported();
        delete supportedAssets[asset];
        emit AssetRemoved(address(asset));
    }

    /**
     * @notice Update rate provider for an asset
     * @param asset The asset to update
     * @param rateProvider New rate provider
     */
    function updateRateProvider(address asset, address rateProvider) external onlyOwner {
        if (asset == baseAsset) revert AssetNotSupported();
        if (supportedAssets[asset].isPegged) revert AssetNotSupported();
        if (rateProvider == address(0)) revert InvalidRateProvider();

        supportedAssets[asset].rateProvider = rateProvider;
        emit RateProviderUpdated(address(asset), rateProvider);
    }

    /**
     * @notice Convert from specific asset to base asset
     * @param asset The asset to get rate for
     * @param assets Amount to covert
     * @return result The rate in terms of base asset (18 decimals)
     */
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result) {
        AssetData memory data = supportedAssets[asset];
        if (data.isPegged) {
            if (data.decimals == decimals) {
                return assets; // 1:1 rate
            } else {
                // 1:1 rate accounting for decimals, convert from asset decimals to base asset decimals
                return _convertDecimals(assets, data.decimals, decimals);
            }
        }

        if (data.rateProvider == address(0)) revert AssetNotSupported();

        // Call external rate provider
        return IRateProvider(data.rateProvider).convertToUnderlying(asset, assets);
    }

    /**
     * @notice Convert from base asset to specific asset
     * @param asset The asset to convert to
     * @param baseAssets Amount in base asset units
     * @return result The amount in asset units
     */
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256 result) {
        AssetData memory data = supportedAssets[asset];
        if (data.isPegged) {
            if (data.decimals == decimals) {
                return baseAssets; // 1:1 rate
            } else {
                // 1:1 rate accounting for decimals, convert from base asset decimals to asset decimals
                return _convertDecimals(baseAssets, decimals, data.decimals);
            }
        }

        if (data.rateProvider == address(0)) revert AssetNotSupported();

        // Call external rate provider
        return IRateProvider(data.rateProvider).convertFromUnderlying(asset, baseAssets);
    }

    /**
     * @notice Check if an asset is supported
     * @param asset The asset to check
     * @return True if asset is supported
     */
    function isSupported(address asset) external view returns (bool) {
        AssetData memory data = supportedAssets[asset];
        if (data.isPegged) {
            return true;
        }
        return data.rateProvider != address(0);
    }

    /**
     * @notice Help account for decimals
     */
    function _convertDecimals(
        uint256 amount, 
        uint8 fromDecimals, 
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        } else {
            return amount / 10 ** (fromDecimals - toDecimals);
        }
    }
} 
