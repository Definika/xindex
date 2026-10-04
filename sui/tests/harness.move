/// The tests' world: a scenario with the vault, P1 and P2 as shared objects, a clock that can move a year, and what
/// Ethereum writes, as the vault reads it. Messages arrive in real Ethereum receipts: a legacy receipt carrying the
/// `VaultMessage` log, alone in its block's receipts trie, the block alone under a headers root both light clients
/// recorded, as `FinalityVerifier.verifyEvent` would take it. The index is a real hub's (`fixtures`), so the snapshot
/// exit reads that hub's storage.
#[test_only]
module xindex_vault::harness;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::hash::keccak256;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::light_client::{Self, LightClient};
use xindex_vault::vault::{Self, Vault};

const CREATOR: address = @0xc4ea7042;
const RELAYER: address = @0x4e1a7e4;
const FREEZER: address = @0xf4ee2e4;
const RECOVERY: address = @0x4ec04e47;
const ALICE: address = @0xa11ce;
const BOB: address = @0xb0b;

const SEPOLIA: u64 = 11_155_111;
const SUI_TESTNET: u64 = 10_803_649_406_359_875_205;
const SEPOLIA_GENESIS: u64 = 1_655_733_600;
/// 1 SUI in MIST.
const ONE: u64 = 1_000_000_000;

const EVENT_TOPIC: vector<u8> = x"88e9f343da472582cef35a32362e15cbdbfd89b650463c638b28bb9d12098e8b";
const DOMAIN: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0";

public fun creator(): address { CREATOR }

public fun relayer(): address { RELAYER }

public fun freezer(): address { FREEZER }

public fun recovery(): address { RECOVERY }

public fun alice(): address { ALICE }

public fun bob(): address { BOB }

public fun one(): u64 { ONE }

public fun sepolia(): u64 { SEPOLIA }

public fun sui_testnet(): u64 { SUI_TESTNET }

public fun sepolia_genesis(): u64 { SEPOLIA_GENESIS }

/// A test: the scenario, the clock, the shared objects' ids, and the next Ethereum block and nonce a message takes.
public struct T {
    s: Scenario,
    clock: Clock,
    vault: ID,
    p1: ID,
    p2: ID,
    block: u64,
    nonce: u64,
    index: vector<u8>,
}

/// An epoch whose lag ends a day after `now`.
public fun epoch_at(now: u64): u64 {
    (now - SEPOLIA_GENESIS) / 384
}

/// A light client of `system`, its key and anchor seeded, anchored at `epoch`.
public fun light_client(system: u8, seed: u8, epoch: u64, ctx: &mut TxContext): LightClient {
    light_client::new(
        system,
        vector::tabulate!(32, |_| seed),
        vector::tabulate!(32, |_| seed ^ 0xff),
        epoch,
        SEPOLIA_GENESIS,
        ctx,
    )
}

/// The scenario at `now` (seconds) with P1 and P2 shared, before any vault.
public fun bare(now: u64): T {
    let mut s = ts::begin(CREATOR);
    let mut clock = clock::create_for_testing(s.ctx());
    clock.set_for_testing(now * 1000);
    let p1 = light_client(light_client::sp1(), 1, epoch_at(now), s.ctx());
    let p2 = light_client(light_client::risc_zero(), 2, epoch_at(now), s.ctx());
    let (id1, id2) = (object::id(&p1), object::id(&p2));
    light_client::share(p1);
    light_client::share(p2);
    T { s, clock, vault: object::id_from_address(@0x0), p1: id1, p2: id2, block: 1_000, nonce: 0, index: f::hub_index() }
}

/// The vault created a little before the fixture's settled intake's deadline, with its index registered and its first
/// checkpoint landed, a second after its creation: a vault takes no deposit before one (B1-04).
public fun new(): T {
    let mut t = created();
    let now = t.now() + 1;
    t.set_now(now);
    t.advance_to(1, now, keccak256(&b"first"));
    t
}

