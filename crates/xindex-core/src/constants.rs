//! The vault's rules, those of the EVM vault (`src/vault/XindexVault.sol`), and the message format of
//! `src/libraries/VaultMessages.sol` and the hub's storage as the snapshot reads it, byte for byte: what every chain's
//! vault holds to alike.

use crate::hex::{h, h20};

/// Largest share of an index's balance that may leave in any 24 hours: 4%, as `SPEED_LIMIT` (0.04e18).
pub const SPEED_LIMIT_PERCENT: u128 = 4;
/// How long a freeze lasts: 14 days.
pub const FREEZE_DURATION: i64 = 14 * 24 * 3600;
/// How long a raised cap or floor, a new freezer or new verifiers wait on the vault before they apply (VLT-2).
pub const GOVERNANCE_DELAY: i64 = 7 * 24 * 3600;
/// How far ahead a first deposit may set an intake's deadline: 7 days.
pub const MAX_INTAKE_LIFE: i64 = 7 * 24 * 3600;
/// How long the vault goes without a new checkpoint before it is stalled: 7 days.
pub const STALL_PERIOD: i64 = 7 * 24 * 3600;
/// How long a proposed successor pair is under review before anyone may adopt it: 30 days.
pub const RECOVERY_DELAY: i64 = 30 * 24 * 3600;
/// How many successors the freezer may veto in one stall.
pub const MAX_RECOVERY_VETOES: u8 = 2;
/// How long after a stall began its last checkpoint becomes the snapshot: 180 days.
pub const SNAPSHOT_EXIT_DELAY: i64 = 180 * 24 * 3600;
/// The current hour and the 24 before it: every real 24-hour span lies inside them.
pub const BUCKETS: usize = 25;
pub const HOUR: i64 = 3600;

/// Message kinds, as `VaultMessages`.
pub const BURN: u8 = 1;
pub const INTAKE_SETTLED: u8 = 2;
pub const INTAKE_FAILED: u8 = 3;
pub const MIGRATE: u8 = 4;
pub const CAP_UPDATE: u8 = 5;
pub const FREEZE: u8 = 6;
pub const FREEZER_CHANGE: u8 = 7;
pub const VERIFIER_ROTATION: u8 = 8;

/// Intake states, as `IXindexVault.IntakeState`.
pub const INTAKE_NONE: u8 = 0;
pub const INTAKE_OPEN: u8 = 1;
pub const INTAKE_SETTLED_STATE: u8 = 2;
pub const INTAKE_FAILED_STATE: u8 = 3;

/// `keccak256("xindex.v4.vault-message")`.
pub const DOMAIN: [u8; 32] = h("bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0");
/// `keccak256("VaultMessage(bytes32,bytes)")`, the log's first topic.
pub const EVENT_TOPIC: [u8; 32] =
    h("88e9f343da472582cef35a32362e15cbdbfd89b650463c638b28bb9d12098e8b");
/// `keccak256("xindex.v4.vault.index-digest")`.
pub const INDEX_DIGEST_DOMAIN: [u8; 32] =
    h("df4e41877859fe1e24a1c7d90334348c094634ae191591983221bdba2ada064b");
/// `keccak256("xindex.v4.vault.intake-digest")`.
pub const INTAKE_DIGEST_DOMAIN: [u8; 32] =
    h("73bc63cbb2438f9ca78af51ef010ac754ee98b02f528cf72c876da9a84dd01f9");

/// The hub's storage the snapshot exit reads (`HybridHubStorage`, and OpenZeppelin's ERC-20 namespace), as the EVM
/// vault and `VaultSnapshot` read it, pinned by `test_theHubLayoutIsPinned` against the compiler's layout: the shares'
/// balances, `_components` (slot 0, each `(units << 160) | token`), `_claimOf` (11), `_recovery` (59),
/// `_settledIntakes` (60) and `_sentMessages` (62).
pub const HUB_SHARES: [u8; 32] =
    h("52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00");
pub const HUB_COMPONENTS_SLOT: u64 = 0;
pub const HUB_CLAIMS_SLOT: u64 = 11;
pub const HUB_RECOVERY_SLOT: u64 = 59;
pub const HUB_SETTLED_INTAKES_SLOT: u64 = 60;
pub const HUB_SENT_MESSAGES_SLOT: u64 = 62;
/// `keccak256("xindex.v4.vault-token")`: the factory's id of a vault token on Ethereum is
/// `address(keccak256(abi.encode(VAULT_TOKEN_DOMAIN, chainId, tokenId)))`, a native coin's token id being zero.
pub const VAULT_TOKEN_DOMAIN: [u8; 32] =
    h("9c6182ca3811bf08fa6c8fe76161124b51b1412ab279edac54be466cd03b37fa");
/// EIP-712, for a holder's signature on its snapshot claim on a chain whose vault has no 20-byte address: the domain
/// carries the vault's 32-byte id as its salt, and the claim names a 32-byte recipient.
/// `keccak256("EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)")`.
pub const EIP712_DOMAIN_TYPEHASH: [u8; 32] =
    h("a604fff5a27d5951f334ccda7abff3286a8af29caeeb196a6f2b40a1dce7612b");
/// `keccak256("SnapshotClaim(address index,address holder,bytes32 recipient)")`.
pub const SNAPSHOT_CLAIM_TYPEHASH: [u8; 32] =
    h("38c8d6ebb6da097d454f26a5f932a2412f5d91b63e745031c7f4bb55076a86db");
/// `keccak256("Xindex vault")` and `keccak256("1")`: the domain's name and version.
pub const EIP712_NAME_HASH: [u8; 32] =
    h("534199b67bed380a48670849464c9b396d7a4dc97416a65fc52258f0afe3b9d4");
pub const EIP712_VERSION_HASH: [u8; 32] =
    h("c89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6");
/// Half the secp256k1 group order: OpenZeppelin's `ECDSA` refuses a signature whose `s` lies above it.
pub const SECP256K1_HALF_ORDER: [u8; 32] =
    h("7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0");
/// 10^18, the hub's unit scale.
pub const WAD: u64 = 1_000_000_000_000_000_000;

/// The EIP-1167 clone's creation code around its implementation, as OpenZeppelin's `Clones` deploys it.
pub const CLONE_PREFIX: [u8; 20] = h20("3d602d80600a3d3981f3363d3d373d3d3d363d73");
pub const CLONE_SUFFIX: [u8; 15] = [
    0x5a, 0xf4, 0x3d, 0x82, 0x80, 0x3e, 0x90, 0x3d, 0x91, 0x60, 0x2b, 0x57, 0xfd, 0x5b, 0xf3,
];
