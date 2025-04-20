// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { ERC4626 } from "solmate/tokens/ERC4626.sol";
import { IUltraVaultOracle, Price } from "src/interfaces/IUltraVaultOracle.sol";
import { IERC20Supply } from "src/interfaces/IERC20Supply.sol";
import { IPausable } from "src/interfaces/IPausable.sol";

/// @notice Price update struct
struct PriceUpdate {
    /// @notice The vault to update the price for
    address vault;
    /// @notice The asset to update the price for (the asset the vault is denominated in)
    address asset;
    /// @notice The share value in assets
    uint256 shareValueInAssets;
}

/// @notice Safety limits for price updates
struct Limit {
    /// @notice Maximum allowed price jump from one update to the next (1e18 = 100%)
    uint256 jump; // 1e18 = 100%
    /// @notice Maximum allowed drawdown from the highwaterMark (1e18 = 100%)
    uint256 drawdown; // 1e18 = 100%
}

/**
 * @title VaultPriceManager
 * @notice Contract managing vault price updates with limits
 * @dev Has built in safety mechanisms to pause vault upon sudden moves
 */
contract VaultPriceManager is InitializableOwnable {
    using FixedPointMathLib for uint256;

    // Events
    event VaultAdded(address vault);
    event LimitsUpdated(address vault, Limit oldLimit, Limit newLimit);
    event AdminUpdated(address vault, address admin, bool isAdmin);

    // Errors
    error CanNotAddNonEmptyVault();
    error ArraysMismatch();
    error NotAdminOrOwner();
    error InvalidLimit();

    IUltraVaultOracle public oracle;

    /// @dev vault => highwaterMark
    mapping(address => uint256) public highwaterMarks;

    /// @dev vault => Limit
    mapping(address => Limit) public limits;

    /// @dev vault => admin => isAdmin
    mapping(address => mapping(address => bool)) public isAdmin;

    /**
     * @notice Initialize controller with oracle and owner
     * @param _oracle Oracle contract address
     * @param _owner Owner address
     */
    constructor(address _oracle, address _owner) {
        initOwner(_owner);
        oracle = IUltraVaultOracle(_oracle);
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add vault to controller
     * @param vault Vault address to add
     * @dev Initializes price to 1e18 (1:1)
     * @dev Must be called before vault receives deposits
     */
    function addVault(address vault) external onlyOwner {
        if (IERC20Supply(vault).totalSupply() > 1)
            revert CanNotAddNonEmptyVault();

        highwaterMarks[vault] = 1e18;

        oracle.setPrice(vault, address(ERC4626(vault).asset()), 1e18);

        emit VaultAdded(vault);
    }

    /**
     * @notice Update vault price and highwaterMark
     * @param priceUpdate Price update data
     * @dev Pauses vault on large price jumps or drawdowns
     */
    function updatePriceInstantly(PriceUpdate calldata priceUpdate) external {
        _updatePriceInstantly(priceUpdate);
    }

    /**
     * @notice Update prices for multiple vaults
     * @param priceUpdates Array of price updates
     */
    function updatePricesInstantly(PriceUpdate[] calldata priceUpdates) external {
        for (uint256 i; i < priceUpdates.length; i++) {
            _updatePriceInstantly(priceUpdates[i]);
        }
    }

    /// @notice Internal price update function
    function _updatePriceInstantly(
        PriceUpdate calldata priceUpdate
    ) internal onlyAdminOrOwner(priceUpdate.vault) {
        _checkSuddenMovements(priceUpdate);

        oracle.setPrice(
            priceUpdate.vault,
            priceUpdate.asset,
            priceUpdate.shareValueInAssets
        );
    }

    /**
     * @notice Update vault price gradually over multiple blocks
     * @param priceUpdate Price update data
     * @param timestampForFullVesting Target timestamp for full vesting
     * @dev Pauses vault on large price jumps
     */
    function updatePriceWithVesting(
        PriceUpdate calldata priceUpdate,
        uint256 timestampForFullVesting
    ) external {
        _updatePriceWithVesting(priceUpdate, timestampForFullVesting);
    }

    /**
     * @notice Update prices for multiple vaults gradually
     * @param priceUpdates Array of price updates
     * @param timestampForFullVesting Array of price changes per block
     */
    function updatePricesWithVesting(
        PriceUpdate[] calldata priceUpdates,
        uint256[] calldata timestampForFullVesting
    ) external {
        if (priceUpdates.length != timestampForFullVesting.length)
            revert ArraysMismatch();

        for (uint256 i; i < priceUpdates.length; i++) {
            _updatePriceWithVesting(
                priceUpdates[i],
                timestampForFullVesting[i]
            );
        }
    }

    /// @notice Internal gradual price update function
    function _updatePriceWithVesting(
        PriceUpdate calldata priceUpdate,
        uint256 timestampForFullVesting
    ) internal onlyAdminOrOwner(priceUpdate.vault) {
        _checkSuddenMovements(priceUpdate);

        oracle.scheduleLinearPriceUpdate(
            priceUpdate.vault,
            priceUpdate.asset,
            priceUpdate.shareValueInAssets,
            timestampForFullVesting
        );
    }

    /// @notice Check price update for sudden price swings and update highwatermark
    function _checkSuddenMovements(
        PriceUpdate calldata priceUpdate
    ) internal {
        uint256 lastPrice = oracle.getCurrentPrice(
            priceUpdate.vault,
            priceUpdate.asset
        );
        uint256 highwaterMark = highwaterMarks[priceUpdate.vault];
        bool paused = IPausable(priceUpdate.vault).paused();
        Limit memory limit = limits[priceUpdate.vault];

        if (
            // Sudden drop
            priceUpdate.shareValueInAssets <
            lastPrice.mulDivDown(1e18 - limit.jump, 1e18) ||
            // Sudden increase
            priceUpdate.shareValueInAssets >
            lastPrice.mulDivDown(1e18 + limit.jump, 1e18) ||
            // Drawdown check
            priceUpdate.shareValueInAssets <
            highwaterMark.mulDivDown(1e18 - limit.drawdown, 1e18)
        ) {
            if (!paused) {
                IPausable(priceUpdate.vault).pause();
            }
        } else if (priceUpdate.shareValueInAssets > highwaterMark) {
            highwaterMarks[priceUpdate.vault] = priceUpdate.shareValueInAssets;
        }
    }

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

    /*//////////////////////////////////////////////////////////////
                        LIMITS UPDATE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set vault price limits
     * @param _vault Vault address
     * @param _limit Price limits to set
     */
    function setLimits(address _vault, Limit memory _limit) external onlyOwner {
        _setLimits(_vault, _limit);
    }

    /**
     * @notice Set price limits for multiple vaults
     * @param _vaults Array of vault addresses
     * @param _limits Array of price limits
     */
    function setLimits(
        address[] memory _vaults,
        Limit[] memory _limits
    ) external onlyOwner {
        if (_vaults.length != _limits.length) 
            revert ArraysMismatch();

        for (uint256 i; i < _vaults.length; i++) {
            _setLimits(_vaults[i], _limits[i]);
        }
    }

    function _setLimits(address _vault, Limit memory _limit) internal {
        if (_limit.jump > 1e18 || _limit.drawdown > 1e18)
            revert InvalidLimit();

        Limit memory oldLimit = limits[_vault];

        if (
            _limit.jump != oldLimit.jump || 
            _limit.drawdown != oldLimit.drawdown
        ) {
            emit LimitsUpdated(_vault, limits[_vault], _limit);

            limits[_vault] = _limit;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            UTILS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim oracle ownership
     */
    function claimOracleOwnership() external onlyOwner {
        InitializableOwnable(address(oracle)).claimOwnership();
    }
}
