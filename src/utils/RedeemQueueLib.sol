// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { PendingRedeem, ClaimableRedeem } from "src/interfaces/Types.sol";
import { IRedeemQueueErrors } from "src/interfaces/IRedeemAccounting.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { REDEEM_QUEUE_STORAGE_LOCATION } from "src/vaults/accounting/RedeemQueue.sol";

/// @title RedeemQueueLib
/// @notice External library for redeem queue state management
/// @dev Uses same ERC-7201 storage slot as RedeemQueue for storage compatibility
/// @dev Public functions are deployed separately and called via DELEGATECALL
library RedeemQueueLib {
    using FixedPointMathLib for uint256;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant UINT128_MAX = type(uint128).max;

    /////////////
    // Storage //
    /////////////

    /// @dev Represents a single storage slot for a pending redeem
    struct PendingRedeemSlot {
        uint128 shares;
        uint128 requestTime;
    }

    /// @dev Represents a single storage slot for a claimable redeem
    struct ClaimableRedeemSlot {
        uint128 assets;
        uint128 shares;
    }

    /// @custom:storage-location erc7201:ultrayield.storage.RedeemQueue
    struct Storage {
        mapping(address => mapping(address => PendingRedeemSlot)) pendingRedeems;
        mapping(address => mapping(address => ClaimableRedeemSlot)) claimableRedeems;
        mapping(address => mapping(address => bool)) autoClaim;
    }

    function _getStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := REDEEM_QUEUE_STORAGE_LOCATION
        }
    }

    //////////////
    // Read Fns //
    //////////////

    function getPendingRedeem(
        address user,
        address token
    ) external view returns (PendingRedeem memory) {
        PendingRedeemSlot storage redeem = _getStorage().pendingRedeems[user][token];
        return PendingRedeem({
            shares: redeem.shares,
            requestTime: redeem.requestTime
        });
    }

    function getClaimableRedeem(
        address user,
        address token
    ) external view returns (ClaimableRedeem memory) {
        ClaimableRedeemSlot storage redeem = _getStorage().claimableRedeems[user][token];
        return ClaimableRedeem({
            shares: redeem.shares,
            assets: redeem.assets
        });
    }

    function getAutoClaim(
        address user,
        address token
    ) external view returns (bool) {
        return _getStorage().autoClaim[user][token];
    }

    //////////////////
    // Calculations //
    //////////////////

    /// @dev Shares are rounded UP for partial claims, so a partial `withdraw` always burns at least
    ///      one whole share. Requesting the full claimable assets hits the exact-match short-circuit
    ///      and returns the full claimable shares exactly. See `_withdrawAsset`.
    function calculateClaimableSharesForAssets(
        address user,
        address token,
        uint256 assets
    ) external view returns (uint256 shares) {
        ClaimableRedeemSlot storage redeem = _getStorage().claimableRedeems[user][token];
        if (assets == redeem.assets) {
            return redeem.shares;
        } else {
            require(assets < redeem.assets, IRedeemQueueErrors.InsufficientClaimableAssets(redeem.assets, assets));
            return assets.mulDivUp(redeem.shares, redeem.assets);
        }
    }

    /// @dev Assets are rounded DOWN for partial claims and the shares-denominated path never retains a
    ///      remainder. Requesting the full claimable shares hits the exact-match short-circuit and
    ///      returns the full claimable assets exactly.
    function calculateClaimableAssetsForShares(
        address user,
        address token,
        uint256 shares
    ) external view returns (uint256 assets) {
        ClaimableRedeemSlot storage redeem = _getStorage().claimableRedeems[user][token];
        if (shares == redeem.shares) {
            return redeem.assets;
        } else {
            require(shares < redeem.shares, IRedeemQueueErrors.InsufficientClaimableShares(redeem.shares, shares));
            return shares.mulDivDown(redeem.assets, redeem.shares);
        }
    }

    ///////////////////////////
    // Update Pending Redeem //
    ///////////////////////////

    function increasePendingRedeem(
        address user,
        address token,
        uint256 amount,
        bool autoClaim
    ) external {
        Storage storage $ = _getStorage();
        PendingRedeemSlot storage pending = $.pendingRedeems[user][token];
        uint256 newShares = uint256(pending.shares) + amount;
        require(newShares <= UINT128_MAX, IRedeemQueueErrors.TooManyShares(newShares));
        pending.shares = uint128(newShares);
        pending.requestTime = uint128(block.timestamp);
        // Last-writer-wins: every request overwrites the per-(user, token) flag
        $.autoClaim[user][token] = autoClaim;
    }

    function consumePendingRedeem(
        address user,
        address token,
        uint256 amount
    ) external {
        Storage storage $ = _getStorage();
        PendingRedeemSlot storage pending = $.pendingRedeems[user][token];
        require(amount <= pending.shares, IRedeemQueueErrors.InsufficientPendingShares(pending.shares, amount));
        // Safe: the require above guarantees amount <= pending.shares
        unchecked {
            pending.shares -= uint128(amount);
        }
        if (pending.shares == 0) {
            pending.requestTime = 0;
            // Clears the flag so future redeem requests start from a clean state
            delete $.autoClaim[user][token];
        }
    }

    /////////////////////////////
    // Update Claimable Redeem //
    /////////////////////////////

    function increaseClaimableRedeem(
        address user,
        address token,
        uint256 assets,
        uint256 shares
    ) external {
        ClaimableRedeemSlot storage redeem = _getStorage().claimableRedeems[user][token];
        uint256 newAssets = uint256(redeem.assets) + assets;
        uint256 newShares = uint256(redeem.shares) + shares;
        require(newAssets <= UINT128_MAX, IRedeemQueueErrors.TooManyAssets(newAssets));
        require(newShares <= UINT128_MAX, IRedeemQueueErrors.TooManyShares(newShares));
        redeem.assets = uint128(newAssets);
        redeem.shares = uint128(newShares);
    }

    function consumeClaimableRedeem(
        address user,
        address token,
        uint256 assets,
        uint256 shares
    ) external {
        ClaimableRedeemSlot storage redeem = _getStorage().claimableRedeems[user][token];
        require(assets <= redeem.assets, IRedeemQueueErrors.InsufficientClaimableAssets(redeem.assets, assets));
        require(shares <= redeem.shares, IRedeemQueueErrors.InsufficientClaimableShares(redeem.shares, shares));
        // Safe: the requires above guarantee assets <= redeem.assets and shares <= redeem.shares
        uint128 remainingAssets;
        uint128 remainingShares;
        unchecked {
            remainingAssets = redeem.assets - uint128(assets);
            remainingShares = redeem.shares - uint128(shares);
        }
        // Defense-in-depth: never leave a one-sided remainder. If either dimension is fully
        // consumed, clear both so a slot can neither strand value nor advertise an
        // unclaimable balance via maxWithdraw/maxRedeem.
        if (remainingAssets == 0 || remainingShares == 0) {
            remainingAssets = 0;
            remainingShares = 0;
        }
        redeem.assets = remainingAssets;
        redeem.shares = remainingShares;
    }
}
