//! What the vault reads of an index at its snapshot exit, and the holder's signature it checks there: the twin of
//! `VaultSnapshot.sol`. Solana's differences: the chain is named by the id the factory's registry gives it, where the
//! EVM vault uses `block.chainid`; a recovery address is a whole 32-byte key, so only zero counts as none; and the
//! signed claim names a 32-byte recipient, under a domain whose salt is the vault's 32-byte id.

use anchor_lang::prelude::*;
use solana_secp256k1_recover::secp256k1_recover;

use crate::abi::keccak;
use crate::constants::*;
use crate::error::VaultError;

/// The slots a claim reads, in order: the holder's shares, the component, its claim of the coin, its recovery key on
/// this chain, and the components array's length.
pub const CLAIM_SLOTS: usize = 5;

pub fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

pub fn address_word(a: &[u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

/// `keccak256(abi.encode(key, slot))`: a mapping's entry at `key`.
pub fn mapping_slot(key: &[u8; 32], slot: &[u8; 32]) -> [u8; 32] {
    keccak(&[key, slot])
}

/// `a + b` as 256-bit numbers: an array element's slot, `bytes32(uint256(a) + b)`. It wraps where Solidity's checked
/// sum would revert; a component that large lies past the array's end, so its claim is refused either way.
fn add(a: &[u8; 32], b: u64) -> [u8; 32] {
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
pub fn vault_token(chain_id: u64) -> [u8; 20] {
    keccak(&[&VAULT_TOKEN_DOMAIN, &word(chain_id), &[0u8; 32]])[12..]
        .try_into()
        .unwrap()
}

/// The slots of the hub's storage `holder`'s claim reads (`CLAIM_SLOTS`).
pub fn claim_slots(holder: &[u8; 20], component: u64, chain_id: u64) -> [[u8; 32]; CLAIM_SLOTS] {
    let h = address_word(holder);
    let components = keccak(&[&word(HUB_COMPONENTS_SLOT)]);
    [
        mapping_slot(&h, &HUB_SHARES),
        add(&components, component),
        mapping_slot(
            &address_word(&vault_token(chain_id)),
            &mapping_slot(&h, &word(HUB_CLAIMS_SLOT)),
        ),
        mapping_slot(&word(chain_id), &mapping_slot(&h, &word(HUB_RECOVERY_SLOT))),
        word(HUB_COMPONENTS_SLOT),
    ]
}

/// The slot of `_settledIntakes[intakeId]`.
pub fn settled_slot(intake_id: &[u8; 32]) -> [u8; 32] {
    mapping_slot(intake_id, &word(HUB_SETTLED_INTAKES_SLOT))
}

/// The slot of `_sentMessages[id]`.
pub fn sent_slot(id: &[u8; 32]) -> [u8; 32] {
    mapping_slot(id, &word(HUB_SENT_MESSAGES_SLOT))
}

fn to_u128(w: &[u8; 32]) -> Result<u128> {
    require!(w[..16].iter().all(|b| *b == 0), VaultError::Overflow);
    Ok(u128::from_be_bytes(w[16..].try_into().unwrap()))
}

/// The holder's share from the values its claim read: its shares at the units then in force, rounded down, plus its
/// claim of the coin; and its recovery key, if it registered one. The component must lie inside the array, whose
/// length the slot itself holds, and be this chain's coin: past the array's end lies other storage a holder could fill,
/// with a token and "units" of its choosing (VLT-1). As every amount from Ethereum, the share must fit 64 bits.
pub fn share(values: &[[u8; 32]], component: u64, chain_id: u64) -> Result<(u64, Option<Pubkey>)> {
    let [shares, packed, claim, recovery, length] = values else {
        return err!(VaultError::BadStateProof);
    };
    let inside = length[..24].iter().any(|b| *b != 0)
        || component < u64::from_be_bytes(length[24..].try_into().unwrap());
    require!(
        inside && packed[12..] == vault_token(chain_id),
        VaultError::WrongComponent
    );
    // `(units << 160) | token`: the units are the word's top 96 bits.
    let units = u128::from_be_bytes([&[0u8; 4][..], &packed[..12]].concat().try_into().unwrap());
    let backing = to_u128(shares)?
        .checked_mul(units)
        .ok_or(VaultError::Overflow)?
        / WAD as u128;
    let amount = backing
        .checked_add(to_u128(claim)?)
        .ok_or(VaultError::Overflow)?;
    let amount = u64::try_from(amount).map_err(|_| VaultError::Overflow)?;
    require!(amount != 0, VaultError::ZeroAmount);
    let registered = (*recovery != [0u8; 32]).then(|| Pubkey::new_from_array(*recovery));
    Ok((amount, registered))
}

/// The id of `holder`'s claim on `index`: its owed account's seed, so a holder claims once.
pub fn claim_id(index: &[u8; 20], holder: &[u8; 20]) -> [u8; 32] {
    keccak(&[
        &SNAPSHOT_CLAIM_TYPEHASH,
        &address_word(index),
        &address_word(holder),
    ])
}

/// The EIP-712 digest `holder` signs to have the vault `vault_id` on chain `chain_id` pay its share of `index` to
/// `recipient`.
pub fn claim_digest(
    vault_id: &[u8; 32],
    chain_id: u64,
    index: &[u8; 20],
    holder: &[u8; 20],
    recipient: &Pubkey,
) -> [u8; 32] {
    let domain = keccak(&[
        &EIP712_DOMAIN_TYPEHASH,
        &EIP712_NAME_HASH,
        &EIP712_VERSION_HASH,
        &word(chain_id),
        vault_id,
    ]);
    let claim = keccak(&[
        &SNAPSHOT_CLAIM_TYPEHASH,
        &address_word(index),
        &address_word(holder),
        recipient.as_ref(),
    ]);
    keccak(&[b"\x19\x01", &domain, &claim])
}

/// `signature` is `holder`'s over `digest`, as OpenZeppelin's `ECDSA.tryRecover` accepts one: 65 bytes `r ++ s ++ v`,
/// `s` in the lower half of the order, `v` 27 or 28, and a signer.
pub fn check_signature(digest: &[u8; 32], signature: &[u8], holder: &[u8; 20]) -> Result<()> {
    require!(signature.len() == 65, VaultError::BadSignature);
    let s: &[u8; 32] = signature[32..64].try_into().unwrap();
    require!(*s <= SECP256K1_HALF_ORDER, VaultError::BadSignature);
    let v = signature[64];
    require!(v == 27 || v == 28, VaultError::BadSignature);
    let key = secp256k1_recover(digest, v - 27, &signature[..64])
        .map_err(|_| error!(VaultError::BadSignature))?;
    let signer: [u8; 20] = keccak(&[&key.to_bytes()])[12..].try_into().unwrap();
    require!(signer == *holder, VaultError::BadSignature);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_constants_are_their_hashes() {
        assert_eq!(keccak(&[b"xindex.v4.vault-token"]), VAULT_TOKEN_DOMAIN);
        assert_eq!(
            keccak(&[b"EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)"]),
            EIP712_DOMAIN_TYPEHASH
        );
        assert_eq!(
            keccak(&[b"SnapshotClaim(address index,address holder,bytes32 recipient)"]),
            SNAPSHOT_CLAIM_TYPEHASH
        );
        assert_eq!(keccak(&[b"Xindex vault"]), EIP712_NAME_HASH);
        assert_eq!(keccak(&[b"1"]), EIP712_VERSION_HASH);
    }

    #[test]
    fn an_array_slot_adds_with_carry() {
        let mut a = [0u8; 32];
        a[31] = 0xff;
        a[30] = 0xff;
        let b = add(&a, 1);
        assert_eq!(&b[29..], &[1, 0, 0]);
        assert_eq!(add(&[0xff; 32], 1), [0u8; 32]);
    }
}
