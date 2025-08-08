// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "./BaseControlledAsyncRedeem.sol";
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
    uint64 public constant MAX_PERFORMANCE_FEE = 3e17; // 30%
    uint64 public constant MAX_MANAGEMENT_FEE = 5e16; // 5%
    uint64 public constant MAX_WITHDRAWAL_FEE = 1e16; // 1%
    uint256 internal constant ONE_YEAR = 365 * 24 * 60 * 60; // 31_536_000 seconds

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
        uint256 withdrawalFee = assets.mulDivDown(fees().withdrawalFee, 1e18);

        // Fulfill request
        uint256 withdrawalAmount = assets - withdrawalFee;
        _fulfillRedeemOfAsset(asset(), withdrawalAmount, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        _transferWithdrawalFeeInAsset(asset(), withdrawalFee);

        return withdrawalAmount;
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
        uint256 withdrawalFee = assets.mulDivDown(fees().withdrawalFee, 1e18);

        // Fulfill request with asset units (base contract expects asset units)
        uint256 withdrawalAmount = assets - withdrawalFee;
        _fulfillRedeemOfAsset(asset, withdrawalAmount, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        // Collect withdrawal fee in asset units
        _transferWithdrawalFeeInAsset(asset, withdrawalFee);

        // Return the amount in asset units for consistency with base contract
        return withdrawalAmount;
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

        uint256 _withdrawalFeeRate = fees().withdrawalFee;
        uint256 totalShares;
        uint256 totalFees;
        address _asset = asset();
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        for (uint256 i; i < shares.length; ) {
            uint256 assets = _optimizedConvertToAssets(shares[i], _totalAssets, _totalSupply);

            // Calculate the withdrawal incentive fee from the assets
            uint256 withdrawalFee = assets.mulDivDown(_withdrawalFeeRate, 1e18);

            // Fulfill redeem
            _fulfillRedeemOfAsset(_asset, assets - withdrawalFee, shares[i], controllers[i]);

            total += assets;
            totalFees += withdrawalFee;
            totalShares += shares[i];

            unchecked { ++i; }
        }

        // Burn shares
        _burn(address(this), totalShares);

        // Transfer withdrawal fees
        _transferWithdrawalFeeInAsset(_asset, totalFees);

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
    function _transferWithdrawalFeeInAsset(
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
        Fees memory _fees = fees();
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        return _accruedPerformanceFee(_fees, _totalAssets, _totalSupply) + _accruedManagementFee(_fees, _totalAssets);
    }

    /// @notice Calculate accrued performance fee
    /// @return accruedPerformanceFee Fee amount in asset token
    /// @dev Based on high water mark value
    function _accruedPerformanceFee(
        Fees memory _fees, 
        uint256 _totalAssets, 
        uint256 _totalSupply
    ) internal view returns (uint256) {
        uint256 performanceFee = _fees.performanceFee;
        if (performanceFee == 0) {
            return 0;
        }
        uint8 _decimals = decimals();
        uint256 shareValue = _optimizedConvertToAssets(10 ** _decimals, _totalAssets, _totalSupply);
        if (shareValue <= _fees.highwaterMark) {
            return 0;
        }
        return performanceFee.mulDivDown(
            (shareValue - _fees.highwaterMark) * _totalSupply,
            (10 ** (18 + _decimals))
        );
    }

    /// @notice Calculate accrued management fee
    /// @return accruedManagementFee Fee amount in asset token
    /// @dev Annualized per minute, based on 525_600 minutes or 31_536_000 seconds per year
    function _accruedManagementFee(Fees memory _fees, uint256 _totalAssets) internal view returns (uint256) {
        uint256 managementFee = _fees.managementFee;
        if (managementFee == 0) {
            return 0;
        }
        uint256 timePassed = block.timestamp - _fees.lastUpdateTimestamp;
        return managementFee.mulDivDown(_totalAssets * timePassed, ONE_YEAR) / 1e18;
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
    /// @dev Reverts if fees exceed limits (30% performance, 5% management, 1% withdrawal)
    /// @dev Collects pending fees before update
    function setFees(Fees memory fees_) public onlyOwner whenNotPaused {
        _collectFees();
        _setFees(fees_);
    }

    function _setFees(Fees memory fees_) internal {
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
        Fees memory _fees = fees();
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        uint256 managementFee = _accruedManagementFee(_fees, _totalAssets);
        uint256 performanceFee = _accruedPerformanceFee(_fees, _totalAssets, _totalSupply);
        uint256 shareValue = _optimizedConvertToAssets(10 ** decimals(), _totalAssets, _totalSupply);

        if (performanceFee + managementFee > 0) {
            AsyncVaultStorage storage $ = _getAsyncVaultStorage();
            // Update the high water mark
            if (shareValue > _fees.highwaterMark) {
                $.fees.highwaterMark = shareValue;
            }
            $.fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Mint shares to fee recipient
            uint256 feeShares = _optimizedConvertToShares(managementFee + performanceFee, _totalAssets, _totalSupply);
            _mint($.feeRecipient, feeShares);

            emit FeesCollected(feeShares, managementFee, performanceFee);
        }
    }
}
