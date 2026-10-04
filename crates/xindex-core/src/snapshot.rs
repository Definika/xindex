//! What a vault reads of an index at its snapshot exit, and the holder's signature it checks there: the twin of
//! `VaultSnapshot.sol`, for a vault chain without a 20-byte address for its vault. The chain is named by the id the
//! factory's registry gives it, where the EVM vault uses `block.chainid`; a recovery address is a whole 32-byte key, so
//! only zero counts as none; and the signed claim names a 32-byte recipient, under a domain whose salt is the vault's
//! 32-byte id.

use crate::abi::{address_word, u256};
use crate::constants::*;
use crate::crypto::Crypto;

/// The slots a claim reads, in order: the holder's shares, the component, its claim of the coin, its recovery key on
/// this chain, and the components array's length.
pub const CLAIM_SLOTS: usize = 5;

/// What a claim or its signature may fail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SnapshotError {
    /// The values read are not a claim's five.
    BadStateProof,
    /// The component lies past the array's end, or is not this chain's coin (VLT-1).
    WrongComponent,
    /// A number past what the vault's amounts hold.
    Overflow,
    ZeroAmount,
    BadSignature,
}

/// `keccak256(abi.encode(key, slot))`: a mapping's entry at `key`.
pub fn mapping_slot<C: Crypto>(c: &C, key: &[u8; 32], slot: &[u8; 32]) -> [u8; 32] {
    c.keccak256(&[key, slot])
}

/// `a + b` as 256-bit numbers: an array element's slot, `bytes32(uint256(a) + b)`. It wraps where Solidity's checked
/// sum would revert; a component that large lies past the array's end, so its claim is refused either way.
pub fn add(a: &[u8; 32], b: u64) -> [u8; 32] {
    let mut out = *a;
    let mut carry = b as u128;
    for i in (0..32).rev() {
        if carry == 0 {
            break;
        }
        let sum = out[i] as u128 + (carry & 0xff);
        out[i] = sum as u8;
        carry = (carry >> 8) + (sum >> 8);
    }
    out
}

/// This chain's coin as the factory names it on Ethereum: `vaultTokenId(chainId, bytes32(0))`.
pub fn vault_token<C: Crypto>(c: &C, chain_id: u64) -> [u8; 20] {
    c.keccak256(&[&VAULT_TOKEN_DOMAIN, &u256(chain_id), &[0u8; 32]])[12..]
        .try_into()
        .unwrap()
}

/// The slots of the hub's storage `holder`'s claim reads (`CLAIM_SLOTS`).
pub fn claim_slots<C: Crypto>(
    c: &C,
    holder: &[u8; 20],
    component: u64,
    chain_id: u64,
) -> [[u8; 32]; CLAIM_SLOTS] {
    let h = address_word(holder);
    let components = c.keccak256(&[&u256(HUB_COMPONENTS_SLOT)]);
    [
        mapping_slot(c, &h, &HUB_SHARES),
        add(&components, component),
        mapping_slot(
            c,
            &address_word(&vault_token(c, chain_id)),
            &mapping_slot(c, &h, &u256(HUB_CLAIMS_SLOT)),
        ),
        mapping_slot(
            c,
            &u256(chain_id),
            &mapping_slot(c, &h, &u256(HUB_RECOVERY_SLOT)),
        ),
        u256(HUB_COMPONENTS_SLOT),
    ]
}

/// The slot of `_settledIntakes[intakeId]`.
pub fn settled_slot<C: Crypto>(c: &C, intake_id: &[u8; 32]) -> [u8; 32] {
    mapping_slot(c, intake_id, &u256(HUB_SETTLED_INTAKES_SLOT))
}

/// The slot of `_sentMessages[id]`.
pub fn sent_slot<C: Crypto>(c: &C, id: &[u8; 32]) -> [u8; 32] {
    mapping_slot(c, id, &u256(HUB_SENT_MESSAGES_SLOT))
}

fn to_u128(w: &[u8; 32]) -> Result<u128, SnapshotError> {
    if !w[..16].iter().all(|b| *b == 0) {
        return Err(SnapshotError::Overflow);
    }
    Ok(u128::from_be_bytes(w[16..].try_into().unwrap()))
}

/// The holder's share from the values its claim read: its shares at the units then in force, rounded down, plus its
/// claim of the coin; and its recovery key, if it registered one. The component must lie inside the array, whose
/// length the slot itself holds, and be this chain's coin: past the array's end lies other storage a holder could fill,
/// with a token and "units" of its choosing (VLT-1). As every amount from Ethereum, the share must fit 64 bits.
pub fn share<C: Crypto>(
    c: &C,
    values: &[[u8; 32]],
    component: u64,
    chain_id: u64,
) -> Result<(u64, Option<[u8; 32]>), SnapshotError> {
    let v = claim_values(c, values, component, chain_id)?;
    let backing = v
        .shares
        .checked_mul(v.units)
        .ok_or(SnapshotError::Overflow)?
        / WAD as u128;
    let amount = backing
        .checked_add(v.claim)
        .ok_or(SnapshotError::Overflow)?;
    let amount = u64::try_from(amount).map_err(|_| SnapshotError::Overflow)?;
    if amount == 0 {
        return Err(SnapshotError::ZeroAmount);
    }
    Ok((amount, v.recovery))
}

