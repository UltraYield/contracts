// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IAddressUpdatableErrors } from "src/interfaces/IAddressUpdatableErrors.sol";

/// @notice Struct for storing address update proposals
struct AddressUpdateProposal {
    address addr;
    uint96 timestamp;
}

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.AddressUpdatable")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ADDRESS_UPDATABLE_STORAGE_LOCATION = 0x4673da7a97aaf39a4c390d00b735c3d8e54e5cd24960b29bc2ba4020399fc300;

abstract contract AddressUpdatable is IAddressUpdatableErrors {
    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant ADDRESS_UPDATE_TIMELOCK = 3 days;
    uint256 internal constant MAX_ADDRESS_UPDATE_WAIT = 7 days;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.AddressUpdatable
    struct AddressUpdatableStorage {
        mapping(bytes32 => address) addresses;
        mapping(bytes32 => AddressUpdateProposal) proposals;
    }

    function _getStorage() internal pure returns (AddressUpdatableStorage storage $) {
        assembly {
            $.slot := ADDRESS_UPDATABLE_STORAGE_LOCATION
        }
    }

    ////////////////////
    // Read Functions //
    ////////////////////

    /// @notice Get the current address for a given key
    /// @param key The key to get the address for
    /// @return The address for the given key
    function _getCurrentAddress(bytes32 key) internal view returns (address) {
        return _getStorage().addresses[key];
    }

    /// @notice Get the address update proposal for a given key
    /// @param key The key to get the proposal for
    /// @return The proposed address and proposal timestamp
    function _getAddressUpdateProposal(bytes32 key) internal view returns (address, uint256) {
        AddressUpdateProposal storage proposal = _getStorage().proposals[key];
        return (proposal.addr, proposal.timestamp);
    }

    /////////////////////
    // Write Functions //
    /////////////////////

    function _initAddress(bytes32 key, address addr) internal {
        AddressUpdatableStorage storage $ = _getStorage();
        require(addr != address(0), ZeroAddressInput());
        require($.addresses[key] == address(0), AddressAlreadyInitialized());
        $.addresses[key] = addr;
    }

    /// @notice Migrate a legacy address into the shared address-update storage
    /// @dev Only writes into empty destination slots, so it is safe to call during V1 -> V2 migration
    function _migrateAddress(bytes32 key, address addr) internal {
        AddressUpdatableStorage storage $ = _getStorage();

        if ($.addresses[key] == address(0) && addr != address(0)) {
            $.addresses[key] = addr;
        }
    }

    /// @notice Propose an address update for a given key
    /// @param key The key to propose the update for
    /// @param newAddress The new address to propose
    /// @dev The new address must not be the zero address
    function _proposeAddressUpdate(bytes32 key, address newAddress) internal {
        require(newAddress != address(0), ZeroAddressInput());
        _getStorage().proposals[key] = AddressUpdateProposal({
            addr: newAddress,
            timestamp: uint96(block.timestamp)
        });
    }

    /// @notice Accept an addressupdate for a given key
    /// @param key The key to accept the update for
    /// @param newAddress The new address to accept
    /// @return oldAddress The old address for the given key
    /// @dev The new address must match the proposed address
    /// @dev The proposal must be accepted within the timelock period
    /// @dev The proposal must not have expired
    function _acceptAddressUpdate(bytes32 key, address newAddress) internal returns (address oldAddress) {
        AddressUpdatableStorage storage $ = _getStorage();
        AddressUpdateProposal storage proposal = $.proposals[key];
        
        // Validate proposal
        require(proposal.addr != address(0), NoPendingUpdateProposal());
        require(proposal.addr == newAddress, UpdateProposalAddressMismatch());
        require(block.timestamp >= proposal.timestamp + ADDRESS_UPDATE_TIMELOCK, CannotAcceptProposalYet());
        require(block.timestamp <= proposal.timestamp + MAX_ADDRESS_UPDATE_WAIT, UpdateProposalExpired());

        // Update address
        oldAddress = $.addresses[key];
        $.addresses[key] = newAddress;
        delete $.proposals[key];
    }
}
