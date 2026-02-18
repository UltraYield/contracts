# Changelog

## Unreleased

### Changed

- **Breaking:** `BaseControlledAsyncRedeem` breaking changes:
  - Add `adjustment` param to `convertToUnderlying` and `convertFromUnderlying` functions
- **Breaking:** `UltraVaultRateProvider` breaking changes:
  - Make the contract non-upgradeable
  - Change asset data storage layout
  - Rename function to get base asset decimals from `decimals` to `baseDecimals`
  - Rename function to query asset info from `supportedAssets` to `getAssetInfo`
  - Change return type of `getAssetInfo` function (previously names `supportedAssets`)
  - Add `adjustmentRate` param to `addAsset` function
  - Add `isPegged` param to `updateRateProvider` function 
  - Add 2 params to `AssetAdded` event: `rateProvider` and `adjustmentRate`
  - Change parameters of `RateProviderUpdated` event to `asset` + `oldRateProvider` + `newRateProvider`
- Move structs and enums from interface files to `Types.sol`

### Added
- `UltraVaultRateProvider` additions:
  - Add functionality to adjust result amount after convertion (per-asset rates)
  - Add `Adjustment` enum that describes adjustment direction
  - Add `adjustment` param to `convertToUnderlying` and `convertFromUnderlying` functions
  - Add `updateAdjustmentRate` function to update asset's adjustment rate
  - Add `getSupportedAssets` function to query the list of all supported assets

### Removed
  - Remove `AssetData` type from `IUltraVaultRateProvider.sol`

### Fixed
