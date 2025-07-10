// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
import { IERC7575, IERC165 } from "ERC-7540/interfaces/IERC7575.sol";
import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { Pausable } from "src/utils/Pausable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract BaseERC7540 is
    ERC4626Upgradeable,
    InitializableOwnable,
    IERC7540Operator,
    Pausable
{

    // Events
    event RoleUpdated(bytes32 role, address account, bool approved);

    // Errors
    error AccessDenied();
    error Misconfigured();

    // @dev All requests have ID == 0
    uint256 internal constant REQUEST_ID = 0;

    // Roles
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    mapping(address => mapping(address => bool)) public isOperator;

    // V0: 2 total: 1 - role mapping, 1 - operator mapping
    uint256[48] private __gap;

    /**
     * @notice Constructor for BaseERC7540
     * @param _owner Owner of the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     */
    function initialize(
        address _owner,
        address _asset,
        string memory _name,
        string memory _symbol
    ) public virtual onlyInitializing {
        if (_asset == address(0))
            revert Misconfigured(); 
        __ERC20_init(_name, _symbol);
        __ERC4626_init(IERC20(_asset));
        initOwner(_owner);
    }

    /// @notice Get total assets in vault
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        ERC7540 LOGIC
    //////////////////////////////////////////////////////////////*/

    function share() public view returns (address) {
        return address(this);
    }

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
        if (isOperator[msg.sender][operator] != approved) {
            isOperator[msg.sender][operator] = approved;
            emit OperatorSet(msg.sender, operator, approved);
            success = true;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        afterDeposit(asset(), assets, shares);

        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        beforeWithdraw(asset(), assets, shares);

        return super.withdraw(assets, receiver, owner);
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
        if (hasRole[role][account] != approved) {
            hasRole[role][account] = approved;

            emit RoleUpdated(role, account, approved);
        }
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
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(address asset, uint256 assets, uint256 shares) internal virtual {}

    function afterDeposit(address asset, uint256 assets, uint256 shares) internal virtual {}

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
