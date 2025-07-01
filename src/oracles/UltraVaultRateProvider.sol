// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "../interfaces/IRateProvider.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    // State
    mapping(address => AssetData) public supportedAssets;
    address public baseAsset;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _baseAsset) external initializer {
        initOwner(_owner);
        baseAsset = _baseAsset;
        // Base asset is always supported and pegged to itself
        supportedAssets[_baseAsset] = AssetData({
            isPegged: true,
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
        if (address(supportedAssets[asset].rateProvider) != address(0)) 
            revert AssetAlreadySupported();
        if (!isPegged && rateProvider == address(0))
            revert InvalidRateProvider();

        supportedAssets[asset] = AssetData({
            isPegged: isPegged,
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
     * @notice Get the rate between an asset and the base asset
     * @param asset The asset to get rate for
     * @return rate The rate in terms of base asset (18 decimals)
     */
    function getRate(address asset) external view returns (uint256 rate) {
        AssetData memory data = supportedAssets[asset];
        if (data.isPegged) {
            return 1e18; // 1:1 rate
        }

        if (data.rateProvider == address(0)) revert AssetNotSupported();

        // Call external rate provider
        return IRateProvider(data.rateProvider).getRate(asset);
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
} 
