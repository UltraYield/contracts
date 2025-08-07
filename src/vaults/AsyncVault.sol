// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "./BaseControlledAsyncRedeem.sol";
import { BaseERC7540 } from "./BaseERC7540.sol";
import { FixedPointMathLib } from "../utils/FixedPointMathLib.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Vault fee configuration
struct Fees {
    // Performance fee rate (100% = 1e18)
    uint64 performanceFee;
    // Management fee rate (100% = 1e18)
    uint64 managementFee;
    // Withdrawal fee rate (100% = 1e18)
    uint64 withdrawalFee;
    // Last fee update timestamp
    uint64 lastUpdateTimestamp;
    // High water mark for performance fees
    uint256 highwaterMark;
}

/// @dev Struct wrapping initialization parameters for AsyncVault
struct AsyncVaultInitParams {
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
    // Fee recipient
    address feeRecipient;
    // Fee configuration
    Fees fees;
}

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.AsyncVault")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ASYNC_VAULT_STORAGE_LOCATION = 0x8b87be01fca60a9d62c55cf3d953b8c6c3db48e53c3aead2b8a9227ba5787400;

/// @title AsyncVault
/// @notice Base contract for ERC-7540 compliant async redeem vaults
/// @dev Asset management logic must be implemented by inheriting contracts
abstract contract AsyncVault is BaseControlledAsyncRedeem {
    using FixedPointMathLib for uint256;

    // Events
    event FeesRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesUpdated(Fees oldFees, Fees newFees);
    event FeesCollected(uint256 shares, uint256 managementFee, uint256 performanceFee);
    event WithdrawalFeeCollected(uint256 shares);

    ///////////////
    // Constants //
    ///////////////

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint64 public constant MAX_PERFORMANCE_FEE = 3e17;
    uint64 public constant MAX_MANAGEMENT_FEE = 5e16;
    uint64 public constant MAX_WITHDRAWAL_FEE = 1e16;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.AsyncVault
    struct AsyncVaultStorage {
        /// @notice Fee recipient address
        address feeRecipient;
        /// @notice Current fees
        Fees fees;
    }

    function _getAsyncVaultStorage() internal pure returns (AsyncVaultStorage storage $) {
        assembly {
            $.slot := ASYNC_VAULT_STORAGE_LOCATION
        }
    }

    /// @notice Initialize vault with basic parameters
    /// @param params Struct wrapping initialization parameters
    function initialize(
        AsyncVaultInitParams memory params
    ) public virtual onlyInitializing {
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: params.rateProvider
        }));

        require(params.feeRecipient != address(0)); 
        _getAsyncVaultStorage().feeRecipient = params.feeRecipient;
        emit FeesRecipientUpdated(address(0), params.feeRecipient);

        _setFees(params.fees);
    }

    //////////////
    // ERC-4626 //
    //////////////

    /// @notice Helper to deposit assets for msg.sender
    /// @param assets Amount to deposit
    /// @return shares Amount of shares received
    function deposit(uint256 assets) external returns (uint256) {
        return super.deposit(assets, msg.sender);
    }

    /// @notice Helper to mint shares for msg.sender
    /// @param shares Amount to mint
    /// @return assets Amount of assets required
    function mint(uint256 shares) external returns (uint256) {
        return super.mint(shares, msg.sender);
    }

    /// @notice Helper to withdraw assets for msg.sender
    /// @param assets Amount to withdraw
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets) external returns (uint256) {
        return super.withdraw(assets, msg.sender, msg.sender);
    }

    /// @notice Helper to redeem shares for msg.sender
    /// @param shares Amount to redeem
    /// @return assets Amount of assets received
    function redeem(uint256 shares) external returns (uint256) {
        return super.redeem(shares, msg.sender, msg.sender);
    }

    //////////////////////////
    // Request Redeem Logic //
    //////////////////////////

    /// @notice Request redeem for msg.sender
    /// @param shares Amount to redeem
    /// @return requestId Request identifier
    function requestRedeem(uint256 shares) external returns (uint256 requestId) {
        return _requestRedeemOfAsset(asset(), shares, msg.sender, msg.sender);
    }

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill redeem request
    /// @param shares Amount to redeem
    /// @param controller Controller to redeem for
    /// @return assets Amount of assets received
    /// @dev Reverts if shares < minAmount
    /// @dev Collects withdrawal fee to incentivize manager
    function fulfillRedeem(
        uint256 shares,
        address controller
    ) external override returns (uint256 assets) {
        // Collect fees accrued to date
        _collectFees();

        assets = convertToAssets(shares);

        // Calculate the withdrawal incentive fee from the assets
        uint256 feesToCollect = assets.mulDivDown(
            uint256(fees().withdrawalFee),
            1e18
        );

        // Fulfill request
        _fulfillRedeemOfAsset(asset(), assets - feesToCollect, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        collectWithdrawalFeeInAsset(asset(), feesToCollect);

        return assets - feesToCollect;
    }

    /// @notice Fulfill redeem request
    /// @param asset Asset
    /// @param shares Amount to redeem
    /// @param controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller
    ) external virtual override returns (uint256 assets) {
        // Collect fees accrued to date
        _collectFees();
        
        // Convert shares to underlying assets, then to asset units
        uint256 underlyingAssets = convertToAssets(shares);
        assets = convertFromUnderlying(asset, underlyingAssets);
        
        // Calculate the withdrawal incentive fee directly in asset units
        uint256 feesToCollect = assets.mulDivDown(
            uint256(fees().withdrawalFee),
            1e18
        );

        // Fulfill request with asset units (base contract expects asset units)
        _fulfillRedeemOfAsset(asset, assets - feesToCollect, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        // Collect withdrawal fee in asset units
        collectWithdrawalFeeInAsset(asset, feesToCollect);

        // Return the amount in asset units for consistency with base contract
        return assets - feesToCollect;
    }

    /// @notice Fulfill multiple redeem requests
    /// @param shares Array of share amounts
    /// @param controllers Array of controllers
    /// @return total Total assets received
    /// @dev Reverts if arrays length mismatch
    /// @dev Collects withdrawal fee to incentivize manager
    function fulfillMultipleRedeems(
        uint256[] memory shares,
        address[] memory controllers
    ) external returns (uint256 total) {
        require(shares.length == controllers.length, Misconfigured());

        _collectFees();

        uint64 withdrawalFee = fees().withdrawalFee;
        uint256 totalShares;
        uint256 totalFees;
        for (uint256 i; i < shares.length; i++) {
            uint256 assets = convertToAssets(shares[i]);

            // Calculate the withdrawal incentive fee from the assets
            uint256 feesToCollect = assets.mulDivDown(
                uint256(withdrawalFee),
                1e18
            );

            // Fulfill redeem
            _fulfillRedeemOfAsset(asset(), assets - feesToCollect, shares[i], controllers[i]);

            total += assets;
            totalFees += feesToCollect;
            totalShares += shares[i];
        }

        // Burn shares
        _burn(address(this), totalShares);

        collectWithdrawalFeeInAsset(asset(), totalFees);

        return total - totalFees;
    }

    /// @dev Internal fulfill redeem request logic
    /// @dev In async vaults it's a privileged function
    function _fulfillRedeemOfAsset(
        address asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual onlyRoleOrOwner(OPERATOR_ROLE) override returns (uint256) {
        return super._fulfillRedeemOfAsset(asset, assets, shares, controller);
    }

    /// @notice Collect withdrawal fee
    /// @param fee Amount to collect
    /// @dev Can be overridden for custom withdrawal logic
    function collectWithdrawalFeeInAsset(
        address asset,
        uint256 fee
    ) internal virtual {
        if (fee > 0) {
            SafeERC20.safeTransfer(IERC20(asset), feeRecipient(), fee);
            emit WithdrawalFeeCollected(fee);
        }
    }

    /////////////////////
    // Hooks overrides //
    /////////////////////

    /// @notice Collect fees before withdraw
    /// @dev Expected to be overridden in inheriting contracts
    function beforeWithdraw(address, uint256, uint256) internal virtual override {
        if (!paused()) 
            _collectFees();
    }

    /// @notice Collect fees before deposit
    /// @dev Expected to be overridden in inheriting contracts
    function beforeDeposit(address, uint256, uint256) internal virtual override {
        _collectFees();
    }

    //////////
    // Fees //
    //////////

    /// @notice Get vault fee parameters
    function fees() public view returns (Fees memory) {
        return _getAsyncVaultStorage().fees;
    }

    /// @notice Get vault fee recipient
    function feeRecipient() public view returns (address) {
        return _getAsyncVaultStorage().feeRecipient;
    }

    /// @notice Get total accrued fees
    function accruedFees() public view returns (uint256) {
        Fees memory fees_ = fees();
        return _accruedPerformanceFee(fees_) + _accruedManagementFee(fees_);
    }

    /// @notice Calculate accrued performance fee
    /// @return accruedPerformanceFee Fee amount in asset token
    /// @dev Based on high water mark value
    function _accruedPerformanceFee(
        Fees memory fees_
    ) internal view returns (uint256) {
        uint256 shareValue = convertToAssets(10 ** decimals());
        uint256 performanceFee = uint256(fees_.performanceFee);

        return performanceFee > 0 && shareValue > fees_.highwaterMark ?
            performanceFee.mulDivDown(
                (shareValue - fees_.highwaterMark) * totalSupply(),
                (10 ** (18 + decimals()))
            ) :
            0;
    }

    /// @notice Calculate accrued management fee
    /// @return accruedManagementFee Fee amount in asset token
    /// @dev Annualized per minute, based on 525600 minutes per year
    function _accruedManagementFee(
        Fees memory fees_
    ) internal view returns (uint256) {
        uint256 managementFee = uint256(fees_.managementFee);

        return managementFee > 0 ? 
            managementFee.mulDivDown(
                totalAssets() * (block.timestamp - fees_.lastUpdateTimestamp),
                31536000 // one year
            ) / 1e18 : 
            0;
    }

    /// @notice Update vault's fee recipient
    /// @param newFeeRecipient_ New fee recipient
    /// @dev Collects pending fees before update
    function setFeeRecipient(address newFeeRecipient_) public onlyOwner whenNotPaused {
        require(newFeeRecipient_ != address(0), Misconfigured());

        address currentFeeRecipient = feeRecipient();
        if (currentFeeRecipient != newFeeRecipient_) {
            _collectFees();
            _getAsyncVaultStorage().feeRecipient = newFeeRecipient_;
            emit FeesRecipientUpdated(currentFeeRecipient, newFeeRecipient_);
        }
    }

    /// @notice Update vault fees
    /// @param fees_ New fee configuration
    /// @dev Reverts if fees exceed limits (20% performance, 5% management, 5% withdrawal)
    /// @dev Collects pending fees before update
    function setFees(Fees memory fees_) public onlyOwner whenNotPaused {
        _collectFees();
        _setFees(fees_);
    }

    function _setFees(Fees memory fees_) internal {
        // Max value: 30% performance, 5% management, 1% withdrawal
        require(
            fees_.performanceFee <= MAX_PERFORMANCE_FEE &&
            fees_.managementFee <= MAX_MANAGEMENT_FEE &&
            fees_.withdrawalFee <= MAX_WITHDRAWAL_FEE,
            Misconfigured()
        );

        fees_.lastUpdateTimestamp = uint64(block.timestamp);

        Fees memory currentFees = fees();
        if (currentFees.highwaterMark == 0) {
            fees_.highwaterMark = 10 ** IERC20Metadata(asset()).decimals();
        } else {
            fees_.highwaterMark = currentFees.highwaterMark;
        }
        _getAsyncVaultStorage().fees = fees_;

        emit FeesUpdated(currentFees, fees_);
    }

    /// @notice Mint fees as shares to recipient
    /// @dev Updates fee-related variables
    function collectFees() external whenNotPaused {
        _collectFees();
    }

    function _collectFees() internal {
        Fees memory fees_ = fees();
        uint256 managementFee = _accruedManagementFee(fees_);
        uint256 performanceFee = _accruedPerformanceFee(fees_);
        uint256 shareValue = convertToAssets(10 ** decimals());

        if (performanceFee + managementFee > 0) {
            AsyncVaultStorage storage $ = _getAsyncVaultStorage();
            // Update the high water mark
            if (shareValue > fees_.highwaterMark) 
                $.fees.highwaterMark = shareValue;

            $.fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Mint shares to fee recipient
            uint256 feeShares = convertToShares(managementFee + performanceFee);
            _mint($.feeRecipient, feeShares);

            emit FeesCollected(feeShares, managementFee, performanceFee);
        }
    }
}
