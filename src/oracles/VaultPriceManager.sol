// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";
import { IOwnable } from "src/interfaces/IOwnable.sol";
import { IERC20Supply } from "src/interfaces/IERC20Supply.sol";
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
    error CannotConnectNonEmptyVault();
    error NotAdminOrOwner();
    error InvalidLimit();
    error AlreadyAdmin();
    error NotAdmin();

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant SCALE = 1e18;
    uint256 public constant MAX_JUMP_LIMIT = SCALE;
    uint256 public constant MAX_DRAWDOWN_LIMIT = SCALE;

    ///////////
    // Types //
    ///////////

    /// @notice Safety limits for price updates
    struct Limits {
        // Maximum allowed price jump from one update to the next (1e18 = 100%)
        uint256 jump;
        // Maximum allowed drawdown from the highwaterMark (1e18 = 100%)
        uint256 drawdown;
    }

    /////////////
    // Storage //
    /////////////

    IUltraVaultOracle public immutable oracle;
    address public immutable vault;
    Limits public limits;
    uint256 public highwaterMark;
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
        require(IERC20Supply(_vault).totalSupply() == 0, CannotConnectNonEmptyVault());
        vault = _vault;
        
        uint256 initialPrice = SCALE;
        highwaterMark = initialPrice;
        oracle.setPriceInstantly(vault, initialPrice);
    }

    //////////////////
    // Oracle Logic //
    //////////////////

    /// @notice Update vault price and highwaterMark
    /// @param _vault Target vault address
    /// @param newPrice New price
    /// @dev Pauses vault on large price jumps or drawdowns
    function updatePriceInstantly(address _vault, uint256 newPrice) external onlyAdminOrOwner {
        require(_vault == vault, InvalidVault());
        _checkSuddenMovements(newPrice);
        oracle.setPriceInstantly(
            _vault,
            newPrice
        );
    }

    /// @notice Update vault price gradually over multiple blocks
    /// @param _vault Target vault address
    /// @param newPrice New price
    /// @param duration Vesting duration
    /// @dev Pauses vault on large price jumps
    function updatePriceWithVesting(
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
    /// @param jump Maximum allowed price jump from one update to the next (1e18 = 100%)
    /// @param drawdown Maximum allowed drawdown from the highwaterMark (1e18 = 100%)
    function updateLimits(uint256 jump, uint256 drawdown) external onlyOwner {
        require(jump <= MAX_JUMP_LIMIT && drawdown <= MAX_DRAWDOWN_LIMIT, InvalidLimit());
        Limits memory oldLimits = limits;
        Limits memory newLimits = Limits({
            jump: jump,
            drawdown: drawdown
        });
        if (
            newLimits.jump != oldLimits.jump || 
            newLimits.drawdown != oldLimits.drawdown
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

    /// @notice Check price update for sudden price swings and update highwatermark
    function _checkSuddenMovements(uint256 newPrice) internal {
        uint256 lastPrice = oracle.currentSharePrice();
        uint256 _highwaterMark = highwaterMark;
        Limits memory _limits = limits;
        if (
            // Sudden drop
            newPrice < lastPrice.mulDivDown(SCALE - _limits.jump, SCALE) ||
            // Sudden increase
            newPrice > lastPrice.mulDivDown(SCALE + _limits.jump, SCALE) ||
            // Drawdown check
            newPrice < _highwaterMark.mulDivDown(SCALE - _limits.drawdown, SCALE)
        ) {
            if (!IPausable(vault).paused()) {
                IPausable(vault).pause();
            }
        } else if (newPrice > _highwaterMark) {
            highwaterMark = newPrice;
        }
    }
}
