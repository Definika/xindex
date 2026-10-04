/// P1 and P2 on Sui: a light client of Ethereum, the twin of `FinalityVerifier.sol` and of
/// `crates/xindex-core/src/light_client.rs`. Anyone advances it with a proof that a checkpoint is finalized by two
/// thirds of the anchor's validators, and it proves a vault message by its receipt in any execution block those proofs
/// covered. P1 is advanced by SP1 proofs (`EthereumFinalityVerifier`), P2 by RISC Zero proofs of the same statement
/// with the same public values (`RiscZeroFinalityVerifier`); only `proofs::verify_sp1` or `verify_risc0` differs.
///
/// Each is a shared object of its own, so the vault names it by its object id, as the EVM vault names a verifier by
/// its address. No owner, no upgrade: the first anchor comes from its creator, checked during the vault's listing delay
/// on Ethereum; every later one is proven, one step at a time from the stored anchor. A light client left more than
/// `MAX_LAG` behind stops for good (LG-4). The program key or image id fixes the statement, and with it Ethereum's
/// network and fork schedule: a new fork needs a new light client, rotated in on the vault.
module xindex_vault::light_client;

use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};
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

/// SP1's Groth16 proof (P1's), or RISC Zero's (P2's).
const SP1: u8 = 1;
const RISC_ZERO: u8 = 2;
/// How long after its anchor's epoch began a light client still takes a proof, as `FinalityVerifier.MAX_LAG`.
const MAX_LAG: u64 = 86_400;
/// An epoch's length: 32 slots of 12 seconds.
const SECONDS_PER_EPOCH: u64 = 384;
/// `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`.
const PUBLIC_VALUES_LEN: u64 = 192;

/// The execution blocks one proof covered.
public struct Range has copy, drop, store {
    first: u64,
    last: u64,
}

/// A light client: its proof system and the program it accepts, its anchor (`keccak256(abi.encode(epoch,
/// validatorsRoot, execHash, execNumber))` of the last checkpoint accepted) and that anchor's epoch, the beacon chain's
/// genesis time (1606824023 on mainnet, 1655733600 on Sepolia), and the blocks each recorded headers root covers.
public struct LightClient has key {
    id: UID,
    system: u8,
    key: vector<u8>,
    anchor: vector<u8>,
    epoch: u64,
    genesis_time: u64,
    ranges: Table<vector<u8>, Range>,
}

public struct Created has copy, drop {
    client: ID,
    system: u8,
    key: vector<u8>,
    anchor: vector<u8>,
    epoch: u64,
    genesis_time: u64,
}

public struct Advanced has copy, drop {
    client: ID,
    epoch: u64,
    anchor: vector<u8>,
    headers_root: vector<u8>,
    first: u64,
    last: u64,
}

/// A light client of `system` (1 SP1, 2 RISC Zero) for the program `key`, from `anchor` at `epoch`. Anyone may make
/// one; a vault trusts only those it names. Share it with `share`, the only way it can leave the transaction.
public fun new(
    system: u8,
    key: vector<u8>,
    anchor: vector<u8>,
    epoch: u64,
    genesis_time: u64,
    ctx: &mut TxContext,
): LightClient {
    assert!(system == SP1 || system == RISC_ZERO, EUnknownSystem);
    assert!(key.length() == 32 && anchor.length() == 32, EZeroValue);
    assert!(!bytes::is_zero(&key) && !bytes::is_zero(&anchor) && genesis_time != 0, EZeroValue);
    let lc = LightClient {
        id: object::new(ctx),
        system,
        key,
        anchor,
        epoch,
        genesis_time,
        ranges: table::new(ctx),
    };
    event::emit(Created { client: object::id(&lc), system, key, anchor, epoch, genesis_time });
    lc
}

/// Shares a light client, so anyone can advance it and any vault can read it.
public fun share(lc: LightClient) {
    transfer::share_object(lc);
}

