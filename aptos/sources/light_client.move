/// P1 and P2 on Aptos: a light client of Ethereum, the twin of `FinalityVerifier.sol`, of
/// `crates/xindex-core/src/light_client.rs` and of `sui/sources/light_client.move`. Anyone advances it with a proof that
/// a checkpoint is finalized by two thirds of the anchor's validators, and it proves a vault message by its receipt in
/// any execution block those proofs covered. P1 is advanced by SP1 proofs (`EthereumFinalityVerifier`), P2 by RISC Zero
/// proofs of the same statement with the same public values (`RiscZeroFinalityVerifier`); only `proofs::verify_sp1` or
/// `verify_risc0` differs.
///
/// Each lives at an object of its own, whose address the vault names, as the EVM vault names a verifier by its
/// address. The object is unowned (its owner is `0x0`, which nobody can sign for) and can never be transferred or
/// deleted; no reference to it is kept, so nothing but this module's code ever touches its state. No owner, no upgrade:
/// the first anchor comes from its creator, checked during the vault's listing delay on Ethereum; every later one is
/// proven, one step at a time from the stored anchor. A light client left more than `MAX_LAG` behind stops for good
/// (LG-4). The program key or image id fixes the statement, and with it Ethereum's network and fork schedule: a new fork
/// needs a new light client, rotated in on the vault.
module xindex_vault::light_client {
    use std::option::{Self, Option};
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use xindex_vault::bytes;
    use xindex_vault::ethereum;
    use xindex_vault::proofs;
    use xindex_vault::rlp;

    /// Not SP1 (1) or RISC Zero (2).
    const EUnknownSystem: u64 = 131;
    /// A key, anchor or genesis time of zero.
    const EZeroValue: u64 = 132;
    /// The anchor's epoch began more than MAX_LAG ago: the light client stopped for good (`TooOld`).
    const ELagging: u64 = 133;
    /// The public values are not `abi.encode(bytes32, bytes32, uint64, bytes32, uint64, uint64)`.
    const EBadPublicValues: u64 = 134;
    /// The proof starts from another anchor.
    const EWrongAnchor: u64 = 135;
    /// No proof recorded the headers root.
    const EUnknownHeaders: u64 = 136;
    /// The log is not the one claimed: another block, emitter, topic or data.
    const ENotTheLog: u64 = 137;
    /// The block is not the checkpoint claimed: another number, timestamp or state root.
    const ENotTheCheckpoint: u64 = 138;
    /// No light client lives at the address.
    const ENoClient: u64 = 139;

    /// SP1's Groth16 proof (P1's), or RISC Zero's (P2's).
    const SP1: u8 = 1;
    const RISC_ZERO: u8 = 2;
    /// How long after its anchor's epoch began a light client still takes a proof, as `FinalityVerifier.MAX_LAG`.
    const MAX_LAG: u64 = 86_400;
    /// An epoch's length: 32 slots of 12 seconds.
    const SECONDS_PER_EPOCH: u64 = 384;
    /// `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`.
    const PUBLIC_VALUES_LEN: u64 = 192;
    const MAX_U64: u256 = 0xffffffffffffffff;

    /// The execution blocks one proof covered.
    struct Range has copy, drop, store {
        first: u64,
        last: u64,
    }

    /// A light client: its proof system and the program it accepts, its anchor (`keccak256(abi.encode(epoch,
    /// validatorsRoot, execHash, execNumber))` of the last checkpoint accepted) and that anchor's epoch, the beacon
    /// chain's genesis time (1606824023 on mainnet, 1655733600 on Sepolia), and the blocks each recorded headers root
    /// covers.
    struct LightClient has key {
        system: u8,
        key: vector<u8>,
        anchor: vector<u8>,
        epoch: u64,
        genesis_time: u64,
        ranges: Table<vector<u8>, Range>,
    }

    #[event]
    struct Created has drop, store {
        client: address,
        system: u8,
        key: vector<u8>,
        anchor: vector<u8>,
        epoch: u64,
        genesis_time: u64,
    }

    #[event]
    struct Advanced has drop, store {
        client: address,
        epoch: u64,
        anchor: vector<u8>,
        headers_root: vector<u8>,
        first: u64,
        last: u64,
    }

