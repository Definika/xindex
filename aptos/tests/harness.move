#[test_only]
/// The tests' world: Aptos's framework with APT as its fungible asset at `0xa` and BN254 enabled, a clock, the vault, P1
/// and P2 at their objects, and what Ethereum writes, as the vault reads it. Messages arrive in real Ethereum receipts:
/// a legacy receipt carrying the `VaultMessage` log, alone in its block's receipts trie, the block alone under a headers
/// root both light clients recorded, as `FinalityVerifier.verifyEvent` would take it. The index is a real hub's
/// (`fixtures`), so the snapshot exit reads that hub's storage. The twin of `sui/tests/harness.move`; Aptos's unit tests
/// run in one global storage with no transactions, so a test's state is a `T` and every call is the vault's own.
module xindex_vault::harness {
    use std::bcs;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::aptos_coin;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::aptos_hash::keccak256;
    use aptos_std::crypto_algebra;
    use aptos_std::simple_map::{Self, SimpleMap};
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::light_client;
    use xindex_vault::vault;

    const CREATOR: address = @0xc4ea7042;
    const RELAYER: address = @0x4e1a7e4;
    const FREEZER: address = @0xf4ee2e4;
    const RECOVERY: address = @0x4ec04e47;
    const ALICE: address = @0xa11ce;
    const BOB: address = @0xb0b;

    const SEPOLIA: u64 = 11_155_111;
    const APTOS_TESTNET: u64 = 10_134_113_455_198_361_380;
    const SEPOLIA_GENESIS: u64 = 1_655_733_600;
    /// 1 APT in octas.
    const ONE: u64 = 100_000_000;

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

    public fun aptos_testnet(): u64 { APTOS_TESTNET }

    public fun sepolia_genesis(): u64 { SEPOLIA_GENESIS }

    /// A test: the vault and the light clients it started with, the next Ethereum block and nonce a message takes, the
    /// index, the APT balances last seen, and a counter for new light clients' seeds.
    struct T has drop {
        vault: address,
        p1: address,
        p2: address,
        block: u64,
        nonce: u64,
        index: vector<u8>,
        seen: SimpleMap<address, u64>,
        clients: u64,
    }

    public fun signer_of(who: address): signer {
        account::create_signer_for_test(who)
    }

    /// An epoch whose lag ends a day after `now`.
    public fun epoch_at(now: u64): u64 {
        (now - SEPOLIA_GENESIS) / 384
    }

    /// Aptos at `now` (seconds): its clock, BN254, and APT as the fungible asset at `0xa`.
    public fun boot(now: u64) {
        let fx = signer_of(@aptos_framework);
        crypto_algebra::enable_cryptography_algebra_natives(&fx);
        timestamp::set_time_has_started_for_testing(&fx);
        timestamp::update_global_time_for_test_secs(now);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
    }

    /// A light client of `system`, its key and anchor seeded, anchored at `epoch`, made by `creator` under `seed`.
    public fun light_client(creator: address, seed: vector<u8>, system: u8, key_seed: u8, epoch: u64): address {
        light_client::create(
            &signer_of(creator),
            seed,
            system,
            bytes::repeat(key_seed, 32),
            bytes::repeat(key_seed ^ 0xff, 32),
            epoch,
            SEPOLIA_GENESIS,
        )
    }

    /// Aptos at `now` (seconds) with P1 and P2, before any vault.
    public fun bare(now: u64): T {
        boot(now);
        let p1 = light_client(CREATOR, b"p1", light_client::sp1(), 1, epoch_at(now));
        let p2 = light_client(CREATOR, b"p2", light_client::risc_zero(), 2, epoch_at(now));
        T {
            vault: @0x0,
            p1,
            p2,
            block: 1_000,
            nonce: 0,
            index: f::hub_index(),
            seen: simple_map::new(),
            clients: 0,
        }
    }

