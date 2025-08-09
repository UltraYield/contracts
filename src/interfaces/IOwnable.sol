// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IOwnable {
    /// @dev Returns the address of the current owner.
    function owner() external view returns (address);

    /// @dev Returns the address of the pending owner.
    /// @dev Returns the address of the pending owner.
    function pendingOwner() external view returns (address);

    /// @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
    /// Can only be called by the current owner.
    ///
    /// Setting `newOwner` to the zero address is allowed; this can be used to cancel an initiated ownership transfer.
    function transferOwnership(address newOwner) external;

    /// @dev The new owner accepts the ownership transfer.
    function acceptOwnership() external;
}