/// The vault as `create` leaves it, with its index registered: its checkpoint the genesis one, with no state, dated a
/// second before `new`'s.
public fun created(): T {
    let now = f::settled_intake_deadline() - 601;
    let mut t = bare(now);
    t.s.next_tx(CREATOR);
    let p1 = t.s.take_shared_by_id<LightClient>(t.p1);
    let p2 = t.s.take_shared_by_id<LightClient>(t.p2);
    t.vault =
        vault::create(
            SEPOLIA,
            SUI_TESTNET,
            f::hub_factory(),
            f::hub_implementation(),
            &p1,
            &p2,
            FREEZER,
            RECOVERY,
            1_000_000 * ONE,
            ONE,
            &t.clock,
            t.s.ctx(),
        );
    ts::return_shared(p1);
    ts::return_shared(p2);
    let mut v = t.take(RELAYER);
    vault::register_index(&mut v, f::hub_index(), f::hub_salt());
    ts::return_shared(v);
    t
}

/// `vault::create` from `sender` on the clients `p1` and `p2` with these settings, as `DeployVault` would deploy.
public fun create_with(
    t: &mut T,
    sender: address,
    source: u64,
    chain: u64,
    factory: vector<u8>,
    p1: ID,
    p2: ID,
    freezer: address,
    recovery: address,
    cap: u64,
    floor: u64,
): ID {
    t.s.next_tx(sender);
    let c1 = t.s.take_shared_by_id<LightClient>(p1);
    let c2 = t.s.take_shared_by_id<LightClient>(p2);
    let id = vault::create(source, chain, factory, f::hub_implementation(), &c1, &c2, freezer, recovery, cap, floor, &t.clock, t.s.ctx());
    ts::return_shared(c1);
    ts::return_shared(c2);
    id
}

/// Shares a light client of `system` with `genesis` time, anchored now: a client of another network or system.
public fun client_with(t: &mut T, system: u8, genesis: u64): ID {
    t.s.next_tx(RELAYER);
    let now = t.now();
    let lc = light_client::new(system, vector::tabulate!(32, |_| 5u8), vector::tabulate!(32, |_| 6u8), (now - genesis) / 384, genesis, t.s.ctx());
    let id = object::id(&lc);
    light_client::share(lc);
    id
}

/// Shares a light client of `system`, seeded `seed`, of Sepolia's genesis, anchored at `epoch`, which may not have
/// begun.
public fun client_at(t: &mut T, system: u8, seed: u8, epoch: u64): ID {
    t.s.next_tx(RELAYER);
    let lc = light_client(system, seed, epoch, t.s.ctx());
    let id = object::id(&lc);
    light_client::share(lc);
    id
}

public fun end(t: T) {
    let T { s, clock, vault: _, p1: _, p2: _, block: _, nonce: _, index: _ } = t;
    clock.destroy_for_testing();
    s.end();
}

// ---------------------------------------------------------------------
// The scenario
// ---------------------------------------------------------------------

/// A new transaction from `sender`, taking the vault.
public fun take(t: &mut T, sender: address): Vault {
    t.s.next_tx(sender);
    t.s.take_shared_by_id<Vault>(t.vault)
}

/// The light client `id`, in the current transaction.
public fun client(t: &T, id: ID): LightClient {
    t.s.take_shared_by_id<LightClient>(id)
}

public fun put(v: Vault) {
    ts::return_shared(v);
}

public fun put_client(lc: LightClient) {
    ts::return_shared(lc);
}

public fun clock(t: &T): &Clock { &t.clock }

/// The clock and the transaction's context together, for a call that takes both.
public fun parts(t: &mut T): (&Clock, &mut TxContext) { (&t.clock, t.s.ctx()) }

public fun ctx(t: &mut T): &mut TxContext { t.s.ctx() }

public fun scenario(t: &mut T): &mut Scenario { &mut t.s }

public fun vault_object(t: &T): ID { t.vault }

public fun p1_id(t: &T): ID { t.p1 }

public fun p2_id(t: &T): ID { t.p2 }

public fun index(t: &T): vector<u8> { t.index }

public fun now(t: &T): u64 { t.clock.timestamp_ms() / 1000 }

