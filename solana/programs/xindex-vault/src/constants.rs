//! The vault's constants: those of the EVM vault (`src/vault/XindexVault.sol`), and the message format of
//! `src/libraries/VaultMessages.sol`, byte for byte.

pub const CONFIG_SEED: &[u8] = b"config";
pub const TREASURY_SEED: &[u8] = b"treasury";
pub const INDEX_SEED: &[u8] = b"index";
pub const INTAKE_SEED: &[u8] = b"intake";
pub const DEPOSIT_SEED: &[u8] = b"deposit";
pub const USED_SEED: &[u8] = b"used";
pub const OWED_SEED: &[u8] = b"owed";

/// Largest share of an index's balance that may leave in any 24 hours: 4%, as `SPEED_LIMIT` (0.04e18).
pub const SPEED_LIMIT_PERCENT: u128 = 4;
/// How long a freeze lasts: 14 days.
pub const FREEZE_DURATION: i64 = 14 * 24 * 3600;
/// How far ahead a first deposit may set an intake's deadline: 7 days.
pub const MAX_INTAKE_LIFE: i64 = 7 * 24 * 3600;
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
pub const DOMAIN: [u8; 32] =
    hex32("bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0");
/// `keccak256("VaultMessage(bytes32,bytes)")`, the log's first topic.
pub const EVENT_TOPIC: [u8; 32] =
    hex32("88e9f343da472582cef35a32362e15cbdbfd89b650463c638b28bb9d12098e8b");
/// `keccak256("xindex.v4.vault.index-digest")`.
pub const INDEX_DIGEST_DOMAIN: [u8; 32] =
    hex32("df4e41877859fe1e24a1c7d90334348c094634ae191591983221bdba2ada064b");
/// `keccak256("xindex.v4.vault.intake-digest")`.
pub const INTAKE_DIGEST_DOMAIN: [u8; 32] =
    hex32("73bc63cbb2438f9ca78af51ef010ac754ee98b02f528cf72c876da9a84dd01f9");

/// The EIP-1167 clone's creation code around its implementation, as OpenZeppelin's `Clones` deploys it.
pub const CLONE_PREFIX: [u8; 20] = hex20("3d602d80600a3d3981f3363d3d373d3d3d363d73");
pub const CLONE_SUFFIX: [u8; 15] = [
    0x5a, 0xf4, 0x3d, 0x82, 0x80, 0x3e, 0x90, 0x3d, 0x91, 0x60, 0x2b, 0x57, 0xfd, 0x5b, 0xf3,
];

const fn nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("not hex"),
    }
}

const fn hex32(s: &str) -> [u8; 32] {
    let b = s.as_bytes();
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = nibble(b[2 * i]) << 4 | nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}

const fn hex20(s: &str) -> [u8; 20] {
    let b = s.as_bytes();
    let mut out = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        out[i] = nibble(b[2 * i]) << 4 | nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}
