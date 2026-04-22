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

interface IRedeemAccounting {
    /// @notice Assumes control of shares from sender into the Vault and submits a Request for asynchronous redeem of asset.
    /// @param asset the asset to redeem in
    /// @param shares the amount of shares to be redeemed to transfer from owner
    /// @param controller the controller of the request who will be able to operate the request
    /// @param owner the source of the shares to be redeemed
    /// @dev most implementations will require pre-approval of the Vault with the Vault's share token.
    /// @return requestId The request ID
    function requestRedeem(address asset, uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Get controller's pending redeem for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return pendingRedeem Pending redeem details
    function getPendingRedeem(address _asset, address _controller) external view returns (PendingRedeem memory);

    /// @notice Get controller's claimable redeem for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return claimableRedeem Claimable redeem details
    function getClaimableRedeem(address _asset, address _controller) external view returns (ClaimableRedeem memory);

    /// @notice Get controller's pending shares for the base asset
    /// @param _controller Controller address
    /// @return pendingShares Amount of pending shares
    function pendingRedeemRequest(uint256 requestId, address _controller) external view returns (uint256);

    /// @notice Get controller's claimable shares for the base asset
    /// @param _controller Controller address
    /// @return claimableShares Amount of claimable shares
    function claimableRedeemRequest(uint256 requestId, address _controller) external view returns (uint256);
}