/// The clock at `ms`, which must not be earlier than now.
public fun set_ms(t: &mut T, ms: u64) {
    t.clock.set_for_testing(ms);
}

public fun warp(t: &mut T, seconds: u64) {
    let ms = t.clock.timestamp_ms() + seconds * 1000;
    t.clock.set_for_testing(ms);
}

/// The vault's 32-byte id.
public fun vault_id(t: &mut T): vector<u8> {
    let v = t.take(RELAYER);
    let id = vault::vault_id(&v);
    put(v);
    id
}

/// Every coin `who` received since last asked, in MIST, taken out of the scenario.
public fun received(t: &mut T, who: address): u64 {
    t.s.next_tx(who);
    let mut total = 0;
    while (ts::has_most_recent_for_address<Coin<SUI>>(who)) {
        let c = t.s.take_from_address<Coin<SUI>>(who);
        total = total + c.burn_for_testing();
    };
    total
}

// ---------------------------------------------------------------------
// What Ethereum writes
// ---------------------------------------------------------------------

/// `VaultMessages.encode`: a message of `kind` from `emitter` on chain `source` with `body`, to vault `vault` on chain
/// `dest`.
public fun message(
    source: u64,
    kind: u8,
    emitter: &vector<u8>,
    body: &vector<u8>,
    nonce: u64,
    dest: u64,
    vault: &vector<u8>,
): vector<u8> {
    let mut out = DOMAIN;
    out.append(bytes::word64(source));
    out.append(bytes::word64((kind as u64)));
    out.append(bytes::word64(dest));
    out.append(*vault);
    out.append(bytes::address_word(emitter));
    out.append(bytes::word64(nonce));
    out.append(bytes::word64(256));
    out.append(bytes::word64(body.length()));
    out.append(*body);
    while (out.length() % 32 != 0) out.push_back(0);
    out
}

public fun rlp_bytes(b: &vector<u8>): vector<u8> {
    if (b.length() == 1 && b[0] < 0x80) return *b;
    let mut out = rlp_len(0x80, b.length());
    out.append(*b);
    out
}

public fun rlp_list(items: &vector<vector<u8>>): vector<u8> {
    let mut body = vector[];
    items.do_ref!(|i| body.append(*i));
    let mut out = rlp_len(0xc0, body.length());
    out.append(body);
    out
}

fun rlp_len(base: u8, len: u64): vector<u8> {
    if (len < 56) return vector[base + (len as u8)];
    let mut be = vector[];
    let mut n = len;
    while (n > 0) {
        be.push_back(((n & 0xff) as u8));
        n = n >> 8;
    };
    be.reverse();
    let mut out = vector[base + 55 + (be.length() as u8)];
    out.append(be);
    out
}

/// `abi.encode(bytes payload)`, a `VaultMessage` log's data.
public fun log_data(payload: &vector<u8>): vector<u8> {
    let mut out = bytes::word64(32);
    out.append(bytes::word64(payload.length()));
    out.append(*payload);
    while (out.length() % 32 != 0) out.push_back(0);
    out
}

/// A successful legacy receipt with one log, `emitter`'s `VaultMessage(id, payload)`.
public fun receipt(emitter: &vector<u8>, id: &vector<u8>, payload: &vector<u8>): vector<u8> {
    let topic = EVENT_TOPIC;
    let log = rlp_list(&vector[
        rlp_bytes(emitter),
        rlp_list(&vector[rlp_bytes(&topic), rlp_bytes(id)]),
        rlp_bytes(&log_data(payload)),
    ]);
    rlp_list(&vector[
        rlp_bytes(&vector[1]),
        rlp_bytes(&vector[0x52, 0x08]),
        rlp_bytes(&vector::tabulate!(256, |_| 0u8)),
        rlp_list(&vector[log]),
    ])
}

/// The receipts trie of a block whose one transaction made `receipt`: a leaf at key `rlp(0)`, nibbles 8 and 0.
public fun receipt_leaf(receipt: &vector<u8>): vector<u8> {
    rlp_list(&vector[rlp_bytes(&vector[0x20, 0x80]), rlp_bytes(receipt)])
}

