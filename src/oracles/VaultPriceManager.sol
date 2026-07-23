// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { BaseVaultPriceManager } from "src/crosschain/BaseVaultPriceManager.sol";
import { PriceSyncMessage, PriceSyncMessageLib } from "src/crosschain/PriceSyncMessage.sol";
import { PriceUpdate } from "src/interfaces/IUltraVaultOracle.sol";
import { IPausable } from "src/interfaces/IPausable.sol";

/// @title VaultPriceManager
/// @notice Main-chain price manager: applies updates locally and broadcasts them over
///         CCIP to every active destination so all chains stay in lockstep.
contract VaultPriceManager is BaseVaultPriceManager {
    using SafeERC20 for IERC20;

    ////////////
    // Events //
    ////////////

    event DestinationAdded(uint64 indexed selector, address receiver, uint256 gasLimit);
    event DestinationRemoved(uint64 indexed selector);
    event DestinationConfigUpdated(uint64 indexed selector, address receiver, uint256 gasLimit);
    event DestinationActiveSet(uint64 indexed selector, bool active);
    event Broadcast(uint64 indexed selector, uint64 indexed nonce, bytes32 messageId);
    event LinkWithdrawn(address indexed to, uint256 amount);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);

    ////////////
    // Errors //
    ////////////

    error DestinationNotFound();
    error DestinationAlreadyExists();
    error InvalidGasLimit();
    error InvalidDelay();
    error Overflow();

    ///////////////
    // Constants //
    ///////////////

    uint256 public constant MIN_DELAY = 15 minutes;
    uint256 public constant MAX_DELAY = 3 hours;
    uint256 public constant DEFAULT_DELAY = 1 hours;

    ///////////
    // Types //
    ///////////

    struct Destination {
        address receiver;
        uint256 gasLimit;
        bool active;
        bool exists;
    }

    /////////////
    // Storage //
    /////////////

    IRouterClient public immutable ccipRouter;
    IERC20 public immutable linkToken;

    /// @notice Lead time before a scheduled update activates (main chain only).
    uint256 public delay;

    mapping(uint64 chainSelector => Destination) public destinations;
    uint64[] public destinationSelectors;

    /// @notice Last broadcast nonce. Incremented per broadcast and stamped on each message.
    uint64 public broadcastNonce;

    /////////////////
    // Constructor //
    /////////////////

    /// @param _initialNonce Starting broadcast nonce; the first broadcast uses
    ///        `_initialNonce + 1`. On a redeploy, set this to the highest `lastNonce`
    ///        across remotes so they keep accepting broadcasts (0 for a fresh deploy).
    constructor(
        address _oracle,
        address _vault,
        address _owner,
        address _ccipRouter,
        address _linkToken,
        uint64 _initialNonce
    ) BaseVaultPriceManager(_oracle, _vault, _owner) {
        require(_ccipRouter != address(0) && _linkToken != address(0), ZeroAddress());
        ccipRouter = IRouterClient(_ccipRouter);
        linkToken = IERC20(_linkToken);
        delay = DEFAULT_DELAY;
        broadcastNonce = _initialNonce;

        // Pre-approve max LINK so each ccipSend can pull its fee.
        IERC20(_linkToken).approve(_ccipRouter, type(uint256).max);
    }

    //////////////////
    // Oracle Logic //
    //////////////////

    /// @notice Schedule an instant update and broadcast it. Activates at `now + delay`.
    /// @param failOnPause If true, revert instead of pausing when `newPrice` breaches the limits.
    function instantPriceUpdate(uint256 newPrice, bool failOnPause) external onlyAdminOrOwner {
        uint256 startTimestamp = block.timestamp + delay;
        // startPrice is unused for an instant update; reuse newPrice.
        bool pauseRequired = _applyUpdate(newPrice, newPrice, 0, startTimestamp, failOnPause);
        _broadcastUpdate(newPrice, newPrice, 0, startTimestamp, pauseRequired);
    }

    /// @notice Schedule a linear-vested update and broadcast it. Vesting begins at
    ///         `now + delay`; the start price is projected to that instant for continuity.
    /// @param failOnPause If true, revert instead of pausing when `newPrice` breaches the limits.
    function linearPriceUpdate(uint256 newPrice, uint256 duration, bool failOnPause) external onlyAdminOrOwner {
        uint256 startTimestamp = block.timestamp + delay;
        uint256 startPrice = oracle.sharePriceAt(startTimestamp);
        bool pauseRequired = _applyUpdate(startPrice, newPrice, duration, startTimestamp, failOnPause);
        _broadcastUpdate(startPrice, newPrice, duration, startTimestamp, pauseRequired);
    }

    /// @notice Re-broadcast the oracle's latest stored update to a single destination under
    ///         its original nonce (the current `broadcastNonce`), without touching local
    ///         state. Heals a destination that missed broadcasts while deactivated, and
    ///         probes a lane before reactivating it.
    /// @dev    Idempotent: the nonce is not bumped, so a destination that already applied
    ///         this update rejects the re-send as stale, retries are free, and a healthy
    ///         remote keeps `lastNonce == broadcastNonce`.
    ///         Deliberately callable for inactive destinations (lane probe).
    function resyncDestination(uint64 selector) external onlyAdminOrOwner {
        Destination memory dest = destinations[selector];
        require(dest.exists, DestinationNotFound());

        // Field widths match PriceSyncMessage; ranges were enforced by the oracle on write.
        PriceUpdate memory u = oracle.lastUpdate();
        uint64 nonce = broadcastNonce;
        PriceSyncMessage memory psm = PriceSyncMessage({
            nonce: nonce,
            startPrice: u.startPrice,
            targetPrice: u.targetPrice,
            vestingDuration: u.vestingDuration,
            startTimestamp: u.startTimestamp,
            // Heal the destination to the main vault's *current* pause state (honored
            // regardless of nonce). If main is paused, a destination that missed the
            // pausing broadcast pauses too; if main is healthy, no stale pause is forced.
            pauseRequired: IPausable(vault).paused()
        });
        _ccipSendTo(selector, dest, PriceSyncMessageLib.encode(psm), nonce);
    }

    /// @notice Update the activation lead time (bounded).
    function setDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= MIN_DELAY && newDelay <= MAX_DELAY, InvalidDelay());
        emit DelayUpdated(delay, newDelay);
        delay = newDelay;
    }

    ///////////////////////////
    // Destination Registry  //
    ///////////////////////////

    function addDestination(uint64 selector, address receiver, uint256 gasLimit) external onlyOwner {
        require(receiver != address(0), ZeroAddress());
        require(gasLimit != 0, InvalidGasLimit());
        require(!destinations[selector].exists, DestinationAlreadyExists());
        destinations[selector] = Destination({
            receiver: receiver,
            gasLimit: gasLimit,
            active: true,
            exists: true
        });
        destinationSelectors.push(selector);
        emit DestinationAdded(selector, receiver, gasLimit);
    }

    function removeDestination(uint64 selector) external onlyOwner {
        require(destinations[selector].exists, DestinationNotFound());
        delete destinations[selector];
        uint256 last = destinationSelectors.length - 1;
        for (uint256 i; i < last; ++i) {
            if (destinationSelectors[i] == selector) {
                destinationSelectors[i] = destinationSelectors[last];
                break;
            }
        }
        destinationSelectors.pop();
        emit DestinationRemoved(selector);
    }

    function updateDestinationConfig(uint64 selector, address receiver, uint256 gasLimit)
        external
        onlyOwner
    {
        Destination storage dest = destinations[selector];
        require(dest.exists, DestinationNotFound());
        require(receiver != address(0), ZeroAddress());
        require(gasLimit != 0, InvalidGasLimit());
        dest.receiver = receiver;
        dest.gasLimit = gasLimit;
        emit DestinationConfigUpdated(selector, receiver, gasLimit);
    }

    /// @notice Flip a destination's active flag (escape hatch for a stuck destination).
    function setDestinationActive(uint64 selector, bool active_) external onlyAdminOrOwner {
        Destination storage dest = destinations[selector];
        require(dest.exists, DestinationNotFound());
        dest.active = active_;
        emit DestinationActiveSet(selector, active_);
    }

    function destinationsCount() external view returns (uint256) {
        return destinationSelectors.length;
    }

    function withdrawLink(address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        linkToken.safeTransfer(to, amount);
        emit LinkWithdrawn(to, amount);
    }

    //////////////
    // Internal //
    //////////////

    function _broadcastUpdate(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp,
        bool pauseRequired
    ) internal {
        require(startPrice <= type(uint88).max, Overflow());
        require(targetPrice <= type(uint88).max, Overflow());
        require(vestingDuration <= type(uint40).max, Overflow());
        require(startTimestamp <= type(uint40).max, Overflow());

        uint64 nonce = ++broadcastNonce;

        PriceSyncMessage memory psm = PriceSyncMessage({
            nonce: nonce,
            startPrice: uint88(startPrice),
            targetPrice: uint88(targetPrice),
            vestingDuration: uint40(vestingDuration),
            startTimestamp: uint40(startTimestamp),
            pauseRequired: pauseRequired
        });
        bytes memory payload = PriceSyncMessageLib.encode(psm);

        uint256 len = destinationSelectors.length;
        for (uint256 i; i < len; ++i) {
            uint64 selector = destinationSelectors[i];
            Destination memory dest = destinations[selector];
            if (!dest.active) continue;

            // No try/catch: any send failure reverts the whole tx (all-or-nothing).
            _ccipSendTo(selector, dest, payload, nonce);
        }
    }

    function _ccipSendTo(
        uint64 selector,
        Destination memory dest,
        bytes memory payload,
        uint64 nonce
    ) internal {
        Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
            receiver: abi.encode(dest.receiver),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: dest.gasLimit })),
            feeToken: address(linkToken)
        });

        bytes32 messageId = ccipRouter.ccipSend(selector, ccipMsg);
        emit Broadcast(selector, nonce, messageId);
    }
}
