// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
// import { IERC7540Operator } from "src/interfaces/IERC7540.sol";
import { IERC7575, IERC165 } from "ERC-7540/interfaces/IERC7575.sol";
// import { IERC7575, IERC165 } from "src/interfaces/IERC7575.sol";
import { ERC4626 } from "solmate/tokens/ERC4626.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { Pausable } from "src/utils/Pausable.sol";

abstract contract BaseERC7540 is
    ERC4626,
    InitializableOwnable,
    IERC7540Operator,
    Pausable
{

    // Events
    event RoleUpdated(bytes32 role, address account, bool approved);

    // Errors
    error AccessDenied();

    // Roles
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // @dev Assume requests are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    address public share = address(this);

    mapping(address => mapping(address => bool)) public isOperator;
    mapping(address controller => mapping(bytes32 nonce => bool used)) public authorizations;

    /**
     * @notice Constructor for BaseERC7540
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     */
    constructor(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(ERC20(_asset), _name, _symbol) {
        initOwner(_owner);
    }

    /// @notice Get total assets in vault
    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        ERC7540 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set operator approval status
     * @param operator Operator address
     * @param approved Status
     * @dev Allows operations on behalf of vault shares holder
     */
    function setOperator(
        address operator,
        bool approved
    ) public virtual returns (bool success) {
        require(msg.sender != operator, "ERC7540Vault/cannot-set-self-as-operator");
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    /*//////////////////////////////////////////////////////////////
                        EIP-7441 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize operator for controller
     * @param controller Controller address
     * @param operator Operator address
     * @param approved Approval status
     * @param nonce Authorization nonce
     * @param deadline Authorization deadline
     * @param signature Authorization signature
     * @dev Operators can requestRedeem, withdraw and redeem for controller
     */
    function authorizeOperator(
        address controller,
        address operator,
        bool approved,
        bytes32 nonce,
        uint256 deadline,
        bytes memory signature
    ) public virtual returns (bool success) {
        require(controller != operator, "ERC7540Vault/cannot-set-self-as-operator");
        require(block.timestamp <= deadline, "ERC7540Vault/expired");
        require(!authorizations[controller][nonce], "ERC7540Vault/authorization-used");

        authorizations[controller][nonce] = true;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        address recoveredAddress = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "AuthorizeOperator(address controller,address operator,bool approved,bytes32 nonce,uint256 deadline)"
                            ),
                            controller,
                            operator,
                            approved,
                            nonce,
                            deadline
                        )
                    )
                )
            ),
            v,
            r,
            s
        );

        require(recoveredAddress != address(0) && recoveredAddress == controller, "INVALID_SIGNER");

        isOperator[controller][operator] = approved;

        emit OperatorSet(controller, operator, approved);

        success = true;
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSABLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update account role
     * @param role Role to update
     * @param account Account address
     * @param approved Approval status
     */
    function updateRole(
        bytes32 role,
        address account,
        bool approved
    ) public onlyOwner {
        hasRole[role][account] = approved;

        emit RoleUpdated(role, account, approved);
    }

    /**
     * @notice Check if caller has role or is owner
     * @param role Role to check
     */
    modifier onlyRoleOrOwner(bytes32 role) {
        if (!hasRole[role][msg.sender] && msg.sender != owner)
            revert AccessDenied();
        _;
    }

    /// @notice Pause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function pause() external onlyRoleOrOwner(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function unpause() external onlyRoleOrOwner(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check interface support
     * @param interfaceId Interface ID to check
     * @return True if interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual returns (bool) {
        return
            interfaceId == type(IERC7575).interfaceId ||
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
