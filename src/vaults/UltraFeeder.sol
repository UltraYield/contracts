// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVault } from "../interfaces/IUltraVault.sol";
import { 
    BaseControlledAsyncRedeem, 
    PendingRedeem, 
    ClaimableRedeem,
    FixedPointMathLib
} from "./BaseControlledAsyncRedeem.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";

/**
 * @title UltraMultiVault
 * @notice ERC-4626 compliant vault that wraps UltraVault for deposits and handles async redeems
 * @dev This vault only handles deposits into the main UltraVault and manages async redeems
 */
contract UltraFeeder is BaseControlledAsyncRedeem, UUPSUpgradeable {
    using FixedPointMathLib for uint256;

    IUltraVault public mainVault;
    IERC20 public underlying;

    event RedeemRequested(address indexed user, uint256 shares);
    event RedeemFulfilled(address indexed user, uint256 assets);
    event AssetsClaimed(address indexed user, uint256 assets);

    error VaultPaused();
    error InvalidMainVault();
    error NoPendingRedeem();
    error NoClaimableAssets();
    error InvalidRedeemRequest();

    // V0: 2 total: 1 - mainVault, 1 - underlying
    uint256[48] private __gap;

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the vault
     * @param _mainVault The UltraVault to deposit into
     * @param _name The name of the vault token
     * @param _symbol The symbol of the vault token
     */
    function initialize(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _mainVault,
        address _rateProvider,
        address _requestQueue
    ) external initializer {
        if (address(_mainVault) == address(0)) revert InvalidMainVault();
        mainVault = IUltraVault(_mainVault);
        
        super.initialize(_owner, _asset, _name, _symbol, _rateProvider, _requestQueue);
    }

    /**
     * @notice Returns the total assets in the vault
     * @return The total assets in the vault
     */
    function totalAssets() public view override returns (uint256) {
        uint256 balance = mainVault.balanceOf(address(this));
        return IPriceSource(mainVault.oracle()).getQuote(
            balance,
            share(), 
            address(mainVault)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    BaseControlledAsyncRedeem OVERRIDES
    //////////////////////////////////////////////////////////////*/

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
    ) internal override whenNotPaused returns (uint256 shares) {
        if (mainVault.paused()) revert VaultPaused();

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

        // Approve main vault to spend assets
        SafeERC20.safeIncreaseAllowance(underlying, address(mainVault), assets);
        
        // Deposit into main vault
        shares = mainVault.deposit(assets, address(this));
        
        // Mint shares to receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(asset, assets, shares);
    }

    /// @dev Mint with asset
    function _mintWithAsset(
        address asset,
        uint256 shares,
        address receiver
    ) internal override whenNotPaused returns (uint256 assets) {
        if (mainVault.paused()) revert VaultPaused();

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

        // Approve main vault to spend assets
        SafeERC20.safeIncreaseAllowance(underlying, address(mainVault), assets);
        
        // Deposit into main vault
        mainVault.deposit(assets, address(this));

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // After-deposit hook
        afterDeposit(asset, assets, shares);
    }

    /**
     * @notice Request to redeem shares
     * @param shares The amount of shares to redeem
     * @return requestId The request ID
     */
    function _requestRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) internal override checkAccess(owner) returns (uint256 requestId) {
        if (IERC20(address(this)).balanceOf(owner) < shares)
            revert InsufficientBalance();
        if (shares == 0)
            revert NothingToRedeem();

        // // Burn user's shares
        // _burn(msg.sender, shares);

        // // Request redeem from main vault
        // requestId = mainVault.requestRedeem(shares);

        // // Track pending redeem
        // pendingRedeems[msg.sender] += shares;

        // emit RedeemRequested(msg.sender, shares);
        // return requestId;

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

    function _fulfillRedeemOfAsset(
        address asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual override returns (uint256) {
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

        // Fulfill redeem in main vault. Requires correctly set role
        assets = mainVault.fulfillRedeem(shares, address(this));

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
                        ACCOUNTING OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the amount of assets that would be deposited for a given amount of shares
     * @param assets The amount of assets to convert
     * @return The amount of shares that would be minted
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return mainVault.previewDeposit(assets);
    }

    /**
     * @notice Returns the amount of shares that would be minted for a given amount of assets
     * @param assets The amount of assets to convert
     * @return The amount of shares that would be minted
     */
    function previewMint(uint256 assets) public view override returns (uint256) {
        return mainVault.previewMint(assets);
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited
     * @return The maximum amount of assets that can be deposited
     */
    function maxDeposit(address) public view override returns (uint256) {
        return mainVault.maxDeposit(address(this));
    }

    /**
     * @notice Returns the maximum amount of shares that can be minted
     * @return The maximum amount of shares that can be minted
     */
    function maxMint(address) public view override returns (uint256) {
        return mainVault.maxMint(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
