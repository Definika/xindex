// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The messages Ethereum sends a vault, and their one encoding. A hub or the factory emits
///         `VaultMessage(id, payload)` with `id = keccak256(payload)`; a vault on another chain accepts the payload
///         once a proof shows that log in a final Ethereum block. The payload names its domain, source and
///         destination chains, vault and index, so no proof can be replayed on another chain, vault or index.
library VaultMessages {
    /// @notice The event every message travels in.
    // Emitted by the Ethereum side, which is not built yet; the vault reads it by its topic, EVENT_TOPIC.
    // wake-disable-next-line unused-event
    event VaultMessage(bytes32 indexed id, bytes payload);

    /// @notice Separates these messages from any other abi-encoded data.
    bytes32 internal constant DOMAIN = keccak256("xindex.v4.vault-message");
    /// @notice `keccak256("VaultMessage(bytes32,bytes)")`, the log's first topic.
    bytes32 internal constant EVENT_TOPIC = keccak256("VaultMessage(bytes32,bytes)");

    /// @notice Pays a redeemer or an executor: body `(bytes32 token, uint256 amount, bytes32 recipient)`.
    uint8 internal constant BURN = 1;
    /// @notice An intake's deposits join the index: body `(uint256 intakeId)`. An intake id carries its deposit
    ///         deadline in its top 64 bits, `(deadline << 192) | nonce`, so nobody can open someone else's intake with a
    ///         different deadline.
    uint8 internal constant INTAKE_SETTLED = 2;
    /// @notice An intake's depositors take their deposits back: body `(uint256 intakeId)`.
    uint8 internal constant INTAKE_FAILED = 3;
    /// @notice Moves coins two index versions share: body `(address newIndex, bytes32 token, uint256 amount)`.
    uint8 internal constant MIGRATE = 4;
    /// @notice Sets a token's quantity cap and outflow floor: body `(bytes32 token, uint256 cap, uint256 floor)`.
    uint8 internal constant CAP_UPDATE = 5;
    /// @notice Freezes the vault: empty body.
    uint8 internal constant FREEZE = 6;
    /// @notice Replaces the guardian's freeze address: body `(bytes32 freezer)`.
    uint8 internal constant FREEZER_CHANGE = 7;
    /// @notice Replaces both Ethereum-event verifiers: body `(bytes32 p1, bytes32 p2)`.
    uint8 internal constant VERIFIER_ROTATION = 8;

    /// @notice One message, decoded.
    struct Message {
        uint256 sourceChainId;
        uint8 kind;
        uint256 destChainId;
        bytes32 vault;
        address index;
        uint256 nonce;
        bytes body;
    }

    /// @notice The payload is not of this domain.
    error WrongDomain(bytes32 domain);

    /// @notice The payload of `m`. The hub and the factory on Ethereum send with it, and the vault's tests build their
    ///         messages with it, so both directions share this one definition of the format.
    // The Ethereum side that sends messages is not built yet; until it is, nothing in src/ calls this.
    // wake-disable-next-line unused-function
    function encode(Message memory m) internal pure returns (bytes memory) {
        return abi.encode(DOMAIN, m.sourceChainId, m.kind, m.destChainId, m.vault, m.index, m.nonce, m.body);
    }

    /// @notice The message in `payload`; reverts `WrongDomain` on a payload of any other format.
    function decode(bytes memory payload) internal pure returns (Message memory m) {
        bytes32 domain;
        (domain, m.sourceChainId, m.kind, m.destChainId, m.vault, m.index, m.nonce, m.body) =
            abi.decode(payload, (bytes32, uint256, uint8, uint256, bytes32, address, uint256, bytes));
        if (domain != DOMAIN) revert WrongDomain(domain);
    }
}
