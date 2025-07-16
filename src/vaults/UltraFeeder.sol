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
 * @title UltraFeeder
 * @notice ERC-4626 compliant vault that wraps UltraVault for deposits and handles async redeems
 * @dev This vault only handles deposits into the main UltraVault and manages async redeems
 */
contract UltraFeeder is BaseControlledAsyncRedeem, UUPSUpgradeable {
    using FixedPointMathLib for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IUltraVault public mainVault;

    error VaultPaused();
    error InvalidMainVault();
    error NoPendingRedeem();
    error NoClaimableAssets();
    error InvalidRedeemRequest();
    error AssetMismatch();
    error ShareNumberMismatch();

    // V0: 1 total: mainVault
    uint256[49] private __gap;

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the vault
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name The name of the vault token
     * @param _symbol The symbol of the vault token
     * @param _mainVault The UltraVault to deposit into
     * @param _requestQueue Request queue for async redeems
     */
    function initialize(
        address _mainVault,
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _requestQueue
    ) external initializer {
        if (address(_mainVault) == address(0)) revert InvalidMainVault();
        mainVault = IUltraVault(_mainVault);
        
        // Validate that the main vault's asset matches our asset
        if (mainVault.asset() != _asset) revert AssetMismatch();
        
        super.initialize(_owner, _asset, _name, _symbol, mainVault.rateProvider(), _requestQueue);
        _pause();
    }

    /**
     * @notice Returns the total assets in the vault
     * @return The total assets in the vault
     */
    function totalAssets() public view override returns (uint256) {
        return IPriceSource(mainVault.oracle()).getQuote(
            totalSupply(),
            address(mainVault),
            address(asset())
        );
    }

    /*//////////////////////////////////////////////////////////////
                    BaseControlledAsyncRedeem OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address asset, uint256 assets, uint256 shares) internal override {
        // Approve main vault to spend assets
        SafeERC20.safeIncreaseAllowance(IERC20(asset), address(mainVault), assets);

        uint256 mainShares = mainVault.depositAsset(asset, assets, address(this));
        if (mainShares != shares) {
            revert ShareNumberMismatch();
        }
    }

    /// @dev Hook for inheriting contracts after request redeem
    function beforeRequestRedeem(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) internal override {
        // Approve main vault to spend it's shares
        SafeERC20.safeIncreaseAllowance(IERC20(address(mainVault)), address(mainVault), shares);

        // Request redeem from main vault
        mainVault.requestRedeemOfAsset(asset, shares, address(this), address(this));
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address asset, uint256 assets, uint256 shares) internal override {

        // Fulfill redeem in main vault. Returns asset units
        mainVault.fulfillRedeemOfAsset(asset, shares, address(this));
        uint256 mainAssetsClaimed = mainVault.redeemAsset(asset, shares, address(this), address(this));

        if (mainAssetsClaimed != assets) {
            revert ShareNumberMismatch();
        }
    }

    /// @dev In async vaults it's a privileged function
    function _fulfillRedeemOfAsset(
        address asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal override onlyRoleOrOwner(OPERATOR_ROLE) returns (uint256) {
        return super._fulfillRedeemOfAsset(asset, assets, shares, controller);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the amount of shares that would be minted for a given amount of assets
     * @param assets The amount of assets to convert
     * @return The amount of shares that would be minted
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return mainVault.previewDeposit(assets);
    }

    /**
     * @notice Returns the amount of assets required for a given amount of shares
     * @param shares The amount of shares to convert
     * @return The amount of assets required
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        return mainVault.previewMint(shares);
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
