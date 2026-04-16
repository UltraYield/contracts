// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";
import { IOwnable } from "src/interfaces/IOwnable.sol";
import { IPausable } from "src/interfaces/IPausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title VaultPriceManager
/// @notice Contract managing vault price updates with limits
/// @dev Has built in safety mechanisms to pause vault upon sudden moves
contract VaultPriceManager is Ownable2Step {
    using FixedPointMathLib for uint256;

    ////////////
    // Events //
    ////////////

    event LimitsUpdated(Limits oldLimits, Limits newLimits);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);

    ////////////
    // Errors //
    ////////////

    error ZeroAddress();
    error InvalidVault();
    error NotAdminOrOwner();
    error InvalidLimit();
    error AlreadyAdmin();
    error NotAdmin();

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant SCALE = 1e18;
    uint256 public constant MAX_JUMP_LIMIT = SCALE;

    ///////////
    // Types //
    ///////////

    /// @notice Safety limits for price updates
    struct Limits {
        // Maximum allowed upward price jump from one update to the next (1e18 = 100%)
        uint128 jumpUp;
        // Maximum allowed downward price jump from one update to the next (1e18 = 100%)
        uint128 jumpDown;
    }

    /////////////
    // Storage //
    /////////////

    IUltraVaultOracle public immutable oracle;
    address public immutable vault;
    Limits public limits;
    mapping(address => bool) public isAdmin;

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize controller with oracle and owner
    /// @param _oracle Oracle contract address
    /// @param _vault Vault address
    /// @param _owner Owner address
    constructor(address _oracle, address _vault, address _owner) Ownable(_owner) {
        require(_oracle != address(0), ZeroAddress());
        oracle = IUltraVaultOracle(_oracle);

        require(_vault != address(0), ZeroAddress());
        require(_vault == oracle.vault(), InvalidVault());
        vault = _vault;
    }

    //////////////////
    // Oracle Logic //
    //////////////////

    /// @notice Update vault price instantly
    /// @param _vault Target vault address
    /// @param newPrice New price
    /// @dev Pauses vault on large price jumps
    function instantPriceUpdate(address _vault, uint256 newPrice) external onlyAdminOrOwner {
        require(_vault == vault, InvalidVault());
        _checkSuddenMovements(newPrice);
        oracle.setPriceInstantly(
            _vault,
            newPrice
        );
    }

    /// @notice Update vault price linearly over a duration
    /// @param _vault Target vault address
    /// @param newPrice New price
    /// @param duration Vesting duration
    /// @dev Pauses vault on large price jumps
    function linearPriceUpdate(
        address _vault,
        uint256 newPrice,
        uint256 duration
    ) external onlyAdminOrOwner {
        require(_vault == vault, InvalidVault());
        _checkSuddenMovements(newPrice);
        oracle.scheduleLinearPriceUpdate(
            _vault,
            newPrice,
            duration
        );
    }

    //////////////////////
    // Admin Role Logic //
    //////////////////////

    /// @notice Set vault admin
    /// @param admin Admin address
    function addAdmin(address admin) external onlyOwner {
        require(admin != address(0), ZeroAddress());
        require(!isAdmin[admin], AlreadyAdmin());
        isAdmin[admin] = true;
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyOwner {
        require(admin != address(0), ZeroAddress());
        require(isAdmin[admin], NotAdmin());
        isAdmin[admin] = false;
        emit AdminRemoved(admin);
    }

    /// @notice Modifier for admin/owner access
    modifier onlyAdminOrOwner() {
        require(msg.sender == owner() || isAdmin[msg.sender], NotAdminOrOwner());
        _;
    }

    ///////////////////
    // Limits Update //
    ///////////////////

    /// @notice Set vault price limits
    /// @param jumpUp Maximum allowed upward price jump from one update to the next (1e18 = 100%)
    /// @param jumpDown Maximum allowed downward price jump from one update to the next (1e18 = 100%)
    function updateLimits(uint128 jumpUp, uint128 jumpDown) external onlyOwner {
        require(jumpUp <= MAX_JUMP_LIMIT && jumpDown <= MAX_JUMP_LIMIT, InvalidLimit());
        Limits memory oldLimits = limits;
        Limits memory newLimits = Limits({
            jumpUp: jumpUp,
            jumpDown: jumpDown
        });
        if (
            newLimits.jumpUp != oldLimits.jumpUp ||
            newLimits.jumpDown != oldLimits.jumpDown
        ) {
            limits = newLimits;
            emit LimitsUpdated(oldLimits, newLimits);
        }
    }

    ///////////
    // Utils //
    ///////////

    /// @notice Claim oracle ownership
    function claimOracleOwnership() external onlyOwner {
        IOwnable(address(oracle)).acceptOwnership();
    }

    //////////////
    // Internal //
    //////////////

    /// @notice Check price update for sudden price swings
    function _checkSuddenMovements(uint256 newPrice) internal {
        uint256 lastPrice = oracle.currentSharePrice();
        Limits memory _limits = limits;
        // pause if update is out of the limits
        if (
            // Sudden drop
            newPrice < lastPrice.mulDivDown(SCALE - _limits.jumpDown, SCALE) ||
            // Sudden increase
            newPrice > lastPrice.mulDivDown(SCALE + _limits.jumpUp, SCALE)
        ) {
            if (!IPausable(vault).paused()) {
                IPausable(vault).pause();
            }
        }
    }
}
