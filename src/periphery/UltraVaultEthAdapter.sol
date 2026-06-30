// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVault } from "src/interfaces/IUltraVault.sol";
import { IUltraVaultEthAdapter } from "src/interfaces/IUltraVaultEthAdapter.sol";
import { IWETH9 } from "src/interfaces/IWETH9.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title UltraVaultEthAdapter
/// @notice Upgradeable adapter contract for depositing native ETH into UltraVault
/// @dev Wraps ETH to WETH and deposits into the vault, forwarding shares to depositor
contract UltraVaultEthAdapter is
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IUltraVaultEthAdapter
{
    /////////////
    // Storage //
    /////////////

    /// @notice The UltraVault instance to deposit into
    IUltraVault public immutable vault;

    /// @notice The WETH token address
    IWETH9 public immutable weth;

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize the adapter with vault and WETH addresses
    /// @param _vault Address of the UltraVault contract
    /// @param _weth Address of the WETH token
    constructor(address _vault, address _weth) {
        require(_vault != address(0), ZeroAddress());
        require(_weth != address(0), ZeroAddress());
        
        vault = IUltraVault(_vault);
        weth = IWETH9(_weth);
        require(_weth == address(vault.asset()), AssetMismatch());
        
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        // Approve vault to spend unlimited WETH from this adapter
        weth.approve(address(vault), type(uint256).max);
    }

    /////////////
    // Deposit //
    /////////////

    /// @notice Preview how many shares would be received for a given ETH amount
    /// @param amount Amount of ETH to preview
    /// @return shares Expected shares to be received
    function previewDepositEth(uint256 amount) external view returns (uint256 shares) {
        return vault.previewDepositForAsset(address(weth), amount);
    }

    /// @notice Allows contract to receive ETH only from WETH contract
    /// @dev Prevents accidental ETH sends
    receive() external payable {
        require(msg.sender == address(weth), InvalidDeposit());
    }

    /// @notice Deposit native ETH and receive vault shares to msg.sender
    /// @return shares Amount of shares minted
    function depositEth() external payable returns (uint256 shares) {
        return depositEth(msg.sender);
    }

    /// @notice Deposit native ETH and receive vault shares
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function depositEth(address receiver) public payable whenNotPaused returns (uint256 shares) {
        require(msg.value > 0, ZeroEthValue());
        
        // Wrap ETH to WETH and deposit WETH into vault
        weth.deposit{value: msg.value}();
        shares = vault.depositAsset(address(weth), msg.value, receiver);
        
        emit EthDeposit(msg.sender, receiver, msg.value, shares);
    }

    /// @notice Deposit native ETH with referral tracking to msg.sender
    /// @param referralId Referral identifier
    /// @return shares Amount of shares minted
    function depositEthWithReferral(
        string calldata referralId
    ) external payable returns (uint256 shares) {
        return depositEthWithReferral(msg.sender, referralId);
    }

    /// @notice Deposit native ETH with referral tracking
    /// @param receiver Address to receive the shares
    /// @param referralId Referral identifier
    /// @return shares Amount of shares minted
    function depositEthWithReferral(
        address receiver,
        string calldata referralId
    ) public payable returns (uint256 shares) {
        shares = depositEth(receiver);
        emit Referral(referralId, msg.sender, shares);
    }

    ////////////
    // Redeem //
    ////////////

    /// @notice Redeem shares for native ETH from fulfilled requests (msg.sender as receiver and controller)
    /// @param shares Amount of shares to redeem
    /// @return ethAmount Amount of ETH received
    function redeemEth(uint256 shares) external returns (uint256 ethAmount) {
        return redeemEth(shares, msg.sender);
    }

    /// @notice Redeem shares for native ETH from fulfilled requests
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the ETH
    /// @return ethAmount Amount of ETH received
    /// @dev Works with fulfilled redemption requests, unwraps WETH to ETH
    function redeemEth(
        uint256 shares,
        address receiver
    ) public whenNotPaused returns (uint256 ethAmount) {
        // Redeem WETH from vault to this adapter
        address controller = msg.sender;
        ethAmount = vault.redeemAsset(address(weth), shares, address(this), controller);
        
        // Unwrap WETH to ETH
        weth.withdraw(ethAmount);
        // Send ETH to receiver
        (bool success, ) = receiver.call{value: ethAmount}("");
        require(success, EthTransferFailed());
        
        emit EthWithdraw(msg.sender, receiver, controller, ethAmount, shares);
    }

    //////////////
    // Pausable //
    //////////////

    /// @notice Pause adapter operations
    /// @dev Only owner can pause
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause adapter operations
    /// @dev Only owner can unpause
    function unpause() external onlyOwner {
        _unpause();
    }

    /////////////////////
    // UUPSUpgradeable //
    /////////////////////

    /// @dev Internal function to authorize upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