fun le(x: u64, n: u64): vector<u8> {
    vector::tabulate!(n, |i| (((x >> ((8 * i) as u8)) & 0xff) as u8))
}

/// `keccak256(abi.encode(uint256 number, uint256 timestamp, stateRoot, receiptsRoot))`, a block's leaf.
public fun leaf(number: u64, timestamp: u64, state_root: &vector<u8>, receipts_root: &vector<u8>): vector<u8> {
    let mut pre = bytes::word64(number);
    pre.append(bytes::word64(timestamp));
    pre.append(*state_root);
    pre.append(*receipts_root);
    keccak256(&pre)
}

/// The header part of a proof: `headersRoot ++ number ++ timestamp ++ stateRoot ++ receiptsRoot ++ path`.
public fun header_with(
    root: &vector<u8>,
    number: u64,
    timestamp: u64,
    state_root: &vector<u8>,
    receipts_root: &vector<u8>,
    path: &vector<vector<u8>>,
): vector<u8> {
    let mut out = *root;
    out.append(le(number, 8));
    out.append(le(timestamp, 8));
    out.append(*state_root);
    out.append(*receipts_root);
    out.push_back((path.length() as u8));
    path.do_ref!(|p| out.append(*p));
    out
}

/// A block alone under its headers root, the leaf itself: the header part of a proof, and that root.
public fun header(number: u64, timestamp: u64, state_root: &vector<u8>, receipts_root: &vector<u8>): (vector<u8>, vector<u8>) {
    let root = leaf(number, timestamp, state_root, receipts_root);
    (header_with(&root, number, timestamp, state_root, receipts_root, &vector[]), root)
}

/// A proof of `payload`'s log by `emitter` in block `number` at `timestamp`, the log's receipt alone in the block's
/// receipts trie, the block alone under the returned headers root.
public fun event_proof(emitter: &vector<u8>, payload: &vector<u8>, number: u64, timestamp: u64): (vector<u8>, vector<u8>) {
    let id = keccak256(payload);
    let leaf_node = receipt_leaf(&receipt(emitter, &id, payload));
    let (mut proof, root) = header(number, timestamp, &vector::tabulate!(32, |_| 7u8), &keccak256(&leaf_node));
    proof.push_back(1);
    proof.append(le(leaf_node.length(), 4));
    proof.append(leaf_node);
    proof.append(le(0, 4));
    proof.append(le(0, 4));
    (proof, root)
}

/// The receipt part of an event proof: the nodes (`fixtures`' node lists), then the transaction's and the log's index.
public fun receipt_part(nodes: &vector<u8>, tx: u64, log: u64): vector<u8> {
    let mut out = *nodes;
    out.append(le(tx, 4));
    out.append(le(log, 4));
    out
}

/// The headers tree over `leaves`, a zero for an odd layer's missing sibling: its root, and leaf `index`'s path.
public fun tree(leaves: vector<vector<u8>>, index: u64): (vector<u8>, vector<vector<u8>>) {
    let mut layer = leaves;
    let mut path = vector[];
    let mut i = index;
    while (layer.length() > 1) {
        if (layer.length() % 2 == 1) layer.push_back(bytes::zero32());
        path.push_back(layer[i ^ 1]);
        let mut next = vector[];
        let mut j = 0;
        while (j < layer.length()) {
            let mut pair = layer[j];
            pair.append(layer[j + 1]);
            next.push_back(keccak256(&pair));
            j = j + 2;
        };
        layer = next;
        i = i / 2;
    };
    (layer[0], path)
}

/// An intake id: its deadline in the top 64 bits, then a nonce.
public fun intake_id(deadline: u64, nonce: u64): vector<u8> {
    let mut id = vector::tabulate!(8, |i| (((deadline >> ((8 * (7 - i)) as u8)) & 0xff) as u8));
    id.append(vector::tabulate!(16, |_| 0u8));
    id.append(vector::tabulate!(8, |i| (((nonce >> ((8 * (7 - i)) as u8)) & 0xff) as u8)));
    id
}

