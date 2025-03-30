// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title InitializableOwnable
 * @notice Ownable contract with two-step ownership transfer
 * @dev Owner can be set only once during initialization
 */
contract InitializableOwnable {

    error NotOwner();

    /// @notice Current owner address
    address public owner;
    /// @notice Address of pending owner
    address public newOwner;

    /// @notice Whether owner has been initialized
    bool internal initialized;

    // ============ Events ============

    /// @notice Emitted when ownership transfer is requested
    event OwnerTransferRequested(
        address indexed oldOwner, 
        address indexed newOwner
    );

    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(
        address indexed oldOwner, 
        address indexed newOwner
    );

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Initialize owner address
     * @param _newOwner Address of initial owner
     * @dev Can only be called once
     */
    function initOwner(address _newOwner) public notInitialized {
        initialized = true;
        owner = _newOwner;
    }

    /**
     * @notice Request ownership transfer
     * @param _newOwner Address of new owner
     */
    function transferOwnership(address _newOwner) public onlyOwner {
        emit OwnerTransferRequested(owner, _newOwner);
        newOwner = _newOwner;
    }

    /**
     * @notice Claim ownership after transfer request
     * @dev Can only be called by pending owner
     */
    function claimOwnership() public {
        require(msg.sender == newOwner, "Claim from wrong address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }

    /* ========== MODIFIERS ========== */

    /// @notice Modifier to ensure contract is not initialized
    modifier notInitialized() {
        require(!initialized, "Not initialized");
        _;
    }

    /// @notice Modifier to ensure caller is owner
    modifier onlyOwner() {
        if (msg.sender != owner)
            revert NotOwner();
        _;
    }
}
