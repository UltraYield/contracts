// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseERC7540 } from "./BaseERC7540.sol";
import { IERC7540Redeem } from "ERC-7540/interfaces/IERC7540.sol";
import { FixedPointMathLib } from "../utils/FixedPointMathLib.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUltraQueue, PendingRedeem, ClaimableRedeem } from "../interfaces/IUltraQueue.sol";
import { IUltraVaultRateProvider, AssetData } from "../interfaces/IUltraVaultRateProvider.sol";
import { AddressUpdateProposal } from "../utils/AddressUpdates.sol";

/**
 * @title BaseControlledAsyncRedeem
 * @notice Base contract for controlled async redeem flows
 * @dev Based on ERC-7540 Reference Implementation
 */
abstract contract BaseControlledAsyncRedeem is BaseERC7540, IERC7540Redeem {
    using FixedPointMathLib for uint256;

    // Rate provider events
    event RateProviderProposed(address indexed proposedProvider);
    event RateProviderUpdated(address indexed oldProvider, address indexed newProvider);

    // Errors
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

    // Rate provider errors
    error MissingRateProvider();
    error NoRateProviderProposed();
    error CanNotAcceptRateProviderYet();
    error RateProviderUpdateExpired();

    // Deprecated
    mapping(address => PendingRedeem) internal _pendingRedeem;
    mapping(address => ClaimableRedeem) internal _claimableRedeem;

    // Request queue
    IUltraQueue requestQueue;

    // Rate provider
    IUltraVaultRateProvider public rateProvider;
    AddressUpdateProposal public proposedRateProvider;

    // V0: 2 total: 1 - pending redeems, 1 - claimable redeems
    // V1: +1, 3 total: added requestQueue. deprecated: _pendingRedeem and _claimableRedeem
    uint256[47] private __gap;

    /**
     * @notice Initialize vault with basic parameters
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _requestQueue withdrawal request queue
     */
    function initialize(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _rateProvider,
        address _requestQueue
    ) public virtual onlyInitializing {
        super.initialize(_owner, _asset, _name, _symbol);

        rateProvider = IUltraVaultRateProvider(_rateProvider);
        requestQueue = IUltraQueue(_requestQueue);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function convertToUnderlying(
        address asset,
        uint256 assets
    ) public virtual returns (uint256 baseAssets) {
        if (!rateProvider.isSupported(asset)) revert AssetNotSupported();

        // Get rate between deposit asset and base asset
        uint256 rate = rateProvider.getRate(asset);
        return (assets * rate) / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets for receiver
     * @param assets Amount to deposit
     * @param receiver Share recipient
     * @return shares Amount of shares received
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before transferring assets
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override whenNotPaused returns (uint256 shares) {
        return _depositAsset(asset(), assets, receiver);
    }

    /**
     * @notice Deposit assets for receiver
     * @param asset Asset
     * @param assets Amount to deposit
     * @param receiver Share recipient
     * @return shares Amount of shares received
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before transferring assets
     */
    function depositAsset(
        address asset,
        uint256 assets,
        address receiver
    ) public whenNotPaused returns (uint256 shares) {
        uint256 baseAssets = convertToUnderlying(asset, assets);
        return _depositAsset(asset, baseAssets, receiver);
    }

    /**
     * @notice Deposit assets for receiver
     * @param asset Asset to deposit
     * @param assets Amount to deposit
     * @param receiver Share recipient
     * @return shares Amount of shares received
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before transferring assets
     */
    function _depositAsset(
        address asset,
        uint256 assets,
        address receiver
    ) internal whenNotPaused returns (uint256 shares) {
        // Rounding down can cause zero shares minted
        shares = previewDeposit(assets);
        if (shares == 0)
            revert EmptyDeposit();

        // Pre-deposit hook
        beforeDeposit(asset, assets, shares);

        // Transfer before mint to avoid reentering
        SafeERC20.safeTransferFrom(
            IERC20(asset),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(asset, assets, shares);
    }

    /**
     * @notice Mint shares for receiver
     * @param shares Amount to mint
     * @param receiver Share recipient
     * @return assets Amount of assets required
     * @dev Synchronous function, reverts if paused
     * @dev Uses claimable balances before minting shares
     */
    function mint(
        uint256 shares,
        address receiver
    ) public virtual override returns (uint256 assets) {
        return _mintWithAsset(asset(), shares, receiver);
    }

    /// @dev Mint with asset
    function _mintWithAsset(
        address asset,
        uint256 shares,
        address receiver
    ) internal whenNotPaused returns (uint256 assets) {

        if (shares == 0)
            revert NothingToMint();

        assets = previewMint(shares); 

        // Pre-deposit hook
        beforeDeposit(asset, assets, shares);

        // Need to transfer before minting or ERC777s could reenter
        SafeERC20.safeTransferFrom(
            IERC20(asset),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(asset, assets, shares);
    }

    /**
     * @notice Withdraw assets from fulfilled redeem requests
     * @param assets Amount to withdraw
     * @param receiver Asset recipient
     * @param controller Controller address
     * @return shares Amount of shares burned
     * @dev Asynchronous function, works when paused
     * @dev Caller must be controller or operator
     * @dev Requires sufficient claimable assets
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public virtual override checkAccess(controller) returns (uint256 shares) {
        return _withdrawAsset(asset(), assets, receiver, controller);
    }

    /**
     * @notice Withdraw assets from fulfilled redeem requests
     * @param asset Asset
     * @param assets Amount to withdraw
     * @param receiver Asset recipient
     * @param controller Controller address
     * @return shares Amount of shares burned
     * @dev Asynchronous function, works when paused
     * @dev Caller must be controller or operator
     * @dev Requires sufficient claimable assets
     */
    function withdrawAsset(
        address asset,
        uint256 assets,
        address receiver,
        address controller
    ) public virtual checkAccess(controller) returns (uint256 shares) {
        uint256 baseAssets = convertToUnderlying(asset, assets);
        return _withdrawAsset(asset, baseAssets, receiver, controller);
    }

    function _withdrawAsset(
        address asset,
        uint256 assets,
        address receiver,
        address controller
    ) internal virtual checkAccess(controller) returns (uint256 shares) {
        if (assets == 0)
            revert NothingToWithdraw();

        ClaimableRedeem memory claimableRedeem =
            requestQueue.getClaimableRedeem(controller, address(this), asset);
        shares = assets.mulDivUp(
            claimableRedeem.shares,
            claimableRedeem.assets
        );

        // Handle
        _withdrawClaimableBalanceForAsset(asset, controller, assets, claimableRedeem);

        // Before-withdrawal hook
        beforeWithdraw(asset, assets, shares);

        requestQueue.setClaimableRedeem(controller, address(this), asset, claimableRedeem);

        // Transfer assets to the receiver
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);

        // After-withdrawal hook
        afterWithdraw(asset, assets, shares);
    }

    function _withdrawClaimableBalanceForAsset(
        address asset,
        address controller,
        uint256 assets,
        ClaimableRedeem memory claimableRedeem
    ) internal {
        uint256 sharesUp = assets.mulDivUp(
            claimableRedeem.shares,
            claimableRedeem.assets
        );

        claimableRedeem.assets -= assets;
        claimableRedeem.shares = 
            claimableRedeem.shares > sharesUp ?
            claimableRedeem.shares - sharesUp :
            0;
        
        requestQueue.setClaimableRedeem(controller, address(this), asset, claimableRedeem);
    }

    /**
     * @notice Redeem shares from fulfilled requests
     * @param shares Amount to redeem
     * @param receiver Asset recipient
     * @param controller Controller address
     * @return assets Amount of assets received
     * @dev Asynchronous function, works when paused
     * @dev Caller must be controller or operator
     * @dev Requires sufficient claimable shares
     */
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public virtual override returns (uint256 assets) {
        return _redeemAsset(asset(), shares, receiver, controller);
    }

    /**
     * @notice Redeem shares from fulfilled requests
     * @param asset Asset
     * @param shares Amount to redeem
     * @param receiver Asset recipient
     * @param controller Controller address
     * @return assets Amount of assets received
     * @dev Asynchronous function, works when paused
     * @dev Caller must be controller or operator
     * @dev Requires sufficient claimable shares
     */
    function redeemAsset(
        address asset,
        uint256 shares,
        address receiver,
        address controller
    ) public virtual returns (uint256 assets) {
        uint256 baseShares = convertToUnderlying(asset, shares);
        return _redeemAsset(asset, baseShares, receiver, controller);
    }

    function _redeemAsset(
        address asset,
        uint256 shares,
        address receiver,
        address controller
    ) internal virtual checkAccess(controller) returns (uint256 assets) {
        if (shares == 0)
            revert NothingToRedeem();

        ClaimableRedeem memory claimableRedeem =
            requestQueue.getClaimableRedeem(controller, address(this), asset);
        assets = shares.mulDivDown(
            claimableRedeem.assets,
            claimableRedeem.shares
        );

        // Modify the claimableRedeem state accordingly
        _redeemClaimableBalanceForAsset(asset, controller, shares, claimableRedeem);

        // Before-withdrawal hook
        beforeWithdraw(asset, assets, shares);

        requestQueue.setClaimableRedeem(controller, address(this), asset, claimableRedeem);

        // Transfer assets to the receiver
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);

        // After-withdrawal hook
        afterWithdraw(asset, assets, shares);
    }

    /**
     * @notice Update claimable balance after redeem
     * @param shares Shares to redeem
     * @param claimableRedeem Claimable redeem of the user
     * @dev Handles precision loss in partial claims
     */
    function _redeemClaimableBalanceForAsset(
        address asset,
        address controller,
        uint256 shares,
        ClaimableRedeem memory claimableRedeem
    ) internal {
        uint256 assetsRoundedUp = shares.mulDivUp(
            claimableRedeem.assets,
            claimableRedeem.shares
        );

        claimableRedeem.assets = 
            claimableRedeem.assets > assetsRoundedUp ?
            claimableRedeem.assets - assetsRoundedUp :
            0;
        claimableRedeem.shares -= shares;

        requestQueue.setClaimableRedeem(controller, address(this), asset, claimableRedeem);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTNG LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the controller's pending redeem
     * @param controller Controller address
     * @return pendingRedeem Pending redeem details
     */
    function getPendingRedeem(
        address controller
    ) public view returns (PendingRedeem memory) {
        return requestQueue.getPendingRedeem(controller, address(this), asset());
    }

    /**
     * @notice Get the controller's pending redeem
     * @param asset Asset
     * @param controller Controller address
     * @return pendingRedeem Pending redeem details
     */
    function getPendingRedeemForAsset(
        address asset,
        address controller
    ) public view returns (PendingRedeem memory) {
        return requestQueue.getPendingRedeem(controller, address(this), asset);
    }

    /// @notice Get claimable redeem request
    function getClaimableRedeem(
        address controller
    ) public view returns (ClaimableRedeem memory) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset());
    }

    /// @notice Get claimable redeem request
    function getClaimableRedeemForAsset(
        address asset,
        address controller
    ) public view returns (ClaimableRedeem memory) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset);
    }

    /**
     * @notice Get pending shares for controller
     * @param controller Controller address
     * @return pendingShares Amount of pending shares
     */
    function pendingRedeemRequest(
        uint256,
        address controller
    ) public view returns (uint256) {
        return requestQueue.getPendingRedeem(controller, address(this), asset()).shares;
    }

    /**
     * @notice Get pending shares for controller
     * @param asset Asset
     * @param controller Controller address
     * @return pendingShares Amount of pending shares
     */
    function pendingRedeemRequestForAsset(
        address asset,
        uint256,
        address controller
    ) public view returns (uint256) {
        return requestQueue.getPendingRedeem(controller, address(this), asset).shares;
    }

    /**
     * @notice Get claimable shares for controller
     * @param controller Controller address
     * @return claimableShares Amount of claimable shares
     */
    function claimableRedeemRequest(
        uint256,
        address controller
    ) public view returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset()).shares;
    }

    /**
     * @notice Get claimable shares for controller
     * @param asset Asset
     * @param controller Controller address
     * @return claimableShares Amount of claimable shares
     */
    function claimableRedeemRequestForAsset(
        address asset,
        uint256,
        address controller
    ) public view returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset).shares;
    }

    /**
     * @notice Preview shares for deposit
     * @param assets Amount to deposit
     * @return shares Amount of shares received
     * @dev Returns 0 if vault is paused
     */
    function previewDeposit(
        uint256 assets
    ) public view virtual override returns (uint256) {
        return paused ? 0 : super.previewDeposit(assets);
    }

    /**
     * @notice Preview assets for mint
     * @param shares Amount to mint
     * @return assets Amount of assets required
     * @dev Returns 0 if vault is paused
     */
    function previewMint(
        uint256 shares
    ) public view virtual override returns (uint256) {
        return paused ? 0 : super.previewMint(shares);
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

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMITS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get max assets for deposit
     * @return assets Maximum deposit amount
     * @dev Returns 0 if vault is paused
     */
    function maxDeposit(
        address
    ) public view virtual override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /**
     * @notice Get max shares for mint
     * @return shares Maximum mint amount
     * @dev Returns 0 if vault is paused
     */
    function maxMint(address) public view virtual override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /**
     * @notice Get max assets for withdraw
     * @param controller Controller address
     * @return assets Maximum withdraw amount
     * @dev Returns controller's claimable assets
     */
    function maxWithdraw(
        address controller
    ) public view virtual override returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset()).assets;
    }

    /**
     * @notice Get max assets for withdraw
     * @param asset Asset
     * @param controller Controller address
     * @return assets Maximum withdraw amount
     * @dev Returns controller's claimable assets
     */
    function maxWithdrawForAsset(
        address asset,
        address controller
    ) public view virtual returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset).assets;
    }

    /**
     * @notice Get max shares for redeem
     * @param controller Controller address
     * @return shares Maximum redeem amount
     * @dev Returns controller's claimable shares
     */
    function maxRedeem(
        address controller
    ) public view virtual override returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset()).shares;
    }

    /**
     * @notice Get max shares for redeem
     * @param asset Asset
     * @param controller Controller address
     * @return shares Maximum redeem amount
     * @dev Returns controller's claimable shares
     */
    function maxRedeemForAsset(
        address asset,
        address controller
    ) public view virtual returns (uint256) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset).shares;
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    event RedeemRequested(
        address indexed controller,
        address indexed owner,
        uint256 requestId,
        address sender,
        uint256 shares
    );

    /**
     * @notice Request redeem of shares
     * @param shares Amount to redeem
     * @param controller Share recipient
     * @param owner Share owner
     * @return requestId Request identifier
     * @dev Adds to controller's pending redeem requests
     */
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external virtual returns (uint256 requestId) {
        return _requestRedeemOfAsset(asset(), shares, controller, owner);
    }

    /**
     * @notice Request redeem of shares
     * @param asset Asset
     * @param shares Amount to redeem
     * @param controller Share recipient
     * @param owner Share owner
     * @return requestId Request identifier
     * @dev Adds to controller's pending redeem requests
     */
    function requestRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) external virtual returns (uint256 requestId) {
        uint256 baseShares = convertToUnderlying(asset, shares);
        return _requestRedeemOfAsset(asset, baseShares, controller, owner);
    }

    function _requestRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) internal checkAccess(owner) returns (uint256 requestId) {
        if (IERC20(address(this)).balanceOf(owner) < shares)
            revert InsufficientBalance();
        if (shares == 0)
            revert NothingToRedeem();

        PendingRedeem memory pendingRedeem =
            requestQueue.getPendingRedeem(controller, address(this), asset);
        pendingRedeem.shares += shares;
        pendingRedeem.requestTime = block.timestamp;

        requestQueue.setPendingRedeem(controller, address(this), asset, pendingRedeem);

        // Transfer shares to vault for burning later
        SafeERC20.safeTransferFrom(IERC20(this), owner, address(this), shares);

        emit RedeemRequested(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL REDEEM REQUEST LOGIC
    //////////////////////////////////////////////////////////////*/

    event RedeemRequestCanceled(
        address indexed controller,
        address indexed receiver,
        uint256 shares
    );

    /**
     * @notice Cancel redeem request for controller
     * @param controller Controller address
     * @dev Transfers pending shares back to msg.sender
     */
    function cancelRedeemRequest(address controller) external virtual {
        return _cancelRedeemRequestOfAsset(asset(), controller, msg.sender);
    }

    /**
     * @notice Cancel redeem request for controller
     * @param asset Asset
     * @param controller Controller address
     * @param receiver Share recipient
     * @dev Transfers pending shares back to receiver
     */
    function cancelRedeemRequestOfAsset(
        address asset,
        address controller,
        address receiver
    ) external virtual {
        return _cancelRedeemRequestOfAsset(asset, controller, receiver);
    }

    /**
     * @notice Cancel redeem request for controller
     * @param controller Controller address
     * @param receiver Share recipient
     * @dev Transfers pending shares back to receiver
     */
    function cancelRedeemRequest(
        address controller,
        address receiver
    ) public virtual {
        return _cancelRedeemRequestOfAsset(asset(), controller, receiver);
    }

    function _cancelRedeemRequestOfAsset(
        address asset,
        address controller,
        address receiver
    ) internal virtual checkAccess(controller) {
        // Get the pending shares
        PendingRedeem memory pendingRedeem = 
            requestQueue.getPendingRedeem(controller, address(this), asset);
        uint256 shares = pendingRedeem.shares;

        if (shares == 0) 
            revert NothingToRedeem();

        pendingRedeem.shares = 0;
        pendingRedeem.requestTime = 0;

        requestQueue.setPendingRedeem(controller, address(this), asset, pendingRedeem);

        // Return pending shares
        SafeERC20.safeTransfer(IERC20(address(this)), receiver, shares);

        emit RedeemRequestCanceled(controller, receiver, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT FULFILLMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    event RedeemRequestFulfilled(
        address indexed controller,
        address indexed fulfiller,
        uint256 shares,
        uint256 assets
    );

    /**
     * @notice Fulfill redeem request
     * @param shares Amount to redeem
     * @param controller Controller address
     * @return assets Amount of claimable assets
     */
    function fulfillRedeem(
        uint256 shares,
        address controller
    ) external virtual returns (uint256) {
        uint256 assets = convertToAssets(shares);

        _burn(address(this), shares);

        return _fulfillRedeemOfAsset(asset(), assets, shares, controller);
    }

    /**
     * @notice Fulfill redeem request
     * @param asset Asset
     * @param shares Amount to redeem
     * @param controller Controller address
     * @return assets Amount of claimable assets
     */
    function fulfillRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller
    ) external virtual returns (uint256) {
        uint256 assets = convertToAssets(shares);
        uint256 baseAssets = convertToUnderlying(asset, assets);

        _burn(address(this), shares);

        return _fulfillRedeemOfAsset(asset, baseAssets, shares, controller);
    }

    /// @dev Internal fulfill redeem request logic
    function _fulfillRedeemOfAsset(
        address asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual returns (uint256) {
        if (assets == 0 || shares == 0) 
            revert InvalidRedeemCall();

        PendingRedeem memory pendingRedeem = 
            requestQueue.getPendingRedeem(controller, address(this), asset);
        ClaimableRedeem memory claimableRedeem =
            requestQueue.getClaimableRedeem(controller, address(this), asset);

        if (pendingRedeem.shares == 0)
            revert NothingToRedeem();

        if (shares > pendingRedeem.shares)
            revert NotEnoughPendingShares();

        // Before fulfill redeem hook
        beforeFulfillRedeem(asset, assets, shares);

        claimableRedeem.shares += shares;
        claimableRedeem.assets += assets;
        pendingRedeem.shares -= shares;

        // Reset the requestTime if redeem is full
        if (pendingRedeem.shares == 0) 
            pendingRedeem.requestTime = 0;

        requestQueue.setPendingRedeem(controller, address(this), asset, pendingRedeem);
        requestQueue.setClaimableRedeem(controller, address(this), asset, claimableRedeem);

        emit RedeemRequestFulfilled(controller, msg.sender, shares, assets);

        // After fulfill redeem hook
        afterFulfillRedeem(assets, shares);

        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                            RATE PROVIDER UPDATES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Propose new rate provider for owner acceptance after delay
     * @param newRateProvider Address of the new rate provider
     */
    function proposeRateProvider(address newRateProvider) external onlyOwner {
        if (newRateProvider == address(0))
            revert MissingRateProvider();

        proposedRateProvider = AddressUpdateProposal({
            addr: newRateProvider,
            timestamp: block.timestamp
        });

        emit RateProviderProposed(newRateProvider);
    }

    /**
     * @notice Accept proposed rate provider
     * @dev Pauses vault to ensure provider setup and prevent deposits with faulty prices
     * @dev Oracle must be switched before unpausing
     */
    function acceptProposedRateProvider() external onlyOwner {
        AddressUpdateProposal memory proposal = proposedRateProvider;

        if (proposal.addr == address(0))
            revert NoRateProviderProposed();
        if (block.timestamp < proposal.timestamp + 3 days)
            revert CanNotAcceptRateProviderYet();
        if (block.timestamp > proposal.timestamp + 7 days)
            revert RateProviderUpdateExpired();

        emit RateProviderUpdated(address(rateProvider), proposal.addr);

        rateProvider = IUltraVaultRateProvider(proposal.addr);

        delete proposedRateProvider;

        // Pause to manually check the setup by operators
        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Hook for inheriting contracts before deposit
    function beforeDeposit(
        address asset,
        uint256 assets, 
        uint256 shares
    ) internal virtual {}

    /// @dev Hook for inheriting contracts after withdrawal
    function afterWithdraw(
        address asset,
        uint256 assets, 
        uint256 shares
    ) internal virtual {}

    /// @dev Hook for inheriting contracts before fulfill
    function beforeFulfillRedeem(
        address asset,
        uint256 assets,
        uint256 shares
    ) internal virtual {}

    /// @dev Hook for inheriting contracts after fulfill
    function afterFulfillRedeem(
        uint256 assets,
        uint256 shares
    ) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                        ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check interface support
     * @param interfaceId Interface ID to check
     * @return exists True if interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override returns (bool) {
        return
            interfaceId == type(IERC7540Redeem).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    modifier checkAccess(address controller) {
        if (controller != msg.sender && !isOperator[controller][msg.sender])
            revert AccessDenied();
        _;
    }
}
