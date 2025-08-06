// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVault, Fees } from "../interfaces/IUltraVault.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "./BaseControlledAsyncRedeem.sol";
import { PendingRedeem, ClaimableRedeem } from "src/interfaces/IUltraQueue.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";

/// @dev Initialization parameters for UltraFeeder
struct UltraFeederInitParams {
    // The UltraVault to deposit into
    address mainVault;
    // Owner of the vault
    address owner;
    // Underlying asset address
    address asset;
    // The name of the vault token
    string name;
    // The symbol of the vault token
    string symbol;
}

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraFeeder")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_FEEDER_STORAGE_LOCATION = 0x73fc0f32a78274c31085b0032ea471ff6cedefdd8cffdf1dfa84871cdcb59000;

/// @title UltraFeeder
/// @notice ERC-4626 compliant vault that wraps UltraVault for deposits and handles async redeems
/// @dev This vault only handles deposits into the main UltraVault and manages async redeems
contract UltraFeeder is BaseControlledAsyncRedeem, UUPSUpgradeable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    event Referral(string indexed referralId, address user, uint256 shares);

    error VaultPaused();
    error InvalidMainVault();
    error NoPendingRedeem();
    error NoClaimableAssets();
    error InvalidRedeemRequest();
    error AssetMismatch();
    error ShareNumberMismatch();

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraFeeder
    struct UltraFeederStorage {
        IUltraVault mainVault;
    }

    function _getUltraFeederStorage() private pure returns (UltraFeederStorage storage $) {
        assembly {
            $.slot := ULTRA_FEEDER_STORAGE_LOCATION
        }
    }

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize UltraFeeder vault
    /// @param params Initialization parameters struct
    function initialize(
        UltraFeederInitParams memory params
    ) external initializer {
        // Validate main vault and base asset
        require(params.mainVault != address(0), InvalidMainVault());
        IUltraVault mainVault_ = IUltraVault(params.mainVault);
        require(mainVault_.asset() == params.asset, AssetMismatch());

        // Store main vault
        _getUltraFeederStorage().mainVault = mainVault_;
        
        // Init BaseControlledAsyncRedeem
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: address(mainVault_.rateProvider())
        }));

        // Pause vault in order to be manually checked by the operator
        _pause();
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the main vault address
    function mainVault() public view returns (IUltraVault) {
        return _getUltraFeederStorage().mainVault;
    }

    /// @notice Returns the total assets in the vault
    /// @return The total assets in the vault
    function totalAssets() public view override returns (uint256) {
        return IPriceSource(mainVault().oracle()).getQuote(
            totalSupply(),
            address(mainVault()),
            address(asset())
        );
    }

    ///////////////////////////////
    // BaseControlledAsyncRedeem //
    ///////////////////////////////

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address _asset, uint256 _assets, uint256 _shares) internal override {
        // Approve main vault to spend assets
        SafeERC20.safeIncreaseAllowance(IERC20(_asset), address(mainVault()), _assets);

        uint256 mainShares = mainVault().depositAsset(_asset, _assets, address(this));
        require(mainShares == _shares, ShareNumberMismatch());
    }

    /// @dev Hook for inheriting contracts after request redeem
    function beforeRequestRedeem(
        address _asset,
        uint256 _shares,
        address, // controller
        address  // owner
    ) internal override {
        // Approve main vault to spend it's shares
        IUltraVault _mainVault = mainVault();
        SafeERC20.safeIncreaseAllowance(IERC20(address(_mainVault)), address(_mainVault), _shares);

        // Request redeem from main vault
        _mainVault.requestRedeemOfAsset(_asset, _shares, address(this), address(this));
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address _asset, uint256 _assets, uint256 _shares) internal override {
        IUltraVault mainVault_ = mainVault();
        // Fulfill redeem in main vault. Returns asset units
        mainVault_.fulfillRedeemOfAsset(_asset, _shares, address(this));
        uint256 mainAssetsClaimed = mainVault_.redeemAsset(_asset, _shares, address(this), address(this));

        // Calculate the expected assets after withdrawal fees from the underlying vault
        Fees memory fees = mainVault_.fees();
        uint256 withdrawalFee = _assets * fees.withdrawalFee / 1e18;
        uint256 expectedAssetsAfterFees = _assets - withdrawalFee;
        require(mainAssetsClaimed == expectedAssetsAfterFees, AssetMismatch());
    }

    /// @dev Hook for inheriting contracts after fulfill redeem
    /// @dev Correct claimable redeem amounts to account for underlying vault fees
    function afterFulfillRedeem(
        address _asset,
        uint256 _assets,
        uint256, // shares
        address _controller
    ) internal override {
        // The base implementation has already updated claimableRedeem.assets += assets
        // We need to correct it to use the actual assets received after fees
        Fees memory fees = mainVault().fees();
        uint256 withdrawalFee = _assets * fees.withdrawalFee / 1e18;
        
        // Correct the claimable redeem amounts to use the actual assets received
        ClaimableRedeem memory claimableRedeem = _getClaimableRedeem(_controller, _asset);
        claimableRedeem.assets -= withdrawalFee;
        _setClaimableRedeem(_controller, _asset, claimableRedeem);
    }


    /// @dev In async vaults it's a privileged function
    function _fulfillRedeemOfAsset(
        address _asset,
        uint256 _assets,
        uint256 _shares,
        address _controller
    ) internal override onlyRoleOrOwner(OPERATOR_ROLE) returns (uint256) {
        return super._fulfillRedeemOfAsset(_asset, _assets, _shares, _controller);
    }

    /// @notice Cancel redeem request for controller and propagate to underlying vault
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @param _receiver Share recipient
    /// @dev Transfers pending shares back to receiver and cancels underlying vault request
    function _cancelRedeemRequestOfAsset(
        address _asset,
        address _controller,
        address _receiver
    ) internal override {
        // First cancel the request in the underlying vault
        // This ensures that the underlying vault's pending redeem is also cleared
        mainVault().cancelRedeemRequestOfAsset(_asset, address(this), address(this));
        
        // Then call the internal implementation to handle the feeder's cancellation
        super._cancelRedeemRequestOfAsset(_asset, _controller, _receiver);
    }

    ////////////////////////
    // ERC-4626 Overrides //
    ////////////////////////

    /// @notice Returns the amount of shares that would be minted for a given amount of assets
    /// @param assets The amount of assets to convert
    /// @return The amount of shares that would be minted
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return mainVault().previewDeposit(assets);
    }

    /// @notice Returns the amount of assets required for a given amount of shares
    /// @param shares The amount of shares to convert
    /// @return The amount of assets required
    function previewMint(uint256 shares) public view override returns (uint256) {
        return mainVault().previewMint(shares);
    }

    /// @notice Returns the maximum amount of assets that can be deposited
    /// @return The maximum amount of assets that can be deposited
    function maxDeposit(address) public view override returns (uint256) {
        return mainVault().maxDeposit(address(this));
    }

    /// @notice Returns the maximum amount of shares that can be minted
    /// @return The maximum amount of shares that can be minted
    function maxMint(address) public view override returns (uint256) {
        return mainVault().maxMint(address(this));
    }

    /////////////////////
    // Referrals Logic //
    /////////////////////

    /// @notice Helper to deposit assets for msg.sender upon referral
    /// @param _assets Amount to deposit
    /// @param _referralId id of referral
    /// @return shares Amount of shares received
    function deposit(
        uint256 _assets,
        string calldata _referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset(), _assets, msg.sender, _referralId);
    }

    /// @notice Helper to deposit assets for msg.sender upon referral specifying receiver
    /// @param _assets Amount to deposit
    /// @param _receiver receiver of deposit
    /// @param _referralId id of referral
    /// @return shares Amount of shares received
    function deposit(
        uint256 _assets,
        address _receiver,
        string calldata _referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset(), _assets, _receiver, _referralId);
    }

    /// @notice Helper to deposit particular asset for msg.sender upon referral
    /// @param _asset Asset to deposit
    /// @param _assets Amount to deposit
    /// @param _receiver receiver of deposit
    /// @param _referralId id of referral
    /// @return shares Amount of shares received
    function depositAsset(
        address _asset,
        uint256 _assets,
        address _receiver,
        string calldata _referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(_asset, _assets, _receiver, _referralId);
    }

    /// @notice Internal helper to deposit assets for msg.sender upon referral
    /// @param _asset Asset to deposit
    /// @param _assets Amount to deposit
    /// @param _receiver receiver of deposit
    /// @param _referralId id of referral
    /// @return shares Amount of shares received
    function _depositAssetWithReferral(
        address _asset,
        uint256 _assets,
        address _receiver,
        string calldata _referralId
    ) internal returns (uint256 shares) {
        shares = _depositAsset(_asset, _assets, _receiver);
        emit Referral(_referralId, msg.sender, shares);
        return shares;
    }

    //////////////////////
    // UUPS Upgradeable //
    //////////////////////

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
