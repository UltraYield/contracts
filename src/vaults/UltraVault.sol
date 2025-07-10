// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AsyncVault, Fees } from "./AsyncVault.sol";
import { PendingRedeem, ClaimableRedeem } from "./BaseControlledAsyncRedeem.sol";
import { AddressUpdateProposal } from "../utils/AddressUpdates.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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

    event Referral(address indexed referrer, address user);

    // Update errors
    error InvalidFundsHolder();
    error NoPendingFundsHolderUpdate();
    error CanNotAcceptFundsHolderYet();
    error FundsHolderUpdateExpired();
    error MissingOracle();
    error NoOracleProposed();
    error CanNotAcceptOracleYet();
    error OracleUpdateExpired();

    // Misc errors
    error CantSetBalancesInNonEmptyVault();

    address public fundsHolder;

    IPriceSource public oracle;

    // Referrals
    mapping(address => address) public referredBy;

    // Updates
    AddressUpdateProposal public proposedFundsHolder;
    AddressUpdateProposal public proposedOracle;

    // V0: 7 total: 1 - funds holder, 1 - oracle, 
    // 2 + 2 - funds and oracle proposals, 1 - referral mapping
    uint256[43] private __gap;

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
        address _rateProvider,
        address _requestQueue,
        address _feeRecipient,
        Fees memory _fees,
        address _oracle,
        address _fundsHolder
    ) external initializer {
        if (_fundsHolder == address(0) || _oracle == address(0))
            revert Misconfigured();

        fundsHolder = _fundsHolder;
        oracle = IPriceSource(_oracle);
        

        _pause();
        
        // Calling at the very end since we need oracle to be setup
        super.initialize(_owner, _asset, _name, _symbol, _rateProvider, _requestQueue, _feeRecipient, _fees);
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
    /// @dev "assets" will already be correct given the token user requested
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
                            UUPS UPGRADABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice UUPS Upgradable access authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