    /// The vault created a little before the fixture's settled intake's deadline, with its index registered: the
    /// vault the fixtures name, at `object::create_object_address(CREATOR, b"xindex.v4.vault")`.
    public fun new(): T {
        let now = f::settled_intake_deadline() - 600;
        let t = bare(now);
        t.vault = vault::create(
            &signer_of(CREATOR),
            SEPOLIA,
            APTOS_TESTNET,
            f::hub_factory(),
            f::hub_implementation(),
            t.p1,
            t.p2,
            FREEZER,
            RECOVERY,
            1_000_000 * ONE,
            ONE,
        );
        assert!(bcs::to_bytes(&t.vault) == f::hub_vault(), 0);
        vault::register_index(t.vault, f::hub_index(), f::hub_salt());
        t
    }

    /// `vault::create` from `sender` on the clients `p1` and `p2` with these settings, as `DeployVault` would deploy.
    public fun create_with(
        self: &mut T,
        sender: address,
        source: u64,
        chain: u64,
        factory: vector<u8>,
        p1: address,
        p2: address,
        freezer: address,
        recovery: address,
        cap: u64,
        floor: u64,
    ): address {
        let v = vault::create(
            &signer_of(sender),
            source,
            chain,
            factory,
            f::hub_implementation(),
            p1,
            p2,
            freezer,
            recovery,
            cap,
            floor,
        );
        self.vault = v;
        v
    }

    /// A light client of `system` with `genesis` time, anchored now: a client of another network or system.
    public fun client_with(self: &mut T, system: u8, genesis: u64): address {
        self.clients += 1;
        let seed = b"other";
        seed.append(bcs::to_bytes(&self.clients));
        let now = now();
        light_client::create(
            &signer_of(RELAYER),
            seed,
            system,
            bytes::repeat(5, 32),
            bytes::repeat(6, 32),
            (now - genesis) / 384,
            genesis,
        )
    }

    // ---------------------------------------------------------------------
    // The clock and the accounts
    // ---------------------------------------------------------------------

    public fun vault(self: &T): address { self.vault }

    public fun p1_id(self: &T): address { self.p1 }

    public fun p2_id(self: &T): address { self.p2 }

    public fun index(self: &T): vector<u8> { self.index }

    public fun now(): u64 { timestamp::now_seconds() }

    /// The clock at `us` microseconds, which must not be earlier than now.
    public fun set_us(us: u64) {
        let now = timestamp::now_microseconds();
        assert!(us >= now, 0);
        if (us > now) timestamp::update_global_time_for_test(us);
    }

    /// The clock at `seconds`, which must not be earlier than now.
    public fun set_now(seconds: u64) {
        set_us(seconds * 1_000_000);
    }

    public fun warp(seconds: u64) {
        if (seconds > 0) timestamp::fast_forward_seconds(seconds);
    }

    /// The vault's 32-byte id.
    public fun vault_id(self: &T): vector<u8> {
        bcs::to_bytes(&self.vault)
    }

    /// APT in `who`'s primary store.
    public fun apt_balance(who: address): u64 {
        primary_fungible_store::balance(who, vault::apt_for_testing())
    }

    /// The APT `who` received since last asked, in octas.
    public fun received(self: &mut T, who: address): u64 {
        let balance = apt_balance(who);
        let last = if (self.seen.contains_key(&who)) { *self.seen.borrow(&who) } else { 0 };
        self.seen.upsert(who, balance);
        balance - last
    }

    /// `amount` octas of new APT in `who`'s primary store.
    public fun mint(who: address, amount: u64) {
        if (amount > 0) primary_fungible_store::deposit(who, aptos_coin::mint_apt_fa_for_test(amount));
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
        let out = DOMAIN;
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
        let out = rlp_len(0x80, b.length());
        out.append(*b);
        out
    }

    public fun rlp_list(items: &vector<vector<u8>>): vector<u8> {
        let body = vector::empty<u8>();
        let i = 0;
        while (i < items.length()) {
            body.append(items[i]);
            i += 1;
        };
        let out = rlp_len(0xc0, body.length());
        out.append(body);
        out
    }

