// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { PendingRedeem, ClaimableRedeem } from "src/interfaces/Types.sol";

interface IRedeemQueueErrors {
    error InsufficientPendingShares(uint256 available, uint256 requested);
    error InsufficientClaimableShares(uint256 available, uint256 requested);
    error InsufficientClaimableAssets(uint256 available, uint256 requested);
    error TooManyShares(uint256 shares);
    error TooManyAssets(uint256 assets);
}
