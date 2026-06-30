// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IUltraVault } from "./IUltraVault.sol";
import { IWETH9 } from "./IWETH9.sol";

/// @title IUltraVaultEthAdapter
/// @notice Interface for the UltraVaultEthAdapter contract
interface IUltraVaultEthAdapter {
    ////////////
    // Errors //
    ////////////

    error ZeroEthValue();
    error ZeroAddress();
    error AssetMismatch();
    error InvalidDeposit();
    error EthTransferFailed();

    ////////////
    // Events //
    ////////////

    event EthDeposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event EthWithdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Referral(string indexed referralId, address indexed user, uint256 shares);

    ////////////////
    // Immutables //
    ////////////////

    /// @notice The UltraVault instance to deposit into
    function vault() external view returns (IUltraVault);

    /// @notice The WETH token address
    function weth() external view returns (IWETH9);

    /////////////
    // Deposit //
    /////////////

    /// @notice Preview how many shares would be received for a given ETH amount
    /// @param amount Amount of ETH to preview
    /// @return shares Expected shares to be received
    function previewDepositEth(uint256 amount) external view returns (uint256 shares);

    /// @notice Deposit native ETH and receive vault shares to msg.sender
    /// @return shares Amount of shares minted
    function depositEth() external payable returns (uint256 shares);

    /// @notice Deposit native ETH and receive vault shares
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function depositEth(address receiver) external payable returns (uint256 shares);

    /// @notice Deposit native ETH with referral tracking to msg.sender
    /// @param referralId Referral identifier
    /// @return shares Amount of shares minted
    function depositEthWithReferral(string calldata referralId) external payable returns (uint256 shares);

    /// @notice Deposit native ETH with referral tracking
    /// @param receiver Address to receive the shares
    /// @param referralId Referral identifier
    /// @return shares Amount of shares minted
    function depositEthWithReferral(
        address receiver,
        string calldata referralId
    ) external payable returns (uint256 shares);

    ////////////
    // Redeem //
    ////////////

    /// @notice Redeem shares for native ETH from fulfilled requests (msg.sender as receiver and controller)
    /// @param shares Amount of shares to redeem
    /// @return ethAmount Amount of ETH received
    function redeemEth(uint256 shares) external returns (uint256 ethAmount);

    /// @notice Redeem shares for native ETH from fulfilled requests
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the ETH
    /// @return ethAmount Amount of ETH received
    function redeemEth(
        uint256 shares,
        address receiver
    ) external returns (uint256 ethAmount);

    //////////////
    // Pausable //
    //////////////

    /// @notice Pause adapter operations
    function pause() external;

    /// @notice Unpause adapter operations
    function unpause() external;
}
