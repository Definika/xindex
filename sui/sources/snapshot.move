/// What the vault reads of an index at its snapshot exit, and the holder's signature it checks there: the twin of
/// `VaultSnapshot.sol` and of `crates/xindex-core/src/snapshot.rs`, for a vault chain without a 20-byte address for its
/// vault. The chain is named by the id the factory's registry gives it; a recovery address is a whole 32-byte Sui
/// address, so only zero counts as none; and the signed claim names a 32-byte recipient, under a domain whose salt is
/// the vault's 32-byte id.
module xindex_vault::snapshot;

use sui::ecdsa_k1;
use sui::hash::keccak256;
use xindex_vault::bytes;

/// The values read are not a claim's five.
const EBadStateProof: u64 = 161;
/// The component lies past the array's end, or is not this chain's coin (VLT-1).
const EWrongComponent: u64 = 162;
/// A number past what the vault's amounts hold.
const EOverflow: u64 = 163;
/// The share is zero.
const EZeroAmount: u64 = 164;
/// Not the holder's signature, as OpenZeppelin's `ECDSA.tryRecover` would accept it.
const EBadSignature: u64 = 165;

/// The hub's storage a claim reads (`HybridHubStorage`, and OpenZeppelin's ERC-20 namespace), pinned by
/// `test_theHubLayoutIsPinned` against the compiler's layout: the shares' balances, `_components` (slot 0, each
/// `(units << 160) | token`), `_claimOf` (11), `_recovery` (59), `_settledIntakes` (60) and `_sentMessages` (62).
const HUB_SHARES: vector<u8> = x"52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00";
const HUB_COMPONENTS_SLOT: u64 = 0;
const HUB_CLAIMS_SLOT: u64 = 11;
const HUB_RECOVERY_SLOT: u64 = 59;
const HUB_SETTLED_INTAKES_SLOT: u64 = 60;
const HUB_SENT_MESSAGES_SLOT: u64 = 62;
/// `keccak256("xindex.v4.vault-token")`: the factory's id of a vault token on Ethereum is
/// `address(keccak256(abi.encode(VAULT_TOKEN_DOMAIN, chainId, tokenId)))`, a native coin's token id being zero.
const VAULT_TOKEN_DOMAIN: vector<u8> = x"9c6182ca3811bf08fa6c8fe76161124b51b1412ab279edac54be466cd03b37fa";
/// `keccak256("EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)")`.
const EIP712_DOMAIN_TYPEHASH: vector<u8> = x"a604fff5a27d5951f334ccda7abff3286a8af29caeeb196a6f2b40a1dce7612b";
/// `keccak256("SnapshotClaim(address index,address holder,bytes32 recipient)")`.
const SNAPSHOT_CLAIM_TYPEHASH: vector<u8> = x"38c8d6ebb6da097d454f26a5f932a2412f5d91b63e745031c7f4bb55076a86db";
/// `keccak256("Xindex vault")` and `keccak256("1")`: the domain's name and version.
const EIP712_NAME_HASH: vector<u8> = x"534199b67bed380a48670849464c9b396d7a4dc97416a65fc52258f0afe3b9d4";
const EIP712_VERSION_HASH: vector<u8> = x"c89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6";
/// The secp256k1 group order, and half of it: OpenZeppelin's `ECDSA` refuses a signature whose `s` lies above it.
const SECP256K1_ORDER: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
const SECP256K1_HALF_ORDER: u256 = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
const KECCAK256: u8 = 0;
/// 10^18, the hub's unit scale.
const WAD: u256 = 1_000_000_000_000_000_000;
const MAX_U128: u256 = 0xffffffffffffffffffffffffffffffff;
const MAX_U256: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

/// `keccak256(abi.encode(key, slot))`: a mapping's entry at `key`.
public fun mapping_slot(key: &vector<u8>, slot: &vector<u8>): vector<u8> {
    let mut pre = *key;
    pre.append(*slot);
    keccak256(&pre)
}

/// `bytes32(uint256(a) + b)`, wrapping where Solidity's checked sum would revert: a component that large lies past the
/// array's end, so its claim is refused either way.
public fun add(a: &vector<u8>, b: u64): vector<u8> {
    let x = bytes::to_u256(a);
    let b = b as u256;
    bytes::word(if (x > MAX_U256 - b) { x - (MAX_U256 - b) - 1 } else { x + b })
}

/// This chain's coin as the factory names it on Ethereum: `vaultTokenId(chainId, bytes32(0))`.
public fun vault_token(chain_id: u64): vector<u8> {
    let mut pre = VAULT_TOKEN_DOMAIN;
    pre.append(bytes::word64(chain_id));
    pre.append(bytes::zero32());
    bytes::slice(&keccak256(&pre), 12, 20)
}

