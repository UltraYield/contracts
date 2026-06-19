// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IComplianceEvents {
    event AccountBlocked(address indexed account);
    event AccountUnblocked(address indexed account);
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);
    event ForceBurned(address indexed account, uint256 amount);
}

interface IComplianceErrors {
    error AddressBlocklisted(address account);
    error AddressFrozen(address account);
}

/// @title ICompliance
/// @notice External interface for the per-address blocklist/freeze controls and forceBurn admin action
interface ICompliance is IComplianceEvents, IComplianceErrors {
    /// @notice Get blocklist and freeze status for `account`
    function restrictionStatus(address account) external view returns (bool blocked, bool frozen);

    /// @notice Add `account` to the blocklist
    function addToBlocklist(address account) external;

    /// @notice Add multiple `accounts` to the blocklist
    function addToBlocklistBatch(address[] calldata accounts) external;

    /// @notice Remove `account` from the blocklist
    function removeFromBlocklist(address account) external;

    /// @notice Mark `account` as frozen
    function freeze(address account) external;

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external;

    /// @notice Burn `amount` of `target`'s wallet shares
    function forceBurn(address target, uint256 amount) external;
}
