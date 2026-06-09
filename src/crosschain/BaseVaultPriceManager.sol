// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";
import { IPausable } from "src/interfaces/IPausable.sol";

/// @title BaseVaultPriceManager
/// @notice Shared logic between the main-chain `VaultPriceManager` (CCIP sender)
///         and the destination-chain `RemoteVaultPriceManager` (CCIP receiver).
abstract contract BaseVaultPriceManager is Ownable2Step {
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
    error UpdateWouldPause();

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

    constructor(address _oracle, address _vault, address _owner) Ownable(_owner) {
        require(_oracle != address(0), ZeroAddress());
        require(_vault != address(0), ZeroAddress());
        require(_vault == IUltraVaultOracle(_oracle).vault(), InvalidVault());
        oracle = IUltraVaultOracle(_oracle);
        vault = _vault;
    }

    ///////////////
    // Modifiers //
    ///////////////

    modifier onlyAdminOrOwner() {
        require(msg.sender == owner() || isAdmin[msg.sender], NotAdminOrOwner());
        _;
    }

    //////////////////////
    // Admin Management //
    //////////////////////

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

    ///////////////////
    // Limits Update //
    ///////////////////

    function updateLimits(uint128 jumpUp, uint128 jumpDown) external onlyOwner {
        require(jumpUp <= MAX_JUMP_LIMIT && jumpDown <= MAX_JUMP_LIMIT, InvalidLimit());
        Limits memory oldLimits = limits;
        Limits memory newLimits = Limits({ jumpUp: jumpUp, jumpDown: jumpDown });
        if (newLimits.jumpUp != oldLimits.jumpUp || newLimits.jumpDown != oldLimits.jumpDown) {
            limits = newLimits;
            emit LimitsUpdated(oldLimits, newLimits);
        }
    }

    ///////////////////////
    // Oracle Ownership  //
    ///////////////////////

    /// @notice Accept ownership of `oracle` previously transferred to this manager.
    function claimOracleOwnership() external onlyOwner {
        Ownable2Step(address(oracle)).acceptOwnership();
    }

    ////////////////////////
    // Public Safety View //
    ////////////////////////

    /// @notice Returns true if applying `newPrice` against the current oracle
    ///         share price would breach the configured jumpUp/jumpDown limits.
    function wouldTriggerPause(uint256 newPrice) public view returns (bool) {
        uint256 lastPrice = oracle.currentSharePrice();
        Limits memory l = limits;
        return (
            newPrice < lastPrice.mulDivDown(SCALE - l.jumpDown, SCALE) ||
            newPrice > lastPrice.mulDivDown(SCALE + l.jumpUp, SCALE)
        );
    }

    //////////////
    // Internal //
    //////////////

    /// @dev Shared pause-then-write path. On a limit breach: reverts with `UpdateWouldPause`
    ///      if `failOnPause`, else pauses (unless already paused). Then writes the update verbatim.
    function _applyUpdate(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp,
        bool failOnPause
    ) internal {
        if (wouldTriggerPause(targetPrice)) {
            require(!failOnPause, UpdateWouldPause());
            if (!IPausable(vault).paused()) {
                IPausable(vault).pause();
            }
        }
        oracle.applyPriceUpdate(startPrice, targetPrice, vestingDuration, startTimestamp);
    }
}