/// A burn body: SUI, `amount` MIST, to the 32-byte `recipient`.
public fun burn_body(amount: u64, recipient: address): vector<u8> {
    let mut out = bytes::zero32();
    out.append(bytes::word64(amount));
    out.append(sui::address::to_bytes(recipient));
    out
}

/// A freeze's body: when the factory's freeze ends, in Unix seconds.
public fun freeze_body(until: u64): vector<u8> {
    bytes::word64(until)
}

public fun cap_body(cap: u64, floor: u64): vector<u8> {
    let mut out = bytes::zero32();
    out.append(bytes::word64(cap));
    out.append(bytes::word64(floor));
    out
}

public fun migrate_body(new_index: &vector<u8>, amount: u64): vector<u8> {
    let mut out = bytes::address_word(new_index);
    out.append(bytes::zero32());
    out.append(bytes::word64(amount));
    out
}

public fun pair_body(p1: ID, p2: ID): vector<u8> {
    let mut out = p1.to_bytes();
    out.append(p2.to_bytes());
    out
}

// ---------------------------------------------------------------------
// The vault's flows, as the NEAR twin's tests drive them
// ---------------------------------------------------------------------

/// A message of `kind` from `emitter` with `body`, to this vault, with the next nonce.
public fun payload(t: &mut T, kind: u8, emitter: &vector<u8>, body: &vector<u8>): vector<u8> {
    t.nonce = t.nonce + 1;
    let vault = t.vault_id();
    message(SEPOLIA, kind, emitter, body, t.nonce, SUI_TESTNET, &vault)
}

/// Both light clients in force recorded the one-block range `block` under `root`, as a proof would have.
public fun record(t: &mut T, root: vector<u8>, block: u64) {
    let v = t.take(RELAYER);
    let (p1, p2) = (vault::p1(&v), vault::p2(&v));
    put(v);
    t.record_for(p1, root, block);
    t.record_for(p2, root, block);
}

public fun record_for(t: &mut T, client: ID, root: vector<u8>, block: u64) {
    t.record_range(client, root, block, block);
}

/// The light client `client` recorded the blocks `first` to `last` under `root`.
public fun record_range(t: &mut T, client: ID, root: vector<u8>, first: u64, last: u64) {
    t.s.next_tx(RELAYER);
    let mut lc = t.s.take_shared_by_id<LightClient>(client);
    light_client::record_for_testing(&mut lc, root, first, last);
    ts::return_shared(lc);
}

/// P1's and P2's proof of `payload`'s log by `emitter`, in block `block`, whose range both recorded.
public fun proof_for(t: &mut T, emitter: &vector<u8>, payload: &vector<u8>, block: u64): vector<u8> {
    let (proof, root) = event_proof(emitter, payload, block, t.now());
    t.record(root, block);
    proof
}

/// Delivers `payload` from `emitter` in block `block`, on P1's proof, P2's, or both.
public fun deliver_at(t: &mut T, emitter: &vector<u8>, payload: vector<u8>, p1: bool, p2: bool, block: u64) {
    let proof = t.proof_for(emitter, &payload, block);
    let mut v = t.take(RELAYER);
    let (c1, c2) = (t.client(vault::p1(&v)), t.client(vault::p2(&v)));
    let (a, b) = (if (p1) proof else vector[], if (p2) proof else vector[]);
    vault::deliver(&mut v, &c1, &c2, payload, block, a, b, &t.clock, t.s.ctx());
    put_client(c1);
    put_client(c2);
    put(v);
}

/// Delivers `payload` in `block` with the proofs given, through the vault's own P1 and P2.
public fun deliver_raw(t: &mut T, payload: vector<u8>, block: u64, proof1: vector<u8>, proof2: vector<u8>) {
    let mut v = t.take(RELAYER);
    let (c1, c2) = (t.client(vault::p1(&v)), t.client(vault::p2(&v)));
    vault::deliver(&mut v, &c1, &c2, payload, block, proof1, proof2, &t.clock, t.s.ctx());
    put_client(c1);
    put_client(c2);
    put(v);
}

