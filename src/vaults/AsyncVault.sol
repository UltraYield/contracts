// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseControlledAsyncRedeem } from "./BaseControlledAsyncRedeem.sol";
import { BaseERC7540, ERC20 } from "./BaseERC7540.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

/// @notice Vault fee configuration
struct Fees {
    /// @notice Performance fee rate (100% = 1e18)
    uint64 performanceFee;
    /// @notice Management fee rate (100% = 1e18)
    uint64 managementFee;
    /// @notice Withdrawal fee rate (100% = 1e18)
    uint64 withdrawalFee;
    /// @notice Last fee update timestamp
    uint64 lastUpdateTimestamp;
    /// @notice High water mark for performance fees
    uint256 highwaterMark;
}

/// @title AsyncVault
/// @notice Base contract for ERC-7540 compliant async redeem vaults
/// @dev Asset management logic must be implemented by inheriting contracts
abstract contract AsyncVault is BaseControlledAsyncRedeem {
    using FixedPointMathLib for uint256;

    // Events
    event FeesRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesUpdated(Fees oldFees, Fees newFees);

    // Errors
    error Misconfigured();

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Fee recipient address
    address feeRecipient;
    /// @notice Current fees
    Fees public fees;

    /**
     * @notice Initialize vault with basic parameters
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _feeRecipient Fee recipient
     * @param _fees Fee configuration
     */
    constructor(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        Fees memory _fees
    ) BaseERC7540(_owner, _asset, _name, _symbol) {
        require(_feeRecipient != address(0)); 
        feeRecipient = _feeRecipient;
        _setFees(_fees);
        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to deposit assets for msg.sender
     * @param assets Amount to deposit
     * @return shares Amount of shares received
     */
    function deposit(uint256 assets) external returns (uint256) {
        return deposit(assets, msg.sender);
    }

    /**
     * @notice Helper to mint shares for msg.sender
     * @param shares Amount to mint
     * @return assets Amount of assets required
     */
    function mint(uint256 shares) external returns (uint256) {
        return mint(shares, msg.sender);
    }

    /**
     * @notice Helper to withdraw assets for msg.sender
     * @param assets Amount to withdraw
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets) external returns (uint256) {
        return withdraw(assets, msg.sender, msg.sender);
    }

    /**
     * @notice Helper to redeem shares for msg.sender
     * @param shares Amount to redeem
     * @return assets Amount of assets received
     */
    function redeem(uint256 shares) external returns (uint256) {
        return redeem(shares, msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request redeem for msg.sender
     * @param shares Amount to redeem
     * @return requestId Request identifier
     */
    function requestRedeem(uint256 shares) external returns (uint256 requestId) {
        return _requestRedeem(shares, msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        FULFILL REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fulfill redeem request
     * @param shares Amount to redeem
     * @param controller Controller to redeem for
     * @return assets Amount of assets received
     * @dev Reverts if shares < minAmount
     * @dev Collects withdrawal fee to incentivize manager
     */
    function fulfillRedeem(
        uint256 shares,
        address controller
    ) external override returns (uint256 assets) {
        // Collect fees accrued to date
        _collectFees();

        assets = convertToAssets(shares);

        // Calculate the withdrawal incentive fee from the assets
        Fees memory fees_ = fees;
        uint256 feesToCollect = assets.mulDivDown(
            uint256(fees_.withdrawalFee),
            1e18
        );

        // Burn the shares
        _burn(address(this), shares);

        // Fulfill request
        _fulfillRedeem(assets - feesToCollect, shares, controller);

        collectWithdrawalFee(feesToCollect);
    }

    /**
     * @notice Fulfill multiple redeem requests
     * @param shares Array of share amounts
     * @param controllers Array of controllers
     * @return total Total assets received
     * @dev Reverts if arrays length mismatch
     * @dev Collects withdrawal fee to incentivize manager
     */
    function fulfillMultipleRedeems(
        uint256[] memory shares,
        address[] memory controllers
    ) external returns (uint256 total) {
        if (shares.length != controllers.length) 
            revert Misconfigured();

        _collectFees();

        Fees memory fees_ = fees;

        uint256 totalShares;
        uint256 totalFees;

        for (uint256 i; i < shares.length; i++) {
            uint256 assets = convertToAssets(shares[i]);

            // Calculate the withdrawal incentive fee from the assets
            uint256 feesToCollect = assets.mulDivDown(
                uint256(fees_.withdrawalFee),
                1e18
            );

            // Fulfill redeem
            _fulfillRedeem(assets - feesToCollect, shares[i], controllers[i]);

            total += assets;
            totalFees += feesToCollect;
            totalShares += shares[i];
        }

        // Burn the shares
        _burn(address(this), totalShares);

        collectWithdrawalFee(totalFees);

        return total;
    }

    /// @dev Internal fulfill redeem request logic
    /// @dev In async vaults it's a priveledged function
    function _fulfillRedeem(
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual onlyRoleOrOwner(OPERATOR_ROLE) override returns (uint256) {
        super._fulfillRedeem(assets, shares, controller);
    }

    /**
     * @notice Collect withdrawal fee
     * @param fee Amount to collect
     * @dev Can be overridden for custom withdrawal logic
     */
    function collectWithdrawalFee(
        uint256 fee
    ) internal virtual {
        if (fee > 0) 
            SafeTransferLib.safeTransfer(asset, feeRecipient, fee);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Collect fees before withdraw
     * @dev Expected to be overridden in inheriting contracts
     */
    function beforeWithdraw(uint256, uint256) internal virtual override {
        if (!paused) 
            _collectFees();
    }

    /**
     * @notice Collect fees before deposit
     * @dev Expected to be overridden in inheriting contracts
     */
    function beforeDeposit(uint256, uint256) internal virtual override {
        _collectFees();
    }

    /*//////////////////////////////////////////////////////////////
                            FEE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get vault fee parameters
    function getFees() public view returns (Fees memory) {
        return fees;
    }

    /// @notice Get total accrued fees
    function accruedFees() public view returns (uint256) {
        Fees memory fees_ = fees;

        return _accruedPerformanceFee(fees_) + _accruedManagementFee(fees_);
    }

    /**
     * @notice Calculate accrued performance fee
     * @return accruedPerformanceFee Fee amount in asset token
     * @dev Based on high water mark value
     */
    function _accruedPerformanceFee(
        Fees memory fees_
    ) internal view returns (uint256) {
        uint256 shareValue = convertToAssets(10 ** decimals);
        uint256 performanceFee = uint256(fees_.performanceFee);

        return performanceFee > 0 && shareValue > fees_.highwaterMark ?
            performanceFee.mulDivUp(
                (shareValue - fees_.highwaterMark) * totalSupply,
                (10 ** (18 + decimals))
            ) :
            0;
    }

    /**
     * @notice Calculate accrued management fee
     * @return accruedManagementFee Fee amount in asset token
     * @dev Annualized per minute, based on 525600 minutes per year
     */
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

    /**
     * @notice Update vault's fee recipient
     * @param newFeeRecipient_ New fee recipient
     * @dev Collects pending fees before update
     */
    function setFeeRecipient(address newFeeRecipient_) public onlyOwner whenNotPaused {
        if (newFeeRecipient_ == address(0)) 
            revert Misconfigured();

        if (feeRecipient != newFeeRecipient_) {
            _collectFees();

            emit FeesRecipientUpdated(feeRecipient, newFeeRecipient_);

            feeRecipient = newFeeRecipient_;
        }
    }

    /**
     * @notice Update vault fees
     * @param fees_ New fee configuration
     * @dev Reverts if fees exceed limits (20% performance, 5% management, 5% withdrawal)
     * @dev Collects pending fees before update
     */
    function setFees(Fees memory fees_) public onlyOwner whenNotPaused {
        _collectFees();

        _setFees(fees_);
    }

    function _setFees(Fees memory fees_) internal {
        // Max value: 30% performance, 5% management, 1% withdrawal
        if (
            fees_.performanceFee > 3e17 ||
            fees_.managementFee > 5e16 ||
            fees_.withdrawalFee > 1e16
        ) revert Misconfigured();

        fees_.lastUpdateTimestamp = uint64(block.timestamp);

        if (fees.highwaterMark == 0) {
            // Baseline
            fees_.highwaterMark = convertToAssets(10 ** decimals);
        } else {
            fees_.highwaterMark = fees.highwaterMark;
        }

        emit FeesUpdated(fees, fees_);

        fees = fees_;
    }

    /**
     * @notice Mint fees as shares to recipient
     * @dev Updates fee-related variables
     */
    function collectFees() external whenNotPaused {
        _collectFees();
    }

    function _collectFees() internal {
        Fees memory fees_ = fees;
        uint256 performanceFee = _accruedPerformanceFee(fees_);
        uint256 managementFee = _accruedManagementFee(fees_);
        uint256 shareValue = convertToAssets(10 ** decimals);

        if (performanceFee + managementFee > 0) {
            // Update the high water mark
            if (shareValue > fees_.highwaterMark) 
                fees.highwaterMark = shareValue;

            fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Mint shares to fee recipient
            _mint(feeRecipient, convertToShares(performanceFee + managementFee));
        }
    }
}