    /// A light client of `system` (1 SP1, 2 RISC Zero) for the program `key`, from `anchor` at `epoch`, at the object
    /// `object::create_object_address(creator, seed)`. Anyone may make one; a vault trusts only those it names.
    public fun create(
        creator: &signer,
        seed: vector<u8>,
        system: u8,
        key: vector<u8>,
        anchor: vector<u8>,
        epoch: u64,
        genesis_time: u64,
    ): address {
        assert!(system == SP1 || system == RISC_ZERO, EUnknownSystem);
        assert!(key.length() == 32 && anchor.length() == 32, EZeroValue);
        assert!(!bytes::is_zero(&key) && !bytes::is_zero(&anchor) && genesis_time != 0, EZeroValue);
        let cref = object::create_named_object(creator, seed);
        // Owned by nobody, and fixed there: no account can move it or act as its owner.
        object::transfer_with_constructor_ref(&cref, @0x0);
        object::set_untransferable(&cref);
        let client = object::address_from_constructor_ref(&cref);
        move_to(
            &object::generate_signer(&cref),
            LightClient { system, key, anchor, epoch, genesis_time, ranges: table::new() },
        );
        event::emit(Created { client, system, key, anchor, epoch, genesis_time });
        client
    }

    /// `create` as a transaction: the client's address is `object::create_object_address(creator, seed)`, and its
    /// `Created` event names it.
    public entry fun create_client(
        creator: &signer,
        seed: vector<u8>,
        system: u8,
        key: vector<u8>,
        anchor: vector<u8>,
        epoch: u64,
        genesis_time: u64,
    ) {
        create(creator, seed, system, key, anchor, epoch, genesis_time);
    }

    /// Anyone, until MAX_LAG after the anchor's epoch began: accepts a proof of the statement from the stored anchor,
    /// and records the blocks it covers. The statement bounds each step to 225 epochs, a day, so an honest prover keeps
    /// up only by proving at least daily (LG-4).
    public entry fun update(client: address, public_values: vector<u8>, proof: vector<u8>) acquires LightClient {
        assert!(exists<LightClient>(client), ENoClient);
        let lc = &mut LightClient[client];
        assert!(timestamp::now_seconds() <= lag_ends_of(lc), ELagging);
        if (lc.system == SP1) {
            proofs::verify_sp1(&lc.key, &public_values, &proof);
        } else {
            proofs::verify_risc0(&lc.key, &public_values, &proof);
        };
        advance(client, lc, &public_values);
    }

    /// Moves the anchor one proven step: the values must start from the stored anchor.
    fun advance(client: address, lc: &mut LightClient, values: &vector<u8>) {
        assert!(values.length() == PUBLIC_VALUES_LEN, EBadPublicValues);
        let anchor_in = bytes::slice(values, 0, 32);
        let anchor_out = bytes::slice(values, 32, 32);
        let epoch = small(values, 2);
        let headers_root = bytes::slice(values, 96, 32);
        let first = small(values, 4);
        let last = small(values, 5);
        assert!(anchor_in == lc.anchor, EWrongAnchor);
        lc.anchor = anchor_out;
        lc.epoch = epoch;
        lc.ranges.upsert(headers_root, Range { first, last });
        event::emit(Advanced { client, epoch, anchor: anchor_out, headers_root, first, last });
    }

    /// Word `i` of the public values, which must fit 64 bits, as `abi.decode` of a `uint64` requires.
    fun small(values: &vector<u8>, i: u64): u64 {
        let w = bytes::u256_at(values, 32 * i);
        assert!(w <= MAX_U64, EBadPublicValues);
        (w as u64)
    }

    fun lag_ends_of(lc: &LightClient): u64 {
        let ends = (lc.genesis_time as u128) + (lc.epoch as u128) * (SECONDS_PER_EPOCH as u128) + (MAX_LAG as u128);
        if (ends > 0xffffffffffffffff) { 0xffffffffffffffff } else { (ends as u64) }
    }

    inline fun borrow(client: address): &LightClient {
        assert!(exists<LightClient>(client), ENoClient);
        &LightClient[client]
    }