/// Anyone, until MAX_LAG after the anchor's epoch began: accepts a proof of the statement from the stored anchor, and
/// records the blocks it covers. The statement bounds each step to 225 epochs, a day, so an honest prover keeps up only
/// by proving at least daily (LG-4).
public fun update(lc: &mut LightClient, public_values: vector<u8>, proof: vector<u8>, clock: &Clock) {
    assert!(now(clock) <= lag_ends(lc), ELagging);
    if (lc.system == SP1) {
        proofs::verify_sp1(&lc.key, &public_values, &proof);
    } else {
        proofs::verify_risc0(&lc.key, &public_values, &proof);
    };
    advance(lc, &public_values);
}

/// Moves the anchor one proven step: the values must start from the stored anchor.
fun advance(lc: &mut LightClient, values: &vector<u8>) {
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
    if (lc.ranges.contains(headers_root)) {
        *&mut lc.ranges[headers_root] = Range { first, last };
    } else {
        lc.ranges.add(headers_root, Range { first, last });
    };
    event::emit(Advanced { client: object::id(lc), epoch, anchor: anchor_out, headers_root, first, last });
}

/// Word `i` of the public values, which must fit 64 bits, as `abi.decode` of a `uint64` requires.
fun small(values: &vector<u8>, i: u64): u64 {
    let w = bytes::u256_at(values, 32 * i);
    assert!(w <= 0xffffffffffffffff, EBadPublicValues);
    w as u64
}

/// The last second the anchor may be advanced from: `genesisTime + epoch * 384 + MAX_LAG`, saturating, as
/// `FinalityVerifier.lagEnds()`.
public fun lag_ends(lc: &LightClient): u64 {
    let ends = (lc.genesis_time as u128) + (lc.epoch as u128) * (SECONDS_PER_EPOCH as u128) + (MAX_LAG as u128);
    if (ends > 0xffffffffffffffff) { 0xffffffffffffffff } else { ends as u64 }
}

/// Aborts unless `proof` shows the log of `emitter` with topics `topic0` and `topic1` and data `data`, of a successful
/// transaction, in Ethereum block `block`, at its place under a headers root this light client recorded.
public fun verify_event(
    lc: &LightClient,
    proof: &vector<u8>,
    block: u64,
    emitter: &vector<u8>,
    topic0: &vector<u8>,
    topic1: &vector<u8>,
    data: &vector<u8>,
) {
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
public fun verify_checkpoint(lc: &LightClient, proof: &vector<u8>, block: u64, timestamp: u64, state_root: &vector<u8>) {
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
    let r = lc.ranges[root];
    ethereum::check_header(header, r.first, r.last);
}

fun now(clock: &Clock): u64 {
    clock.timestamp_ms() / 1000
}

public fun system(lc: &LightClient): u8 { lc.system }

public fun key(lc: &LightClient): vector<u8> { lc.key }

public fun anchor(lc: &LightClient): vector<u8> { lc.anchor }

public fun epoch(lc: &LightClient): u64 { lc.epoch }

public fun genesis_time(lc: &LightClient): u64 { lc.genesis_time }

/// The blocks the proof that recorded `headers_root` covered, if one did.
public fun range(lc: &LightClient, headers_root: vector<u8>): Option<Range> {
    if (lc.ranges.contains(headers_root)) option::some(lc.ranges[headers_root]) else option::none()
}

public fun range_first(r: &Range): u64 { r.first }

public fun range_last(r: &Range): u64 { r.last }

public fun sp1(): u8 { SP1 }

public fun risc_zero(): u8 { RISC_ZERO }

/// Records that a proof covered blocks `first` to `last` under `headers_root`, as `update` does after a proof: for tests
/// that build their own headers trees.
#[test_only]
public fun record_for_testing(lc: &mut LightClient, headers_root: vector<u8>, first: u64, last: u64) {
    if (lc.ranges.contains(headers_root)) {
        *&mut lc.ranges[headers_root] = Range { first, last };
    } else {
        lc.ranges.add(headers_root, Range { first, last });
    };
}

#[test_only]
public fun advance_for_testing(lc: &mut LightClient, values: vector<u8>) {
    advance(lc, &values);
}

#[test_only]
public fun destroy_for_testing(lc: LightClient) {
    let LightClient { id, system: _, key: _, anchor: _, epoch: _, genesis_time: _, ranges } = lc;
    ranges.drop();
    id.delete();
}
