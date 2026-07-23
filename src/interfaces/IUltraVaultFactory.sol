// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @notice Semantic version of an UltraVault implementation.
///         The tag is part of the identity: "1.2.0-rc1" and "1.2.0" are distinct versions.
struct Version {
    // Major version number
    uint8 major;
    // Minor version number
    uint8 minor;
    // Patch version number
    uint8 patch;
    // Optional tag, e.g. "rc1"; empty string for a release
    string tag;
}

/// @title IUltraVaultFactory
/// @notice Version registry and CREATE2 deployer for UltraVault proxies
interface IUltraVaultFactory {
    ////////////
    // Events //
    ////////////

    /// @notice Emitted when an implementation is registered for a version
    /// @param versionKey Registry key of the version
    /// @param implementation The implementation address
    /// @param initSelector Selector of the implementation's initializer
    /// @param version Full version identity
    event VersionRegistered(
        bytes32 indexed versionKey,
        address indexed implementation,
        bytes4 initSelector,
        Version version
    );

    /// @notice Emitted when a version is disabled for deployment
    /// @param versionKey Registry key of the version
    event VersionDisabled(bytes32 indexed versionKey);

    /// @notice Emitted when a disabled version is re-enabled
    /// @param versionKey Registry key of the version
    event VersionEnabled(bytes32 indexed versionKey);

    /// @notice Emitted for every vault deployed by the factory
    /// @param vault The deployed proxy address
    /// @param versionKey Registry key of the deployed version
    /// @param implementation Implementation the proxy points to
    /// @param salt Caller-supplied salt; the effective CREATE2 salt is keccak256(abi.encode(deployer, salt))
    /// @param deployer Account that performed the deployment
    event VaultDeployed(
        address indexed vault,
        bytes32 indexed versionKey,
        address indexed implementation,
        bytes32 salt,
        address deployer
    );

    ////////////
    // Errors //
    ////////////

    error ZeroAdminAddress();
    error ZeroImplementation();
    error ImplementationNotContract(address implementation);
    error ZeroInitSelector();
    error ZeroVersionKey();
    error VersionAlreadyRegistered(bytes32 versionKey);
    error ImplementationAlreadyRegistered();
    error UnknownVersion();
    error VersionStatusUnchanged(bytes32 versionKey);
    error DisabledVersion();
    error SaltAlreadyUsed(address predictedVault);
    error VaultNotInitialized();
    error UnregisteredImplementation();

    //////////////
    // View Fns //
    //////////////

    /// @notice Registry key of a version: keccak256(abi.encode(major, minor, patch, tag))
    function getVersionKey(Version calldata version) external pure returns (bytes32 key);

    /// @notice Implementation registered for a version
    /// @dev Reverts with UnknownVersion; resolves disabled versions
    function getImplementation(Version calldata version) external view returns (address implementation);

    /// @notice Full registry record of a version
    /// @dev Reverts with UnknownVersion; resolves disabled versions
    /// @return implementation Implementation contract for the version
    /// @return initSelector Selector of the implementation's initializer
    /// @return disabled Whether deployment of the version is disabled
    function getVersionInfo(
        Version calldata version
    ) external view returns (address implementation, bytes4 initSelector, bool disabled);

    /// @notice Whether a version is registered
    function versionExists(Version calldata version) external view returns (bool exists);

    /// @notice Whether deployment of a registered version is disabled
    /// @dev Reverts with UnknownVersion
    function isVersionDisabled(Version calldata version) external view returns (bool disabled);

    /// @notice Number of registered versions
    function versionsCount() external view returns (uint256 count);

    /// @notice Version at a registration index
    function versionAt(uint256 index) external view returns (Version memory version);

    /// @notice All registered versions in registration order, including disabled ones
    function getAllVersions() external view returns (Version[] memory versions);

    /// @notice CREATE2 address of a vault of `version` deployed by `deployer` with `salt`
    /// @dev Reverts with UnknownVersion; works for disabled versions
    function predictVaultAddress(
        Version calldata version,
        address deployer,
        bytes32 salt
    ) external view returns (address vault);

    /// @notice Registered version of an implementation
    /// @dev Reverts with UnregisteredImplementation if the implementation is not in the registry
    function getImplementationVersion(address implementation) external view returns (Version memory version);

    ///////////////
    // Write Fns //
    ///////////////

    /// @notice Register an implementation for a version
    /// @dev Append-only: the version key and the implementation must both be unused.
    ///      DEFAULT_ADMIN_ROLE only
    /// @param initSelector Selector of the implementation's initializer, called on every deploy
    function registerVersion(Version calldata version, address implementation, bytes4 initSelector) external;

    /// @notice Disable or re-enable deployment of a registered version
    /// @dev Blocks deployVault only; lookups still resolve. DEFAULT_ADMIN_ROLE only
    function setVersionDisabled(Version calldata version, bool disabled) external;

    /// @notice Deploy an ERC1967Proxy of the version's implementation via CREATE2 and call
    ///         its registered initializer with `initParams` in the same transaction
    /// @dev The proxy is deployed with empty constructor data and a caller-bound salt, so its
    ///      address depends only on (factory, msg.sender, salt, implementation). A non-zero
    ///      asset() is required after the call as proof of initialization. DEPLOYER_ROLE only
    /// @param version Registered, non-disabled version to deploy
    /// @param salt CREATE2 salt; bound to the caller address, so deployers cannot occupy
    ///        each other's predicted addresses
    /// @param initParams ABI-encoded initializer arguments without selector
    /// @return vault The deployed and initialized proxy
    function deployVault(
        Version calldata version,
        bytes32 salt,
        bytes calldata initParams
    ) external returns (address vault);
}
