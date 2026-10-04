/// Ethereum's encodings, read and written byte for byte: the `VaultMessages` payload, the digests the hub proves, the
/// log data the light clients check, an index's CREATE2 address, and `attest`'s record. The twin of
/// `crates/xindex-core/src/abi.rs` and `sui/sources/abi.move`; the tests pin every function against values Solidity's
/// own encoder produced (`cast abi-encode`).
module xindex_vault::abi {
    use aptos_std::aptos_hash::keccak256;
    use xindex_vault::bytes;

    /// Not the canonical encoding of a message or of its body.
    const EBadMessage: u64 = 201;
    /// A number past 64 bits: an amount, a chain id or a nonce.
    const EOverflow: u64 = 202;

    /// `keccak256("xindex.v4.vault-message")`.
    const DOMAIN: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0";
    /// `keccak256("VaultMessage(bytes32,bytes)")`, the log's first topic.
    const EVENT_TOPIC: vector<u8> = x"88e9f343da472582cef35a32362e15cbdbfd89b650463c638b28bb9d12098e8b";
    /// `keccak256("xindex.v4.vault.index-digest")`.
    const INDEX_DIGEST_DOMAIN: vector<u8> = x"df4e41877859fe1e24a1c7d90334348c094634ae191591983221bdba2ada064b";
    /// `keccak256("xindex.v4.vault.intake-digest")`.
    const INTAKE_DIGEST_DOMAIN: vector<u8> = x"73bc63cbb2438f9ca78af51ef010ac754ee98b02f528cf72c876da9a84dd01f9";
    /// `keccak256("xindex.v4.vault-attest")`: the domain of `attest`'s record (interfaces doc).
    const ATTEST_DOMAIN: vector<u8> = x"b0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c";
    /// The EIP-1167 clone's creation code around its implementation, as OpenZeppelin's `Clones` deploys it.
    const CLONE_PREFIX: vector<u8> = x"3d602d80600a3d3981f3363d3d373d3d3d363d73";
    const CLONE_SUFFIX: vector<u8> = x"5af43d82803e903d91602b57fd5bf3";

    const WORD: u64 = 32;
    /// The payload's head: domain, source chain, kind, destination chain, vault, index, nonce, and the body's offset.
    const HEAD: u64 = 256;
    const MAX_U64: u256 = 0xffffffffffffffff;

    /// One message, decoded: the fields the vault checks, and the body its kind reads.
    struct Message has copy, drop {
        source_chain_id: u64,
        kind: u8,
        dest_chain_id: u64,
        vault: vector<u8>,
        index: vector<u8>,
        nonce: u64,
        body: vector<u8>,
    }

    public fun source_chain_id(m: &Message): u64 { m.source_chain_id }

    public fun kind(m: &Message): u8 { m.kind }

    public fun dest_chain_id(m: &Message): u64 { m.dest_chain_id }

    public fun vault(m: &Message): vector<u8> { m.vault }

    public fun index(m: &Message): vector<u8> { m.index }

    public fun nonce(m: &Message): u64 { m.nonce }

    public fun body(m: &Message): vector<u8> { m.body }

    public fun event_topic(): vector<u8> { EVENT_TOPIC }

    /// Decodes `abi.encode(DOMAIN, sourceChainId, kind, destChainId, vault, index, nonce, body)`, refusing anything but
    /// its canonical encoding: a payload is known by its hash, so one message must have one encoding.
    public fun decode_message(p: &vector<u8>): Message {
        let domain = DOMAIN;
        assert!(p.length() >= HEAD + WORD && bytes::slice_eq(p, 0, WORD, &domain), EBadMessage);
        let source_chain_id = u64_at(p, 1);
        let kind = bytes::u256_at(p, 2 * WORD);
        assert!(kind <= 0xff, EBadMessage);
        let dest_chain_id = u64_at(p, 3);
        let vault = bytes::slice(p, 4 * WORD, WORD);
        let index = address_at(p, 5 * WORD);
        let nonce = u64_at(p, 6);
        assert!(u64_at(p, 7) == HEAD, EBadMessage);
        let len = u64_at(p, 8);
        assert!(len <= p.length(), EBadMessage);
        let start = HEAD + WORD;
        let padded = (len + WORD - 1) / WORD * WORD;
        assert!(p.length() == start + padded, EBadMessage);
        let i = start + len;
        while (i < p.length()) {
            assert!(p[i] == 0, EBadMessage);
            i += 1;
        };
        Message {
            source_chain_id,
            kind: (kind as u8),
            dest_chain_id,
            vault,
            index,
            nonce,
            body: bytes::slice(p, start, len),
        }
    }

    /// Word `i` of `p`, which must fit 64 bits.
    fun u64_at(p: &vector<u8>, i: u64): u64 {
        let w = bytes::u256_at(p, i * WORD);
        assert!(w <= MAX_U64, EOverflow);
        (w as u64)
    }

    /// The address in the word at `at`: its 12 high bytes must be zero, as Solidity's decoder requires.
    fun address_at(p: &vector<u8>, at: u64): vector<u8> {
        let i = 0;
        while (i < 12) {
            assert!(p[at + i] == 0, EBadMessage);
            i += 1;
        };
        bytes::slice(p, at + 12, 20)
    }

    /// The body's `i`-th word, of a body that must be exactly `words` long.
    public fun body_word(body: &vector<u8>, words: u64, i: u64): vector<u8> {
        assert!(body.length() == words * WORD && i < words, EBadMessage);
        bytes::slice(body, i * WORD, WORD)
    }

