// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AsyncVault, Fees } from "./AsyncVault.sol";
import { PendingRedeem, ClaimableRedeem } from "./BaseControlledAsyncRedeem.sol";
import { FixedPointMathLib } from "../utils/FixedPointMathLib.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IUltraVaultRateProvider, AssetData } from "../interfaces/IUltraVaultRateProvider.sol";

struct AddressUpdateProposal {
    address addr;
    uint256 timestamp;
}

/**
 * @title UltraVault
 * @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
 */
contract UltraVault is AsyncVault, UUPSUpgradeable {

    // Events
    event FundsHolderProposed(address indexed proposedFundsHolder);
    event FundsHolderChanged(address indexed oldFundsHolder, address indexed newFundsHolder);

    event OracleProposed(address indexed proposedOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    event RateProviderProposed(address indexed proposedProvider);
    event RateProviderUpdated(address indexed oldProvider, address indexed newProvider);

    event Referral(address indexed referrer, address user);

    // Update errors
    error InvalidFundsHolder();
    error NoPendingFundsHolderUpdate();
    error CanNotAcceptFundsHolderYet();
    error FundsHolderUpdateExpired();
    error MissingOracle();
    error MissingRateProvider();
    error NoOracleProposed();
    error NoRateProviderProposed();
    error CanNotAcceptOracleYet();
    error CanNotAcceptRateProviderYet();
    error OracleUpdateExpired();
    error RateProviderUpdateExpired();

    // Misc errors
    error CantSetBalancesInNonEmptyVault();
    error AssetNotSupported();

    address public fundsHolder;

    IPriceSource public oracle;

    // Referrals
    mapping(address => address) public referredBy;

    // Updates
    AddressUpdateProposal public proposedFundsHolder;
    AddressUpdateProposal public proposedOracle;
    AddressUpdateProposal public proposedRateProvider;

    // Rate provider
    IUltraVaultRateProvider public rateProvider;

    // V0: 7 total: 1 - funds holder, 1 - oracle, 
    // 2 + 2 - funds and oracle proposals, 1 - referral mapping
    // V1: 8 total, +1: rateProvider
    uint256[42] private __gap;

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer for the UltraVault, initially paused
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _feeRecipient Fee recipient
     * @param _fees Fee on the vault
     * @param _oracle The oracle to use for pricing
     * @param _fundsHolder The fundsHolder which will manage the assets
     */
    function initialize(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _requestQueue,
        address _feeRecipient,
        Fees memory _fees,
        address _oracle,
        address _fundsHolder,
        address _rateProvider
    ) external initializer {
        if (_fundsHolder == address(0) || _oracle == address(0))
            revert Misconfigured();

        fundsHolder = _fundsHolder;
        oracle = IPriceSource(_oracle);
        rateProvider = IUltraVaultRateProvider(_rateProvider);

        _pause();
        
        // Calling at the very end since we need oracle to be setup
        super.initialize(_owner, _asset, _name, _symbol, _requestQueue, _feeRecipient, _fees);
    }

    /*//////////////////////////////////////////////////////////////
                        REFERRALS LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to deposit assets for msg.sender upon referral
     * @param assets Amount to deposit
     * @return shares Amount of shares received
     */
    function referDeposit(
        uint256 assets, 
        address referrer
    ) external returns (uint256) {
        if (referredBy[msg.sender] == address(0)) {
            referredBy[msg.sender] = referrer;
            emit Referral(referrer, msg.sender);
        }
        return deposit(assets, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIAL BALANCES SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Setup initial balances in the vault without depositing the funds
     * @notice We expect the funds to be separately sent to funds holder
     * @param users Array of users to setup balances
     * @param shares Shares of respective users
     * @dev Reverts if arrays length mismatch
     */
    function setupInitialBalances(
        address[] memory users,
        uint256[] memory shares
    ) external onlyOwner {
        if (totalSupply() > 0)
            revert CantSetBalancesInNonEmptyVault();
        if (users.length != shares.length) 
            revert Misconfigured();

        for (uint256 i; i < users.length; i++) {
            _mint(users[i], shares[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        return oracle.getQuote(totalSupply(), share(), asset());
    }

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
                            ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address asset, uint256 assets, uint256) internal override {
        // Funds are sent to holder
        SafeERC20.safeTransfer(IERC20(asset), fundsHolder, assets);
    }

    /*//////////////////////////////////////////////////////////////
                    BaseControlledAsyncRedeem OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    function beforeFulfillRedeem(address asset, uint256 assets, uint256) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset), fundsHolder, address(this), assets);
    }

    /*//////////////////////////////////////////////////////////////
                        AsyncVault OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AsyncVault
    function collectWithdrawalFeeInAsset(
        address asset,
        uint256 fee
    ) internal override {
        if (fee > 0) {
            // Transfer the fee from the fundsHolder to the fee recipient
            SafeERC20.safeTransferFrom(IERC20(asset), fundsHolder, feeRecipient, fee);
            emit WithdrawalFeeCollected(fee);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDS HOLDER UPDATES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Propose fundsHolder change, can be accepted after delay
     * @param newFundsHolder New fundsHolder address
     * @dev changing the holder should be used only in case of multisig upgrade after funds transfer
     */
    function proposeFundsHolder(address newFundsHolder) external onlyOwner {
        if (newFundsHolder == address(0))
            revert InvalidFundsHolder();

        proposedFundsHolder = AddressUpdateProposal({
            addr: newFundsHolder,
            timestamp: block.timestamp
        });

        emit FundsHolderProposed(newFundsHolder);
    }

    /**
     * @notice Accept proposed fundsHolder
     * @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
     * @dev Oracle must be switched before unpausing
     */
    function acceptFundsHolder() external onlyOwner {
        AddressUpdateProposal memory proposal = proposedFundsHolder;

        if (proposal.addr == address(0))
            revert NoPendingFundsHolderUpdate();
        if (block.timestamp < proposal.timestamp + 3 days)
            revert CanNotAcceptFundsHolderYet();
        if (block.timestamp > proposal.timestamp + 7 days)
            revert FundsHolderUpdateExpired();

        emit FundsHolderChanged(fundsHolder, proposal.addr);

        fundsHolder = proposal.addr;

        delete proposedFundsHolder;

        // Pause to manually check the setup by operators
        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE UPDATES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Propose new oracle for owner acceptance after delay
     * @param newOracle Address of the new oracle
     */
    function proposeOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0))
            revert MissingOracle();

        proposedOracle = AddressUpdateProposal({
            addr: newOracle,
            timestamp: block.timestamp
        });

        emit OracleProposed(newOracle);
    }

    /**
     * @notice Accept proposed oracle
     * @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
     * @dev Oracle must be switched before unpausing
     */
    function acceptProposedOracle() external onlyOwner {
        AddressUpdateProposal memory proposal = proposedOracle;

        if (proposal.addr == address(0))
            revert NoOracleProposed();
        if (block.timestamp < proposal.timestamp + 3 days)
            revert CanNotAcceptOracleYet();
        if (block.timestamp > proposal.timestamp + 7 days)
            revert OracleUpdateExpired();

        emit OracleUpdated(address(oracle), proposal.addr);

        oracle = IPriceSource(proposal.addr);

        delete proposedOracle;

        // Pause to manually check the setup by operators
        _pause();
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
                            MULTI-ASSET LOGIC
    //////////////////////////////////////////////////////////////*/

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
    function getClaimableRedeemForAsset(
        address asset,
        address controller
    ) public view returns (ClaimableRedeem memory) {
        return requestQueue.getClaimableRedeem(controller, address(this), asset);
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
    ) public virtual {
        return _cancelRedeemRequestOfAsset(asset, controller, receiver);
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

    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice UUPS Upgradable access authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
