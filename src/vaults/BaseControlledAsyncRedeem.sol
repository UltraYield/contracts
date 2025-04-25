// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseERC7540 } from "./BaseERC7540.sol";
import { IERC7540Redeem } from "ERC-7540/interfaces/IERC7540.sol";
import { FixedPointMathLib } from "../utils/FixedPointMathLib.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct PendingRedeem {
    uint256 shares;
    uint256 requestTime;
}

struct ClaimableRedeem {
    uint256 assets;
    uint256 shares;
}

/**
 * @title BaseControlledAsyncRedeem
 * @notice Base contract for controlled async redeem flows
 * @dev Based on ERC-7540 Reference Implementation
 */
abstract contract BaseControlledAsyncRedeem is BaseERC7540, IERC7540Redeem {
    using FixedPointMathLib for uint256;

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

    mapping(address => PendingRedeem) internal _pendingRedeem;
    mapping(address => ClaimableRedeem) internal _claimableRedeem;

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
    ) public override whenNotPaused returns (uint256 shares) {
        // Rounding down can cause zero shares minted
        shares = previewDeposit(assets);
        if (shares == 0)
            revert EmptyDeposit();

        // Pre-deposit hook
        beforeDeposit(assets, shares);

        // Transfer before mint to avoid reentering
        SafeERC20.safeTransferFrom(
            IERC20(asset()),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(assets, shares);
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
    ) public override whenNotPaused returns (uint256 assets) {

        if (shares == 0)
            revert NothingToMint();

        assets = previewMint(shares); 

        // Pre-deposit hook
        beforeDeposit(assets, shares);

        // Need to transfer before minting or ERC777s could reenter
        SafeERC20.safeTransferFrom(
            IERC20(asset()),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(assets, shares);
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
        if (assets == 0)
            revert NothingToWithdraw();

        ClaimableRedeem storage claimableRedeem = _claimableRedeem[controller];
        shares = assets.mulDivUp(
            claimableRedeem.shares,
            claimableRedeem.assets
        );

        // Handle
        _withdrawClaimableBalance(assets, claimableRedeem);

        // Before-withdrawal hook
        beforeWithdraw(assets, shares);

        // Transfer assets to the receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);

        // After-withdrawal hook
        afterWithdraw(assets, shares);
    }

    /**
     * @notice Update claimable balance after withdrawal
     * @param assets Amount withdrawn
     * @param claimableRedeem Controller's claimable balance
     * @dev Handles precision loss in partial claims
     */
    function _withdrawClaimableBalance(
        uint256 assets,
        ClaimableRedeem storage claimableRedeem
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
    ) public virtual override checkAccess(controller) returns (uint256 assets) {
        if (shares == 0)
            revert NothingToRedeem();

        ClaimableRedeem storage claimableRedeem = _claimableRedeem[controller];
        assets = shares.mulDivDown(
            claimableRedeem.assets,
            claimableRedeem.shares
        );

        // Modify the claimableRedeem state accordingly
        _redeemClaimableBalance(shares, claimableRedeem);

        // Before-withdrawal hook
        beforeWithdraw(assets, shares);

        // Transfer assets to the receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);

        // After-withdrawal hook
        afterWithdraw(assets, shares);
    }

    /**
     * @notice Update claimable balance after redeem
     * @param shares Shares to redeem
     * @param claimableRedeem Claimable redeem of the user
     * @dev Handles precision loss in partial claims
     */
    function _redeemClaimableBalance(
        uint256 shares,
        ClaimableRedeem storage claimableRedeem
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
        return _pendingRedeem[controller];
    }

    /// @notice Get claimable redeem request
    function getClaimableRedeem(
        address controller
    ) public view returns (ClaimableRedeem memory) {
        return _claimableRedeem[controller];
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
        return _pendingRedeem[controller].shares;
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
        return _claimableRedeem[controller].shares;
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
        return _claimableRedeem[controller].assets;
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
        return _claimableRedeem[controller].shares;
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
        return _requestRedeem(shares, controller, owner);
    }

    /// @dev Internal redeem request logic
    function _requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) internal checkAccess(owner) returns (uint256 requestId) {
        if (IERC20(address(this)).balanceOf(owner) < shares)
            revert InsufficientBalance();
        if (shares == 0)
            revert NothingToRedeem();

        PendingRedeem storage pendingRedeem = _pendingRedeem[controller];
        pendingRedeem.shares += shares;
        pendingRedeem.requestTime = block.timestamp;

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
        return _cancelRedeemRequest(controller, msg.sender);
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
        return _cancelRedeemRequest(controller, receiver);
    }

    /// @dev Internal cancel redeem request logic
    function _cancelRedeemRequest(
        address controller,
        address receiver
    ) internal virtual checkAccess(controller) {
        // Get the pending shares
        PendingRedeem storage pendingRedeem = _pendingRedeem[controller];
        uint256 shares = pendingRedeem.shares;

        if (shares == 0) 
            revert NothingToRedeem();

        pendingRedeem.shares = 0;
        pendingRedeem.requestTime = 0;

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

        return _fulfillRedeem(assets, shares, controller);
    }

    /// @dev Internal fulfill redeem request logic
    function _fulfillRedeem(
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual returns (uint256) {
        if (assets == 0 || shares == 0) 
            revert InvalidRedeemCall();

        PendingRedeem storage pendingRedeem = _pendingRedeem[controller];
        ClaimableRedeem storage claimableRedeem = _claimableRedeem[controller];

        if (pendingRedeem.shares == 0)
            revert NothingToRedeem();

        if (shares > pendingRedeem.shares)
            revert NotEnoughPendingShares();

        // Before fulfill redeem hook
        beforeFulfillRedeem(assets, shares);

        claimableRedeem.shares += shares;
        claimableRedeem.assets += assets;
        pendingRedeem.shares -= shares;

        // Reset the requestTime if redeem is full
        if (pendingRedeem.shares == 0) 
            pendingRedeem.requestTime = 0;

        emit RedeemRequestFulfilled(controller, msg.sender, shares, assets);

        // After fulfill redeem hook
        afterFulfillRedeem(assets, shares);

        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Hook for inheriting contracts before deposit
    function beforeDeposit(
        uint256 assets, 
        uint256 shares
    ) internal virtual {}

    /// @dev Hook for inheriting contracts after withdrawal
    function afterWithdraw(
        uint256 assets, 
        uint256 shares
    ) internal virtual {}

    /// @dev Hook for inheriting contracts before fulfill
    function beforeFulfillRedeem(
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
