// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
import { IERC7575, IERC165 } from "ERC-7540/interfaces/IERC7575.sol";
import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { IPausable } from "src/interfaces/IPausable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.BaseERC7540")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant BASE_ERC7540_STORAGE_LOCATION = 0x7ed40989b9d2239ce36ec9550c05ebed21dbbee7653259cce6262e159951a800;

abstract contract BaseERC7540 is
    ERC4626Upgradeable,
    InitializableOwnable,
    PausableUpgradeable,
    IPausable,
    IERC7540Operator
{
    // Events
    event RoleUpdated(bytes32 role, address account, bool approved);

    // Errors
    error AccessDenied();
    error Misconfigured();

    ///////////////
    // Constants //
    ///////////////

    // @dev All requests have ID == 0
    uint256 internal constant REQUEST_ID = 0;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.BaseERC7540
    struct BaseERC7540Storage {
        mapping(bytes32 => mapping(address => bool)) hasRole;
        mapping(address => mapping(address => bool)) isOperator;
    }

    function _getBaseERC7540Storage() private pure returns (BaseERC7540Storage storage $) {
        assembly {
            $.slot := BASE_ERC7540_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    /// @notice Constructor for BaseERC7540
    /// @param _owner Owner of the vault
    /// @param _asset Underlying asset address
    /// @param _name Vault name
    /// @param _symbol Vault symbol
    function initialize(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol
    ) public virtual onlyInitializing {
        require(_asset != address(0), Misconfigured());
        __Pausable_init();
        __ERC20_init(_name, _symbol);
        __ERC4626_init(IERC20(_asset));
        initOwner(_owner);
    }

    /// @notice Get total assets in vault
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /////////////
    // ERC7540 //
    /////////////

    function share() public view returns (address) {
        return address(this);
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _getBaseERC7540Storage().hasRole[role][account];
    }

    function isOperator(address _owner, address _operator) public view returns (bool) {
        return _getBaseERC7540Storage().isOperator[_owner][_operator];
    }

    /// @notice Set operator approval status
    /// @param operator Operator address
    /// @param approved Status
    /// @dev Allows operations on behalf of vault shares holder
    function setOperator(
        address operator,
        bool approved
    ) public virtual returns (bool success) {
        require(msg.sender != operator, "ERC7540Vault/cannot-set-self-as-operator");
        if (isOperator(msg.sender, operator) != approved) {
            _getBaseERC7540Storage().isOperator[msg.sender][operator] = approved;
            emit OperatorSet(msg.sender, operator, approved);
            success = true;
        }
    }

    //////////////
    // Pausable //
    //////////////

    /// @notice Update account role
    /// @param role Role to update
    /// @param account Account address
    /// @param approved Approval status
    function updateRole(
        bytes32 role,
        address account,
        bool approved
    ) public onlyOwner {
        if (hasRole(role,account) != approved) {
            _getBaseERC7540Storage().hasRole[role][account] = approved;
            emit RoleUpdated(role, account, approved);
        }
    }

    /// @notice Check if caller has role or is owner
    /// @param role Role to check
    modifier onlyRoleOrOwner(bytes32 role) {
        require(hasRole(role, msg.sender) || msg.sender == owner, AccessDenied());
        _;
    }

    /// @notice Check if the contract is paused
    /// @return True if the contract is paused, false otherwise
    function paused() public view override(IPausable, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /// @notice Pause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function pause() external override onlyRoleOrOwner(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function unpause() external override onlyRoleOrOwner(PAUSER_ROLE) {
        _unpause();
    }

    ////////////
    // ERC165 //
    ////////////

    /// @notice Check interface support
    /// @param interfaceId Interface ID to check
    /// @return True if interface is supported
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual returns (bool) {
        return
            interfaceId == type(IERC7575).interfaceId ||
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
