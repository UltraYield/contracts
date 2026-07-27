// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IUltraVaultRateProvider, Adjustment } from "src/interfaces/IUltraVaultRateProvider.sol";

/// @title UltraVaultRateProvider
/// @notice Handles rate calculations between assets for UltraVault
contract UltraVaultRateProvider is Ownable2Step, IUltraVaultRateProvider {
    ///////////////
    // Constants //
    ///////////////

    uint8 internal constant MIN_DECIMALS = 6;
    uint8 internal constant MAX_DECIMALS = 18;
    uint256 internal constant SCALE = 1e18; // 100%
    uint56 internal constant MAX_ADJUSTMENT_RATE = 0.01e18; // 1%

    ///////////
    // Types //
    ///////////

    struct AssetSlot {
        uint8 decimals;
        uint56 adjustmentRate; // 1e16 = 1%
        address rateProvider; // External rate provider if not pegged
        uint32 __padding;
    }

    /////////////
    // Storage //
    /////////////

    /// @inheritdoc IUltraVaultRateProvider
    address public immutable baseAsset;

    /// @inheritdoc IUltraVaultRateProvider
    uint8 public immutable baseDecimals;

    /// @dev Mapping of supported assets to their data
    mapping(address => AssetSlot) internal supportedAssets;

    /// @dev List of supported assets
    address[] internal assetList;

    //////////
    // Init //
    //////////

    constructor(address _owner, address _baseAsset) Ownable(_owner) {
        // Ensure decimals within allowed range
        uint8 decimals = IERC20Metadata(_baseAsset).decimals();
        require(decimals >= MIN_DECIMALS && decimals <= MAX_DECIMALS, InvalidDecimals());

        baseAsset = _baseAsset;
        baseDecimals = decimals;

        // Add the base asset directly; state is empty and it is pegged with no
        // rate provider and no adjustment, so the checks in _addAsset are redundant
        supportedAssets[_baseAsset] = AssetSlot({
            decimals: decimals,
            rateProvider: address(0),
            adjustmentRate: 0,
            __padding: 0
        });
        assetList.push(_baseAsset);

        // Emit event
        emit AssetAdded(_baseAsset, true, address(0), 0);
    }

    /////////////////////////////
    // IUltraVaultRateProvider //
    /////////////////////////////

    /// @inheritdoc IUltraVaultRateProvider
    function getAssetInfo(address asset) public view returns (bool isPegged, uint8 decimals, address rateProvider, uint56 adjustmentRate) {
        AssetSlot memory slot = supportedAssets[asset];
        bool assetIsSupported = slot.decimals > 0;
        isPegged = assetIsSupported && slot.rateProvider == address(0);
        decimals = slot.decimals;
        rateProvider = slot.rateProvider;
        adjustmentRate = slot.adjustmentRate;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function getSupportedAssets() external view returns (address[] memory) {
        return assetList;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function isSupported(address asset) public view returns (bool) {
        return supportedAssets[asset].decimals > 0;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function addAsset(address asset, bool isPegged, address rateProvider, uint56 adjustmentRate) external onlyOwner {
        _addAsset(asset, isPegged, rateProvider, adjustmentRate);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function removeAsset(address asset) external onlyOwner {
        // Checks
        require(asset != baseAsset, CannotUpdateBaseAsset());
        require(isSupported(asset), AssetNotSupported());

        // Update storage
        delete supportedAssets[asset];
        // The asset is guaranteed to be present, so only scan up to the last
        // entry: if it is not found earlier it must be the last one, which the
        // trailing pop removes without a redundant self-assignment
        uint256 lastIndex = assetList.length - 1;
        for (uint256 i = 0; i < lastIndex; i++) {
            if (assetList[i] == asset) {
                assetList[i] = assetList[lastIndex];
                break;
            }
        }
        assetList.pop();

        // Emit event
        emit AssetRemoved(asset);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function updateRateProvider(address asset, bool isPegged, address newRateProvider) external onlyOwner {
        // Checks
        require(asset != baseAsset, CannotUpdateBaseAsset());
        require(isSupported(asset), AssetNotSupported());
        bool rateProviderIsValid = isPegged
            ? newRateProvider == address(0)
            : newRateProvider != address(0);
        require(rateProviderIsValid, InvalidRateProvider());

        // Update storage
        AssetSlot storage slot = supportedAssets[asset];

        // Emit event before mutation, reading the old value directly from storage
        emit RateProviderUpdated(asset, slot.rateProvider, newRateProvider);
        slot.rateProvider = newRateProvider;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function updateAdjustmentRate(address asset, uint56 newAdjustmentRate) external onlyOwner {
        // Checks
        require(asset != baseAsset, CannotUpdateBaseAsset());
        require(isSupported(asset), AssetNotSupported());
        require(newAdjustmentRate <= MAX_ADJUSTMENT_RATE, AdjustmentRateTooHigh());

        // Update storage
        AssetSlot storage slot = supportedAssets[asset];

        // Emit event before mutation, reading the old value directly from storage
        emit AdjustmentRateUpdated(asset, slot.adjustmentRate, newAdjustmentRate);
        slot.adjustmentRate = newAdjustmentRate;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertToUnderlying(address asset, uint256 assets, Adjustment adjustment) external view returns (uint256) {
        (bool isPegged, uint8 decimals, address rateProvider, uint56 adjustmentRate) = getAssetInfo(asset);
        uint256 amount = _convertToUnderlying(asset, assets, isPegged, decimals, rateProvider);
        return _applyAdjustment(amount, adjustmentRate, adjustment);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertFromUnderlying(address asset, uint256 baseAssets, Adjustment adjustment) external view returns (uint256) {
        (bool isPegged, uint8 decimals, address rateProvider, uint56 adjustmentRate) = getAssetInfo(asset);
        uint256 amount = _convertFromUnderlying(asset, baseAssets, isPegged, decimals, rateProvider);
        return _applyAdjustment(amount, adjustmentRate, adjustment);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256) {
        (bool isPegged, uint8 decimals, address rateProvider,) = getAssetInfo(asset);
        return _convertToUnderlying(asset, assets, isPegged, decimals, rateProvider);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256) {
        (bool isPegged, uint8 decimals, address rateProvider,) = getAssetInfo(asset);
        return _convertFromUnderlying(asset, baseAssets, isPegged, decimals, rateProvider);
    }

    //////////////////////
    // Internal Helpers //
    //////////////////////

    function _convertToUnderlying(
        address asset,
        uint256 assets,
        bool isPegged,
        uint8 decimals,
        address rateProvider
    ) internal view returns (uint256) {
        if (isPegged) {
            return _convertDecimals(assets, decimals, baseDecimals);
        } else {
            require(rateProvider != address(0), AssetNotSupported());
            // Call external rate provider
            return IRateProvider(rateProvider).convertToUnderlying(asset, assets);
        }
    }

    function _convertFromUnderlying(
        address asset,
        uint256 baseAssets,
        bool isPegged,
        uint8 decimals,
        address rateProvider
    ) internal view returns (uint256) {
        if (isPegged) {
            return _convertDecimals(baseAssets, baseDecimals, decimals);
        } else {
            require(rateProvider != address(0), AssetNotSupported());
            // Call external rate provider
            return IRateProvider(rateProvider).convertFromUnderlying(asset, baseAssets);
        }
    }

    /// @dev Internal function to add an asset
    function _addAsset(address asset, bool isPegged, address rateProvider, uint56 adjustmentRate) internal {
        // Ensure not supported
        require(!isSupported(asset), AssetAlreadySupported());
        // Ensure pegged value and rate provider are consistent
        bool rateProviderIsValid = isPegged
            ? rateProvider == address(0)
            : rateProvider != address(0);
        require(rateProviderIsValid, InvalidRateProvider());
        // Ensure decimals within allowed range
        uint8 decimals = IERC20Metadata(asset).decimals();
        require(decimals >= MIN_DECIMALS && decimals <= MAX_DECIMALS, InvalidDecimals());
        // Ensure adjustment rate is not too high
        require(adjustmentRate <= MAX_ADJUSTMENT_RATE, AdjustmentRateTooHigh());

        // Update storage
        supportedAssets[asset] = AssetSlot({
            decimals: decimals,
            rateProvider: rateProvider,
            adjustmentRate: adjustmentRate,
            __padding: 0
        });
        assetList.push(asset);

        // Emit event
        emit AssetAdded(asset, isPegged, rateProvider, adjustmentRate);
    }

    function _applyAdjustment(uint256 amount, uint56 adjustmentRate, Adjustment adjustment) internal pure returns (uint256) {
        if (adjustmentRate == 0) {
            return amount;
        }
        // adjustmentRate <= MAX_ADJUSTMENT_RATE < SCALE, so SCALE - adjustmentRate never underflows
        if (adjustment == Adjustment.DOWN) {
            unchecked {
                return Math.mulDiv(amount, SCALE - uint256(adjustmentRate), SCALE, Math.Rounding.Floor);
            }
        }
        if (adjustment == Adjustment.UP) {
            // Inverse of DOWN: ceil(amount * SCALE / (SCALE - adjustmentRate))
            unchecked {
                return Math.mulDiv(amount, SCALE, SCALE - uint256(adjustmentRate), Math.Rounding.Ceil);
            }
        }
        revert UnknownAdjustment();
    }

    /// @dev Helps with decimals accounting
    function _convertDecimals(
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