/// Delivers `payload` from `emitter`, in the next block, on P1's proof, P2's, or both.
public fun deliver_by(t: &mut T, emitter: &vector<u8>, payload: vector<u8>, p1: bool, p2: bool) {
    let block = t.next_block();
    t.deliver_at(emitter, payload, p1, p2, block);
}

/// A message of `kind` from the index, on both proofs, from a block the checkpoint covers; its payload.
public fun deliver(t: &mut T, kind: u8, body: vector<u8>): vector<u8> {
    let index = t.index;
    let payload = t.payload(kind, &index, &body);
    t.deliver_by(&index, payload, true, true);
    payload
}

/// A message of `kind` from the factory with `body` and `nonce`, on P1's proof, P2's or both.
public fun govern(t: &mut T, kind: u8, body: vector<u8>, nonce: u64, p1: bool, p2: bool): vector<u8> {
    let factory = f::hub_factory();
    let vault = t.vault_id();
    let payload = message(SEPOLIA, kind, &factory, &body, nonce, SUI_TESTNET, &vault);
    t.deliver_by(&factory, payload, p1, p2);
    payload
}

/// The factory's freeze with `nonce`, sent now: it ends FREEZE_DURATION from now, as `_freezeChain` records it.
public fun govern_freeze(t: &mut T, nonce: u64, p1: bool, p2: bool): vector<u8> {
    let body = freeze_body(t.now() + 14 * 86_400);
    t.govern(6, body, nonce, p1, p2)
}

/// The next block for a message: one the vault's checkpoint already covers.
public fun next_block(t: &mut T): u64 {
    let (covered, _, _) = t.checkpoint();
    if (covered < t.block + 1) {
        let b = t.block + 100;
        t.advance(b);
    };
    t.block = t.block + 1;
    t.block
}

public fun checkpoint(t: &mut T): (u64, u64, vector<u8>) {
    let v = t.take(RELAYER);
    let (block, timestamp, root) = vault::checkpoint(&v);
    put(v);
    (block, timestamp, root)
}

/// A checkpoint at `block`, now, with a state root of its own, that P1 and P2 both prove; a second later first if the
/// last checkpoint is dated now, since a checkpoint must be newer in time too.
public fun advance(t: &mut T, block: u64) {
    let (_, ts, _) = t.checkpoint();
    if (ts >= t.now()) t.warp(1);
    let mut pre = b"state";
    pre.append(le(block, 8));
    let root = keccak256(&pre);
    let now = t.now();
    t.advance_to(block, now, root);
}

/// The proof of checkpoint `(block, timestamp, root)`, its block recorded alone by the clients `p1` and `p2`.
public fun checkpoint_proof(t: &mut T, block: u64, timestamp: u64, root: &vector<u8>, p1: ID, p2: ID): vector<u8> {
    let (head, headers_root) = header(block, timestamp, root, &vector::tabulate!(32, |_| 9u8));
    t.record_for(p1, headers_root, block);
    t.record_for(p2, headers_root, block);
    head
}

public fun advance_to(t: &mut T, block: u64, timestamp: u64, root: vector<u8>) {
    let (p1, p2) = t.pair();
    let proof = t.checkpoint_proof(block, timestamp, &root, p1, p2);
    let mut v = t.take(RELAYER);
    let (c1, c2) = (t.client(p1), t.client(p2));
    vault::advance_checkpoint(&mut v, &c1, &c2, block, timestamp, root, proof, proof, &t.clock);
    put_client(c1);
    put_client(c2);
    put(v);
}

/// The vault's P1 and P2.
public fun pair(t: &mut T): (ID, ID) {
    let v = t.take(RELAYER);
    let (p1, p2) = (vault::p1(&v), vault::p2(&v));
    put(v);
    (p1, p2)
}

/// Deposits `amount` from `who` into intake `intake` of the index.
public fun deposit(t: &mut T, who: address, intake: vector<u8>, amount: u64) {
    let mut v = t.take(who);
    let coin = coin::mint_for_testing<SUI>(amount, t.s.ctx());
    vault::deposit(&mut v, t.index, intake, coin, &t.clock, t.s.ctx());
    put(v);
}

