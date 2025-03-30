// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { AsyncVault, Limits, Fees } from "./AsyncVault.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";

struct AddressUpdateProposal {
    address addr;
    uint256 timestamp;
}

/**
 * @title UltraVault
 * @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management

 */
contract UltraVault is AsyncVault {

    // Events
    event FundsHolderProposed(address indexed proposedFundsHolder);
    event FundsHolderChanged(address indexed oldFundsHolder, address indexed newFundsHolder);

    event OracleProposed(address indexed proposedOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // Errors
    error InvalidFundsHolder();
    error NoPendingFundsHolderUpdate();
    error CanNotAcceptFundsHolderYet();
    error MissingOracle();
    error NoOracleProposed();
    error CanNotAcceptOracleYet();

    address public fundsHolder;

    IPriceSource public oracle;

    // Updates
    AddressUpdateProposal public proposedFundsHolder;
    AddressUpdateProposal public proposedOracle;

    /**
     * @notice Constructor for the UltraVault
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _feeRecipient Fee recipient
     * @param _fees Fee on the vault
     * @param _limits Limits for deposits
     * @param _oracle The oracle to use for pricing
     * @param _fundsHolder The fundsHolder which will manage the assets
     */
    constructor(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        Fees memory _fees,
        Limits memory _limits,
        address _oracle,
        address _fundsHolder
    ) AsyncVault(_owner, _asset, _name, _symbol, _feeRecipient, _fees, _limits) {
        if (_fundsHolder == address(0) || _oracle == address(0))
            revert Misconfigured();

        fundsHolder = _fundsHolder;
        oracle = IPriceSource(_oracle);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        return oracle.getQuote(totalSupply, share, address(asset));
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(uint256 assets, uint256) internal override {
        _collectFees();

        // Funds are sent to holder
        SafeTransferLib.safeTransfer(asset, fundsHolder, assets);
    }

    /*//////////////////////////////////////////////////////////////
                    BaseControlledAsyncRedeem OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    function beforeFulfillRedeem(uint256 assets, uint256) internal override {
        SafeTransferLib.safeTransferFrom(asset, fundsHolder, address(this), assets);
    }

    /*//////////////////////////////////////////////////////////////
                    AsyncVault OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AsyncVault
    function collectWithdrawalFee(
        uint256 fee
    ) internal override {
        if (fee > 0)
            // Transfer the fee from the fundsHolder to the fee recipient
            SafeTransferLib.safeTransferFrom(asset, fundsHolder, feeRecipient, fee);
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
        if (proposal.timestamp + 3 days > block.timestamp)
            revert CanNotAcceptFundsHolderYet();

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
        if (proposal.timestamp + 3 days > block.timestamp)
            revert CanNotAcceptOracleYet();

        emit OracleUpdated(address(oracle), proposal.addr);

        oracle = IPriceSource(proposal.addr);

        delete proposedOracle;

        // Pause to manually check the setup by operators
        _pause();
    }
}
