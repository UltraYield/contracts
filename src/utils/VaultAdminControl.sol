// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { InitializableOwnable } from "./InitializableOwnable.sol";

contract VaultAdminControl is InitializableOwnable {

    /// @notice Emitted when admin is updated
    event AdminUpdated(address vault, address admin, bool isAdmin);

    /// @notice Error when caller is not admin or owner
    error NotAdminOrOwner();

    /// @dev vault => admin => isAdmin
    mapping(address => mapping(address => bool)) public isAdmin;

    /*//////////////////////////////////////////////////////////////
                        ADMIN ROLE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set vault admin
     * @param _vault Vault address
     * @param _admin Admin address
     * @param _isAdmin Whether to add or remove admin
     */
    function setAdmin(
        address _vault,
        address _admin,
        bool _isAdmin
    ) external onlyOwner {
        if (isAdmin[_vault][_admin] != _isAdmin) {
            emit AdminUpdated(_vault, _admin, _isAdmin);
            isAdmin[_vault][_admin] = _isAdmin;
        }
    }

    /**
     * @notice Modifier for admin/owner access
     * @param _vault Vault to check access for
     */
    modifier onlyAdminOrOwner(address _vault) {
        if (msg.sender != owner && !isAdmin[_vault][msg.sender])
            revert NotAdminOrOwner();
        _;
    }
}
