// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IComplianceEvents {
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);
    event ForceBurned(address indexed account, uint256 amount);
}

interface IComplianceErrors {
    error AddressFrozen(address account);
}

/// @title ICompliance
/// @notice External interface for the per-address freeze controls and forceBurn admin action
interface ICompliance is IComplianceEvents, IComplianceErrors {
    /// @notice Returns true if `account` is frozen
    function isFrozen(address account) external view returns (bool);

    /// @notice Mark `account` as frozen
    function freeze(address account) external;

    /// @notice Mark multiple `accounts` as frozen
    function freezeBatch(address[] calldata accounts) external;

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external;

    /// @notice Burn `amount` of `target`'s wallet shares
    function forceBurn(address target, uint256 amount) external;
}