    /// A word holding an amount, which must fit 64 bits: the vault's coin is APT in octas (interfaces doc).
    public fun amount(w: &vector<u8>): u64 {
        let x = bytes::to_u256(w);
        assert!(x <= MAX_U64, EOverflow);
        (x as u64)
    }

    /// A word holding an address: its 12 high bytes must be zero.
    public fun to_address(w: &vector<u8>): vector<u8> {
        assert!(w.length() == WORD, EBadMessage);
        address_at(w, 0)
    }

    /// A message's id: its payload's hash, the log's second topic.
    public fun message_id(payload: &vector<u8>): vector<u8> {
        keccak256(*payload)
    }

    /// The log's data: `abi.encode(bytes payload)`.
    public fun log_data(payload: &vector<u8>): vector<u8> {
        let out = bytes::word64(WORD);
        out.append(bytes::word64(payload.length()));
        out.append(*payload);
        while (out.length() % WORD != 0) out.push_back(0);
        out
    }

    /// `keccak256(abi.encode(INDEX_DIGEST_DOMAIN, chainId, vault, index, tokens, balances, paid))`, `vault` the vault's
    /// 32-byte id, with the chain's native coin as `address(0)` the only token, listed once the index has been
    /// credited, as `XindexVault._refreshIndexDigest` writes it.
    public fun index_digest(
        chain_id: u64,
        vault: &vector<u8>,
        index: &vector<u8>,
        has: bool,
        balance: u64,
        paid: u64,
    ): vector<u8> {
        let n = if (has) { 1 } else { 0 };
        let tokens = 7 * WORD;
        let balances = tokens + WORD * (1 + n);
        let paids = balances + WORD * (1 + n);
        let out = INDEX_DIGEST_DOMAIN;
        out.append(bytes::word64(chain_id));
        out.append(*vault);
        out.append(bytes::address_word(index));
        out.append(bytes::word64(tokens));
        out.append(bytes::word64(balances));
        out.append(bytes::word64(paids));
        out.append(bytes::word64(n));
        if (has) out.append(bytes::zero32());
        out.append(bytes::word64(n));
        if (has) out.append(bytes::word64(balance));
        out.append(bytes::word64(n));
        if (has) out.append(bytes::word64(paid));
        keccak256(out)
    }

    /// `keccak256(abi.encode(INTAKE_DIGEST_DOMAIN, chainId, vault, index, intakeId, state, tokens, totals))`, as
    /// `XindexVault._refreshIntakeDigest` writes it and the hub's `_intakeDigest` reads it.
    public fun intake_digest(
        chain_id: u64,
        vault: &vector<u8>,
        index: &vector<u8>,
        intake_id: &vector<u8>,
        state: u8,
        has: bool,
        total: u64,
    ): vector<u8> {
        let n = if (has) { 1 } else { 0 };
        let tokens = 8 * WORD;
        let totals = tokens + WORD * (1 + n);
        let out = INTAKE_DIGEST_DOMAIN;
        out.append(bytes::word64(chain_id));
        out.append(*vault);
        out.append(bytes::address_word(index));
        out.append(*intake_id);
        out.append(bytes::word64((state as u64)));
        out.append(bytes::word64(tokens));
        out.append(bytes::word64(totals));
        out.append(bytes::word64(n));
        if (has) out.append(bytes::zero32());
        out.append(bytes::word64(n));
        if (has) out.append(bytes::word64(total));
        keccak256(out)
    }

    /// The address OpenZeppelin's `Clones.predictDeterministicAddress(implementation, salt, deployer)` gives: the
    /// factory's CREATE2 clone of the hub template under `salt`.
    public fun predict_clone(implementation: &vector<u8>, salt: &vector<u8>, deployer: &vector<u8>): vector<u8> {
        let init = CLONE_PREFIX;
        init.append(*implementation);
        init.append(CLONE_SUFFIX);
        let pre = vector[0xff];
        pre.append(*deployer);
        pre.append(*salt);
        pre.append(keccak256(init));
        bytes::slice(&keccak256(pre), 12, 20)
    }

    /// An intake id's deadline: its top 64 bits, `(deadline << 192) | nonce`.
    public fun deadline_of(intake_id: &vector<u8>): u64 {
        bytes::be_at(intake_id, 0, 8)
    }

    /// `attest`'s record: `abi.encode(ATTEST_DOMAIN, uint256 chainId, bytes32 vaultId, uint256 timestamp, bytes32[] slots,
    /// bytes32[] values)`, `timestamp` Aptos's `timestamp::now_microseconds()` when `attest` runs (interfaces doc).
    public fun attest_record(
        chain_id: u64,
        vault: &vector<u8>,
        timestamp_us: u64,
        slots: &vector<vector<u8>>,
        values: &vector<vector<u8>>,
    ): vector<u8> {
        let n = slots.length();
        let out = ATTEST_DOMAIN;
        out.append(bytes::word64(chain_id));
        out.append(*vault);
        out.append(bytes::word64(timestamp_us));
        out.append(bytes::word64(6 * WORD));
        out.append(bytes::word64(6 * WORD + WORD + WORD * n));
        out.append(bytes::word64(n));
        let i = 0;
        while (i < n) {
            out.append(slots[i]);
            i += 1;
        };
        let m = values.length();
        out.append(bytes::word64(m));
        let i = 0;
        while (i < m) {
            out.append(values[i]);
            i += 1;
        };
        out
    }
}