/// Deposits `amount` into a fresh intake from Alice, and settles it on both proofs: the index holds it.
public fun fund(t: &mut T, amount: u64): vector<u8> {
    t.nonce = t.nonce + 1;
    let intake = intake_id(t.now() + 3600, t.nonce);
    t.deposit(ALICE, intake, amount);
    t.deliver(2, intake);
    intake
}

/// The index's balance, paid total and what it may pay now.
public fun balance(t: &mut T): u64 {
    let index = t.index;
    let (_, balance, _, _, _) = t.index_state(index);
    balance
}

public fun index_state(t: &mut T, index: vector<u8>): (bool, u64, u64, vector<u8>, u64) {
    let v = t.take(RELAYER);
    let (has, balance, paid, digest, available) = vault::index_state(&v, index, &t.clock);
    put(v);
    (has, balance, paid, digest, available)
}

public fun held(t: &mut T): u64 {
    let v = t.take(RELAYER);
    let held = vault::held(&v);
    assert!(vault::coins(&v) == held);
    put(v);
    held
}

public fun owed_remaining(t: &mut T, id: vector<u8>): u64 {
    let v = t.take(RELAYER);
    let (_, _, _, remaining) = vault::owed(&v, t.index, id);
    put(v);
    remaining
}

public fun intake_state(t: &mut T, intake: vector<u8>): u8 {
    let v = t.take(RELAYER);
    let (state, _, _) = vault::intake(&v, t.index, intake);
    put(v);
    state
}

public fun stalled(t: &mut T): bool {
    let v = t.take(RELAYER);
    let stalled = vault::stalled(&v, &t.clock);
    put(v);
    stalled
}

public fun release(t: &mut T, id: vector<u8>) {
    let mut v = t.take(RELAYER);
    vault::release(&mut v, t.index, id, &t.clock, t.s.ctx());
    put(v);
}

// ---------------------------------------------------------------------
// Recovery
// ---------------------------------------------------------------------

/// Two light clients, a successor or rotation candidate.
public struct Pair has copy, drop {
    a: ID,
    b: ID,
}

public fun pair_of(a: ID, b: ID): Pair { Pair { a, b } }

public fun first(p: &Pair): ID { p.a }

public fun second(p: &Pair): ID { p.b }

/// A new SP1 and RISC Zero pair, shared, as a `Pair`.
public fun successor_pair(t: &mut T, seed: u8): Pair {
    let (a, b) = t.new_pair(seed);
    Pair { a, b }
}

/// The continuity test the clients `pair` pass: the vault's last checkpoint, a recent one at `recent_block`, and, when
/// `payload` is not empty, the last message, `payload` in `block`, each proven by both, the pair kept alive to now as
/// its provers would keep it.
public fun continuity(t: &mut T, pair: Pair, recent_block: u64, payload: vector<u8>, block: u64): vault::Continuity {
    let (a, b) = (pair.a, pair.b);
    t.keep_alive(a);
    t.keep_alive(b);
    let (last_block, last_ts, last_root) = t.checkpoint();
    let last = t.checkpoint_proof(last_block, last_ts, &last_root, a, b);
    let mut pre = b"recent";
    pre.append(le(recent_block, 8));
    let recent_root = keccak256(&pre);
    let now = t.now();
    let recent = t.checkpoint_proof(recent_block, now, &recent_root, a, b);
    let message = if (payload.is_empty()) vector[] else {
        let emitter = bytes::slice(&payload, 5 * 32 + 12, 20);
        let (proof, root) = event_proof(&emitter, &payload, block, now);
        t.record_for(a, root, block);
        t.record_for(b, root, block);
        proof
    };
    vault::continuity(last, last, recent_block, now, recent_root, recent, recent, payload, block, message, message)
}

public fun propose(t: &mut T, who: address, pair: Pair, c: vault::Continuity) {
    let (a, b) = (pair.a, pair.b);
    let mut v = t.take(who);
    let (c1, c2) = (t.client(a), t.client(b));
    vault::propose_successor(&mut v, &c1, &c2, c, &t.clock, t.s.ctx());
    put_client(c1);
    put_client(c2);
    put(v);
}

