// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseERC7540 } from "src/vaults/BaseERC7540.sol";
import { IERC7540Redeem } from "ERC-7540/interfaces/IERC7540.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PendingRedeem, ClaimableRedeem } from "src/interfaces/IUltraQueue.sol";
import { IUltraVaultRateProvider } from "src/interfaces/IUltraVaultRateProvider.sol";
import { AddressUpdateProposal } from "src/utils/AddressUpdates.sol";
import { UltraQueue } from "src/vaults/accounting/UltraQueue.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.BaseControlledAsyncRedeem")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant BASE_ASYNC_REDEEM_STORAGE_LOCATION = 0xaf7389673351d5ab654ae6fb9b324c897ebef437a969ec1524dcc6c7b5ca5400;

/// @dev Initialization parameters for BaseControlledAsyncRedeem
struct BaseControlledAsyncRedeemInitParams {
    // Owner of the vault
    address owner;
    // Underlying asset address
    address asset;
    // Vault name
    string name;
    // Vault symbol
    string symbol;
    // Oracle for assets exchange rate
    address rateProvider;
}

/// @title BaseControlledAsyncRedeem
/// @notice Base contract for controlled async redeem flows
/// @dev Based on ERC-7540 Reference Implementation
abstract contract BaseControlledAsyncRedeem is BaseERC7540, UltraQueue, IERC7540Redeem {
    using FixedPointMathLib for uint256;

    ////////////
    // Events //
    ////////////

    event RateProviderProposed(address indexed proposedProvider);
    event RateProviderUpdated(address indexed oldProvider, address indexed newProvider);
    event RedeemRequestFulfilled(
        address indexed controller,
        address indexed fulfiller,
        uint256 shares,
        uint256 assets
    );
    event RedeemRequested(
        address indexed controller,
        address indexed owner,
        uint256 requestId,
        address sender,
        uint256 shares
    );
    event RedeemRequestCanceled(
        address indexed controller,
        address indexed receiver,
        uint256 shares
    );

    ////////////
    // Errors //
    ////////////

    error CanNotPreviewWithdrawInAsyncVault();
    error CanNotPreviewRedeemInAsyncVault();
    error NotEnoughPendingShares();
    error EmptyDeposit();
    error NothingToMint();
    error InvalidRedeemCall();
    error NothingToRedeem();
    error NothingToWithdraw();
    error InsufficientBalance();
    error AssetNotSupported();
    error MissingRateProvider();
    error NoRateProviderProposed();
    error CanNotAcceptRateProviderYet();
    error RateProviderUpdateExpired();

    ///////////////
    // Constants //
    ///////////////

    uint256 public constant ADDRESS_UPDATE_TIMELOCK = 3 days;
    uint256 public constant MAX_ADDRESS_UPDATE_WAIT = 7 days;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.BaseControlledAsyncRedeem
    struct BaseAsyncRedeemStorage {
        IUltraVaultRateProvider rateProvider;
        AddressUpdateProposal proposedRateProvider;
    }

    function _getBaseAsyncRedeemStorage() private pure returns (BaseAsyncRedeemStorage storage $) {
        assembly {
            $.slot := BASE_ASYNC_REDEEM_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    /// @notice Initialize vault with basic parameters
    /// @param params Struct wrapping initialization parameters
    function initialize(
        BaseControlledAsyncRedeemInitParams memory params
    ) public virtual onlyInitializing {
        super.initialize(params.owner, params.asset, params.name, params.symbol);
        _getBaseAsyncRedeemStorage().rateProvider = IUltraVaultRateProvider(params.rateProvider);
    }

    /////////////////
    // Public view //
    /////////////////

    function rateProvider() public view returns (IUltraVaultRateProvider) {
        return _getBaseAsyncRedeemStorage().rateProvider;
    }

    function proposedRateProvider() public view returns (AddressUpdateProposal memory) {
        return _getBaseAsyncRedeemStorage().proposedRateProvider;
    }

    //////////////////////
    // Asset Conversion //
    //////////////////////

    function convertToUnderlying(
        address _asset,
        uint256 _assets
    ) public view virtual returns (uint256 baseAssets) {
        // If asset is the same as base asset, no conversion needed
        if (_asset == this.asset()) {
            return _assets;
        }
        // Call reverts if asset not supported
        return rateProvider().convertToUnderlying(_asset, _assets);
    }

    function convertFromUnderlying(
        address _asset,
        uint256 _baseAssets
    ) public view virtual returns (uint256 assets) {
        // If asset is the same as base asset, no conversion needed
        if (_asset == this.asset()) {
            return _baseAssets;
        }
        // Call reverts if asset not supported
        return rateProvider().convertFromUnderlying(_asset, _baseAssets);
    }

    ////////////////////
    // Deposit & Mint //
    ////////////////////

    /// @notice Deposit exact number of assets in base asset and mint shares to receiver
    /// @param _assets Amount of assets to deposit
    /// @param _receiver Share receiver
    /// @return shares Amount of shares received
    /// @dev Reverts if paused
    function deposit(
        uint256 _assets,
        address _receiver
    ) public override returns (uint256 shares) {
        return _depositAsset(asset(), _assets, _receiver);
    }

    /// @notice Deposit exact number of assets in specific asset and mint shares to receiver
    /// @param _asset Asset to deposit in
    /// @param _assets Amount of assets to deposit
    /// @param _receiver Share receiver
    /// @return shares Amount of shares received
    /// @dev Reverts if paused
    function depositAsset(
        address _asset,
        uint256 _assets,
        address _receiver
    ) public returns (uint256 shares) {
        return _depositAsset(_asset, _assets, _receiver);
    }

    /// @dev Internal function for depositing exact number of `assets` in `asset` and minting shares to `receiver`
    /// @dev Reverts if paused
    /// @dev `receiver` is validated to be non-zero within ERC20Upgradeable
    function _depositAsset(
        address _asset,
        uint256 _assets,
        address _receiver
    ) internal whenNotPaused returns (uint256 shares) {
        shares = previewDepositForAsset(_asset, _assets);
        _performDeposit(_asset, _assets, shares, _receiver);
    }

    /// @notice Mint exact number of shares to receiver and deposit in base asset
    /// @param _shares Amount of shares to mint
    /// @param _receiver Share receiver
    /// @return assets Amount of assets required
    /// @dev Reverts if paused
    function mint(
        uint256 _shares,
        address _receiver
    ) public override returns (uint256 assets) {
        return _mintWithAsset(asset(), _shares, _receiver);
    }

    /// @notice Mint exact number of shares to receiver and deposit in specific asset
    /// @param _asset Asset to deposit in
    /// @param _shares Amount of shares to mint
    /// @param _receiver Share receiver
    /// @return assets Amount of assets required
    /// @dev Reverts if paused
    function mintWithAsset(
        address _asset,
        uint256 _shares,
        address _receiver
    ) public returns (uint256 assets) {
        return _mintWithAsset(_asset, _shares, _receiver);
    }

    /// @dev Internal function for minting exactly `shares` to `receiver` and depositing in `asset`
    /// @dev Reverts if paused
    /// @dev `receiver` is validated to be non-zero within ERC20Upgradeable
    function _mintWithAsset(
        address _asset,
        uint256 _shares,
        address _receiver
    ) internal whenNotPaused returns (uint256 assets) {
        assets = previewMintForAsset(_asset, _shares);
        _performDeposit(_asset, assets, _shares, _receiver);
    }

    function _performDeposit(
        address _asset,
        uint256 _assets,
        uint256 _shares,
        address _receiver
    ) internal {
        // Checks
        require(_assets != 0, EmptyDeposit());
        require(_shares != 0, NothingToMint());

        // Pre-deposit hook - use the actual asset amount being transferred
        beforeDeposit(_asset, _assets, _shares);

        // Need to transfer before minting or ERC777s could reenter
        SafeERC20.safeTransferFrom(
            IERC20(_asset),
            msg.sender,
            address(this),
            _assets
        );

        // Mint shares to receiver
        _mint(_receiver, _shares);

        // Emit event
        emit Deposit(msg.sender, _receiver, _assets, _shares);

        // After-deposit hook - use the actual asset amount that was transferred
        afterDeposit(_asset, _assets, _shares);
    }

    ///////////////////////
    // Withdraw & Redeem //
    ///////////////////////

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param _assets Amount to withdraw
    /// @param _receiver Asset recipient
    /// @param _controller Controller address
    /// @return shares Amount of shares burned
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable assets
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _controller
    ) public override returns (uint256 shares) {
        return _withdrawAsset(asset(), _assets, _receiver, _controller);
    }

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param _asset Asset
    /// @param _assets Amount to withdraw
    /// @param _receiver Asset recipient
    /// @param _controller Controller address
    /// @return shares Amount of shares burned
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable assets
    function withdrawAsset(
        address _asset,
        uint256 _assets,
        address _receiver,
        address _controller
    ) public returns (uint256 shares) {
        return _withdrawAsset(_asset, _assets, _receiver, _controller);
    }

    function _withdrawAsset(
        address _asset,
        uint256 _assets,
        address _receiver,
        address _controller
    ) internal whenNotPaused checkAccess(_controller) returns (uint256 shares) {
        require(_assets != 0, NothingToWithdraw());

        // Validate that requested assets don't exceed claimable assets
        ClaimableRedeem memory claimableRedeem = _getClaimableRedeem(_controller, _asset);
        require(_assets <= claimableRedeem.assets, InsufficientBalance());
        
        // Calculate shares to burn based on the claimable redeem ratio
        shares = _assets == claimableRedeem.assets 
            ? claimableRedeem.shares 
            : _assets.mulDivUp(claimableRedeem.shares, claimableRedeem.assets);
        require(shares != 0, NothingToRedeem());

        // Execute withdraw
        _performWithdraw(_asset, _assets, shares, _receiver, _controller);
    }

    /// @notice Redeem shares from fulfilled requests
    /// @param _shares Amount to redeem
    /// @param _receiver Asset recipient
    /// @param _controller Controller address
    /// @return assets Amount of assets received
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable shares
    function redeem(
        uint256 _shares,
        address _receiver,
        address _controller
    ) public override returns (uint256 assets) {
        return _redeemAsset(asset(), _shares, _receiver, _controller);
    }

    /// @notice Redeem shares from fulfilled requests
    /// @param _asset Asset
    /// @param _shares Amount to redeem
    /// @param _receiver Asset recipient
    /// @param _controller Controller address
    /// @return assets Amount of assets received
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable shares
    function redeemAsset(
        address _asset,
        uint256 _shares,
        address _receiver,
        address _controller
    ) public returns (uint256 assets) {
        // Shares are already in vault share units, no conversion needed
        return _redeemAsset(_asset, _shares, _receiver, _controller);
    }

    function _redeemAsset(
        address _asset,
        uint256 _shares,
        address _receiver,
        address _controller
    ) internal whenNotPaused checkAccess(_controller) returns (uint256 assets) {
        require(_shares != 0, NothingToRedeem());
        
        // Calculate assets directly in asset units
        ClaimableRedeem memory claimableRedeem = _getClaimableRedeem(_controller, _asset);
        require(_shares <= claimableRedeem.shares, InsufficientBalance());
        assets = _shares == claimableRedeem.shares 
            ? claimableRedeem.assets
            : _shares.mulDivDown(claimableRedeem.assets, claimableRedeem.shares);
        require(assets != 0, NothingToWithdraw());

        // Execute withdraw
        _performWithdraw(_asset, assets, _shares, _receiver, _controller);
    }

    /// @dev Internal function for performing a withdraw
    /// @param _asset Asset to withdraw assets in
    /// @param _assets Amount of assets to withdraw
    /// @param _shares Amount of shares to burn
    /// @param _receiver Asset recipient
    /// @param _controller Controller address
    function _performWithdraw(
        address _asset,
        uint256 _assets,
        uint256 _shares,
        address _receiver,
        address _controller
    ) internal {
        // Before-withdrawal hook - use asset units for the hook
        beforeWithdraw(_asset, _assets, _shares);

        // Update claimable redeem
        ClaimableRedeem memory claimableRedeem = _getClaimableRedeem(_controller, _asset);
        claimableRedeem.assets -= _assets;
        claimableRedeem.shares -= _shares;
        _setClaimableRedeem(_controller, _asset, claimableRedeem);

        // Transfer assets to the receiver
        SafeERC20.safeTransfer(IERC20(_asset), _receiver, _assets);
        emit Withdraw(msg.sender, _receiver, _controller, _assets, _shares);
        
        // After-withdrawal hook - use asset units for the hook
        afterWithdraw(_asset, _assets, _shares);
    }

    ////////////////
    // Accounting //
    ////////////////

    /// @notice Get the controller's pending redeem
    /// @param _controller Controller address
    /// @return pendingRedeem Pending redeem details
    function getPendingRedeem(
        address _controller
    ) public view returns (PendingRedeem memory) {
        return _getPendingRedeem(_controller, asset());
    }

    /// @notice Get the controller's pending redeem
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return pendingRedeem Pending redeem details
    function getPendingRedeemForAsset(
        address _asset,
        address _controller
    ) public view returns (PendingRedeem memory) {
        return _getPendingRedeem(_controller, _asset);
    }

    /// @notice Get claimable redeem request
    function getClaimableRedeem(
        address _controller
    ) public view returns (ClaimableRedeem memory) {
        return _getClaimableRedeem(_controller, asset());
    }

    /// @notice Get claimable redeem request
    function getClaimableRedeemForAsset(
        address _asset,
        address _controller
    ) public view returns (ClaimableRedeem memory) {
        return _getClaimableRedeem(_controller, _asset);
    }

    /// @notice Get pending shares for controller
    /// @param _controller Controller address
    /// @return pendingShares Amount of pending shares
    function pendingRedeemRequest(
        uint256, // requestId
        address _controller
    ) public view returns (uint256) {
        return _getPendingRedeem(_controller, asset()).shares;
    }

    /// @notice Get pending shares for controller
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return pendingShares Amount of pending shares
    function pendingRedeemRequestForAsset(
        address _asset,
        uint256, // requestId
        address _controller
    ) public view returns (uint256) {
        return _getPendingRedeem(_controller, _asset).shares;
    }

    /// @notice Get claimable shares for controller
    /// @param _controller Controller address
    /// @return claimableShares Amount of claimable shares
    function claimableRedeemRequest(
        uint256, // requestId
        address _controller
    ) public view returns (uint256) {
        return _getClaimableRedeem(_controller, asset()).shares;
    }

    /// @notice Get claimable shares for controller
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return claimableShares Amount of claimable shares
    function claimableRedeemRequestForAsset(
        address _asset,
        uint256, // requestId
        address _controller
    ) public view returns (uint256) {
        return _getClaimableRedeem(_controller, _asset).shares;
    }

    /// @notice Preview shares for deposit
    /// @param _assets Amount to deposit
    /// @return shares Amount of shares received
    /// @dev Returns 0 if vault is paused
    function previewDeposit(
        uint256 _assets
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : super.previewDeposit(_assets);
    }

    /// @notice Preview shares for deposit
    /// @param _asset Asset
    /// @param _assets Amount to deposit
    /// @return shares Amount of shares received
    /// @dev Returns 0 if vault is paused
    function previewDepositForAsset(
        address _asset,
        uint256 _assets
    ) public view virtual returns (uint256) {
        // Convert to underlying for share calculation
        uint256 baseAssets = convertToUnderlying(_asset, _assets);
        return paused() ? 0 : super.previewDeposit(baseAssets);
    }

    /// @notice Preview assets for mint
    /// @param _shares Amount to mint
    /// @return assets Amount of assets required
    /// @dev Returns 0 if vault is paused
    function previewMint(
        uint256 _shares
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : super.previewMint(_shares);
    }

    /// @notice Preview assets for mint
    /// @param _asset Asset to deposit in
    /// @param _shares Amount to mint
    /// @return assets Amount of assets required
    /// @dev Returns 0 if vault is paused
    function previewMintForAsset(
        address _asset,
        uint256 _shares
    ) public view virtual returns (uint256) {
        // Calculate assets needed in underlying units, then convert to asset units
        uint256 baseAssets = super.previewMint(_shares);
        return paused() ? 0 : convertFromUnderlying(_asset, baseAssets);
    }


    /// @dev Preview withdraw not supported for async flows
    function previewWithdraw(
        uint256
    ) public pure virtual override returns (uint256) {
        revert CanNotPreviewWithdrawInAsyncVault();
    }

    /// @dev Preview redeem not supported for async flows
    function previewRedeem(
        uint256
    ) public pure virtual override returns (uint256) {
        revert CanNotPreviewRedeemInAsyncVault();
    }

    ///////////////////////////////
    // Deposti & Withdraw Limits //
    ///////////////////////////////

    /// @notice Get max assets for deposit
    /// @return assets Maximum deposit amount
    /// @dev Returns 0 if vault is paused
    function maxDeposit(
        address // receiver
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @notice Get max shares for mint
    /// @return shares Maximum mint amount
    /// @dev Returns 0 if vault is paused
    function maxMint(
        address // receiver
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @notice Get max assets for withdraw
    /// @param _controller Controller address
    /// @return assets Maximum withdraw amount
    /// @dev Returns controller's claimable assets
    function maxWithdraw(
        address _controller
    ) public view virtual override returns (uint256) {
        return _getClaimableRedeem(_controller, asset()).assets;
    }

    /// @notice Get max assets for withdraw
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return assets Maximum withdraw amount
    /// @dev Returns controller's claimable assets
    function maxWithdrawForAsset(
        address _asset,
        address _controller
    ) public view virtual returns (uint256) {
        return _getClaimableRedeem(_controller, _asset).assets;
    }

    /// @notice Get max shares for redeem
    /// @param _controller Controller address
    /// @return shares Maximum redeem amount
    /// @dev Returns controller's claimable shares
    function maxRedeem(
        address _controller
    ) public view virtual override returns (uint256) {
        return _getClaimableRedeem(_controller, asset()).shares;
    }

    /// @notice Get max shares for redeem
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return shares Maximum redeem amount
    /// @dev Returns controller's claimable shares
    function maxRedeemForAsset(
        address _asset,
        address _controller
    ) public view virtual returns (uint256) {
        return _getClaimableRedeem(_controller, _asset).shares;
    }

    ////////////////////
    // Request Redeem //
    ////////////////////

    /// @notice Request redeem of shares
    /// @param _shares Amount to redeem
    /// @param _controller Share recipient
    /// @param _owner Share owner
    /// @return requestId Request identifier
    /// @dev Adds to controller's pending redeem requests
    function requestRedeem(
        uint256 _shares,
        address _controller,
        address _owner
    ) external returns (uint256 requestId) {
        return _requestRedeemOfAsset(asset(), _shares, _controller, _owner);
    }

    /// @notice Request redeem of shares
    /// @param _asset Asset
    /// @param _shares Amount to redeem
    /// @param _controller Share recipient
    /// @param _owner Share owner
    /// @return requestId Request identifier
    /// @dev Adds to controller's pending redeem requests
    function requestRedeemOfAsset(
        address _asset,
        uint256 _shares,
        address _controller,
        address _owner
    ) external returns (uint256 requestId) {
        return _requestRedeemOfAsset(_asset, _shares, _controller, _owner);
    }

    function _requestRedeemOfAsset(
        address _asset,
        uint256 _shares,
        address _controller,
        address _owner
    ) internal checkAccess(_owner) returns (uint256 requestId) {
        require(_shares != 0, NothingToRedeem());
        require(IERC20(address(this)).balanceOf(_owner) >= _shares, InsufficientBalance());

        // Validate that the asset is supported by the rate provider
        // This prevents users from creating pending redeem requests for unsupported assets
        require(_asset == this.asset() || rateProvider().isSupported(_asset), AssetNotSupported());

        beforeRequestRedeem(_asset, _shares, _controller, _owner);

        PendingRedeem memory pendingRedeem =
            _getPendingRedeem(_controller, _asset);
        pendingRedeem.shares += _shares;
        pendingRedeem.requestTime = block.timestamp;

        _setPendingRedeem(_controller, _asset, pendingRedeem);

        // Transfer shares to vault for burning later
        SafeERC20.safeTransferFrom(IERC20(this), _owner, address(this), _shares);

        emit RedeemRequested(_controller, _owner, REQUEST_ID, msg.sender, _shares);
        
        return REQUEST_ID;
    }

    ////////////////////////
    // Redeem Cancelation //
    ////////////////////////

    /// @notice Cancel redeem request for controller
    /// @param controller Controller address
    /// @dev Transfers pending shares back to msg.sender
    function cancelRedeemRequest(address controller) external {
        return _cancelRedeemRequestOfAsset(asset(), controller, msg.sender);
    }

    /// @notice Cancel redeem request for controller
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @param _receiver Share recipient
    /// @dev Transfers pending shares back to receiver
    function cancelRedeemRequestOfAsset(
        address _asset,
        address _controller,
        address _receiver
    ) external {
        return _cancelRedeemRequestOfAsset(_asset, _controller, _receiver);
    }

    /// @notice Cancel redeem request for controller
    /// @param _controller Controller address
    /// @param _receiver Share recipient
    /// @dev Transfers pending shares back to receiver
    function cancelRedeemRequest(
        address _controller,
        address _receiver
    ) public {
        return _cancelRedeemRequestOfAsset(asset(), _controller, _receiver);
    }

    function _cancelRedeemRequestOfAsset(
        address _asset,
        address _controller,
        address _receiver
    ) internal virtual checkAccess(_controller) {
        // Get the pending shares
        PendingRedeem memory pendingRedeem = _getPendingRedeem(_controller, _asset);
        uint256 shares = pendingRedeem.shares;
        require(shares != 0, NothingToRedeem());

        // Update pending redeem
        pendingRedeem.shares = 0;
        pendingRedeem.requestTime = 0;
        _setPendingRedeem(_controller, _asset, pendingRedeem);

        // Send pending shares from vault to receiver
        SafeERC20.safeTransfer(IERC20(address(this)), _receiver, shares);

        emit RedeemRequestCanceled(_controller, _receiver, shares);
    }

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill redeem request
    /// @param _shares Amount to redeem
    /// @param _controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeem(
        uint256 _shares,
        address _controller
    ) external virtual returns (uint256) {
        uint256 assets = convertToAssets(_shares);
        _burn(address(this), _shares);
        return _fulfillRedeemOfAsset(asset(), assets, _shares, _controller);
    }

    /// @notice Fulfill redeem request
    /// @param _asset Asset
    /// @param _shares Amount to redeem
    /// @param _controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeemOfAsset(
        address _asset,
        uint256 _shares,
        address _controller
    ) external virtual returns (uint256 assets) {
        // Convert shares to underlying assets, then to asset units
        uint256 underlyingAssets = convertToAssets(_shares);
        assets = convertFromUnderlying(_asset, underlyingAssets);
        _burn(address(this), _shares);
        return _fulfillRedeemOfAsset(_asset, assets, _shares, _controller);
    }

    /// @dev Internal fulfill redeem request logic
    function _fulfillRedeemOfAsset(
        address _asset,
        uint256 _assets,
        uint256 _shares,
        address _controller
    ) internal virtual returns (uint256) {
        require(_assets != 0 && _shares != 0, InvalidRedeemCall());

        PendingRedeem memory pendingRedeem = _getPendingRedeem(_controller, _asset);
        ClaimableRedeem memory claimableRedeem = _getClaimableRedeem(_controller, _asset);
        require(_shares <= pendingRedeem.shares, NotEnoughPendingShares());

        // Before fulfill redeem hook
        beforeFulfillRedeem(_asset, _assets, _shares);

        claimableRedeem.shares += _shares;
        claimableRedeem.assets += _assets;
        pendingRedeem.shares -= _shares;

        // Reset the request time if redeem is full
        if (pendingRedeem.shares == 0) 
            pendingRedeem.requestTime = 0;

        _setPendingRedeem(_controller, _asset, pendingRedeem);
        _setClaimableRedeem(_controller, _asset, claimableRedeem);

        emit RedeemRequestFulfilled(_controller, msg.sender, _shares, _assets);

        // After fulfill redeem hook
        afterFulfillRedeem(_asset, _assets, _shares, _controller);

        return _assets;
    }

    ///////////////////////////
    // Rate Provider Updates //
    ///////////////////////////

    /// @notice Propose new rate provider for owner acceptance after delay
    /// @param _newRateProvider Address of the new rate provider
    function proposeRateProvider(address _newRateProvider) external onlyOwner {
        require(_newRateProvider != address(0), MissingRateProvider());

        _getBaseAsyncRedeemStorage().proposedRateProvider = AddressUpdateProposal({
            addr: _newRateProvider,
            timestamp: block.timestamp
        });

        emit RateProviderProposed(_newRateProvider);
    }

    /// @notice Accept proposed rate provider
    /// @dev Pauses vault to ensure provider setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptProposedRateProvider() external onlyOwner {
        BaseAsyncRedeemStorage storage $ = _getBaseAsyncRedeemStorage();
        AddressUpdateProposal memory proposal = $.proposedRateProvider;

        require(proposal.addr != address(0), NoRateProviderProposed());
        require(block.timestamp >= proposal.timestamp + ADDRESS_UPDATE_TIMELOCK, CanNotAcceptRateProviderYet());
        require(block.timestamp <= proposal.timestamp + MAX_ADDRESS_UPDATE_WAIT, RateProviderUpdateExpired());

        $.rateProvider = IUltraVaultRateProvider(proposal.addr);
        delete $.proposedRateProvider;
        emit RateProviderUpdated(address($.rateProvider), proposal.addr);

        // Pause to manually check the setup by operators
        _pause();
    }

    ///////////
    // Hooks //
    ///////////

    /// @dev Hook for executing custom logic right before deposit/mint
    function beforeDeposit(address asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for executing custom logic right after deposit/mint
    function afterDeposit(address asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for executing custom logic right before withdraw/redeem
    function beforeWithdraw(address asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for executing custom logic right after withdraw/redeem
    function afterWithdraw(address asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for inheriting contracts after request redeem
    function beforeRequestRedeem(address asset, uint256 shares, address controller, address owner) internal virtual {}

    /// @dev Hook for inheriting contracts before fulfill
    function beforeFulfillRedeem(address asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for inheriting contracts after fulfill
    function afterFulfillRedeem(address asset, uint256 assets, uint256 shares, address controller) internal virtual {}

    ////////////
    // ERC165 //
    ////////////

    /// @notice Check interface support
    /// @param interfaceId Interface ID to check
    /// @return exists True if interface is supported
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override returns (bool) {
        return
            interfaceId == type(IERC7540Redeem).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////
    // Access Control //
    ////////////////////

    modifier checkAccess(address _controller) {
        require(_controller == msg.sender || isOperator(_controller, msg.sender), AccessDenied());
        _;
    }
}