/// The slots of the hub's storage `holder`'s claim reads, in order: its shares, the component, its claim of the coin,
/// its recovery key on this chain, and the components array's length.
public fun claim_slots(holder: &vector<u8>, component: u64, chain_id: u64): vector<vector<u8>> {
    let h = bytes::address_word(holder);
    let shares = HUB_SHARES;
    let components = keccak256(&bytes::word64(HUB_COMPONENTS_SLOT));
    vector[
        mapping_slot(&h, &shares),
        add(&components, component),
        mapping_slot(
            &bytes::address_word(&vault_token(chain_id)),
            &mapping_slot(&h, &bytes::word64(HUB_CLAIMS_SLOT)),
        ),
        mapping_slot(&bytes::word64(chain_id), &mapping_slot(&h, &bytes::word64(HUB_RECOVERY_SLOT))),
        bytes::word64(HUB_COMPONENTS_SLOT),
    ]
}

/// The slot of `_settledIntakes[intakeId]`.
public fun settled_slot(intake_id: &vector<u8>): vector<u8> {
    mapping_slot(intake_id, &bytes::word64(HUB_SETTLED_INTAKES_SLOT))
}

/// The slot of `_sentMessages[id]`.
public fun sent_slot(id: &vector<u8>): vector<u8> {
    mapping_slot(id, &bytes::word64(HUB_SENT_MESSAGES_SLOT))
}

/// The holder's share from the values its claim read: its shares at the units then in force, rounded down, plus its
/// claim of the coin; and its recovery key, if it registered one. The component must lie inside the array, whose
/// length the slot itself holds, and be this chain's coin: past the array's end lies other storage a holder could fill,
/// with a token and "units" of its choosing (VLT-1). As every amount from Ethereum, the share must fit 64 bits; the
/// shares and the claim must fit 128, as the other twins require, and the product is taken in 256 bits, as Solidity
/// takes it.
public fun share(values: &vector<vector<u8>>, component: u64, chain_id: u64): (u64, Option<vector<u8>>) {
    assert!(values.length() == 5, EBadStateProof);
    let shares = bytes::to_u256(&values[0]);
    let packed = &values[1];
    let claim = bytes::to_u256(&values[2]);
    let recovery = values[3];
    let length = bytes::to_u256(&values[4]);
    assert!((component as u256) < length, EWrongComponent);
    assert!(bytes::slice_eq(packed, 12, 20, &vault_token(chain_id)), EWrongComponent);
    // `(units << 160) | token`: the units are the word's top 96 bits.
    let units = bytes::to_u256(packed) >> 160;
    assert!(shares <= MAX_U128 && claim <= MAX_U128, EOverflow);
    let amount = shares * units / WAD + claim;
    assert!(amount <= 0xffffffffffffffff, EOverflow);
    assert!(amount != 0, EZeroAmount);
    let registered = if (bytes::is_zero(&recovery)) option::none() else option::some(recovery);
    ((amount as u64), registered)
}

/// The id of `holder`'s claim on `index`, by which the vault lets each holder claim once.
public fun claim_id(index: &vector<u8>, holder: &vector<u8>): vector<u8> {
    let mut pre = SNAPSHOT_CLAIM_TYPEHASH;
    pre.append(bytes::address_word(index));
    pre.append(bytes::address_word(holder));
    keccak256(&pre)
}

/// What `holder` signs to have the vault `vault_id` on chain `chain_id` pay its share of `index` to `recipient`: the
/// EIP-712 message `0x1901 ++ domainSeparator ++ structHash`, whose keccak256 is the digest signed.
public fun claim_message(
    vault_id: &vector<u8>,
    chain_id: u64,
    index: &vector<u8>,
    holder: &vector<u8>,
    recipient: &vector<u8>,
): vector<u8> {
    let mut domain = EIP712_DOMAIN_TYPEHASH;
    domain.append(EIP712_NAME_HASH);
    domain.append(EIP712_VERSION_HASH);
    domain.append(bytes::word64(chain_id));
    domain.append(*vault_id);
    let mut claim = SNAPSHOT_CLAIM_TYPEHASH;
    claim.append(bytes::address_word(index));
    claim.append(bytes::address_word(holder));
    claim.append(*recipient);
    let mut message = x"1901";
    message.append(keccak256(&domain));
    message.append(keccak256(&claim));
    message
}

/// Aborts unless `signature` is `holder`'s over keccak256 of `message`, as OpenZeppelin's `ECDSA.tryRecover` accepts
/// one: 65 bytes `r ++ s ++ v`, `r` and `s` nonzero and below the order, `s` in its lower half, `v` 27 or 28, and a
/// signer. A signature whose `r` is no point's x-coordinate is refused by Sui's recovery itself, with its own code.
public fun check_signature(message: &vector<u8>, signature: &vector<u8>, holder: &vector<u8>) {
    assert!(signature.length() == 65, EBadSignature);
    let r = bytes::u256_at(signature, 0);
    let s = bytes::u256_at(signature, 32);
    assert!(r != 0 && r < SECP256K1_ORDER && s != 0 && s <= SECP256K1_HALF_ORDER, EBadSignature);
    let v = signature[64];
    assert!(v == 27 || v == 28, EBadSignature);
    let mut sig = bytes::slice(signature, 0, 64);
    sig.push_back(v - 27);
    let key = ecdsa_k1::decompress_pubkey(&ecdsa_k1::secp256k1_ecrecover(&sig, message, KECCAK256));
    let signer = bytes::slice(&keccak256(&bytes::slice(&key, 1, 64)), 12, 20);
    assert!(signer == *holder, EBadSignature);
}