    fun rlp_len(base: u8, len: u64): vector<u8> {
        if (len < 56) return vector[base + (len as u8)];
        let be = vector::empty<u8>();
        let n = len;
        while (n > 0) {
            be.push_back(((n & 0xff) as u8));
            n >>= 8;
        };
        be.reverse();
        let out = vector[base + 55 + (be.length() as u8)];
        out.append(be);
        out
    }

    /// `abi.encode(bytes payload)`, a `VaultMessage` log's data.
    public fun log_data(payload: &vector<u8>): vector<u8> {
        let out = bytes::word64(32);
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
            rlp_bytes(&bytes::repeat(0, 256)),
            rlp_list(&vector[log]),
        ])
    }

    /// The receipts trie of a block whose one transaction made `receipt`: a leaf at key `rlp(0)`, nibbles 8 and 0.
    public fun receipt_leaf(receipt: &vector<u8>): vector<u8> {
        rlp_list(&vector[rlp_bytes(&vector[0x20, 0x80]), rlp_bytes(receipt)])
    }

    fun le(x: u64, n: u64): vector<u8> {
        let out = vector::empty<u8>();
        let i = 0;
        while (i < n) {
            out.push_back((((x >> ((8 * i) as u8)) & 0xff) as u8));
            i += 1;
        };
        out
    }

    /// `keccak256(abi.encode(uint256 number, uint256 timestamp, stateRoot, receiptsRoot))`, a block's leaf.
    public fun leaf(number: u64, timestamp: u64, state_root: &vector<u8>, receipts_root: &vector<u8>): vector<u8> {
        let pre = bytes::word64(number);
        pre.append(bytes::word64(timestamp));
        pre.append(*state_root);
        pre.append(*receipts_root);
        keccak256(pre)
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
        let out = *root;
        out.append(le(number, 8));
        out.append(le(timestamp, 8));
        out.append(*state_root);
        out.append(*receipts_root);
        out.push_back((path.length() as u8));
        let i = 0;
        while (i < path.length()) {
            out.append(path[i]);
            i += 1;
        };
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
        let id = keccak256(*payload);
        let leaf_node = receipt_leaf(&receipt(emitter, &id, payload));
        let (proof, root) = header(number, timestamp, &bytes::repeat(7, 32), &keccak256(leaf_node));
        proof.push_back(1);
        proof.append(le(leaf_node.length(), 4));
        proof.append(leaf_node);
        proof.append(le(0, 4));
        proof.append(le(0, 4));
        (proof, root)
    }

    /// The receipt part of an event proof: the nodes (`fixtures`' node lists), then the transaction's and the log's
    /// index.
    public fun receipt_part(nodes: &vector<u8>, tx: u64, log: u64): vector<u8> {
        let out = *nodes;
        out.append(le(tx, 4));
        out.append(le(log, 4));
        out
    }

    /// The headers tree over `leaves`, a zero for an odd layer's missing sibling: its root, and leaf `index`'s path.
    public fun tree(leaves: vector<vector<u8>>, index: u64): (vector<u8>, vector<vector<u8>>) {
        let layer = leaves;
        let path = vector::empty<vector<u8>>();
        let i = index;
        while (layer.length() > 1) {
            if (layer.length() % 2 == 1) layer.push_back(bytes::zero32());
            path.push_back(layer[i ^ 1]);
            let next = vector::empty<vector<u8>>();
            let j = 0;
            while (j < layer.length()) {
                let pair = layer[j];
                pair.append(layer[j + 1]);
                next.push_back(keccak256(pair));
                j += 2;
            };
            layer = next;
            i /= 2;
        };
        (layer[0], path)
    }

    /// An intake id: its deadline in the top 64 bits, then a nonce.
    public fun intake_id(deadline: u64, nonce: u64): vector<u8> {
        let id = le(deadline, 8);
        id.reverse();
        id.append(bytes::repeat(0, 16));
        let n = le(nonce, 8);
        n.reverse();
        id.append(n);
        id
    }

    /// A burn body: APT, `amount` octas, to the 32-byte `recipient`.
    public fun burn_body(amount: u64, recipient: address): vector<u8> {
        let out = bytes::zero32();
        out.append(bytes::word64(amount));
        out.append(bcs::to_bytes(&recipient));
        out
    }

    public fun cap_body(cap: u64, floor: u64): vector<u8> {
        let out = bytes::zero32();
        out.append(bytes::word64(cap));
        out.append(bytes::word64(floor));
        out
    }

    public fun migrate_body(new_index: &vector<u8>, amount: u64): vector<u8> {
        let out = bytes::address_word(new_index);
        out.append(bytes::zero32());
        out.append(bytes::word64(amount));
        out
    }

    public fun pair_body(p1: address, p2: address): vector<u8> {
        let out = bcs::to_bytes(&p1);
        out.append(bcs::to_bytes(&p2));
        out
    }

    // ---------------------------------------------------------------------
    // The vault's flows, as the Sui twin's tests drive them
    // ---------------------------------------------------------------------

    /// A message of `kind` from `emitter` with `body`, to this vault, with the next nonce.
    public fun payload(self: &mut T, kind: u8, emitter: &vector<u8>, body: &vector<u8>): vector<u8> {
        self.nonce += 1;
        message(SEPOLIA, kind, emitter, body, self.nonce, APTOS_TESTNET, &vault_id(self))
    }

    /// Both light clients in force recorded the one-block range `block` under `root`, as a proof would have.
    public fun record(self: &T, root: vector<u8>, block: u64) {
        let (p1, p2) = pair(self);
        record_for(p1, root, block);
        record_for(p2, root, block);
    }

    public fun record_for(client: address, root: vector<u8>, block: u64) {
        light_client::record_for_testing(client, root, block, block);
    }

    /// The light client `client` recorded the blocks `first` to `last` under `root`.
    public fun record_range(client: address, root: vector<u8>, first: u64, last: u64) {
        light_client::record_for_testing(client, root, first, last);
    }

    /// P1's and P2's proof of `payload`'s log by `emitter`, in block `block`, whose range both recorded.
    public fun proof_for(self: &T, emitter: &vector<u8>, payload: &vector<u8>, block: u64): vector<u8> {
        let (proof, root) = event_proof(emitter, payload, block, now());
        record(self, root, block);
        proof
    }

    /// Delivers `payload` from `emitter` in block `block`, on P1's proof, P2's, or both.
    public fun deliver_at(self: &T, emitter: &vector<u8>, payload: vector<u8>, p1: bool, p2: bool, block: u64) {
        let proof = proof_for(self, emitter, &payload, block);
        let a = if (p1) proof else vector[];
        let b = if (p2) proof else vector[];
        vault::deliver(self.vault, payload, block, a, b);
    }

    /// Delivers `payload` in `block` with the proofs given, through the vault's own P1 and P2.
    public fun deliver_raw(self: &T, payload: vector<u8>, block: u64, proof1: vector<u8>, proof2: vector<u8>) {
        vault::deliver(self.vault, payload, block, proof1, proof2);
    }

    /// Delivers `payload` from `emitter`, in the next block, on P1's proof, P2's, or both.
    public fun deliver_by(self: &mut T, emitter: &vector<u8>, payload: vector<u8>, p1: bool, p2: bool) {
        let block = next_block(self);
        deliver_at(self, emitter, payload, p1, p2, block);
    }

    /// A message of `kind` from the index, on both proofs, from a block the checkpoint covers; its payload.
    public fun deliver(self: &mut T, kind: u8, body: vector<u8>): vector<u8> {
        let index = self.index;
        let payload = payload(self, kind, &index, &body);
        deliver_by(self, &index, payload, true, true);
        payload
    }

    /// A message of `kind` from the factory with `body` and `nonce`, on P1's proof, P2's or both.
    public fun govern(self: &mut T, kind: u8, body: vector<u8>, nonce: u64, p1: bool, p2: bool): vector<u8> {
        let factory = f::hub_factory();
        let payload = message(SEPOLIA, kind, &factory, &body, nonce, APTOS_TESTNET, &vault_id(self));
        deliver_by(self, &factory, payload, p1, p2);
        payload
    }

    /// The next block for a message: one the vault's checkpoint already covers.
    public fun next_block(self: &mut T): u64 {
        let (covered, _, _) = checkpoint(self);
        if (covered < self.block + 1) {
            let b = self.block + 100;
            advance(self, b);
        };
        self.block += 1;
        self.block
    }

    public fun checkpoint(self: &T): (u64, u64, vector<u8>) {
        vault::checkpoint(self.vault)
    }

    /// A checkpoint at `block`, now, with a state root of its own, that P1 and P2 both prove; a second later first if
    /// the last checkpoint is dated now, since a checkpoint must be newer in time too.
    public fun advance(self: &T, block: u64) {
        let (_, ts, _) = checkpoint(self);
        if (ts >= now()) warp(1);
        let pre = b"state";
        pre.append(le(block, 8));
        advance_to(self, block, now(), keccak256(pre));
    }

    /// The proof of checkpoint `(block, timestamp, root)`, its block recorded alone by the clients `p1` and `p2`.
    public fun checkpoint_proof(block: u64, timestamp: u64, root: &vector<u8>, p1: address, p2: address): vector<u8> {
        let (head, headers_root) = header(block, timestamp, root, &bytes::repeat(9, 32));
        record_for(p1, headers_root, block);
        record_for(p2, headers_root, block);
        head
    }

    public fun advance_to(self: &T, block: u64, timestamp: u64, root: vector<u8>) {
        let (p1, p2) = pair(self);
        let proof = checkpoint_proof(block, timestamp, &root, p1, p2);
        vault::advance_checkpoint(self.vault, block, timestamp, root, proof, proof);
    }

    /// The vault's P1 and P2.
    public fun pair(self: &T): (address, address) {
        (vault::p1(self.vault), vault::p2(self.vault))
    }

    /// Deposits `amount` from `who` into intake `intake` of the index, APT minted to `who` first.
    public fun deposit(self: &T, who: address, intake: vector<u8>, amount: u64) {
        mint(who, amount);
        vault::deposit(&signer_of(who), self.vault, self.index, intake, amount);
    }

    /// Deposits `amount` into a fresh intake from Alice, and settles it on both proofs: the index holds it.
    public fun fund(self: &mut T, amount: u64): vector<u8> {
        self.nonce += 1;
        let intake = intake_id(now() + 3600, self.nonce);
        deposit(self, ALICE, intake, amount);
        deliver(self, 2, intake);
        intake
    }

    /// The index's balance.
    public fun balance(self: &T): u64 {
        let (_, balance, _, _, _) = vault::index_state(self.vault, self.index);
        balance
    }

    public fun index_state(self: &T, index: vector<u8>): (bool, u64, u64, vector<u8>, u64) {
        vault::index_state(self.vault, index)
    }

    /// What the vault holds, checked against its store's balance.
    public fun held(self: &T): u64 {
        let held = vault::held(self.vault);
        assert!(vault::coins(self.vault) == held, 0);
        held
    }

    public fun owed_remaining(self: &T, id: vector<u8>): u64 {
        let (_, _, _, remaining) = vault::owed(self.vault, self.index, id);
        remaining
    }

    public fun intake_state(self: &T, intake: vector<u8>): u8 {
        let (state, _, _) = vault::intake(self.vault, self.index, intake);
        state
    }

    public fun stalled(self: &T): bool {
        vault::stalled(self.vault)
    }

    public fun release(self: &T, id: vector<u8>) {
        vault::release(self.vault, self.index, id);
    }

    public fun freeze_by(self: &T, who: address) {
        vault::freeze_vault(&signer_of(who), self.vault);
    }

    // ---------------------------------------------------------------------
    // Recovery
    // ---------------------------------------------------------------------

    /// Two light clients, a successor or rotation candidate.
    struct Pair has copy, drop {
        a: address,
        b: address,
    }

    public fun pair_of(a: address, b: address): Pair { Pair { a, b } }

    public fun first(self: &Pair): address { self.a }

    public fun second(self: &Pair): address { self.b }

    /// A new SP1 and RISC Zero pair, as a `Pair`.
    public fun successor_pair(self: &mut T, seed: u8): Pair {
        let (a, b) = new_pair(self, seed);
        Pair { a, b }
    }

    /// The continuity test the clients `pair` pass: the vault's last checkpoint, a recent one at `recent_block`, and,
    /// when `payload` is not empty, the last message, `payload` in `block`, each proven by both.
    public fun continuity(self: &T, pair: Pair, recent_block: u64, payload: vector<u8>, block: u64): vault::Continuity {
        let (a, b) = (pair.a, pair.b);
        let (last_block, last_ts, last_root) = checkpoint(self);
        let last = checkpoint_proof(last_block, last_ts, &last_root, a, b);
        let pre = b"recent";
        pre.append(le(recent_block, 8));
        let recent_root = keccak256(pre);
        let now = now();
        let recent = checkpoint_proof(recent_block, now, &recent_root, a, b);
        let message = if (payload.is_empty()) vector[] else {
            let emitter = bytes::slice(&payload, 5 * 32 + 12, 20);
            let (proof, root) = event_proof(&emitter, &payload, block, now);
            record_for(a, root, block);
            record_for(b, root, block);
            proof
        };
        vault::continuity(last, last, recent_block, now, recent_root, recent, recent, payload, block, message, message)
    }

    public fun propose(self: &T, who: address, pair: Pair, c: vault::Continuity) {
        vault::propose_successor(&signer_of(who), self.vault, pair.a, pair.b, c);
    }

    public fun veto(self: &T, who: address) {
        vault::veto_successor(&signer_of(who), self.vault);
    }

    /// Adopts the pair on a checkpoint at `block`, now, both prove.
    public fun adopt(self: &T, pair: Pair, block: u64) {
        let root = bytes::repeat(((block & 0xff) as u8), 32);
        let now = now();
        let proof = checkpoint_proof(block, now, &root, pair.a, pair.b);
        vault::adopt_successor(self.vault, block, now, root, proof, proof);
    }

    public fun begin_snapshot(self: &T) {
        vault::begin_snapshot(self.vault);
    }

    public fun successor(self: &T): (address, address, u64) {
        vault::successor(self.vault)
    }

    public fun vetoes(self: &T): u8 {
        vault::vetoes(self.vault)
    }

    public fun last_message(self: &T): vector<u8> {
        vault::last_message(self.vault)
    }

    public fun stall_start(self: &T): u64 {
        vault::stall_start(self.vault)
    }

    public fun nonce(self: &T): u64 { self.nonce }

    public fun last_block(self: &T): u64 { self.block }

    /// Two new light clients, SP1 and RISC Zero, anchored now: a successor or rotation pair, keys seeded by `seed`.
    public fun new_pair(self: &mut T, seed: u8): (address, address) {
        self.clients += 1;
        let epoch = epoch_at(now());
        let s1 = b"pair-a";
        s1.append(bcs::to_bytes(&self.clients));
        let s2 = b"pair-b";
        s2.append(bcs::to_bytes(&self.clients));
        let a = light_client(RELAYER, s1, light_client::sp1(), seed, epoch);
        let b = light_client(RELAYER, s2, light_client::risc_zero(), seed + 1, epoch);
        (a, b)
    }

    /// The SP1 and RISC Zero fixtures' clients: SP1's program key and RISC Zero's image id, anchored now.
    public fun fixture_pair(): (address, address) {
        let epoch = epoch_at(now());
        let a = light_client::create(
            &signer_of(RELAYER),
            b"fixture-sp1",
            light_client::sp1(),
            f::sp1_program_key(),
            bytes::repeat(0xaa, 32),
            epoch,
            SEPOLIA_GENESIS,
        );
        let b = light_client::create(
            &signer_of(RELAYER),
            b"fixture-risc0",
            light_client::risc_zero(),
            f::risc0_image_id(),
            bytes::repeat(0xaa, 32),
            epoch,
            SEPOLIA_GENESIS,
        );
        (a, b)
    }
}
