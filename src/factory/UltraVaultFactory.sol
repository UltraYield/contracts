// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { DEPLOYER_ROLE } from "src/utils/Roles.sol";
import {
    IUltraVaultFactory,
    IVaultImplementationGetter,
    Version
} from "src/interfaces/IUltraVaultFactory.sol";

/// @title UltraVaultFactory
/// @notice Immutable version registry and CREATE2 deployer for UltraVault proxies.
///         Implementations are pre-deployed (one per version) and registered by the admin;
///         deployers create proxies of registered versions at predictable addresses.
/// @dev Proxies are deployed with empty constructor data, so a vault address depends only on
///      (factory, salt, implementation). Deployers can pre-compute it and pre-deploy contracts
///      that reference the vault (upgrade module, oracle) before it exists.
contract UltraVaultFactory is AccessControl, IUltraVaultFactory {
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

    /// @dev Version key => registry record. A version exists iff implementation != address(0)
    mapping(bytes32 versionKey => VersionInfo info) private _versions;

    /// @dev Implementation => version key (one-to-one; bytes32(0) = unregistered)
    mapping(address implementation => bytes32 versionKey) private _versionKeyByImpl;

    /// @dev Append-only list of registered version keys, in registration order
    bytes32[] private _versionKeys;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address defaultAdmin) {
        require(defaultAdmin != address(0), ZeroAdminAddress());
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

        bytes32 key = _getVersionKey(version);
        require(_versions[key].implementation == address(0), VersionAlreadyRegistered(key));
        require(_versionKeyByImpl[implementation] == bytes32(0), ImplementationAlreadyRegistered());

        _versions[key] = VersionInfo({
            version: version,
            implementation: implementation,
            initSelector: initSelector,
            disabled: false
        });
        _versionKeyByImpl[implementation] = key;
        _versionKeys.push(key);

        emit VersionRegistered(key, implementation, initSelector, version);
    }

    /// @inheritdoc IUltraVaultFactory
    function setVersionDisabled(
        Version calldata version,
        bool disabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 key = _getVersionKey(version);
        VersionInfo storage info = _versions[key];
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
        VersionInfo storage info = _versions[key];
        address impl = info.implementation;
        require(impl != address(0), UnknownVersion());
        require(!info.disabled, DisabledVersion());

        address predicted = _predictVaultAddress(impl, salt);
        require(predicted.code.length == 0, SaltAlreadyUsed(predicted));

        // Empty constructor data: the CREATE2 address depends only on (factory, salt, impl)
        vault = address(new ERC1967Proxy{ salt: salt }(impl, ""));

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
        implementation = _versions[_getVersionKey(version)].implementation;
        require(implementation != address(0), UnknownVersion());
    }

    /// @inheritdoc IUltraVaultFactory
    function versionExists(Version calldata version) external view returns (bool) {
        return _versions[_getVersionKey(version)].implementation != address(0);
    }

    /// @inheritdoc IUltraVaultFactory
    function isVersionDisabled(Version calldata version) external view returns (bool) {
        VersionInfo storage info = _versions[_getVersionKey(version)];
        require(info.implementation != address(0), UnknownVersion());
        return info.disabled;
    }

    /// @inheritdoc IUltraVaultFactory
    function versionsCount() external view returns (uint256) {
        return _versionKeys.length;
    }

    /// @inheritdoc IUltraVaultFactory
    function versionAt(uint256 index) external view returns (Version memory) {
        return _versions[_versionKeys[index]].version;
    }

    /// @inheritdoc IUltraVaultFactory
    function getAllVersions() external view returns (Version[] memory versions) {
        uint256 length = _versionKeys.length;
        versions = new Version[](length);
        for (uint256 i; i < length; ++i) {
            versions[i] = _versions[_versionKeys[i]].version;
        }
    }

    /// @inheritdoc IUltraVaultFactory
    function predictVaultAddress(Version calldata version, bytes32 salt) external view returns (address) {
        return _predictVaultAddress(getImplementation(version), salt);
    }

    /// @inheritdoc IUltraVaultFactory
    function getVaultVersion(address vault) external view returns (Version memory) {
        address impl = IVaultImplementationGetter(vault).implementation();
        bytes32 key = _versionKeyByImpl[impl];
        require(key != bytes32(0), UnregisteredImplementation());
        return _versions[key].version;
    }

    //////////////
    // Internal //
    //////////////

    /// @dev abi.encode (not encodePacked) for collision-safety with the dynamic tag
    function _getVersionKey(Version calldata version) internal pure returns (bytes32) {
        return keccak256(abi.encode(version.major, version.minor, version.patch, version.tag));
    }

    /// @dev CREATE2 address of an ERC1967Proxy of `impl` with empty constructor data,
    ///      deployed by this factory with `salt`
    function _predictVaultAddress(address impl, bytes32 salt) internal view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, bytes(""))
            ))
        );
    }
}
