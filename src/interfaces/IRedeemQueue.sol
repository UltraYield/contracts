
struct PendingRedeem {
    uint256 shares;
    uint256 requestTime;
}

struct ClaimableRedeem {
    uint256 assets;
    uint256 shares;
}

interface IRedeemQueueErrors {
    error InsufficientPendingShares(uint256 available, uint256 requested);
    error InsufficientClaimableShares(uint256 available, uint256 requested);
    error InsufficientClaimableAssets(uint256 available, uint256 requested);
    error TooManyShares(uint256 shares);
    error TooManyAssets(uint256 assets);
}
