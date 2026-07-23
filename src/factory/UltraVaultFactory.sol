// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IUltraVaultFactory, Version } from "src/interfaces/IUltraVaultFactory.sol";

/// @dev Role allowed to deploy vaults through the factory
bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE"); // 0xfc425f2263d0df187444b70e47283d622c70181c5baebb1306a01edba1ce184c

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraVaultFactory")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_VAULT_FACTORY_STORAGE_LOCATION =
    0xac63b6a228a5b1dcd547cbf5529b1c6f67922516921363344d03255cd3917c00;

/// @title UltraVaultFactory
/// @notice Upgradeable version registry and CREATE2 deployer for UltraVault proxies.
///         Implementations are pre-deployed (one per version) and registered by the admin;
///         deployers create proxies of registered versions at predictable addresses.
/// @dev Proxies are deployed with empty constructor data and a deployer-bound salt, so a vault
///      address depends only on (factory, deployer, salt, implementation). Deployers can
///      pre-compute it and pre-deploy contracts that reference the vault (upgrade module,
///      oracle) before it exists; binding the salt to the deployer prevents one deployer from
///      occupying an address predicted for another.
contract UltraVaultFactory is AccessControlUpgradeable, UUPSUpgradeable, IUltraVaultFactory {
    /////////////
    // Storage //
    /////////////

    /// @dev Registry record for a registered version
    struct VersionInfo {
        // Full version identity (kept for reverse lookups and enumeration)
        Version version;
        // Implementation contract for this version
        address implementation;
        // Selector of the implementation's initializer, prepended to initParams on deploy
        bytes4 initSelector;
        // When true, deployVault reverts for this version; lookups still resolve
        bool disabled;
    }

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVaultFactory
    struct UltraVaultFactoryStorage {
        // Version key => registry record. A version exists iff implementation != address(0)
        mapping(bytes32 versionKey => VersionInfo info) versions;
        // Implementation => version key (one-to-one; bytes32(0) = unregistered)
        mapping(address implementation => bytes32 versionKey) versionKeyByImpl;
        // Append-only list of registered version keys, in registration order
        bytes32[] versionKeys;
    }

    /// @dev Returns the namespaced ERC-7201 storage struct for UltraVaultFactory
    function _getUltraVaultFactoryStorage() private pure returns (UltraVaultFactoryStorage storage $) {
        assembly {
            $.slot := ULTRA_VAULT_FACTORY_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    /// @notice Disable implementation's initializer
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the factory
    /// @param defaultAdmin Account granted DEFAULT_ADMIN_ROLE
    function initialize(address defaultAdmin) external initializer {
        require(defaultAdmin != address(0), ZeroAdminAddress());
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    //////////////
    // Registry //
    //////////////

    /// @inheritdoc IUltraVaultFactory
    function registerVersion(
        Version calldata version,
        address implementation,
        bytes4 initSelector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(implementation != address(0), ZeroImplementation());
        require(implementation.code.length != 0, ImplementationNotContract(implementation));
        require(initSelector != bytes4(0), ZeroInitSelector());

        UltraVaultFactoryStorage storage $ = _getUltraVaultFactoryStorage();
        bytes32 key = _getVersionKey(version);
        require(key != bytes32(0), ZeroVersionKey());
        require($.versions[key].implementation == address(0), VersionAlreadyRegistered(key));
        require($.versionKeyByImpl[implementation] == bytes32(0), ImplementationAlreadyRegistered());

        $.versions[key] = VersionInfo({
            version: version,
            implementation: implementation,
            initSelector: initSelector,
            disabled: false
        });
        $.versionKeyByImpl[implementation] = key;
        $.versionKeys.push(key);

        emit VersionRegistered(key, implementation, initSelector, version);
    }

    /// @inheritdoc IUltraVaultFactory
    function setVersionDisabled(
        Version calldata version,
        bool disabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 key = _getVersionKey(version);
        VersionInfo storage info = _getUltraVaultFactoryStorage().versions[key];
        require(info.implementation != address(0), UnknownVersion());
        require(info.disabled != disabled, VersionStatusUnchanged(key));

        info.disabled = disabled;
        if (disabled) {
            emit VersionDisabled(key);
        } else {
            emit VersionEnabled(key);
        }
    }

    ////////////////
    // Deployment //
    ////////////////

    /// @inheritdoc IUltraVaultFactory
    function deployVault(
        Version calldata version,
        bytes32 salt,
        bytes calldata initParams
    ) external onlyRole(DEPLOYER_ROLE) returns (address vault) {
        bytes32 key = _getVersionKey(version);
        VersionInfo storage info = _getUltraVaultFactoryStorage().versions[key];
        address impl = info.implementation;
        require(impl != address(0), UnknownVersion());
        require(!info.disabled, DisabledVersion());

        // Bind the salt to the caller so deployers cannot occupy each other's predicted addresses
        bytes32 deploySalt = _getDeploySalt(msg.sender, salt);
        address predicted = _predictVaultAddress(impl, deploySalt);
        require(predicted.code.length == 0, SaltAlreadyUsed(predicted));

        // Empty constructor data: the CREATE2 address depends only on (factory, deployer, salt, impl)
        vault = address(new ERC1967Proxy{ salt: deploySalt }(impl, ""));

        // Call the registered initializer in the same transaction; reverts bubble up
        Address.functionCall(vault, abi.encodePacked(info.initSelector, initParams));

        // Every initialized vault has a non-zero underlying asset (enforced by the initializer);
        // an uninitialized proxy reports address(0)
        require(IERC4626(vault).asset() != address(0), VaultNotInitialized());

        emit VaultDeployed(vault, key, impl, salt, msg.sender);
    }

    //////////////
    // View Fns //
    //////////////

    /// @inheritdoc IUltraVaultFactory
    function getVersionKey(Version calldata version) external pure returns (bytes32) {
        return _getVersionKey(version);
    }

    /// @inheritdoc IUltraVaultFactory
    function getImplementation(Version calldata version) public view returns (address implementation) {
        implementation = _getUltraVaultFactoryStorage().versions[_getVersionKey(version)].implementation;
        require(implementation != address(0), UnknownVersion());
    }

    /// @inheritdoc IUltraVaultFactory
    function getVersionInfo(
        Version calldata version
    ) external view returns (address implementation, bytes4 initSelector, bool disabled) {
        VersionInfo storage info = _getUltraVaultFactoryStorage().versions[_getVersionKey(version)];
        implementation = info.implementation;
        require(implementation != address(0), UnknownVersion());
        return (implementation, info.initSelector, info.disabled);
    }

    /// @inheritdoc IUltraVaultFactory
    function versionExists(Version calldata version) external view returns (bool) {
        return _getUltraVaultFactoryStorage().versions[_getVersionKey(version)].implementation != address(0);
    }

    /// @inheritdoc IUltraVaultFactory
    function isVersionDisabled(Version calldata version) external view returns (bool) {
        VersionInfo storage info = _getUltraVaultFactoryStorage().versions[_getVersionKey(version)];
        require(info.implementation != address(0), UnknownVersion());
        return info.disabled;
    }

    /// @inheritdoc IUltraVaultFactory
    function versionsCount() external view returns (uint256) {
        return _getUltraVaultFactoryStorage().versionKeys.length;
    }

    /// @inheritdoc IUltraVaultFactory
    function versionAt(uint256 index) external view returns (Version memory) {
        UltraVaultFactoryStorage storage $ = _getUltraVaultFactoryStorage();
        return $.versions[$.versionKeys[index]].version;
    }

    /// @inheritdoc IUltraVaultFactory
    function getAllVersions() external view returns (Version[] memory versions) {
        UltraVaultFactoryStorage storage $ = _getUltraVaultFactoryStorage();
        uint256 length = $.versionKeys.length;
        versions = new Version[](length);
        for (uint256 i; i < length; ++i) {
            versions[i] = $.versions[$.versionKeys[i]].version;
        }
    }

    /// @inheritdoc IUltraVaultFactory
    function predictVaultAddress(
        Version calldata version,
        address deployer,
        bytes32 salt
    ) external view returns (address) {
        return _predictVaultAddress(getImplementation(version), _getDeploySalt(deployer, salt));
    }

    /// @inheritdoc IUltraVaultFactory
    function getImplementationVersion(address implementation) external view returns (Version memory) {
        UltraVaultFactoryStorage storage $ = _getUltraVaultFactoryStorage();
        bytes32 key = $.versionKeyByImpl[implementation];
        require(key != bytes32(0), UnregisteredImplementation());
        return $.versions[key].version;
    }

    //////////////
    // Internal //
    //////////////

    /// @dev abi.encode (not encodePacked) for collision-safety with the dynamic tag
    function _getVersionKey(Version calldata version) internal pure returns (bytes32) {
        return keccak256(abi.encode(version.major, version.minor, version.patch, version.tag));
    }

    /// @dev Effective CREATE2 salt: the caller-provided salt bound to the deployer address
    function _getDeploySalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    /// @dev CREATE2 address of an ERC1967Proxy of `impl` with empty constructor data,
    ///      deployed by this factory with `deploySalt`
    function _predictVaultAddress(address impl, bytes32 deploySalt) internal view returns (address) {
        return Create2.computeAddress(
            deploySalt,
            keccak256(abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, bytes(""))
            ))
        );
    }

    //////////////
    // Upgrades //
    //////////////

    /// @dev Restrict factory upgrades to the admin
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