/// `share`, for a chain whose amounts need 128 bits, as NEAR's yoctoNEAR do. The hub's `shares * units / 1e18` is
/// computed in 256 bits, as Solidity computes it: on such a chain a share's units alone can pass 2^80, so the product
/// can pass 2^128 while the share itself fits. The share must fit 128 bits.
pub fn share_wide<C: Crypto>(
    c: &C,
    values: &[[u8; 32]],
    component: u64,
    chain_id: u64,
) -> Result<(u128, Option<[u8; 32]>), SnapshotError> {
    let v = claim_values(c, values, component, chain_id)?;
    let backing = mul_div_wad(v.shares, v.units).ok_or(SnapshotError::Overflow)?;
    let amount = backing
        .checked_add(v.claim)
        .ok_or(SnapshotError::Overflow)?;
    if amount == 0 {
        return Err(SnapshotError::ZeroAmount);
    }
    Ok((amount, v.recovery))
}

/// What a claim reads of the hub, decoded.
struct ClaimValues {
    shares: u128,
    units: u128,
    claim: u128,
    recovery: Option<[u8; 32]>,
}

/// The holder's shares, the component's units, the holder's claim of the coin and its recovery key, from the values its
/// claim read, once the component is shown inside the array and this chain's coin (VLT-1).
fn claim_values<C: Crypto>(
    c: &C,
    values: &[[u8; 32]],
    component: u64,
    chain_id: u64,
) -> Result<ClaimValues, SnapshotError> {
    let [shares, packed, claim, recovery, length] = values else {
        return Err(SnapshotError::BadStateProof);
    };
    let inside = length[..24].iter().any(|b| *b != 0)
        || component < u64::from_be_bytes(length[24..].try_into().unwrap());
    if !inside || packed[12..] != vault_token(c, chain_id) {
        return Err(SnapshotError::WrongComponent);
    }
    // `(units << 160) | token`: the units are the word's top 96 bits.
    let mut units = [0u8; 16];
    units[4..].copy_from_slice(&packed[..12]);
    let units = u128::from_be_bytes(units);
    Ok(ClaimValues {
        shares: to_u128(shares)?,
        units,
        claim: to_u128(claim)?,
        recovery: (*recovery != [0u8; 32]).then_some(*recovery),
    })
}

/// `a * b / 1e18`, rounded down, with the product in 256 bits; none if the quotient passes 128 bits.
pub fn mul_div_wad(a: u128, b: u128) -> Option<u128> {
    // The product as four 64-bit limbs, most significant first.
    let (a1, a0) = ((a >> 64) as u64, a as u64);
    let (b1, b0) = ((b >> 64) as u64, b as u64);
    let p00 = a0 as u128 * b0 as u128;
    let p01 = a0 as u128 * b1 as u128;
    let p10 = a1 as u128 * b0 as u128;
    let p11 = a1 as u128 * b1 as u128;
    let mid = (p00 >> 64) + (p01 as u64 as u128) + (p10 as u64 as u128);
    let limb0 = p00 as u64;
    let limb1 = mid as u64;
    let high = p11 + (p01 >> 64) + (p10 >> 64) + (mid >> 64);
    let limbs = [(high >> 64) as u64, high as u64, limb1, limb0];
    // Long division by 1e18, which fits 64 bits, limb by limb.
    let d = WAD as u128;
    let mut rem: u128 = 0;
    let mut q = [0u64; 4];
    for (i, limb) in limbs.iter().enumerate() {
        let cur = (rem << 64) | *limb as u128;
        q[i] = (cur / d) as u64;
        rem = cur % d;
    }
    if q[0] != 0 || q[1] != 0 {
        return None;
    }
    Some(((q[2] as u128) << 64) | q[3] as u128)
}

/// The id of `holder`'s claim on `index`, by which a vault lets each holder claim once.
pub fn claim_id<C: Crypto>(c: &C, index: &[u8; 20], holder: &[u8; 20]) -> [u8; 32] {
    c.keccak256(&[
        &SNAPSHOT_CLAIM_TYPEHASH,
        &address_word(index),
        &address_word(holder),
    ])
}

/// The EIP-712 digest `holder` signs to have the vault `vault_id` on chain `chain_id` pay its share of `index` to
/// `recipient`.
pub fn claim_digest<C: Crypto>(
    c: &C,
    vault_id: &[u8; 32],
    chain_id: u64,
    index: &[u8; 20],
    holder: &[u8; 20],
    recipient: &[u8; 32],
) -> [u8; 32] {
    let domain = c.keccak256(&[
        &EIP712_DOMAIN_TYPEHASH,
        &EIP712_NAME_HASH,
        &EIP712_VERSION_HASH,
        &u256(chain_id),
        vault_id,
    ]);
    let claim = c.keccak256(&[
        &SNAPSHOT_CLAIM_TYPEHASH,
        &address_word(index),
        &address_word(holder),
        recipient,
    ]);
    c.keccak256(&[b"\x19\x01", &domain, &claim])
}

/// `signature` is `holder`'s over `digest`, as OpenZeppelin's `ECDSA.tryRecover` accepts one: 65 bytes `r ++ s ++ v`,
/// `s` in the lower half of the order, `v` 27 or 28, and a signer.
pub fn check_signature<C: Crypto>(
    c: &C,
    digest: &[u8; 32],
    signature: &[u8],
    holder: &[u8; 20],
) -> Result<(), SnapshotError> {
    if signature.len() != 65 {
        return Err(SnapshotError::BadSignature);
    }
    let s: &[u8; 32] = signature[32..64].try_into().unwrap();
    if *s > SECP256K1_HALF_ORDER {
        return Err(SnapshotError::BadSignature);
    }
    let v = signature[64];
    if v != 27 && v != 28 {
        return Err(SnapshotError::BadSignature);
    }
    let key = c
        .secp256k1_recover(digest, v - 27, signature[..64].try_into().unwrap())
        .map_err(|_| SnapshotError::BadSignature)?;
    let signer: [u8; 20] = c.keccak256(&[&key])[12..].try_into().unwrap();
    if signer != *holder {
        return Err(SnapshotError::BadSignature);
    }
    Ok(())
}