public fun veto(t: &mut T, who: address) {
    let mut v = t.take(who);
    vault::veto_successor(&mut v, t.s.ctx());
    put(v);
}

/// Adopts the pair on a checkpoint at `block`, now, both prove.
public fun adopt(t: &mut T, pair: Pair, block: u64) {
    let (a, b) = (pair.a, pair.b);
    let root = vector::tabulate!(32, |_| ((block & 0xff) as u8));
    let now = t.now();
    let proof = t.checkpoint_proof(block, now, &root, a, b);
    let mut v = t.take(RELAYER);
    let (c1, c2) = (t.client(a), t.client(b));
    vault::adopt_successor(&mut v, &c1, &c2, block, now, root, proof, proof, &t.clock);
    put_client(c1);
    put_client(c2);
    put(v);
}

public fun begin_snapshot(t: &mut T) {
    let mut v = t.take(RELAYER);
    vault::begin_snapshot(&mut v, &t.clock);
    put(v);
}

public fun successor(t: &mut T): (ID, ID, u64) {
    let v = t.take(RELAYER);
    let (a, b, ends) = vault::successor(&v);
    put(v);
    (a, b, ends)
}

public fun vetoes(t: &mut T): u8 {
    let v = t.take(RELAYER);
    let n = vault::vetoes(&v);
    put(v);
    n
}

public fun last_message(t: &mut T): vector<u8> {
    let v = t.take(RELAYER);
    let m = vault::last_message(&v);
    put(v);
    m
}

public fun stall_start(t: &mut T): u64 {
    let v = t.take(RELAYER);
    let s = vault::stall_start(&v);
    put(v);
    s
}

/// The clock at `seconds`, which must not be earlier than now.
public fun set_now(t: &mut T, seconds: u64) {
    t.clock.set_for_testing(seconds * 1000);
}

public fun nonce(t: &T): u64 { t.nonce }

public fun last_block(t: &T): u64 { t.block }

/// Shares two new light clients, SP1 and RISC Zero, anchored now: a successor or rotation pair.
public fun new_pair(t: &mut T, seed: u8): (ID, ID) {
    t.s.next_tx(RELAYER);
    let epoch = epoch_at(t.now());
    let a = light_client(light_client::sp1(), seed, epoch, t.s.ctx());
    let b = light_client(light_client::risc_zero(), seed + 1, epoch, t.s.ctx());
    let (ida, idb) = (object::id(&a), object::id(&b));
    light_client::share(a);
    light_client::share(b);
    (ida, idb)
}

/// Advances the light client `id` one step to the epoch now in progress, as its provers keep it alive: a rotated or
/// successor pair must still be within its lag when it is taken (B4-03).
public fun keep_alive(t: &mut T, id: ID) {
    t.s.next_tx(RELAYER);
    let mut lc = t.s.take_shared_by_id<LightClient>(id);
    let anchor = light_client::anchor(&lc);
    let epoch = (t.now() - light_client::genesis_time(&lc)) / 384;
    let mut values = anchor;
    values.append(keccak256(&anchor));
    values.append(bytes::word64(epoch));
    values.append(keccak256(&bytes::word64(epoch)));
    values.append(bytes::word64(0));
    values.append(bytes::word64(0));
    light_client::advance_at_for_testing(&mut lc, values, t.now());
    ts::return_shared(lc);
}

/// The SP1 and RISC Zero fixtures' clients: SP1's program key and RISC Zero's image id, anchored now.
public fun fixture_pair(t: &mut T): (ID, ID) {
    t.s.next_tx(RELAYER);
    let epoch = epoch_at(t.now());
    let a = light_client::new(light_client::sp1(), f::sp1_program_key(), vector::tabulate!(32, |_| 0xaa), epoch, SEPOLIA_GENESIS, t.s.ctx());
    let b = light_client::new(light_client::risc_zero(), f::risc0_image_id(), vector::tabulate!(32, |_| 0xaa), epoch, SEPOLIA_GENESIS, t.s.ctx());
    let (ida, idb) = (object::id(&a), object::id(&b));
    light_client::share(a);
    light_client::share(b);
    (ida, idb)
}
