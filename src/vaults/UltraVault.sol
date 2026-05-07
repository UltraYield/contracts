// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { IUltraVaultEvents, IUltraVaultErrors } from "src/interfaces/IUltraVault.sol";
import { Adjustment, Fees } from "src/interfaces/Types.sol";
import { AddressUpdateProposal } from "src/utils/AddressUpdates.sol";
import { ComplianceLib } from "src/utils/ComplianceLib.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "src/vaults/BaseControlledAsyncRedeem.sol";
import { COMPLIANCE_ROLE, OPERATOR_ROLE } from "src/utils/Roles.sol";

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
    // External timelocked upgrade module
    address upgradeModule;
}

/// @title UltraVault
/// @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
contract UltraVault is BaseControlledAsyncRedeem, IUltraVaultEvents, IUltraVaultErrors {
    using FixedPointMathLib for uint256;
    using Math for uint256;
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant ONE_YEAR = 365 * 24 * 60 * 60; // 31_536_000 seconds
    uint256 internal constant SCALE = 1e18; // Default scale
    // forge-lint: disable-next-line(unsafe-typecast)
    uint64 internal constant ONE_PERCENT = uint64(SCALE) / 100;
    uint64 internal constant MAX_PERFORMANCE_FEE = 30 * ONE_PERCENT; // 30%
    uint64 internal constant MAX_MANAGEMENT_FEE = 5 * ONE_PERCENT; // 5%
    uint64 internal constant MAX_WITHDRAWAL_FEE = ONE_PERCENT; // 1%
    uint64 internal constant MAX_INSTANT_REDEEM_PREMIUM = ONE_PERCENT / 2; // 0.5%

    uint256 internal constant FUNDS_HOLDER_TIMELOCK = 3 days;
    uint256 internal constant ORACLE_TIMELOCK = 3 days;
    uint256 internal constant INSTANT_REDEEM_EXITPOINT_TIMELOCK = 3 days;

    bytes32 internal constant FUNDS_HOLDER_KEY = keccak256("fundsHolder");
    bytes32 internal constant ORACLE_KEY = keccak256("oracle");
    bytes32 internal constant INSTANT_REDEEM_EXITPOINT_KEY = keccak256("instantRedeemExitpoint");

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVault
    struct UltraVaultStorage {
        address _fundsHolder; // Deprecated in V2
        IPriceSource _oracle; // Deprecated in V2
        AddressUpdateProposal _proposedFundsHolder; // Deprecated in V2
        AddressUpdateProposal _proposedOracle; // Deprecated in V2
        address feeRecipient;
        Fees fees;
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
            rateProvider: params.rateProvider,
            upgradeModule: params.upgradeModule
        }));

        _getUltraVaultStorage().feeRecipient = params.feeRecipient;
        emit FeesRecipientUpdated(address(0), params.feeRecipient);
        _setFees(params.fees);
    }

    /// @notice V1 -> V2 migration hook
    /// @dev Copies only the live V1 contract addresses into the V2 address registry
    /// @dev Pending V1 address-update proposals are intentionally not migrated
    /// @param _instantRedeemExitpoint Address for the new instant redeem exitpoint (not present in V1)
    /// @param _upgradeModule Address of the external timelocked upgrade module (not present in V1)
    function initializeV2(
        address _instantRedeemExitpoint,
        address _upgradeModule
    ) external reinitializer(2) {
        _migrateBaseControlledAsyncRedeemStateFromV1();

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        _migrateAddress(FUNDS_HOLDER_KEY, $._fundsHolder);
        _migrateAddress(ORACLE_KEY, address($._oracle));
        _initAddress(INSTANT_REDEEM_EXITPOINT_KEY, _instantRedeemExitpoint);
        _initAddress(UPGRADE_MODULE_KEY, _upgradeModule);

        _pause();
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

    ////////////////////////////
    // Initial Balances Setup //
    ////////////////////////////

    /// @notice Setup initial balances in the vault without depositing the funds
    /// @notice We expect the funds to be separately sent to funds holder
    /// @param users Array of users to setup balances
    /// @param shares Shares of respective users
    /// @dev Reverts if arrays length mismatch
    function setupInitialBalances(
        address[] memory users,
        uint256[] memory shares
    ) external onlyOwner {
        require(totalSupply() == 0, CannotSetBalancesInNonEmptyVault());
        require(users.length == shares.length, InputLengthMismatch());

        for (uint256 i; i < users.length; i++) {
            _mint(users[i], shares[i]);
        }
    }

    ////////////////
    // Accounting //
    ////////////////

    function getSharePrice() public view returns (uint256) {
        return oracle().currentSharePrice();
    }

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        uint256 totalShares = totalSupply();
        return convertToAssets(totalShares);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 sharePrice = getSharePrice();
        return _optimizedConvertToAssets(shares, sharePrice);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 sharePrice = getSharePrice();
        return _optimizedConvertToShares(assets, sharePrice);
    }

    /// @dev Optimized function for converting shares to assets.
    /// @dev Uses pre-fetched share price. Always rounds down.
    function _optimizedConvertToAssets(
        uint256 shares,
        uint256 sharePrice
    ) internal pure returns (uint256 assets) {
        return shares.mulDivDown(sharePrice, SCALE);
    }

    /// @dev Optimized function for converting assets to shares.
    /// @dev Uses pre-fetched share price. Always rounds down.
    function _optimizedConvertToShares(
        uint256 assets,
        uint256 sharePrice
    ) internal pure returns (uint256 shares) {
        return assets.mulDivDown(SCALE, sharePrice);
    }

    /// @dev Oracle-based conversion used by ERC4626 preview/deposit/mint/withdraw/redeem.
    ///      Overriding these ensures the deposit path uses the same math as the public
    ///      convertToShares/convertToAssets (oracle-driven), avoiding a virtual-offset
    ///      mispricing on first deposit when the oracle is not 1:1.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(SCALE, getSharePrice(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(getSharePrice(), SCALE, rounding);
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev Hook for executing custom logic right after deposit/mint
    /// @dev Sends deposited funds to fundsHolder
    function _afterDeposit(
        address _asset, 
        uint256 assets, 
        uint256 /* shares */,
        address /* receiver */
    ) internal override {
        _ensureNotRestricted(msg.sender);
        IERC20(_asset).safeTransfer(fundsHolder(), assets);
    }

    /// @dev Hook for executing custom logic right before withdraw/redeem
    /// @dev Enforces compliance restrictions on receiver and controller
    function _beforeWithdraw(
        address /* _asset */, 
        uint256 /* assets */, 
        uint256 /* shares */,
        address receiver,
        address controller
    ) internal view override {
        _ensureNotRestricted(receiver);
        if (controller != receiver) _ensureNotRestricted(controller);
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function _beforeFulfillRedeem(address _asset, uint256 assets, uint256) internal override {
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

    /// @dev Block restricted addresses from cancelling pending redeems
    /// @dev Receiver is gated by `_update` on the share transfer back from the vault.
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal override {
        _ensureNotRestricted(controller);
        super._handleRedeemRequestCancelation(_asset, shares, controller, receiver);
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
    ///      Liquidity bounds the gross payout (netAssets + fee are both pulled from the exitpoint),
    ///      so the shares are derived from liquidity directly and capped at controller balance.
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
        uint256 maxUnderlyingAssets = convertToUnderlying(_asset, liquidity, Adjustment.UP);
        uint256 maxShares = convertToShares(maxUnderlyingAssets);
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
    ///      Reverts with InstantRedeemSlippageExceeded if netAssets < minAssets.
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @param minAssets Minimum net assets the receiver must receive; reverts InstantRedeemSlippageExceeded if not met. Pass 0 to disable.
    /// @param receiver The address to receive the net assets
    /// @param controller The address whose shares are burned
    /// @return assets The net asset amount transferred to receiver (after fee deduction)
    function instantRedeem(
        address _asset,
        uint256 shares,
        uint256 minAssets,
        address receiver,
        address controller
    ) external checkAccess(controller) whenNotPaused returns (uint256) {
        _ensureIsSupported(_asset);
        _ensureNotRestricted(receiver);
        if (controller != receiver) {
            _ensureNotRestricted(controller);
        }
        require(shares != 0, NothingToRedeem());
        require(balanceOf(controller) >= shares, InsufficientBalance());

        // Collect accrued fees before processing (consistent with deposits and fulfillRedeem)
        _collectFees();

        // Prepare instant redeem amounts
        (uint256 grossAssets, uint256 fee, uint256 netAssets) = _previewInstantRedeem(_asset, shares);
        require(netAssets != 0, NothingToWithdraw());

        // Slippage protection — bound caller's worst-case received amount
        if (netAssets < minAssets) {
            revert InstantRedeemSlippageExceeded(netAssets, minAssets);
        }

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

        // Standard ERC-4626 event so generic indexers can track instant-redeem flows
        emit Withdraw(msg.sender, receiver, controller, netAssets, shares);
        emit InstantRedeem(controller, receiver, _asset, shares, netAssets, fee);

        return netAssets;
    }

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

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
        uint256 sharePrice = getSharePrice();
        uint256 withdrawalFeeRate = getFees().withdrawalFee;
        uint256[] memory result = new uint256[](length);
        for (uint256 i; i < length; ) {
            // Resolve redeem amount in the requested asset
            address _asset = assets[i];
            uint256 _shares = shares[i];
            address _controller = controllers[i];
            uint256 underlyingAssets = _optimizedConvertToAssets(_shares, sharePrice);
            uint256 convertedAssets = convertFromUnderlying(_asset, underlyingAssets, Adjustment.DOWN);

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
        address oldFundsHolder = _acceptAddressUpdate(FUNDS_HOLDER_KEY, newFundsHolder, FUNDS_HOLDER_TIMELOCK);
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
        address oldOracle = _acceptAddressUpdate(ORACLE_KEY, newOracle, ORACLE_TIMELOCK);
        emit OracleUpdated(oldOracle, newOracle);

        // Pause to manually check the setup by operators
        _pause();
    }

    //////////////////////////////////////
    // Instant Redeem Exitpoint Updates //
    //////////////////////////////////////

    /// @notice Propose instant redeem exitpoint change, can be accepted after delay
    /// @param newExitpoint New exitpoint address
    function proposeInstantRedeemExitpoint(address newExitpoint) external onlyOwner {
        _proposeAddressUpdate(INSTANT_REDEEM_EXITPOINT_KEY, newExitpoint);
        emit InstantRedeemExitpointProposed(newExitpoint);
    }

    /// @notice Accept proposed instant redeem exitpoint
    /// @dev Pauses vault to manually check the setup by operators
    function acceptInstantRedeemExitpoint(address newExitpoint) external onlyOwner {
        address oldExitpoint = _acceptAddressUpdate(
            INSTANT_REDEEM_EXITPOINT_KEY, 
            newExitpoint, 
            INSTANT_REDEEM_EXITPOINT_TIMELOCK
        );
        emit InstantRedeemExitpointChanged(oldExitpoint, newExitpoint);

        // Pause to manually check the setup by operators
        _pause();
    }

    //////////
    // Fees //
    //////////

    /// @notice Get vault fee parameters
    function getFees() public view returns (Fees memory) {
        return _getUltraVaultStorage().fees;
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

    ////////////////
    // Compliance //
    ////////////////

    /// @notice Get blocklist and freeze status for `account`
    /// @return blocked True if `account` is blocklisted
    /// @return frozen True if `account` is frozen
    function restrictionStatus(address account) external view returns (bool blocked, bool frozen) {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        blocked = $.blocklisted[account];
        frozen = $.frozen[account];
    }

    /// @notice Add `account` to the blocklist
    function blocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.blocklist(account);
    }

    /// @notice Remove `account` from the blocklist
    function unblocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unblocklist(account);
    }

    /// @notice Mark `account` as frozen
    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freeze(account);
    }

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unfreeze(account);
    }

    /// @notice Burn `amount` shares from `target`'s wallet balance.
    /// @dev Only affects `balanceOf(target)`; pending and claimable redeems are untouched.
    function forceBurn(address target, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        _burn(target, amount);
        emit ForceBurned(target, amount);
    }

    /// @dev Reverts if `account` is blocklisted or frozen.
    /// @dev Returns early on `address(0)` so callers don't need to special-case mints/burns.
    function _ensureNotRestricted(address account) internal view {
        if (account == address(0)) return;
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        if ($.blocklisted[account]) revert AddressBlocklisted(account);
        if ($.frozen[account]) revert AddressFrozen(account);
    }

    /// @dev Gates share transfers and mints. 
    /// @dev Burns (`to == 0`) skip the from-side check so `forceBurn` can destroy a restricted address's shares.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _ensureNotRestricted(from);
        }
        _ensureNotRestricted(to);
        super._update(from, to, value);
    }

    ////////////////////////
    // Internal functions //
    ////////////////////////

    /// @dev Struct wrapping total assets, supply and share value to optimize fee calculations
    struct Totals {
        uint256 totalAssets;
        uint256 totalShares;
        uint256 sharePrice;
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
            newFees.highwaterMark = 10 ** decimals();
        } else {
            newFees.highwaterMark = currentFees.highwaterMark;
        }
        _getUltraVaultStorage().fees = newFees;

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
        if (totals.sharePrice > fees.highwaterMark) {
            _getUltraVaultStorage().fees.highwaterMark = totals.sharePrice;
        }
        // Collect fees as shares if non-zero
        if (totalFeesInAssets > 0) {
            // Update timestamp
            _getUltraVaultStorage().fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Convert fees to shares
            uint256 feesInShares = _optimizedConvertToShares(totalFeesInAssets, totals.sharePrice);

            // Mint shares to fee recipient
            _mint(feeRecipient(), feesInShares);

            emit FeesCollected(
                feesInShares, 
                managementFee, 
                performanceFee, 
                totals.totalAssets, 
                totals.totalShares, 
                totals.sharePrice
            );
        }
    }

    function _snapshotTotals() internal view returns (Totals memory) {
        uint256 sharePrice = getSharePrice();
        uint256 totalShares = totalSupply();
        return Totals({
            totalAssets: _optimizedConvertToAssets(totalShares, sharePrice),
            totalShares: totalShares,
            sharePrice: sharePrice
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
        if (performanceFee == 0 || totals.sharePrice <= fees.highwaterMark) {
            return 0;
        }
        return performanceFee.mulDivDown(
            (totals.sharePrice - fees.highwaterMark) * totals.totalShares,
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
        grossAssets = convertFromUnderlying(_asset, underlyingAssets, Adjustment.DOWN);
        Fees memory fees = getFees();
        fee = grossAssets.mulDivDown(fees.withdrawalFee + fees.instantRedeemPremium, SCALE);
        netAssets = grossAssets - fee;
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
