// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

struct PendingRedeem {
    uint256 shares;
    uint256 requestTime;
}

struct ClaimableRedeem {
    uint256 assets;
    uint256 shares;
}

interface IUltraQueue {
    function getPendingRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (PendingRedeem memory);

    function getClaimableRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (ClaimableRedeem memory);

    function setPendingRedeem(
        address user, 
        address vault, 
        address token,
        PendingRedeem memory pendingRedeem
    ) external;

    function setClaimableRedeem(
        address user, 
        address vault, 
        address token,
        ClaimableRedeem memory claimableRedeem
    ) external;
}
