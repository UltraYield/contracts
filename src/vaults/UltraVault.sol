// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { Fees, IUltraVaultEvents, IUltraVaultErrors } from "src/interfaces/IUltraVault.sol";
import { AddressUpdateProposal } from "src/utils/AddressUpdates.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "src/vaults/BaseControlledAsyncRedeem.sol";
import { OPERATOR_ROLE } from "src/utils/Roles.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraVault")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_VAULT_STORAGE_LOCATION = 0x4a2c313ed01a3f9b3ba2e7d99f5ac7985ad5a3c0482c127738b38df017064300;

/// @dev Initialization parameters for UltraVault
struct UltraVaultInitParams {
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
    // Oracle to use for pricing
    address oracle;
    // FundsHolder which will manage the assets
    address fundsHolder;
    // Exitpoint address for instant redeems
    address instantRedeemExitpoint;
}

/// @title UltraVault
/// @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
contract UltraVault is BaseControlledAsyncRedeem, IUltraVaultEvents, IUltraVaultErrors {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant ONE_YEAR = 365 * 24 * 60 * 60; // 31_536_000 seconds
    uint256 internal constant SCALE = 1e18; // Default scale
    uint64 internal constant ONE_PERCENT = uint64(SCALE) / 100;
    uint64 internal constant MAX_PERFORMANCE_FEE = 30 * ONE_PERCENT; // 30%
    uint64 internal constant MAX_MANAGEMENT_FEE = 5 * ONE_PERCENT; // 5%
    uint64 internal constant MAX_WITHDRAWAL_FEE = ONE_PERCENT; // 1%
    uint64 internal constant MAX_INSTANT_REDEEM_PREMIUM = ONE_PERCENT / 2; // 0.5%
    bytes32 internal constant FUNDS_HOLDER_KEY = keccak256("fundsHolder");
    bytes32 internal constant ORACLE_KEY = keccak256("oracle");
    bytes32 internal constant INSTANT_REDEEM_EXITPOINT_KEY = keccak256("instantRedeemExitpoint");

    ////////////////
    // Data Types //
    ////////////////

    /// @dev Vault fee storage slot
    struct FeesSlot {
        // 1st slot: 64 * 4 = 256 bits
        uint64 performanceFee;
        uint64 managementFee;
        uint64 withdrawalFee;
        uint64 lastUpdateTimestamp;
        // 2nd slot: 256 bits
        uint256 highwaterMark;
        // 3rd slot: 64 + 192 = 256 bits
        uint64 instantRedeemPremium;
        uint192 __gap;
    }

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVault
    struct UltraVaultStorage {
        address __fundsHolder; // Deprecated in V2
        IPriceSource __oracle; // Deprecated in V2
        AddressUpdateProposal __proposedFundsHolder; // Deprecated in V2
        AddressUpdateProposal __proposedOracle; // Deprecated in V2
        address feeRecipient;
        FeesSlot fees;
    }

    function _getUltraVaultStorage() private pure returns (UltraVaultStorage storage $) {
        assembly {
            $.slot := ULTRA_VAULT_STORAGE_LOCATION
        }
    }
    
    //////////
    // Init //
    //////////

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /// @param params Initialization parameters struct
    function initialize(
        UltraVaultInitParams memory params
    ) external initializer {
        require(params.feeRecipient != address(0), ZeroFeeRecipientAddress());

        _initAddress(FUNDS_HOLDER_KEY, params.fundsHolder);
        _initAddress(ORACLE_KEY, params.oracle);
        _initAddress(INSTANT_REDEEM_EXITPOINT_KEY, params.instantRedeemExitpoint);
        _pause();
        
        // Calling at the end since we need oracle to be setup
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: params.rateProvider
        }));

        _getUltraVaultStorage().feeRecipient = params.feeRecipient;
        emit FeesRecipientUpdated(address(0), params.feeRecipient);
        _setFees(params.fees);
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the funds holder address
    function fundsHolder() public view returns (address) {
        return _getCurrentAddress(FUNDS_HOLDER_KEY);
    }

    /// @notice Get the oracle address
    function oracle() public view returns (IPriceSource) {
        return IPriceSource(_getCurrentAddress(ORACLE_KEY));
    }

    /// @notice Get the instant redeem exitpoint address
    function instantRedeemExitpoint() public view returns (address) {
        return _getCurrentAddress(INSTANT_REDEEM_EXITPOINT_KEY);
    }

    /// @notice Get the proposed funds holder
    function proposedFundsHolder() external view returns (address, uint256) {
        return _getAddressUpdateProposal(FUNDS_HOLDER_KEY);
    }

    /// @notice Get the proposed oracle
    function proposedOracle() external view returns (address, uint256) {
        return _getAddressUpdateProposal(ORACLE_KEY);
    }

    /// @notice Get the proposed instant redeem exitpoint
    function proposedInstantRedeemExitpoint() external view returns (address, uint256) {
        return _getAddressUpdateProposal(INSTANT_REDEEM_EXITPOINT_KEY);
    }

    ////////////////
    // Accounting //
    ////////////////

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        return oracle().getQuote(totalSupply(), share(), asset());
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address _asset, uint256 assets, uint256) internal override {
        IERC20(_asset).safeTransfer(fundsHolder(), assets);
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address _asset, uint256 assets, uint256) internal override {
        IERC20(_asset).safeTransferFrom(fundsHolder(), address(this), assets);
    }

    ////////////////////
    // Deposit & Mint //
    ////////////////////

    /// @dev Collects fees right before making a deposit
    function _depositAsset(
        address _asset,
        uint256 assets,
        address receiver
    ) internal override returns (uint256 shares) {
        _collectFees();
        shares = super._depositAsset(_asset, assets, receiver);
    }

    /// @dev Collects fees right before performing a mint
    function _mintWithAsset(
        address _asset,
        uint256 shares,
        address receiver
    ) internal override returns (uint256 assets) {
        _collectFees();
        assets = super._mintWithAsset(_asset, shares, receiver);
    }

    ////////////////////
    // Instant Redeem //
    ////////////////////

    /// @notice Returns the available liquidity for instant redeem of a given asset
    /// @param _asset The asset address to check liquidity for
    /// @return liquidity The available liquidity (minimum of exitpoint balance and allowance to this vault)
    function getLiquidity(address _asset) public view returns (uint256 liquidity) {
        address exitpoint = instantRedeemExitpoint();
        uint256 balance = IERC20(_asset).balanceOf(exitpoint);
        uint256 allowed = IERC20(_asset).allowance(exitpoint, address(this));
        liquidity = balance < allowed ? balance : allowed;
    }

    /// @notice Returns the maximum shares a controller can instant-redeem for a given asset
    /// @dev Considers both the controller's share balance and available liquidity.
    ///      Computes max gross assets from liquidity using fee rate, converts to shares, and caps at controller balance.
    /// @param _asset The asset address to redeem for
    /// @param controller The address whose shares would be redeemed
    /// @return shares The maximum redeemable shares
    function maxInstantRedeem(
        address _asset,
        address controller
    ) external view returns (uint256 shares) {
        uint256 liquidity = getLiquidity(_asset);
        uint256 shareBalance = balanceOf(controller);
        if (liquidity == 0 || shareBalance == 0) {
            return 0;
        }
        Fees memory fees = getFees();
        uint256 instantRedeemFeeRate = fees.withdrawalFee + fees.instantRedeemPremium;
        uint256 maxGrossAssets = liquidity.mulDivDown(SCALE, SCALE - instantRedeemFeeRate);
        uint256 maxGrossUnderlyingAssets = _convertToUnderlying(_asset, maxGrossAssets);
        uint256 maxShares = convertToShares(maxGrossUnderlyingAssets);
        return maxShares < shareBalance ? maxShares : shareBalance;
    }

    /// @notice Previews the net assets a receiver would get for instant-redeeming a given number of shares
    /// @dev Converts shares to gross assets via oracle, then deducts the additive instant redeem fee
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @return assets The net asset amount after fee deduction
    function previewInstantRedeem(
        address _asset,
        uint256 shares
    ) public view returns (uint256) {
        (, , uint256 netAssets) = _previewInstantRedeem(_asset, shares);
        return netAssets;
    }

    /// @notice Instantly redeems shares for assets, bypassing the async redemption queue
    /// @dev Collects accrued fees, calculates additive fee (withdrawalFee + instantRedeemPremium),
    ///      burns shares from controller, transfers net assets to receiver, transfers fee to feeRecipient.
    ///      Reverts if insufficient liquidity in instantRedeemExitpoint.
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the net assets
    /// @param controller The address whose shares are burned
    /// @return assets The net asset amount transferred to receiver (after fee deduction)
    function instantRedeem(
        address _asset,
        uint256 shares,
        address receiver,
        address controller
    ) external checkAccess(controller) whenNotPaused returns (uint256) {
        _ensureIsSupported(_asset);
        require(shares != 0, NothingToRedeem());
        require(balanceOf(controller) >= shares, InsufficientBalance());

        // Collect accrued fees before processing (consistent with deposits and fulfillRedeem)
        _collectFees();

        // Prepare instant redeem amounts
        (uint256 grossAssets, uint256 fee, uint256 netAssets) = _previewInstantRedeem(_asset, shares);
        require(netAssets != 0, NothingToWithdraw());

        // Check liquidity
        uint256 availableLiquidity = getLiquidity(_asset);
        if (grossAssets > availableLiquidity) {
            revert InsufficientLiquidity(_asset, grossAssets, availableLiquidity);
        }

        // Burn shares from controller
        _burn(controller, shares);

        // Transfer net assets to receiver
        address exitpoint = instantRedeemExitpoint();
        IERC20(_asset).safeTransferFrom(exitpoint, receiver, netAssets);

        // Transfer fee to feeRecipient
        if (fee > 0) {
            IERC20(_asset).safeTransferFrom(exitpoint, feeRecipient(), fee);
        }

        emit InstantRedeemExecuted(controller, receiver, _asset, shares, netAssets, fee);

        return netAssets;
    }

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill redeem request
    /// @param _asset Asset
    /// @param shares Amount to redeem
    /// @param controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeem(
        address _asset,
        uint256 shares,
        address controller
    ) external override onlyRole(OPERATOR_ROLE) returns (uint256 assets) {
        // Collect fees accrued to date
        _collectFees();
        
        // Convert shares to underlying assets, then to asset units
        uint256 underlyingAssets = convertToAssets(shares);
        assets = _convertFromUnderlying(_asset, underlyingAssets);
        
        // Calculate the withdrawal incentive fee directly in asset units
        uint256 withdrawalFee = assets.mulDivDown(getFees().withdrawalFee, SCALE);

        // Fulfill request with asset units (base contract expects asset units)
        uint256 withdrawalAmount = assets - withdrawalFee;
        _fulfillRedeem(_asset, withdrawalAmount, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        // Collect withdrawal fee in asset units
        _transferWithdrawalFeeInAsset(_asset, withdrawalFee);

        // Return the amount in asset units for consistency with base contract
        return withdrawalAmount;
    }

    /// @notice Fulfill multiple redeem requests
    /// @param assets Array of assets
    /// @param shares Array of share amounts
    /// @param controllers Array of controllers
    /// @return Array of fulfilled amounts in requested asset
    /// @dev Reverts if arrays length mismatch
    /// @dev Collects withdrawal fee to incentivize manager
    function fulfillMultipleRedeems(
        address[] memory assets,
        uint256[] memory shares,
        address[] memory controllers
    ) external override onlyRole(OPERATOR_ROLE) returns (uint256[] memory) {
        // Check input length
        uint256 length = assets.length;
        require(length == shares.length && length == controllers.length, InputLengthMismatch());

        // Collect fees accrued to date
        _collectFees();

        // Prepare values for calculations
        uint256 totalShares;
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        uint256 withdrawalFeeRate = getFees().withdrawalFee;
        uint256[] memory result = new uint256[](length);
        for (uint256 i; i < length; ) {
            // Resolve redeem amount in the requested asset
            address _asset = assets[i];
            uint256 _shares = shares[i];
            address _controller = controllers[i];
            uint256 underlyingAssets = _optimizedConvertToAssets(_shares, _totalAssets, _totalSupply);
            uint256 convertedAssets = _convertFromUnderlying(_asset, underlyingAssets);

            // Calculate and transfer withdrawal fee (in asset units)
            uint256 withdrawalFee = convertedAssets.mulDivDown(withdrawalFeeRate, SCALE);
            _transferWithdrawalFeeInAsset(_asset, withdrawalFee);

            // Fulfill redeem
            uint256 assetsFulfilled = _fulfillRedeem(_asset, convertedAssets - withdrawalFee, _shares, _controller);
            result[i] = assetsFulfilled;
            totalShares += _shares;

            unchecked { ++i; }
        }

        // Burn shares
        _burn(address(this), totalShares);

        return result;
    }

    //////////////////////////
    // Funds Holder Updates //
    //////////////////////////

    /// @notice Propose fundsHolder change, can be accepted after delay
    /// @param newFundsHolder New fundsHolder address
    /// @dev changing the holder should be used only in case of multisig upgrade after funds transfer
    function proposeFundsHolder(address newFundsHolder) external onlyOwner {
        _proposeAddressUpdate(FUNDS_HOLDER_KEY, newFundsHolder);
        emit FundsHolderProposed(newFundsHolder);
    }

    /// @notice Accept proposed fundsHolder
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptFundsHolder(address newFundsHolder) external onlyOwner {
        address oldFundsHolder = _acceptAddressUpdate(FUNDS_HOLDER_KEY, newFundsHolder);
        emit FundsHolderChanged(oldFundsHolder, newFundsHolder);

        // Pause to manually check the setup by operators
        _pause();
    }

    ////////////////////
    // Oracle Updates //
    ////////////////////

    /// @notice Propose new oracle for owner acceptance after delay
    /// @param newOracle Address of the new oracle
    function proposeOracle(address newOracle) external onlyOwner {
        _proposeAddressUpdate(ORACLE_KEY, newOracle);
        emit OracleProposed(newOracle);
    }

    /// @notice Accept proposed oracle
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptProposedOracle(address newOracle) external onlyOwner {
        address oldOracle = _acceptAddressUpdate(ORACLE_KEY, newOracle);
        emit OracleUpdated(oldOracle, newOracle);

        // Pause to manually check the setup by operators
        _pause();
    }

    /////////////////////////////////////////
    // Instant Redeem Exitpoint Updates //
    /////////////////////////////////////////

    /// @notice Propose instant redeem exitpoint change, can be accepted after delay
    /// @param newExitpoint New exitpoint address
    function proposeInstantRedeemExitpoint(address newExitpoint) external onlyOwner {
        _proposeAddressUpdate(INSTANT_REDEEM_EXITPOINT_KEY, newExitpoint);
        emit InstantRedeemExitpointProposed(newExitpoint);
    }

    /// @notice Accept proposed instant redeem exitpoint
    /// @dev Pauses vault to manually check the setup by operators
    function acceptInstantRedeemExitpoint(address newExitpoint) external onlyOwner {
        address oldExitpoint = _acceptAddressUpdate(INSTANT_REDEEM_EXITPOINT_KEY, newExitpoint);
        emit InstantRedeemExitpointChanged(oldExitpoint, newExitpoint);

        // Pause to manually check the setup by operators
        _pause();
    }

    //////////
    // Fees //
    //////////

    /// @notice Get vault fee parameters
    function getFees() public view returns (Fees memory) {
        FeesSlot memory slot = _getUltraVaultStorage().fees;
        return Fees({
            performanceFee: slot.performanceFee,
            managementFee: slot.managementFee,
            withdrawalFee: slot.withdrawalFee,
            lastUpdateTimestamp: slot.lastUpdateTimestamp,
            highwaterMark: slot.highwaterMark,
            instantRedeemPremium: slot.instantRedeemPremium
        });
    }

    /// @notice Get vault fee recipient
    function feeRecipient() public view returns (address) {
        return _getUltraVaultStorage().feeRecipient;
    }

    /// @notice Get total accrued fees
    function accruedFees() external view returns (uint256 managementFee, uint256 performanceFee) {
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();
        managementFee = _calculateAccruedManagementFee(fees, totals);
        performanceFee = _calculateAccruedPerformanceFee(fees, totals);
    }

    /// @notice Get the withdrawal fee
    function calculateWithdrawalFee(uint256 assets) external view returns (uint256) {
        return assets.mulDivDown(getFees().withdrawalFee, SCALE);
    }

    /// @notice Update vault's fee recipient
    /// @param newFeeRecipient New fee recipient
    /// @dev Collects pending fees before update
    function setFeeRecipient(address newFeeRecipient) public onlyOwner whenNotPaused {
        require(newFeeRecipient != address(0), ZeroFeeRecipientAddress());
        UltraVaultStorage storage $ = _getUltraVaultStorage();

        address oldFeeRecipient = $.feeRecipient;
        if (oldFeeRecipient != newFeeRecipient) {
            _collectFees();
            $.feeRecipient = newFeeRecipient;
            emit FeesRecipientUpdated(oldFeeRecipient, newFeeRecipient);
        }
    }

    /// @notice Update vault fees
    /// @param fees New fee configuration
    /// @dev Reverts if fees exceed limits (30% performance, 5% management, 1% withdrawal)
    /// @dev Collects pending fees before update
    function setFees(Fees memory fees) public onlyOwner whenNotPaused {
        _collectFees();
        _setFees(fees);
    }

    /// @notice Mint fees as shares to recipient
    /// @dev Updates fee-related variables
    function collectFees() external onlyOwner whenNotPaused {
        _collectFees();
    }

    ////////////////////////
    // Internal functions //
    ////////////////////////

    /// @dev Struct wrapping total assets, supply and share value to optimize fee calculations
    struct Totals {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 shareValue;
    }

    function _setFees(Fees memory newFees) internal {
        // Validate fees
        require(
            newFees.performanceFee <= MAX_PERFORMANCE_FEE &&
            newFees.managementFee <= MAX_MANAGEMENT_FEE &&
            newFees.withdrawalFee <= MAX_WITHDRAWAL_FEE &&
            newFees.instantRedeemPremium <= MAX_INSTANT_REDEEM_PREMIUM,
            InvalidFees()
        );

        newFees.lastUpdateTimestamp = uint64(block.timestamp);

        Fees memory currentFees = getFees();
        if (currentFees.highwaterMark == 0) {
            newFees.highwaterMark = 10 ** IERC20Metadata(asset()).decimals();
        } else {
            newFees.highwaterMark = currentFees.highwaterMark;
        }
        _getUltraVaultStorage().fees = FeesSlot({
            performanceFee: newFees.performanceFee,
            managementFee: newFees.managementFee,
            withdrawalFee: newFees.withdrawalFee,
            lastUpdateTimestamp: newFees.lastUpdateTimestamp,
            highwaterMark: newFees.highwaterMark,
            instantRedeemPremium: newFees.instantRedeemPremium,
            __gap: 0
        });

        emit FeesUpdated(currentFees, newFees);
    }

    function _collectFees() internal {
        // Prepare inputs for calculations
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();

        // Calculate fees
        uint256 managementFee = _calculateAccruedManagementFee(fees, totals);
        uint256 performanceFee = _calculateAccruedPerformanceFee(fees, totals);
        uint256 totalFeesInAssets = managementFee + performanceFee;

        // Update highwater mark
        if (totals.shareValue > fees.highwaterMark) {
            _getUltraVaultStorage().fees.highwaterMark = totals.shareValue;
        }
        // Collect fees as shares if non-zero
        if (totalFeesInAssets > 0) {
            // Update timestamp
            _getUltraVaultStorage().fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Convert fees to shares
            uint256 feesInShares = _optimizedConvertToShares(totalFeesInAssets, totals.totalAssets, totals.totalSupply);

            // Mint shares to fee recipient
            _mint(feeRecipient(), feesInShares);

            emit FeesCollected(
                feesInShares, 
                managementFee, 
                performanceFee, 
                totals.totalAssets, 
                totals.totalSupply, 
                totals.shareValue
            );
        }
    }

    function _snapshotTotals() internal view returns (Totals memory) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        return Totals({
            totalAssets: _totalAssets,
            totalSupply: _totalSupply,
            shareValue: _optimizedConvertToAssets(10 ** decimals(), _totalAssets, _totalSupply)
        });
    }

    /// @notice Calculate accrued performance fee
    /// @return accruedPerformanceFee Fee amount in asset token
    /// @dev Based on high water mark value
    function _calculateAccruedPerformanceFee(
        Fees memory fees, 
        Totals memory totals
    ) internal view returns (uint256) {
        uint256 performanceFee = fees.performanceFee;
        if (performanceFee == 0 || totals.shareValue <= fees.highwaterMark) {
            return 0;
        }
        return performanceFee.mulDivDown(
            (totals.shareValue - fees.highwaterMark) * totals.totalSupply,
            (10 ** (18 + decimals()))
        );
    }

    /// @notice Calculate accrued management fee
    /// @return accruedManagementFee Fee amount in asset token
    /// @dev Annualized per minute, based on 525_600 minutes or 31_536_000 seconds per year
    function _calculateAccruedManagementFee(Fees memory fees, Totals memory totals) internal view returns (uint256) {
        uint256 managementFee = fees.managementFee;
        if (managementFee == 0) {
            return 0;
        }
        uint256 timePassed = block.timestamp - fees.lastUpdateTimestamp;
        return managementFee.mulDivDown(totals.totalAssets * timePassed, ONE_YEAR) / SCALE;
    }

    function _previewInstantRedeem(address _asset, uint256 shares) 
        internal 
        view 
        returns (uint256 grossAssets, uint256 fee, uint256 netAssets)
    {
        uint256 underlyingAssets = convertToAssets(shares);
        grossAssets = _convertFromUnderlying(_asset, underlyingAssets);
        fee = _calculateInstantRedeemFee(grossAssets);
        netAssets = grossAssets - fee;
    }

    /// @dev Calculate the instant redeem fee for a given gross asset amount
    /// @param grossAssets The gross asset amount before fee deduction
    /// @return fee The fee amount in assets
    function _calculateInstantRedeemFee(uint256 grossAssets) internal view returns (uint256) {
        Fees memory fees = getFees();
        uint256 instantRedeemFeeRate = fees.withdrawalFee + fees.instantRedeemPremium;
        return grossAssets.mulDivDown(instantRedeemFeeRate, SCALE);
    }

    /// @notice Transfer withdrawal fee to fee recipient
    /// @param _asset Asset to transfer
    /// @param fee Amount to transfer
    function _transferWithdrawalFeeInAsset(
        address _asset,
        uint256 fee
    ) internal {
        if (fee > 0) {
            // Transfer the fee from the fundsHolder to the fee recipient
            IERC20(_asset).safeTransferFrom(fundsHolder(), feeRecipient(), fee);
            emit WithdrawalFeeCollected(fee);
        }
    }
}
