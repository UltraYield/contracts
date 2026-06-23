// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IComplianceEvents } from "src/interfaces/ICompliance.sol";
import { IAllowlistEvents } from "src/interfaces/IAllowlist.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.Compliance")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant COMPLIANCE_STORAGE_LOCATION = 0xbe508e3cf19f76c02ce3ef084fcdeeaf41d8436cf97d44f5a26356dbb6809600;

/// @title ComplianceLib
/// @notice External library for access-restriction state mutations and reads.
/// @notice Holds both the freeze exclusion control and the deposit allowlist. The ERC-7201
///         namespace string stays `ultrayield.storage.Compliance` so the layout is canonical and
///         shared across vault variants (and upgrade-safe for existing compliance deployments).
/// @dev Public functions are deployed separately and called via DELEGATECALL.
library ComplianceLib {
    /// @custom:storage-location erc7201:ultrayield.storage.Compliance
    /// @dev Allowlist fields are APPENDED after the original freeze member; never reorder.
    struct Storage {
        mapping(address => bool) frozen;
        mapping(address => bool) allowlisted;
        bool allowlistDisabled; // allowlist enforcement ON by default
    }

    function _getComplianceStorage() internal pure returns (Storage storage $) {
        assembly {
            $.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }

    ////////////
    // Freeze //
    ////////////

    function freeze(address account) external {
        _freeze(account);
    }

    function freezeBatch(address[] calldata accounts) external {
        for (uint256 i; i < accounts.length; i++) {
            _freeze(accounts[i]);
        }
    }

    function unfreeze(address account) external {
        Storage storage $ = _getComplianceStorage();
        if ($.frozen[account]) {
            $.frozen[account] = false;
            emit IComplianceEvents.AccountUnfrozen(account);
        }
    }

    /// @dev Idempotent freeze — only writes/emits on an actual state change
    function _freeze(address account) private {
        Storage storage $ = _getComplianceStorage();
        if (!$.frozen[account]) {
            $.frozen[account] = true;
            emit IComplianceEvents.AccountFrozen(account);
        }
    }

    ///////////////
    // Allowlist //
    ///////////////

    function addToAllowlist(address account) external {
        _addToAllowlist(account);
    }

    function addToAllowlistBatch(address[] calldata accounts) external {
        for (uint256 i; i < accounts.length; i++) {
            _addToAllowlist(accounts[i]);
        }
    }

    function removeFromAllowlist(address account) external {
        Storage storage $ = _getComplianceStorage();
        if ($.allowlisted[account]) {
            $.allowlisted[account] = false;
            emit IAllowlistEvents.AccountDisallowed(account);
        }
    }

    /// @dev Idempotent add — only writes/emits on an actual state change
    function _addToAllowlist(address account) private {
        Storage storage $ = _getComplianceStorage();
        if (!$.allowlisted[account]) {
            $.allowlisted[account] = true;
            emit IAllowlistEvents.AccountAllowed(account);
        }
    }
}
