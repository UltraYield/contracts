// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AsyncVault, Fees } from "./AsyncVault.sol";
import { PendingRedeem, ClaimableRedeem } from "./BaseControlledAsyncRedeem.sol";
import { AddressUpdateProposal } from "../utils/AddressUpdates.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraVault")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_VAULT_STORAGE_LOCATION = 0x4a2c313ed01a3f9b3ba2e7d99f5ac7985ad5a3c0482c127738b38df017064300;

/// @notice Initialization parameters for UltraVault
/// @param _owner Owner of the vault
/// @param _asset Underlying asset address
/// @param _name Vault name
/// @param _symbol Vault symbol
/// @param _rateProvider oracle for assets exchange rate
/// @param _requestQueue withdrawal request queue
/// @param _feeRecipient Fee recipient
/// @param _fees Fee on the vault
/// @param _oracle The oracle to use for pricing
/// @param _fundsHolder The fundsHolder which will manage the assets
struct UltraVaultInitParams {
    address owner;
    address asset;
    string name;
    string symbol;
    address rateProvider;
    address requestQueue;
    address feeRecipient;
    Fees fees;
    address oracle;
    address fundsHolder;
}

/// @title UltraVault
/// @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
contract UltraVault is AsyncVault, UUPSUpgradeable {
    ////////////
    // Events //
    ////////////

    event FundsHolderProposed(address indexed proposedFundsHolder);
    event FundsHolderChanged(address indexed oldFundsHolder, address indexed newFundsHolder);
    event OracleProposed(address indexed proposedOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event Referral(string indexed referralId, address user, uint256 shares);

    ////////////
    // Errors //
    ////////////

    error InvalidFundsHolder();
    error NoPendingFundsHolderUpdate();
    error CanNotAcceptFundsHolderYet();
    error FundsHolderUpdateExpired();
    error MissingOracle();
    error NoOracleProposed();
    error CanNotAcceptOracleYet();
    error OracleUpdateExpired();
    error CantSetBalancesInNonEmptyVault();

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVault
    struct UltraVaultStorage {
        address fundsHolder;
        IPriceSource oracle;
        AddressUpdateProposal proposedFundsHolder;
        AddressUpdateProposal proposedOracle;
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
        UltraVaultInitParams calldata params
    ) external initializer {
        require(params.fundsHolder != address(0) && params.oracle != address(0), Misconfigured());

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.fundsHolder = params.fundsHolder;
        $.oracle = IPriceSource(params.oracle);
        _pause();
        
        // Calling at the very end since we need oracle to be setup
        super.initialize(
            params.owner,
            params.asset,
            params.name,
            params.symbol,
            params.rateProvider,
            params.requestQueue,
            params.feeRecipient,
            params.fees
        );
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the funds holder address
    function fundsHolder() public view returns (address) {
        return _getUltraVaultStorage().fundsHolder;
    }

    /// @notice Get the oracle address
    function oracle() public view returns (IPriceSource) {
        return _getUltraVaultStorage().oracle;
    }

    /// @notice Get the proposed funds holder
    function proposedFundsHolder() public view returns (address, uint256) {
        AddressUpdateProposal memory proposal = _getUltraVaultStorage().proposedFundsHolder;
        return (proposal.addr, proposal.timestamp);
    }

    /// @notice Get the proposed oracle
    function proposedOracle() public view returns (address, uint256) {
        AddressUpdateProposal memory proposal = _getUltraVaultStorage().proposedOracle;
        return (proposal.addr, proposal.timestamp);
    }

    ///////////////
    // Referrals //
    ///////////////

    /// @notice Helper to deposit assets for msg.sender upon referral
    /// @param assets Amount to deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function deposit(
        uint256 assets,
        string calldata referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset(), assets, msg.sender, referralId);
    }

    /// @notice Helper to deposit assets for msg.sender upon referral specifying receiver
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function deposit(
        uint256 assets,
        address receiver,
        string calldata referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset(), assets, receiver, referralId);
    }

    /// @notice Helper to deposit particular asset for msg.sender upon referral
    /// @param asset Asset to deposit
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositAsset(
        address asset,
        uint256 assets,
        address receiver,
        string calldata referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset, assets, receiver, referralId);
    }

    /// @notice Internal helper to deposit assets for msg.sender upon referral
    /// @param asset Asset to deposit
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function _depositAssetWithReferral(
        address asset,
        uint256 assets,
        address receiver,
        string calldata referralId
    ) internal returns (uint256 shares) {
        shares = _depositAsset(asset, assets, receiver);
        emit Referral(referralId, msg.sender, shares);
        return shares;
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
        require(totalSupply() == 0, CantSetBalancesInNonEmptyVault());
        require(users.length == shares.length, Misconfigured());

        for (uint256 i; i < users.length; i++) {
            _mint(users[i], shares[i]);
        }
    }

    ////////////////
    // Accounting //
    ////////////////

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        return oracle().getQuote(totalSupply(), share(), asset());
    }

    ////////////////////////
    // ERC-4626 Overrides //
    ////////////////////////

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address asset, uint256 assets, uint256) internal override {
        // Funds are sent to holder
        SafeERC20.safeTransfer(IERC20(asset), fundsHolder(), assets);
    }

    /////////////////////////////////////////
    // BaseControlledAsyncRedeem Overrides //
    /////////////////////////////////////////

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address asset, uint256 assets, uint256) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset), fundsHolder(), address(this), assets);
    }

    //////////////////////////
    // AsyncVault Overrides //
    //////////////////////////

    /// @inheritdoc AsyncVault
    function collectWithdrawalFeeInAsset(
        address asset,
        uint256 fee
    ) internal override {
        if (fee > 0) {
            // Transfer the fee from the fundsHolder to the fee recipient
            SafeERC20.safeTransferFrom(IERC20(asset), fundsHolder(), super.feeRecipient(), fee);
            emit WithdrawalFeeCollected(fee);
        }
    }

    //////////////////////////
    // Funds Holder Updates //
    //////////////////////////

    /// @notice Propose fundsHolder change, can be accepted after delay
    /// @param newFundsHolder New fundsHolder address
    /// @dev changing the holder should be used only in case of multisig upgrade after funds transfer
    function proposeFundsHolder(address newFundsHolder) external onlyOwner {
        require(newFundsHolder != address(0), InvalidFundsHolder());

        _getUltraVaultStorage().proposedFundsHolder = AddressUpdateProposal({
            addr: newFundsHolder,
            timestamp: block.timestamp
        });

        emit FundsHolderProposed(newFundsHolder);
    }

    /// @notice Accept proposed fundsHolder
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptFundsHolder() external onlyOwner {
        (address proposedHolder, uint256 proposalTimestamp) = proposedFundsHolder();

        require(proposedHolder != address(0), NoPendingFundsHolderUpdate());
        require(block.timestamp >= proposalTimestamp + ADDRESS_UPDATE_TIMELOCK, CanNotAcceptFundsHolderYet());
        require(block.timestamp <= proposalTimestamp + MAX_ADDRESS_UPDATE_WAIT, FundsHolderUpdateExpired());

        emit FundsHolderChanged(fundsHolder(), proposedHolder);

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.fundsHolder = proposedHolder;
        delete $.proposedFundsHolder;

        // Pause to manually check the setup by operators
        _pause();
    }

    ////////////////////
    // Oracle Updates //
    ////////////////////

    /// @notice Propose new oracle for owner acceptance after delay
    /// @param newOracle Address of the new oracle
    function proposeOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), MissingOracle());

        _getUltraVaultStorage().proposedOracle = AddressUpdateProposal({
            addr: newOracle,
            timestamp: block.timestamp
        });

        emit OracleProposed(newOracle);
    }

    /// @notice Accept proposed oracle
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptProposedOracle() external onlyOwner {
        (address newOracle, uint256 proposalTimestamp) = proposedOracle();

        require(newOracle != address(0), NoOracleProposed());
        require(block.timestamp >= proposalTimestamp + ADDRESS_UPDATE_TIMELOCK, CanNotAcceptOracleYet());
        require(block.timestamp <= proposalTimestamp + MAX_ADDRESS_UPDATE_WAIT, OracleUpdateExpired());

        emit OracleUpdated(address(oracle()), newOracle);

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.oracle = IPriceSource(newOracle);
        delete $.proposedOracle;

        // Pause to manually check the setup by operators
        _pause();
    }

    /////////////////////
    // UUPS Upgradable //
    /////////////////////

    /// @notice UUPS Upgradable access authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
