// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVault } from "src/interfaces/IUltraVault.sol";
import { IUltraFrontendHelper } from "src/interfaces/IUltraFrontendHelper.sol";
import { IUltraVaultRateProvider, Adjustment } from "src/interfaces/IUltraVaultRateProvider.sol";
import { PendingRedeem } from "src/interfaces/Types.sol";

contract UltraFrontendHelper is IUltraFrontendHelper {
    /////////////
    // Storage //
    /////////////

    IUltraVault internal immutable vault;

    //////////
    // Init //
    //////////

    constructor(address _vault) {
        require(_vault != address(0), "ZERO_ADDRESS");
        vault = IUltraVault(_vault);
        require(vault.fundsHolder() != address(0), "INVALID_VAULT");
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @inheritdoc IUltraFrontendHelper
    function getVault() external view returns (address) {
        return address(vault);
    }

    /// @inheritdoc IUltraFrontendHelper
    function getVaultState() external view returns (VaultState memory) {
        uint8 decimals = vault.decimals();
        return VaultState({
            totalAssets: vault.totalAssets(),
            totalShares: vault.totalSupply(),
            sharePrice: vault.convertToAssets(10 ** decimals)
        });
    }

    /// @inheritdoc IUltraFrontendHelper
    function previewDeposit(address asset, uint256 amount) external view returns (uint256) {
        uint256 baseAssets = vault.convertToUnderlying(asset, amount, Adjustment.DOWN);
        uint256 shares = vault.convertToShares(baseAssets);
        return shares;
    }

    /// @inheritdoc IUltraFrontendHelper
    function previewRedeem(address asset, uint256 shares) external view returns (uint256) {
        uint256 baseAssets = vault.convertToAssets(shares);
        uint256 assets = vault.convertFromUnderlying(asset, baseAssets, Adjustment.DOWN);
        uint256 withdrawalFee = vault.calculateWithdrawalFee(assets);
        // withdrawalFee is capped at MAX_WITHDRAWAL_FEE (< 100%) in the vault, so it can never exceed assets
        unchecked {
            return assets - withdrawalFee;
        }
    }

    /// @inheritdoc IUltraFrontendHelper
    function collectPendingRedeems(address[] calldata assets, address[] calldata users) external view returns (Redeem[] memory redeems) {
        // 1. Validate assets
        IUltraVaultRateProvider rateProvider = vault.rateProvider();
        for (uint256 i = 0; i < assets.length; i++) {
            require(rateProvider.isSupported(assets[i]), "UNSUPPORTED_ASSET");
        }
        // 2. Allocate the maximum possible size and populate in a single pass
        redeems = new Redeem[](users.length * assets.length);
        uint256 totalRedeems = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            for (uint256 j = 0; j < assets.length; j++) {
                address asset = assets[j];
                PendingRedeem memory redeem = vault.getPendingRedeem(asset, user);
                if (redeem.shares > 0) {
                    redeems[totalRedeems] = Redeem({
                        user: user,
                        asset: asset,
                        shares: redeem.shares,
                        requestTime: redeem.requestTime
                    });
                    totalRedeems++;
                }
            }
        }
        // 3. Shrink the array to the actual number of redeems
        assembly {
            mstore(redeems, totalRedeems)
        }
        return redeems;
    }
}