    #[view]
    /// The last second the anchor may be advanced from: `genesisTime + epoch * 384 + MAX_LAG`, saturating, as
    /// `FinalityVerifier.lagEnds()`.
    public fun lag_ends(client: address): u64 acquires LightClient {
        lag_ends_of(borrow(client))
    }

    /// Aborts unless `proof` shows the log of `emitter` with topics `topic0` and `topic1` and data `data`, of a
    /// successful transaction, in Ethereum block `block`, at its place under a headers root this light client recorded.
    public fun verify_event(
        client: address,
        proof: &vector<u8>,
        block: u64,
        emitter: &vector<u8>,
        topic0: &vector<u8>,
        topic1: &vector<u8>,
        data: &vector<u8>,
    ) acquires LightClient {
        let lc = borrow(client);
        let (header, nodes, tx_index, log_index) = ethereum::parse_event(proof);
        check_header(lc, &header);
        assert!(ethereum::number(&header) == block, ENotTheLog);
        let log = ethereum::log(proof, &ethereum::receipts_root(&header), &nodes, tx_index, log_index);
        let d = ethereum::data(&log);
        assert!(
            ethereum::emitter(&log) == *emitter
                && ethereum::topic0(&log) == *topic0
                && ethereum::topic1(&log) == *topic1
                && bytes::slice_eq(proof, rlp::start(&d), rlp::len(&d), data),
            ENotTheLog,
        );
    }

    /// Aborts unless `proof` places block `block`, with that timestamp and state root, under a headers root this light
    /// client recorded, as `FinalityVerifier.verifyCheckpoint` returns it.
    public fun verify_checkpoint(
        client: address,
        proof: &vector<u8>,
        block: u64,
        timestamp: u64,
        state_root: &vector<u8>,
    ) acquires LightClient {
        let lc = borrow(client);
        let header = ethereum::parse_header(proof);
        check_header(lc, &header);
        assert!(
            ethereum::number(&header) == block
                && ethereum::timestamp(&header) == timestamp
                && ethereum::state_root(&header) == *state_root,
            ENotTheCheckpoint,
        );
    }

    fun check_header(lc: &LightClient, header: &ethereum::Header) {
        let root = ethereum::headers_root(header);
        assert!(lc.ranges.contains(root), EUnknownHeaders);
        let r = *lc.ranges.borrow(root);
        ethereum::check_header(header, r.first, r.last);
    }

    #[view]
    public fun is_client(client: address): bool {
        exists<LightClient>(client)
    }

    #[view]
    public fun system(client: address): u8 acquires LightClient { borrow(client).system }

    #[view]
    public fun key(client: address): vector<u8> acquires LightClient { borrow(client).key }

    #[view]
    public fun anchor(client: address): vector<u8> acquires LightClient { borrow(client).anchor }

    #[view]
    public fun epoch(client: address): u64 acquires LightClient { borrow(client).epoch }

    #[view]
    public fun genesis_time(client: address): u64 acquires LightClient { borrow(client).genesis_time }

    /// The blocks the proof that recorded `headers_root` covered, if one did.
    public fun range(client: address, headers_root: vector<u8>): Option<Range> acquires LightClient {
        let lc = borrow(client);
        if (lc.ranges.contains(headers_root)) option::some(*lc.ranges.borrow(headers_root)) else option::none()
    }

    public fun range_first(r: &Range): u64 { r.first }

    public fun range_last(r: &Range): u64 { r.last }

    public fun sp1(): u8 { SP1 }

    public fun risc_zero(): u8 { RISC_ZERO }

    #[test_only]
    /// Records that a proof covered blocks `first` to `last` under `headers_root`, as `update` does after a proof: for
    /// tests that build their own headers trees.
    public fun record_for_testing(client: address, headers_root: vector<u8>, first: u64, last: u64) acquires LightClient {
        LightClient[client].ranges.upsert(headers_root, Range { first, last });
    }

    #[test_only]
    public fun advance_for_testing(client: address, values: vector<u8>) acquires LightClient {
        let lc = &mut LightClient[client];
        advance(client, lc, &values);
    }
}
