// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "src/interfaces/IRateProvider.sol";

/// @title ComposableRateProvider
/// @notice Chains two IRateProviders through a single intermediate asset and exposes the pair as
///         one IRateProvider (e.g. sUSDe -> USDe -> USDC). Because it is itself an IRateProvider,
///         deeper chains are built by nesting: a ComposableRateProvider can serve as either leg of
///         an outer ComposableRateProvider.
/// @dev Pure router: it performs NO decimal math and stores no decimals. It forwards the caller's
///      `asset` to `assetProvider` and supplies `intermediateAsset` to `baseProvider`, relying on
///      each leg to handle its own decimals in the respective token's native units.
contract ComposableRateProvider is IRateProvider {
    ////////////////
    // Immutables //
    ////////////////

    /// @notice The intermediate asset bridging the two legs; supplied to `baseProvider`.
    address public immutable intermediateAsset;

    /// @notice Leg converting the input asset <-> the intermediate asset.
    IRateProvider public immutable assetProvider;

    /// @notice Leg converting the intermediate asset <-> the base asset.
    IRateProvider public immutable baseProvider;

    ////////////
    // Errors //
    ////////////

    error ZeroAddress();

    /////////////////
    // Constructor //
    /////////////////

    /// @param _intermediateAsset The asset bridging the two legs
    /// @param _assetProvider Leg converting input asset <-> intermediate asset
    /// @param _baseProvider Leg converting intermediate asset <-> base asset
    constructor(address _intermediateAsset, address _assetProvider, address _baseProvider) {
        require(_intermediateAsset != address(0), ZeroAddress());
        require(_assetProvider != address(0), ZeroAddress());
        require(_baseProvider != address(0), ZeroAddress());

        intermediateAsset = _intermediateAsset;
        assetProvider = IRateProvider(_assetProvider);
        baseProvider = IRateProvider(_baseProvider);
    }

    ///////////////////////
    // IRateProvider API //
    ///////////////////////

    /// @inheritdoc IRateProvider
    /// @notice Convert an input-asset amount to the base asset via the intermediate asset.
    /// @param asset The input asset (forwarded to `assetProvider`, which gates it)
    /// @param assets Amount of the input asset
    /// @return Amount in the base asset
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256) {
        uint256 intermediateAmount = assetProvider.convertToUnderlying(asset, assets);
        return baseProvider.convertToUnderlying(intermediateAsset, intermediateAmount);
    }

    /// @inheritdoc IRateProvider
    /// @notice Convert a base-asset amount to the input asset via the intermediate asset.
    /// @param asset The input asset (forwarded to `assetProvider`, which gates it)
    /// @param baseAssets Amount in the base asset
    /// @return Amount of the input asset
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256) {
        uint256 intermediateAmount = baseProvider.convertFromUnderlying(intermediateAsset, baseAssets);
        return assetProvider.convertFromUnderlying(asset, intermediateAmount);
    }
}
