/// Xindex v4 Stage B: the vault on Aptos, holding APT for every index whose shares live on Ethereum. The twin of the EVM
/// vault (`src/vault/XindexVault.sol`) and of the Solana, NEAR, Stellar and Sui vaults: coins come in only as deposits
/// to an intake and leave only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over any 24
/// hours. If Ethereum's formats change unannounced and P1 and P2 stop working, the vault stalls, may adopt a successor
/// pair after a continuity test and 30 days of review, and after 180 days pays each index's holders at its last
/// checkpoint directly (design 6.9). Its state is proven to Ethereum by `attest`, whose `Attested` event
/// `AptosStateVerifier` reads from a signed ledger (`design/2026-10-04-four-chains-interfaces.md`).
///
/// What Aptos changes:
/// - The vault's state lives at an object whose owner is `0x0` and which can never be transferred: no account can sign
///   for it or act as its owner, and its `ExtendRef`, the only way to its signer, sits inside that state, which only this
///   module reads. The vault id is the object's address. P1 and P2 are `light_client` objects of this package, named by
///   their addresses.
/// - Time is `timestamp::now_seconds()` for every rule, and `now_microseconds()` in `attest`'s record.
/// - Amounts are APT in octas, `u64`; one from Ethereum that does not fit is refused. APT is the fungible asset whose
///   metadata is `0xa`. The coins sit in a fungible store at an object the vault owns, which only this module withdraws
///   from, so `held` equals its balance but for what someone deposits there directly, which counts nowhere.
/// - A recipient is a 32-byte Aptos address. A payout is APT deposited to its primary store, which never fails but for a
///   store frozen by the asset's issuer, and then the payout waits, owed, as on the EVM.
/// - No owner, no upgrade, no capability: the package is published with `upgrade_policy = "immutable"`, and every role
///   is an address fixed in the vault's state (README, "Ownerless and immutable").
module xindex_vault::vault {
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::aptos_hash::keccak256;
    use aptos_std::from_bcs;
    use aptos_std::table::{Self, Table};
    use xindex_vault::abi::{Self, Message};
    use xindex_vault::bytes;
    use xindex_vault::light_client;
    use xindex_vault::snapshot;
    use xindex_vault::state_reader;

    // ---------------------------------------------------------------------
    // Refusals, by the EVM vault's names where it has them, numbered as Sui's twin numbers them
    // ---------------------------------------------------------------------

    const EZeroAddress: u64 = 1;
    const EZeroAmount: u64 = 2;
    const ENotAnIndex: u64 = 3;
    const EVaultFrozen: u64 = 4;
    const EVaultStalled: u64 = 5;
    const EIntakeClosed: u64 = 6;
    const EIntakeTooLong: u64 = 7;
    const EIntakeNotOpen: u64 = 8;
    const ECapExceeded: u64 = 9;
    const ENoProof: u64 = 10;
    /// A body names another token, or a deposit is not APT.
    const ENotNative: u64 = 11;
    const EWrongRoute: u64 = 12;
    const EWrongEmitter: u64 = 13;
    const EUnknownKind: u64 = 14;
    const EBothProofsRequired: u64 = 15;
    const ENotCheckpointed: u64 = 16;
    const EIssuedAfterSnapshot: u64 = 17;
    const EAlreadyDelivered: u64 = 18;
    const ENothingOwed: u64 = 19;
    const ENothingPayable: u64 = 20;
    const ENothingToRefund: u64 = 21;
    const ENotFreezer: u64 = 22;
    const EWrongRecipient: u64 = 23;
    const EStaleGovernance: u64 = 24;
    const ENoPendingChange: u64 = 25;
    const EChangeNotReady: u64 = 26;
    const ENotNewer: u64 = 27;
    const ENotRecent: u64 = 28;
    const ENotStalled: u64 = 29;
    const ENotRecoveryProposer: u64 = 30;
    const ESameRole: u64 = 31;
    const ESuccessorPending: u64 = 32;
    const ENoSuccessor: u64 = 33;
    const EDiscontinuous: u64 = 34;
    const EVetoesExhausted: u64 = 35;
    const EReviewNotOver: u64 = 36;
    const ESnapshotTaken: u64 = 37;
    const ENoSnapshot: u64 = 38;
    const ESnapshotNotDue: u64 = 39;
    const ENoCheckpoint: u64 = 40;
    const ENotRecorded: u64 = 41;
    const EAlreadyClaimed: u64 = 42;
    const ENotAttested: u64 = 43;
    /// An address named as P1 or P2 holds no light client of this package, or P1 is not an SP1 client or P2 not a RISC
    /// Zero one.
    const EWrongVerifier: u64 = 44;
    const EVerifiersNotDistinct: u64 = 45;
    /// `DeployVault`'s refusals: an unknown source chain, a chain id not Aptos's for it, a floor above the cap, a role
    /// that is the creating key, and light clients whose anchor can no longer be advanced from.
    const EUnknownSource: u64 = 46;
    const EWrongChain: u64 = 47;
    const EFloorAboveCap: u64 = 48;
    const ERoleIsCreator: u64 = 49;
    const EAnchorTooOld: u64 = 50;
    // 51 is Sui's `EVerifiersRequired`: on Aptos a rotation names addresses, so `apply_change` applies it.
    /// An argument of the wrong length: an index, salt, intake id or slot.
    const EBadLength: u64 = 52;
    /// A freeze's body is not empty.
    const EBadMessage: u64 = 53;
    /// No vault lives at the address.
    const ENoVault: u64 = 54;

    // ---------------------------------------------------------------------
    // The rules, as the EVM vault's
    // ---------------------------------------------------------------------

    const FREEZE_DURATION: u64 = 14 * 86_400;
    const GOVERNANCE_DELAY: u64 = 7 * 86_400;
    const MAX_INTAKE_LIFE: u64 = 7 * 86_400;
    const STALL_PERIOD: u64 = 7 * 86_400;
    const RECOVERY_DELAY: u64 = 30 * 86_400;
    const MAX_RECOVERY_VETOES: u8 = 2;
    const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
    /// The current hour and the 24 before it: every real 24-hour span lies inside them.
    const BUCKETS: u64 = 25;
    const HOUR: u64 = 3600;
    /// 4% a day, as `SPEED_LIMIT` (0.04e18).
    const SPEED_LIMIT_PERCENT: u128 = 4;

    /// Message kinds, as `VaultMessages`.
    const BURN: u8 = 1;
    const INTAKE_SETTLED: u8 = 2;
    const INTAKE_FAILED: u8 = 3;
    const MIGRATE: u8 = 4;
    const CAP_UPDATE: u8 = 5;
    const FREEZE: u8 = 6;
    const FREEZER_CHANGE: u8 = 7;
    const VERIFIER_ROTATION: u8 = 8;

    /// Intake states, as `IXindexVault.IntakeState`.
    const INTAKE_NONE: u8 = 0;
    const INTAKE_OPEN: u8 = 1;
    const INTAKE_SETTLED_STATE: u8 = 2;
    const INTAKE_FAILED_STATE: u8 = 3;

    /// The hub's storage layout the slot map follows (`HybridHubStorage`): `intakeDigest` (15), `indexDigest` (14),
    /// `_snapshot.stateRoot` (25).
    const INTAKE_DIGEST_SLOT: u64 = 15;
    const INDEX_DIGEST_SLOT: u64 = 14;
    const SNAPSHOT_ROOT_SLOT: u64 = 25;

    /// The chains: Ethereum mainnet and Sepolia, their beacon genesis times, and Aptos's registry ids for each,
    /// `aptos:1` and `aptos:2` (interfaces doc).
    const ETHEREUM: u64 = 1;
    const SEPOLIA: u64 = 11_155_111;
    const ETHEREUM_GENESIS: u64 = 1_606_824_023;
    const SEPOLIA_GENESIS: u64 = 1_655_733_600;
    const APTOS_MAINNET: u64 = 549_304_973_309_166_888;
    const APTOS_TESTNET: u64 = 10_134_113_455_198_361_380;

    /// APT's fungible-asset metadata, the object `0xa` (`@aptos_fungible_asset`), paired with `0x1::aptos_coin::AptosCoin`.
    const APT: address = @0xa;
    /// The seeds of the vault's object, `object::create_object_address(creator, VAULT_SEED)`, and of its coins' store,
    /// `object::create_object_address(vault, STORE_SEED)`.
    const VAULT_SEED: vector<u8> = b"xindex.v4.vault";
    const STORE_SEED: vector<u8> = b"xindex.v4.vault.apt";

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// A final Ethereum block: its number, its timestamp and its state root.
    struct Checkpoint has copy, drop, store {
        block: u64,
        timestamp: u64,
        state_root: vector<u8>,
    }

    /// A successor pair under review, and when the review ends; `review_ends` zero when none is.
    struct Successor has copy, drop, store {
        p1: address,
        p2: address,
        review_ends: u64,
    }

    /// A governance change waiting: the hash of its body and when it may apply, zero when none waits.
    struct PendingChange has copy, drop, store {
        body_hash: vector<u8>,
        ready_at: u64,
    }

    /// One hour's payouts, tagged with the hour so a stale slot reads as empty.
    struct Bucket has copy, drop, store {
        hour: u64,
        amount: u64,
    }

    /// An index registered here: whether APT is among its tokens (set by its first credit, as the EVM vault's
    /// `_indexTokens`), its balance, everything paid out of it, its outflow buckets and its digest.
    struct IndexState has copy, drop, store {
        has_native: bool,
        balance: u64,
        paid_total: u64,
        outflow: vector<Bucket>,
        digest: vector<u8>,
    }

    /// A mint order's or a rebalance delivery's deposits for one index.
    struct Intake has copy, drop, store {
        state: u8,
        has_native: bool,
        total: u64,
        digest: vector<u8>,
    }

    /// A burn, a migration or a snapshot claim accepted and not yet paid in full: to an address, or into another index.
    struct Owed has copy, drop, store {
        to_index: bool,
        recipient: address,
        new_index: vector<u8>,
        remaining: u64,
    }

    struct IntakeKey has copy, drop, store {
        index: vector<u8>,
        intake_id: vector<u8>,
    }

    struct DepositKey has copy, drop, store {
        index: vector<u8>,
        intake_id: vector<u8>,
        depositor: address,
    }

    struct OwedKey has copy, drop, store {
        index: vector<u8>,
        id: vector<u8>,
    }

    /// The vault, at its object's address. Every coin it accounts for is in `held`, which `store`'s balance always
    /// covers: settled balances plus the deposits of open and failed intakes not yet refunded.
    struct Vault has key {
        /// The only way to the vault's signer, which owns `store`: only this module reads it.
        extend_ref: ExtendRef,
        store: Object<FungibleStore>,
        source_chain_id: u64,
        chain_id: u64,
        factory: vector<u8>,
        hub_implementation: vector<u8>,
        p1: address,
        p2: address,
        freezer: address,
        recovery_proposer: address,
        frozen_until: u64,
        cap: u64,
        outflow_floor: u64,
        held: u64,
        /// The factory's nonce of the last cap update, freezer change and rotation taken on both proofs (VLT-4).
        cap_nonce: u64,
        freezer_nonce: u64,
        rotation_nonce: u64,
        /// A raised cap or floor, a new freezer and new verifiers each wait GOVERNANCE_DELAY here (VLT-2).
        pending_cap: PendingChange,
        pending_freezer: PendingChange,
        pending_rotation: PendingChange,
        checkpoint: Checkpoint,
        snapshot: Checkpoint,
        successor: Successor,
        /// The last message delivered on both proofs, which a successor must prove again (LG-3).
        last_message: vector<u8>,
        /// The freezer's vetoes in the current stall (LG-2).
        vetoes: u8,
        indexes: Table<vector<u8>, IndexState>,
        intakes: Table<IntakeKey, Intake>,
        deposits: Table<DepositKey, u64>,
        owed: Table<OwedKey, Owed>,
        used: Table<vector<u8>, bool>,
        /// The values `attest` vouches for, by the slot the hub reads them at on an EVM vault.
        slots: Table<vector<u8>, vector<u8>>,
    }

    /// What a successor pair must prove: the checkpoint the pair in force last accepted, a recent one, and the last
    /// message delivered on both proofs, if there was one (its payload empty when not).
    struct Continuity has copy, drop {
        last1: vector<u8>,
        last2: vector<u8>,
        recent: Checkpoint,
        recent1: vector<u8>,
        recent2: vector<u8>,
        message: vector<u8>,
        message_block: u64,
        message1: vector<u8>,
        message2: vector<u8>,
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    #[event]
    /// What `attest` emits: `record = abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestampUs, slots, values)`. Only
    /// `attest` packs one, so a ledger holding one shows a successful `attest`: `AptosStateVerifier` reads it as
    /// `<package>::vault::Attested`, whose BCS is the record as a byte string.
    struct Attested has drop, store {
        record: vector<u8>,
    }

    #[event]
    struct VaultCreated has drop, store { vault: address, source_chain_id: u64, chain_id: u64, p1: address, p2: address }

    #[event]
    struct IndexRegistered has drop, store { vault: address, index: vector<u8>, salt: vector<u8> }

    #[event]
    struct Deposited has drop, store {
        vault: address,
        index: vector<u8>,
        intake_id: vector<u8>,
        depositor: address,
        amount: u64,
    }

    #[event]
    struct Refunded has drop, store {
        vault: address,
        index: vector<u8>,
        intake_id: vector<u8>,
        depositor: address,
        amount: u64,
    }

    #[event]
    struct MessageDelivered has drop, store { vault: address, id: vector<u8>, kind: u8, index: vector<u8> }

    #[event]
    struct BurnAccepted has drop, store {
        vault: address,
        index: vector<u8>,
        id: vector<u8>,
        amount: u64,
        recipient: address,
    }

    #[event]
    struct MigrationAccepted has drop, store {
        vault: address,
        index: vector<u8>,
        id: vector<u8>,
        amount: u64,
        new_index: vector<u8>,
    }

    #[event]
    struct Paid has drop, store { vault: address, index: vector<u8>, id: vector<u8>, amount: u64, remaining: u64 }

    #[event]
    struct IntakeSettled has drop, store { vault: address, index: vector<u8>, intake_id: vector<u8> }

    #[event]
    struct IntakeFailed has drop, store { vault: address, index: vector<u8>, intake_id: vector<u8> }

    #[event]
    struct IntakeResolved has drop, store { vault: address, index: vector<u8>, intake_id: vector<u8>, settled: bool }

    #[event]
    struct CapSet has drop, store { vault: address, cap: u64, outflow_floor: u64 }

    #[event]
    struct FreezerChanged has drop, store { vault: address, freezer: address }

    #[event]
    struct VerifiersRotated has drop, store { vault: address, p1: address, p2: address }

    #[event]
    struct ChangeQueued has drop, store { vault: address, kind: u8, body: vector<u8>, ready_at: u64 }

    #[event]
    struct ChangeApplied has drop, store { vault: address, kind: u8 }

    #[event]
    struct ChangeCancelled has drop, store { vault: address, kind: u8 }

    #[event]
    struct Frozen has drop, store { vault: address, until: u64, by_factory: bool }

    #[event]
    struct CheckpointAdvanced has drop, store { vault: address, block: u64, timestamp: u64, state_root: vector<u8> }

    #[event]
    struct SuccessorProposed has drop, store { vault: address, p1: address, p2: address, review_ends: u64 }

    #[event]
    struct SuccessorVetoed has drop, store { vault: address, vetoes: u8 }

    #[event]
    struct SuccessorAdopted has drop, store { vault: address, p1: address, p2: address }

    #[event]
    struct SuccessorLapsed has drop, store { vault: address }

    #[event]
    struct SnapshotBegun has drop, store { vault: address, block: u64, timestamp: u64, state_root: vector<u8> }

    #[event]
    struct SnapshotClaimed has drop, store {
        vault: address,
        index: vector<u8>,
        holder: vector<u8>,
        recipient: address,
        amount: u64,
        id: vector<u8>,
    }

    // ---------------------------------------------------------------------
    // Creation
    // ---------------------------------------------------------------------

    /// Creates a vault at `object::create_object_address(creator, b"xindex.v4.vault")` and returns that address, the
    /// vault id Ethereum's registry names. It refuses what `DeployVault` refuses where Move can see it: a source chain
    /// other than Ethereum or Sepolia, a chain id not Aptos's for it, a missing factory or template, light clients that
    /// are not one SP1 and one RISC Zero client of this package and of the source chain's beacon genesis, still within
    /// their lag, roles that are unset, the same or the creating key, and a floor above the cap. That the recovery
    /// proposer is the owner's emergency multisig, and the freezer the guardian's key, is the deployment's to check
    /// (README). Its first week's grace: a stall is a week without a new checkpoint, counted from creation until the
    /// first.
    public fun create(
        creator: &signer,
        source_chain_id: u64,
        chain_id: u64,
        factory: vector<u8>,
        hub_implementation: vector<u8>,
        p1: address,
        p2: address,
        freezer: address,
        recovery_proposer: address,
        native_cap: u64,
        native_floor: u64,
    ): address {
        let genesis = if (source_chain_id == ETHEREUM) {
            assert!(chain_id == APTOS_MAINNET, EWrongChain);
            ETHEREUM_GENESIS
        } else {
            assert!(source_chain_id == SEPOLIA, EUnknownSource);
            assert!(chain_id == APTOS_TESTNET, EWrongChain);
            SEPOLIA_GENESIS
        };
        assert!(factory.length() == 20 && hub_implementation.length() == 20, EBadLength);
        assert!(!bytes::is_zero(&factory) && !bytes::is_zero(&hub_implementation), EZeroAddress);
        assert!(light_client::is_client(p1) && light_client::is_client(p2), EWrongVerifier);
        assert!(light_client::system(p1) == light_client::sp1(), EWrongVerifier);
        assert!(light_client::system(p2) == light_client::risc_zero(), EWrongVerifier);
        assert!(light_client::genesis_time(p1) == genesis && light_client::genesis_time(p2) == genesis, EWrongVerifier);
        let now = timestamp::now_seconds();
        assert!(now <= light_client::lag_ends(p1) && now <= light_client::lag_ends(p2), EAnchorTooOld);
        assert!(freezer != @0x0 && recovery_proposer != @0x0, EZeroAddress);
        assert!(freezer != recovery_proposer, ESameRole);
        let creator_address = signer::address_of(creator);
        assert!(freezer != creator_address && recovery_proposer != creator_address, ERoleIsCreator);
        assert!(native_floor <= native_cap, EFloorAboveCap);

        // The vault's object, owned by nobody and fixed there: no account can act as its owner, and its signer comes
        // only from the `ExtendRef` kept in its state.
        let cref = object::create_named_object(creator, VAULT_SEED);
        object::transfer_with_constructor_ref(&cref, @0x0);
        object::set_untransferable(&cref);
        let extend_ref = object::generate_extend_ref(&cref);
        let vault_signer = object::generate_signer(&cref);
        let vault = signer::address_of(&vault_signer);
        // Its coins' store, at an object the vault owns, fixed there too.
        let scref = object::create_named_object(&vault_signer, STORE_SEED);
        let store = fungible_asset::create_store(&scref, apt());
        if (!object::is_untransferable(store)) object::set_untransferable(&scref);
        let none = PendingChange { body_hash: vector[], ready_at: 0 };
        move_to(&vault_signer, Vault {
            extend_ref,
            store,
            source_chain_id,
            chain_id,
            factory,
            hub_implementation,
            p1,
            p2,
            freezer,
            recovery_proposer,
            frozen_until: 0,
            cap: native_cap,
            outflow_floor: native_floor,
            held: 0,
            cap_nonce: 0,
            freezer_nonce: 0,
            rotation_nonce: 0,
            pending_cap: none,
            pending_freezer: none,
            pending_rotation: none,
            checkpoint: Checkpoint { block: 0, timestamp: now, state_root: bytes::zero32() },
            snapshot: Checkpoint { block: 0, timestamp: 0, state_root: bytes::zero32() },
            successor: no_successor(),
            last_message: bytes::zero32(),
            vetoes: 0,
            indexes: table::new(),
            intakes: table::new(),
            deposits: table::new(),
            owed: table::new(),
            used: table::new(),
            slots: table::new(),
        });
        event::emit(VaultCreated { vault, source_chain_id, chain_id, p1, p2 });
        event::emit(CapSet { vault, cap: native_cap, outflow_floor: native_floor });
        vault
    }

    /// `create` as a transaction: the vault's address is `object::create_object_address(creator, b"xindex.v4.vault")`,
    /// and its `VaultCreated` event names it.
    public entry fun create_vault(
        creator: &signer,
        source_chain_id: u64,
        chain_id: u64,
        factory: vector<u8>,
        hub_implementation: vector<u8>,
        p1: address,
        p2: address,
        freezer: address,
        recovery_proposer: address,
        native_cap: u64,
        native_floor: u64,
    ) {
        create(
            creator,
            source_chain_id,
            chain_id,
            factory,
            hub_implementation,
            p1,
            p2,
            freezer,
            recovery_proposer,
            native_cap,
            native_floor,
        );
    }

    // ---------------------------------------------------------------------
    // Indexes and deposits
    // ---------------------------------------------------------------------

    /// Anyone: records `index` once its address is the factory's CREATE2 clone of the hub template under `salt`. Only a
    /// registered index takes deposits or sends messages that run.
    public entry fun register_index(vault: address, index: vector<u8>, salt: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        assert!(index.length() == 20 && salt.length() == 32, EBadLength);
        assert!(abi::predict_clone(&v.hub_implementation, &salt, &v.factory) == index, ENotAnIndex);
        if (v.indexes.contains(index)) return;
        let outflow = vector::empty<Bucket>();
        let i = 0;
        while (i < BUCKETS) {
            outflow.push_back(Bucket { hour: 0, amount: 0 });
            i += 1;
        };
        v.indexes.add(index, IndexState { has_native: false, balance: 0, paid_total: 0, outflow, digest: vector[] });
        event::emit(IndexRegistered { vault, index, salt });
        refresh_index(v, vault, &index);
    }

    /// Anyone, while neither frozen nor stalled: deposits `amount` octas of APT from its primary store into intake
    /// `intake_id` of `index`. The intake's deadline is its id's top 64 bits: nobody can open another's intake with
    /// another deadline, and deposits close at it for all.
    public entry fun deposit(
        depositor: &signer,
        vault: address,
        index: vector<u8>,
        intake_id: vector<u8>,
        amount: u64,
    ) acquires Vault {
        let fa = primary_fungible_store::withdraw(depositor, apt(), amount);
        deposit_asset(depositor, vault, index, intake_id, fa);
    }

    /// `deposit` of APT already withdrawn, from wherever the depositor holds it: the asset must be APT.
    public fun deposit_asset(
        depositor: &signer,
        vault: address,
        index: vector<u8>,
        intake_id: vector<u8>,
        fa: FungibleAsset,
    ) acquires Vault {
        let v = borrow_mut(vault);
        assert!(v.indexes.contains(index), ENotAnIndex);
        check_not_frozen(v);
        // A stalled vault may never again see the message that would settle or fail an intake.
        assert!(!stalled_of(v), EVaultStalled);
        assert!(fungible_asset::metadata_from_asset(&fa) == apt(), ENotNative);
        let amount = fungible_asset::amount(&fa);
        assert!(amount != 0, EZeroAmount);
        assert!(intake_id.length() == 32, EBadLength);
        let deadline = abi::deadline_of(&intake_id);
        let now = timestamp::now_seconds();
        assert!(now <= deadline, EIntakeClosed);
        let key = IntakeKey { index, intake_id };
        let state = if (v.intakes.contains(key)) { v.intakes.borrow(key).state } else { INTAKE_NONE };
        if (state == INTAKE_NONE) {
            assert!((deadline as u128) <= (now as u128) + (MAX_INTAKE_LIFE as u128), EIntakeTooLong);
            v.intakes.add(key, Intake { state: INTAKE_OPEN, has_native: false, total: 0, digest: vector[] });
        } else {
            assert!(state == INTAKE_OPEN, EIntakeClosed);
        };
        assert!((v.held as u128) + (amount as u128) <= (v.cap as u128), ECapExceeded);
        v.held += amount;
        fungible_asset::deposit(v.store, fa);
        let depositor = signer::address_of(depositor);
        let mine = v.deposits.borrow_mut_with_default(DepositKey { index, intake_id, depositor }, 0);
        *mine += amount;
        let intake = v.intakes.borrow_mut(key);
        intake.total += amount;
        intake.has_native = true;
        event::emit(Deposited { vault, index, intake_id, depositor, amount });
        refresh_intake(v, vault, &index, &intake_id);
    }

    /// A depositor of a failed intake, while not frozen: takes its deposit back, to its primary store, as the EVM vault
    /// sends it to `msg.sender`.
    public entry fun refund(depositor: &signer, vault: address, index: vector<u8>, intake_id: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        let key = IntakeKey { index, intake_id };
        assert!(v.intakes.contains(key) && v.intakes.borrow(key).state == INTAKE_FAILED_STATE, EIntakeNotOpen);
        check_not_frozen(v);
        let depositor = signer::address_of(depositor);
        let dkey = DepositKey { index, intake_id, depositor };
        let amount = if (v.deposits.contains(dkey)) { *v.deposits.borrow(dkey) } else { 0 };
        assert!(amount != 0, ENothingToRefund);
        *v.deposits.borrow_mut(dkey) = 0;
        v.held -= amount;
        let intake = v.intakes.borrow_mut(key);
        intake.total -= amount;
        event::emit(Refunded { vault, index, intake_id, depositor, amount });
        refresh_intake(v, vault, &index, &intake_id);
        send(v, depositor, amount);
    }

    // ---------------------------------------------------------------------
    // Messages from Ethereum
    // ---------------------------------------------------------------------

    /// Anyone: runs one `VaultMessage` an index or the factory emitted, its log in Ethereum block `block`, on P1's
    /// proof, P2's or both (an empty proof is none). After a snapshot, no block past it; then the canonical encoding,
    /// the route, the emitter and the proofs; for a message that moves coins or loosens a rule, both proofs and a
    /// checkpoint covering its block (VLT-3); and a used mark, so a message runs at most once, whoever sends it again
    /// (LG-1).
    public entry fun deliver(
        vault: address,
        payload: vector<u8>,
        block: u64,
        proof1: vector<u8>,
        proof2: vector<u8>,
    ) acquires Vault {
        let v = borrow_mut(vault);
        // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
        assert!(v.snapshot.block == 0 || block <= v.snapshot.block, EIssuedAfterSnapshot);
        let id = abi::message_id(&payload);
        let m = abi::decode_message(&payload);
        let kind = abi::kind(&m);
        assert!(kind != 0 && kind <= VERIFIER_ROTATION, EUnknownKind);
        check_route(v, vault, &m);
        let governance = kind >= CAP_UPDATE;
        // Any Ethereum contract can emit a message naming itself; a governance kind is the factory's alone, and an
        // index's kind runs only for a clone of the factory registered here.
        if (governance) {
            assert!(abi::index(&m) == v.factory, EWrongEmitter);
        } else {
            assert!(v.indexes.contains(abi::index(&m)), ENotAnIndex);
        };
        let has1 = !proof1.is_empty();
        let has2 = !proof2.is_empty();
        assert!(has1 || has2, ENoProof);
        let data = abi::log_data(&payload);
        let topic = abi::event_topic();
        if (has1) light_client::verify_event(v.p1, &proof1, block, &abi::index(&m), &topic, &id, &data);
        if (has2) light_client::verify_event(v.p2, &proof2, block, &abi::index(&m), &topic, &id, &data);
        let both = has1 && has2;
        let loosening = needs_both(v, &m);
        if (loosening) {
            assert!(both, EBothProofsRequired);
            // A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
            // snapshot at that checkpoint never pays twice what such a message already paid (VLT-3).
            assert!(block <= v.checkpoint.block, ENotCheckpointed);
        };
        assert!(!v.used.contains(id), EAlreadyDelivered);
        // A cut taken on one proof moves no mark (VLT-4), so it stays deliverable on both, which moves the mark past an
        // older raise; until then a replay on one proof only applies it again (A3-02). A freeze is used up at once.
        if (both || kind == FREEZE) v.used.add(id, true);
        // Only a message on both proofs: one broken proof system could forge a one-proof freeze, which no honest
        // successor could prove again (LG-3).
        if (both) v.last_message = id;
        event::emit(MessageDelivered { vault, id, kind, index: abi::index(&m) });
        if (governance) governance_message(v, vault, &m, loosening, both)
        else index_message(v, vault, &m, id);
    }

    /// Anyone, while not frozen: pays what the speed limit now allows of an owed burn, claim or migration.
    public entry fun release(vault: address, index: vector<u8>, id: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        pay(v, vault, index, id, true);
    }

    /// The freezer only, before any snapshot exit: freezes the vault for FREEZE_DURATION from now. Nothing could
    /// replace the freezer after a snapshot, so it must not be able to hold the exit off for good (VLT-5).
    public entry fun freeze_vault(freezer: &signer, vault: address) acquires Vault {
        let v = borrow_mut(vault);
        assert!(signer::address_of(freezer) == v.freezer, ENotFreezer);
        check_no_snapshot(v);
        freeze_now(v, vault, false);
    }

    /// Anyone, from its ready time: applies the waiting cap update, freezer change or rotation whose body its
    /// `ChangeQueued` event announced. A freeze in force holds every change but the freezer's replacement: a freezer
    /// that froze again and again must not be able to keep itself in place.
    public entry fun apply_change(vault: address, kind: u8, body: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        take_pending(v, kind, &body);
        apply(v, vault, kind, &body);
        event::emit(ChangeApplied { vault, kind });
    }

    /// The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
    public entry fun cancel_change(freezer: &signer, vault: address, kind: u8) acquires Vault {
        let v = borrow_mut(vault);
        assert!(signer::address_of(freezer) == v.freezer && kind != FREEZER_CHANGE, ENotFreezer);
        let waiting = pending_mut(v, kind);
        assert!(waiting.ready_at != 0, ENoPendingChange);
        *waiting = PendingChange { body_hash: vector[], ready_at: 0 };
        event::emit(ChangeCancelled { vault, kind });
    }

    // ---------------------------------------------------------------------
    // Checkpoints, stall recovery and the snapshot exit (design 6.9)
    // ---------------------------------------------------------------------

    /// Anyone, before a snapshot exit: records a final Ethereum block both P1 and P2 prove, newer than the last, which
    /// keeps the vault out of a stall. One recent enough to end a stall also lapses any successor under review and
    /// starts the freezer's count again; a stale one leaves the stall, its successor and its count (LG-2).
    public entry fun advance_checkpoint(
        vault: address,
        block: u64,
        timestamp: u64,
        state_root: vector<u8>,
        proof1: vector<u8>,
        proof2: vector<u8>,
    ) acquires Vault {
        let v = borrow_mut(vault);
        check_no_snapshot(v);
        let c = Checkpoint { block, timestamp, state_root };
        proven_by_both(v.p1, v.p2, &c, &proof1, &proof2);
        check_newer(v, &c);
        v.checkpoint = c;
        event::emit(CheckpointAdvanced { vault, block, timestamp, state_root: c.state_root });
        if (stalled_of(v)) return;
        // A recent one ends the stall: the pair in force works again.
        v.vetoes = 0;
        lapse_successor(v, vault);
    }

    /// What a successor pair must prove, assembled for `propose_successor`: `last1` and `last2` prove the vault's last
    /// checkpoint, `recent1` and `recent2` the checkpoint `(recent_block, recent_timestamp, recent_state_root)`, and
    /// `message1` and `message2` the log of `message` in `message_block`, the last message delivered on both proofs, if
    /// any.
    public fun continuity(
        last1: vector<u8>,
        last2: vector<u8>,
        recent_block: u64,
        recent_timestamp: u64,
        recent_state_root: vector<u8>,
        recent1: vector<u8>,
        recent2: vector<u8>,
        message: vector<u8>,
        message_block: u64,
        message1: vector<u8>,
        message2: vector<u8>,
    ): Continuity {
        Continuity {
            last1,
            last2,
            recent: Checkpoint { block: recent_block, timestamp: recent_timestamp, state_root: recent_state_root },
            recent1,
            recent2,
            message,
            message_block,
            message1,
            message2,
        }
    }

    /// The recovery proposer only, while stalled, before a snapshot exit, with none under review: proposes the light
    /// clients at `p1` and `p2`, one SP1 and one RISC Zero, which must prove the last checkpoint, a recent one and the
    /// last message delivered on both proofs.
    public fun propose_successor(
        proposer: &signer,
        vault: address,
        p1: address,
        p2: address,
        proofs: Continuity,
    ) acquires Vault {
        let v = borrow_mut(vault);
        assert!(signer::address_of(proposer) == v.recovery_proposer, ENotRecoveryProposer);
        check_no_snapshot(v);
        assert!(stalled_of(v), ENotStalled);
        assert!(v.successor.review_ends == 0, ESuccessorPending);
        check_pair(p1, p2);
        // (a) The last checkpoint the pair in force accepted.
        let last = v.checkpoint;
        proven_by_both(p1, p2, &last, &proofs.last1, &proofs.last2);
        // (b) A recent one, which the successor's proof shows descends from it.
        proven_by_both(p1, p2, &proofs.recent, &proofs.recent1, &proofs.recent2);
        check_recent(v, &proofs.recent);
        // (c) The last message the pair in force delivered on both proofs, if there was one.
        if (!bytes::is_zero(&v.last_message)) {
            let id = abi::message_id(&proofs.message);
            assert!(id == v.last_message, EDiscontinuous);
            let emitter = abi::index(&abi::decode_message(&proofs.message));
            let data = abi::log_data(&proofs.message);
            let topic = abi::event_topic();
            light_client::verify_event(p1, &proofs.message1, proofs.message_block, &emitter, &topic, &id, &data);
            light_client::verify_event(p2, &proofs.message2, proofs.message_block, &emitter, &topic, &id, &data);
        };
        let review_ends = timestamp::now_seconds() + RECOVERY_DELAY;
        v.successor = Successor { p1, p2, review_ends };
        event::emit(SuccessorProposed { vault, p1, p2, review_ends });
    }

    /// `propose_successor` as a transaction, the continuity test's parts as arguments.
    public entry fun propose_successor_entry(
        proposer: &signer,
        vault: address,
        p1: address,
        p2: address,
        last1: vector<u8>,
        last2: vector<u8>,
        recent_block: u64,
        recent_timestamp: u64,
        recent_state_root: vector<u8>,
        recent1: vector<u8>,
        recent2: vector<u8>,
        message: vector<u8>,
        message_block: u64,
        message1: vector<u8>,
        message2: vector<u8>,
    ) acquires Vault {
        let proofs = continuity(
            last1,
            last2,
            recent_block,
            recent_timestamp,
            recent_state_root,
            recent1,
            recent2,
            message,
            message_block,
            message1,
            message2,
        );
        propose_successor(proposer, vault, p1, p2, proofs);
    }

    /// The freezer only, at most MAX_RECOVERY_VETOES times a stall: drops the successor under review.
    public entry fun veto_successor(freezer: &signer, vault: address) acquires Vault {
        let v = borrow_mut(vault);
        assert!(signer::address_of(freezer) == v.freezer, ENotFreezer);
        assert!(v.successor.review_ends != 0, ENoSuccessor);
        assert!(v.vetoes < MAX_RECOVERY_VETOES, EVetoesExhausted);
        v.vetoes += 1;
        v.successor = no_successor();
        event::emit(SuccessorVetoed { vault, vetoes: v.vetoes });
    }

    /// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2, which ends
    /// the stall and the freezer's count.
    public entry fun adopt_successor(
        vault: address,
        block: u64,
        timestamp: u64,
        state_root: vector<u8>,
        proof1: vector<u8>,
        proof2: vector<u8>,
    ) acquires Vault {
        let v = borrow_mut(vault);
        let s = v.successor;
        // A snapshot clears any successor, and a checkpoint that ends the stall lapses it, so a pending one is still in
        // its stall.
        assert!(s.review_ends != 0, ENoSuccessor);
        assert!(timestamp::now_seconds() >= s.review_ends, EReviewNotOver);
        let c = Checkpoint { block, timestamp, state_root };
        proven_by_both(s.p1, s.p2, &c, &proof1, &proof2);
        check_recent(v, &c);
        v.successor = no_successor();
        v.vetoes = 0;
        v.p1 = s.p1;
        v.p2 = s.p2;
        v.checkpoint = c;
        event::emit(SuccessorAdopted { vault, p1: s.p1, p2: s.p2 });
        event::emit(CheckpointAdvanced { vault, block, timestamp, state_root: c.state_root });
    }

    /// Anyone, SNAPSHOT_EXIT_DELAY after the stall began: takes the last checkpoint as the snapshot for good. From then
    /// on no message from a later Ethereum block runs, and holders at it claim directly.
    public entry fun begin_snapshot(vault: address) acquires Vault {
        let v = borrow_mut(vault);
        check_no_snapshot(v);
        let due = v.checkpoint.timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY;
        assert!(timestamp::now_seconds() >= due, ESnapshotNotDue);
        let last = v.checkpoint;
        // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
        assert!(!bytes::is_zero(&last.state_root), ENoCheckpoint);
        v.snapshot = last;
        put_slot(v, bytes::word64(SNAPSHOT_ROOT_SLOT), last.state_root);
        event::emit(SnapshotBegun { vault, block: last.block, timestamp: last.timestamp, state_root: last.state_root });
        lapse_successor(v, vault);
    }

    /// Anyone after the snapshot: pays `holder`'s share of APT in `index` at the snapshot, read from the hub's storage
    /// there, to `recipient`: the recovery address it registered in the hub for this chain, if any, which a contract
    /// holder must register; otherwise the recipient it signed for with its Ethereum key (EIP-712, the domain's salt
    /// this vault's id). Within the speed limit, as any payout: a snapshot of a forged checkpoint takes no more than a
    /// forged burn. Once per holder and index.
    public entry fun claim_snapshot(
        vault: address,
        index: vector<u8>,
        holder: vector<u8>,
        component: u64,
        recipient: address,
        signature: vector<u8>,
        proof: vector<u8>,
    ) acquires Vault {
        let v = borrow_mut(vault);
        assert!(v.indexes.contains(index), ENotAnIndex);
        assert!(holder.length() == 20, EBadLength);
        assert!(recipient != @0x0, EZeroAddress);
        // The vault itself, or its coins' store, would strand the payout (SOL-9).
        check_recipient(v, vault, recipient);
        let root = snapshot_root(v);
        let slots = snapshot::claim_slots(&holder, component, v.chain_id);
        let values = state_reader::read_slots(&root, &index, &slots, &proof);
        let (amount, registered) = snapshot::share(&values, component, v.chain_id);
        if (registered.is_some()) {
            // A holder that registered a recovery address, such as a contract, is paid there and nowhere else.
            assert!(registered.destroy_some() == bcs::to_bytes(&recipient), EWrongRecipient);
        } else {
            let message = snapshot::claim_message(&bcs::to_bytes(&vault), v.chain_id, &index, &holder, &bcs::to_bytes(&recipient));
            snapshot::check_signature(&message, &signature, &holder);
        };
        let id = snapshot::claim_id(&index, &holder);
        let key = OwedKey { index, id };
        assert!(!v.owed.contains(key), EAlreadyClaimed);
        v.owed.add(key, Owed { to_index: false, recipient, new_index: vector[], remaining: amount });
        event::emit(SnapshotClaimed { vault, index, holder, recipient, amount, id });
        pay(v, vault, index, id, false);
    }

    /// Anyone, after the snapshot: settles an intake still open if the hub had sent its settle message by the snapshot,
    /// and otherwise fails it, so its depositors take their coins back. The hub marks an intake settled in the
    /// transaction that sends its settle message (`_settledIntakes`), so its mark at the snapshot says whether that
    /// message was sent by then: nothing sent later will ever run here.
    public entry fun resolve_intake(vault: address, index: vector<u8>, intake_id: vector<u8>, proof: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        let key = IntakeKey { index, intake_id };
        assert!(v.intakes.contains(key) && v.intakes.borrow(key).state == INTAKE_OPEN, EIntakeNotOpen);
        let mark = read_hub(v, &index, snapshot::settled_slot(&intake_id), &proof);
        let settled = !bytes::is_zero(&mark);
        event::emit(IntakeResolved { vault, index, intake_id, settled });
        resolve(v, vault, index, intake_id, settled);
    }

    /// Anyone after the snapshot: a burn or migration the index sent before the snapshot and that never arrived runs on
    /// the index's own record of it (`_sentMessages`), once, within the speed limit, as a delivered one would. Every
    /// other kind in flight at the snapshot resolves without one: an intake's through `resolve_intake`, and governance
    /// not at all.
    public entry fun deliver_recorded(vault: address, payload: vector<u8>, proof: vector<u8>) acquires Vault {
        let v = borrow_mut(vault);
        let id = abi::message_id(&payload);
        let m = abi::decode_message(&payload);
        let kind = abi::kind(&m);
        assert!(kind == BURN || kind == MIGRATE, EUnknownKind);
        check_route(v, vault, &m);
        assert!(v.indexes.contains(abi::index(&m)), ENotAnIndex);
        // The index marks each burn and migration in the transaction that sends it, and only it writes its storage, so
        // its mark at the snapshot shows the index sent this message by then.
        let mark = read_hub(v, &abi::index(&m), snapshot::sent_slot(&id), &proof);
        assert!(!bytes::is_zero(&mark), ENotRecorded);
        assert!(!v.used.contains(id), EAlreadyDelivered);
        v.used.add(id, true);
        event::emit(MessageDelivered { vault, id, kind, index: abi::index(&m) });
        index_message(v, vault, &m, id);
    }

    // ---------------------------------------------------------------------
    // What Ethereum proves of this vault
    // ---------------------------------------------------------------------

    /// Anyone, as a transaction of its own: aborts unless every slot holds its value, a slot never written holding
    /// zero; then emits one `Attested` event whose `record` is `abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestampUs,
    /// slots, values)`, `timestampUs` `timestamp::now_microseconds()`. The slots are those the hub reads on an EVM vault:
    /// an intake's digest, an index's digest, and the snapshot's state root. A failed transaction emits no event, so a
    /// ledger holding one proves a successful `attest` (interfaces doc). It is an entry function and not a public one,
    /// so no script or module can run it between two other calls: a record shows the vault's state between two
    /// transactions.
    entry fun attest(vault: address, slots: vector<vector<u8>>, values: vector<vector<u8>>) acquires Vault {
        let v = borrow(vault);
        assert!(slots.length() == values.length(), ENotAttested);
        let i = 0;
        while (i < slots.length()) {
            assert!(slots[i].length() == 32 && values[i].length() == 32, ENotAttested);
            assert!(slot_of(v, slots[i]) == values[i], ENotAttested);
            i += 1;
        };
        let record = abi::attest_record(v.chain_id, &bcs::to_bytes(&vault), timestamp::now_microseconds(), &slots, &values);
        event::emit(Attested { record });
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    inline fun borrow_mut(vault: address): &mut Vault {
        assert!(exists<Vault>(vault), ENoVault);
        &mut Vault[vault]
    }

    inline fun borrow(vault: address): &Vault {
        assert!(exists<Vault>(vault), ENoVault);
        &Vault[vault]
    }

    fun apt(): Object<Metadata> {
        object::address_to_object<Metadata>(APT)
    }

    fun no_successor(): Successor {
        Successor { p1: @0x0, p2: @0x0, review_ends: 0 }
    }

    fun lapse_successor(v: &mut Vault, vault: address) {
        if (v.successor.review_ends != 0) {
            v.successor = no_successor();
            event::emit(SuccessorLapsed { vault });
        }
    }

    fun check_not_frozen(v: &Vault) {
        assert!(timestamp::now_seconds() >= v.frozen_until, EVaultFrozen);
    }

    fun check_no_snapshot(v: &Vault) {
        assert!(bytes::is_zero(&v.snapshot.state_root), ESnapshotTaken);
    }

    fun snapshot_root(v: &Vault): vector<u8> {
        let root = v.snapshot.state_root;
        assert!(!bytes::is_zero(&root), ENoSnapshot);
        root
    }

    fun stalled_of(v: &Vault): bool {
        timestamp::now_seconds() > v.checkpoint.timestamp + STALL_PERIOD
    }

    /// A checkpoint after the last, in blocks and in time, not in the future, and with a state to read.
    fun check_newer(v: &Vault, c: &Checkpoint) {
        let last = &v.checkpoint;
        assert!(
            c.block > last.block && c.timestamp > last.timestamp && c.timestamp <= timestamp::now_seconds()
                && c.state_root.length() == 32 && !bytes::is_zero(&c.state_root),
            ENotNewer,
        );
    }

    /// A newer checkpoint within STALL_PERIOD of now: one that would not leave the vault stalled.
    fun check_recent(v: &Vault, c: &Checkpoint) {
        check_newer(v, c);
        assert!(c.timestamp + STALL_PERIOD >= timestamp::now_seconds(), ENotRecent);
    }

    /// Two light clients of this package and of two different proof systems: a successor or rotated pair.
    fun check_pair(p1: address, p2: address) {
        assert!(light_client::is_client(p1) && light_client::is_client(p2), EWrongVerifier);
        assert!(p1 != p2, EVerifiersNotDistinct);
        assert!(light_client::system(p1) != light_client::system(p2), EVerifiersNotDistinct);
    }

    /// Both light clients of a pair prove checkpoint `c`, as `_agreed` requires: the same block, timestamp and root.
    fun proven_by_both(p1: address, p2: address, c: &Checkpoint, proof1: &vector<u8>, proof2: &vector<u8>) {
        light_client::verify_checkpoint(p1, proof1, c.block, c.timestamp, &c.state_root);
        light_client::verify_checkpoint(p2, proof2, c.block, c.timestamp, &c.state_root);
    }

    /// The message is Ethereum's, for this chain and this vault.
    fun check_route(v: &Vault, vault: address, m: &Message) {
        assert!(
            abi::source_chain_id(m) == v.source_chain_id && abi::dest_chain_id(m) == v.chain_id
                && abi::vault(m) == bcs::to_bytes(&vault),
            EWrongRoute,
        );
    }

    /// A payout's recipient: never the vault's own object or its coins' store, where APT would be stranded (SOL-9).
    fun check_recipient(v: &Vault, vault: address, recipient: address) {
        assert!(recipient != vault && recipient != object::object_address(&v.store), EWrongRecipient);
    }

    /// Whether a message needs both proofs and a checkpoint covering its block: everything that moves coins or changes
    /// governance does. Only a freeze, and a cap update that raises neither the cap nor the floor, may rest on one.
    fun needs_both(v: &Vault, m: &Message): bool {
        let kind = abi::kind(m);
        if (kind == FREEZE) return false;
        if (kind == CAP_UPDATE) {
            let (cap, floor) = read_cap(&abi::body(m));
            return cap > v.cap || floor > v.outflow_floor
        };
        true
    }

    /// A cap update's body: the native coin's id, which must be zero, then its cap and floor.
    fun read_cap(body: &vector<u8>): (u64, u64) {
        check_native(&abi::body_word(body, 3, 0));
        (abi::amount(&abi::body_word(body, 3, 1)), abi::amount(&abi::body_word(body, 3, 2)))
    }

    /// A body word that must be zero: the vault holds APT only, `address(0)` on Ethereum.
    fun check_native(word: &vector<u8>) {
        assert!(bytes::is_zero(word), ENotNative);
    }

    /// One slot of `index`'s storage in Ethereum's state at the snapshot.
    fun read_hub(v: &Vault, index: &vector<u8>, slot: vector<u8>, proof: &vector<u8>): vector<u8> {
        let root = snapshot_root(v);
        state_reader::read_slots(&root, index, &vector[slot], proof)[0]
    }

    fun index_message(v: &mut Vault, vault: address, m: &Message, id: vector<u8>) {
        let kind = abi::kind(m);
        if (kind == BURN) {
            burn(v, vault, m, id);
        } else if (kind == INTAKE_SETTLED || kind == INTAKE_FAILED) {
            let intake_id = abi::body_word(&abi::body(m), 1, 0);
            let key = IntakeKey { index: abi::index(m), intake_id };
            let state = if (v.intakes.contains(key)) { v.intakes.borrow(key).state } else { INTAKE_NONE };
            assert!(state == INTAKE_NONE || state == INTAKE_OPEN, EIntakeNotOpen);
            resolve(v, vault, abi::index(m), intake_id, kind == INTAKE_SETTLED);
        } else {
            migrate(v, vault, m, id);
        }
    }

    /// A burn from an index: pays its recipient what the speed limit allows now, and owes the rest.
    fun burn(v: &mut Vault, vault: address, m: &Message, id: vector<u8>) {
        let body = abi::body(m);
        check_native(&abi::body_word(&body, 3, 0));
        let amount = abi::amount(&abi::body_word(&body, 3, 1));
        let word = abi::body_word(&body, 3, 2);
        assert!(amount != 0, EZeroAmount);
        assert!(!bytes::is_zero(&word), EZeroAddress);
        let recipient = from_bcs::to_address(word);
        // The vault itself, or its coins' store, would strand the payout (SOL-9).
        check_recipient(v, vault, recipient);
        let index = abi::index(m);
        v.owed.add(OwedKey { index, id }, Owed { to_index: false, recipient, new_index: vector[], remaining: amount });
        event::emit(BurnAccepted { vault, index, id, amount, recipient });
        pay(v, vault, index, id, false);
    }

    /// A migration from an index: moves coins two index versions share from the old index's balance into the new
    /// one's, within the speed limit, as a burn leaves (Stage B spec, section 5.5). The coins never leave the vault.
    fun migrate(v: &mut Vault, vault: address, m: &Message, id: vector<u8>) {
        let body = abi::body(m);
        let index = abi::index(m);
        let new_index = abi::to_address(&abi::body_word(&body, 3, 0));
        assert!(new_index != index && v.indexes.contains(new_index), ENotAnIndex);
        check_native(&abi::body_word(&body, 3, 1));
        let amount = abi::amount(&abi::body_word(&body, 3, 2));
        assert!(amount != 0, EZeroAmount);
        v.owed.add(OwedKey { index, id }, Owed { to_index: true, recipient: @0x0, new_index, remaining: amount });
        event::emit(MigrationAccepted { vault, index, id, amount, new_index });
        pay(v, vault, index, id, false);
    }

    /// Settles an intake, whose deposits join the index, or fails it, so its depositors can take them back.
    fun resolve(v: &mut Vault, vault: address, index: vector<u8>, intake_id: vector<u8>, settle: bool) {
        let key = IntakeKey { index, intake_id };
        if (!v.intakes.contains(key)) {
            v.intakes.add(key, Intake { state: INTAKE_NONE, has_native: false, total: 0, digest: vector[] });
        };
        let intake = v.intakes.borrow_mut(key);
        if (settle) {
            intake.state = INTAKE_SETTLED_STATE;
            let (has, total) = (intake.has_native, intake.total);
            if (has) {
                let state = v.indexes.borrow_mut(index);
                state.balance += total;
                state.has_native = true;
            };
            event::emit(IntakeSettled { vault, index, intake_id });
            refresh_intake(v, vault, &index, &intake_id);
            if (has) refresh_index(v, vault, &index);
        } else {
            intake.state = INTAKE_FAILED_STATE;
            event::emit(IntakeFailed { vault, index, intake_id });
            refresh_intake(v, vault, &index, &intake_id);
        }
    }

    /// What `state` may still pay out now: 4% of its balance before the recent outflow, or the floor if larger, less
    /// what already left.
    fun available_of(state: &IndexState, floor: u64): u64 {
        let recent = recent_of(state);
        let limit = ((state.balance as u128) + recent) * SPEED_LIMIT_PERCENT / 100;
        let limit = if (limit < (floor as u128)) { (floor as u128) } else { limit };
        if (limit > recent) { ((limit - recent) as u64) } else { 0 }
    }

    /// What the buckets hold of the current hour and the 24 before it: a stale slot reads empty.
    fun recent_of(state: &IndexState): u128 {
        let hour = timestamp::now_seconds() / HOUR;
        let total: u128 = 0;
        let i = 0;
        while (i < BUCKETS) {
            let b = &state.outflow[i];
            if (b.hour + BUCKETS > hour) total += (b.amount as u128);
            i += 1;
        };
        total
    }

    /// Pays what the speed limit, the index's balance and a freeze allow of owed `(index, id)`. `strict` is set for an
    /// explicit release, which aborts when it can pay nothing; a message just accepted keeps waiting instead. A
    /// migration is paid into the new index's balance, so the coins stay in the vault and `held` stays; anything else is
    /// APT deposited to its recipient.
    fun pay(v: &mut Vault, vault: address, index: vector<u8>, id: vector<u8>, strict: bool) {
        let key = OwedKey { index, id };
        assert!(v.owed.contains(key), ENothingOwed);
        let owed = *v.owed.borrow(key);
        assert!(owed.remaining != 0, ENothingOwed);
        assert!(v.indexes.contains(index), ENotAnIndex);
        let now = timestamp::now_seconds();
        let pay = if (now < v.frozen_until) {
            0
        } else {
            let state = v.indexes.borrow(index);
            min(min(owed.remaining, available_of(state, v.outflow_floor)), state.balance)
        };
        if (pay == 0) {
            assert!(!strict, ENothingPayable);
            return
        };
        let remaining = owed.remaining - pay;
        v.owed.borrow_mut(key).remaining = remaining;
        let hour = now / HOUR;
        let state = v.indexes.borrow_mut(index);
        state.balance -= pay;
        state.paid_total += pay;
        let bucket = &mut state.outflow[hour % BUCKETS];
        if (bucket.hour == hour) {
            bucket.amount += pay;
        } else {
            *bucket = Bucket { hour, amount: pay };
        };
        refresh_index(v, vault, &index);
        event::emit(Paid { vault, index, id, amount: pay, remaining });
        if (owed.to_index) {
            let new = v.indexes.borrow_mut(owed.new_index);
            new.balance += pay;
            new.has_native = true;
            refresh_index(v, vault, &owed.new_index);
        } else {
            v.held -= pay;
            send(v, owed.recipient, pay);
        }
    }

    /// APT out of the vault's store into `to`'s primary store.
    fun send(v: &Vault, to: address, amount: u64) {
        let signer = object::generate_signer_for_extending(&v.extend_ref);
        let fa = fungible_asset::withdraw(&signer, v.store, amount);
        primary_fungible_store::deposit(to, fa);
    }

    /// A freeze, a cap update raising neither figure, a raise, a new freezer or new verifiers from the factory. The
    /// factory's nonce only rises: an older message of a kind, delivered late, cannot undo a newer one. Only one on both
    /// proofs moves the mark, so a single broken proof system cannot lock the factory out with a forged nonce (VLT-4). A
    /// loosening change waits GOVERNANCE_DELAY here, where the freezer can see it and stop a raise or a rotation,
    /// however its proofs were obtained (VLT-2).
    fun governance_message(v: &mut Vault, vault: address, m: &Message, loosening: bool, both: bool) {
        let kind = abi::kind(m);
        let body = abi::body(m);
        if (kind == FREEZE) {
            assert!(body.is_empty(), EBadMessage);
            // Nothing could replace the freezer after a snapshot, and nothing may hold the exit off (VLT-5).
            check_no_snapshot(v);
            freeze_now(v, vault, true);
            return
        };
        let nonce = abi::nonce(m);
        let last = if (kind == CAP_UPDATE) {
            v.cap_nonce
        } else if (kind == FREEZER_CHANGE) {
            v.freezer_nonce
        } else {
            v.rotation_nonce
        };
        assert!(nonce > last, EStaleGovernance);
        if (both) {
            if (kind == CAP_UPDATE) v.cap_nonce = nonce
            else if (kind == FREEZER_CHANGE) v.freezer_nonce = nonce
            else v.rotation_nonce = nonce;
        };
        // The body's form, checked before it waits.
        if (kind == CAP_UPDATE) {
            let (_, _) = read_cap(&body);
        } else if (kind == FREEZER_CHANGE) {
            let _ = abi::body_word(&body, 1, 0);
        } else {
            let _ = abi::body_word(&body, 2, 0);
        };
        if (loosening) {
            let ready_at = timestamp::now_seconds() + GOVERNANCE_DELAY;
            *pending_mut(v, kind) = PendingChange { body_hash: keccak256(body), ready_at };
            event::emit(ChangeQueued { vault, kind, body, ready_at });
        } else {
            // Newer than a waiting raise, which it replaces.
            *pending_mut(v, kind) = PendingChange { body_hash: vector[], ready_at: 0 };
            apply(v, vault, kind, &body);
        }
    }

    /// The waiting change of `kind`, which must be `body` and ready, and not held by a freeze unless it replaces the
    /// freezer; taken, so it applies once.
    fun take_pending(v: &mut Vault, kind: u8, body: &vector<u8>) {
        let now = timestamp::now_seconds();
        let frozen = now < v.frozen_until;
        let waiting = pending_mut(v, kind);
        assert!(waiting.ready_at != 0 && waiting.body_hash == keccak256(*body), ENoPendingChange);
        assert!(now >= waiting.ready_at, EChangeNotReady);
        assert!(kind == FREEZER_CHANGE || !frozen, EVaultFrozen);
        *waiting = PendingChange { body_hash: vector[], ready_at: 0 };
    }

    fun apply(v: &mut Vault, vault: address, kind: u8, body: &vector<u8>) {
        if (kind == CAP_UPDATE) {
            let (cap, floor) = read_cap(body);
            v.cap = cap;
            v.outflow_floor = floor;
            event::emit(CapSet { vault, cap, outflow_floor: floor });
        } else if (kind == FREEZER_CHANGE) {
            let word = abi::body_word(body, 1, 0);
            assert!(!bytes::is_zero(&word), EZeroAddress);
            let freezer = from_bcs::to_address(word);
            v.freezer = freezer;
            event::emit(FreezerChanged { vault, freezer });
        } else {
            // Two light clients of this package, one SP1 and one RISC Zero, named by their objects' addresses.
            let p1 = from_bcs::to_address(abi::body_word(body, 2, 0));
            let p2 = from_bcs::to_address(abi::body_word(body, 2, 1));
            check_pair(p1, p2);
            v.p1 = p1;
            v.p2 = p2;
            event::emit(VerifiersRotated { vault, p1, p2 });
        }
    }

    fun pending_mut(v: &mut Vault, kind: u8): &mut PendingChange {
        if (kind == CAP_UPDATE) return &mut v.pending_cap;
        if (kind == FREEZER_CHANGE) return &mut v.pending_freezer;
        assert!(kind == VERIFIER_ROTATION, ENoPendingChange);
        &mut v.pending_rotation
    }

    /// Freezes the vault for FREEZE_DURATION from now; a later freeze extends it, and none shortens it.
    fun freeze_now(v: &mut Vault, vault: address, by_factory: bool) {
        let until = timestamp::now_seconds() + FREEZE_DURATION;
        if (until > v.frozen_until) v.frozen_until = until;
        event::emit(Frozen { vault, until: v.frozen_until, by_factory });
    }

    fun refresh_index(v: &mut Vault, vault: address, index: &vector<u8>) {
        let vid = bcs::to_bytes(&vault);
        let chain_id = v.chain_id;
        let state = v.indexes.borrow_mut(*index);
        state.digest = abi::index_digest(chain_id, &vid, index, state.has_native, state.balance, state.paid_total);
        let digest = state.digest;
        put_slot(v, index_slot(index), digest);
    }

    fun refresh_intake(v: &mut Vault, vault: address, index: &vector<u8>, intake_id: &vector<u8>) {
        let vid = bcs::to_bytes(&vault);
        let chain_id = v.chain_id;
        let intake = v.intakes.borrow_mut(IntakeKey { index: *index, intake_id: *intake_id });
        intake.digest = abi::intake_digest(chain_id, &vid, index, intake_id, intake.state, intake.has_native, intake.total);
        let digest = intake.digest;
        put_slot(v, intake_slot(index, intake_id), digest);
    }

    fun put_slot(v: &mut Vault, slot: vector<u8>, value: vector<u8>) {
        v.slots.upsert(slot, value);
    }

    fun slot_of(v: &Vault, slot: vector<u8>): vector<u8> {
        if (v.slots.contains(slot)) *v.slots.borrow(slot) else bytes::zero32()
    }

    fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// Where the hub reads an index's digest on an EVM vault: `keccak256(abi.encode(index, 14))`.
    public fun index_slot(index: &vector<u8>): vector<u8> {
        snapshot::mapping_slot(&bytes::address_word(index), &bytes::word64(INDEX_DIGEST_SLOT))
    }

    /// Where the hub reads an intake's digest: `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`.
    public fun intake_slot(index: &vector<u8>, intake_id: &vector<u8>): vector<u8> {
        let inner = snapshot::mapping_slot(&bytes::address_word(index), &bytes::word64(INTAKE_DIGEST_SLOT));
        snapshot::mapping_slot(intake_id, &inner)
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    #[view]
    /// The vault's address for `creator`: `object::create_object_address(creator, b"xindex.v4.vault")`.
    public fun vault_address(creator: address): address {
        object::create_object_address(&creator, VAULT_SEED)
    }

    #[view]
    /// The vault's id in messages, digests and records: its object's address, as 32 bytes (interfaces doc).
    public fun vault_id(vault: address): vector<u8> acquires Vault {
        borrow(vault);
        bcs::to_bytes(&vault)
    }

    #[view]
    public fun is_vault(vault: address): bool { exists<Vault>(vault) }

    #[view]
    public fun source_chain_id(vault: address): u64 acquires Vault { borrow(vault).source_chain_id }

    #[view]
    public fun chain_id(vault: address): u64 acquires Vault { borrow(vault).chain_id }

    #[view]
    public fun factory(vault: address): vector<u8> acquires Vault { borrow(vault).factory }

    #[view]
    public fun hub_implementation(vault: address): vector<u8> acquires Vault { borrow(vault).hub_implementation }

    #[view]
    public fun p1(vault: address): address acquires Vault { borrow(vault).p1 }

    #[view]
    public fun p2(vault: address): address acquires Vault { borrow(vault).p2 }

    #[view]
    public fun freezer(vault: address): address acquires Vault { borrow(vault).freezer }

    #[view]
    public fun recovery_proposer(vault: address): address acquires Vault { borrow(vault).recovery_proposer }

    #[view]
    public fun frozen_until(vault: address): u64 acquires Vault { borrow(vault).frozen_until }

    #[view]
    public fun cap(vault: address): u64 acquires Vault { borrow(vault).cap }

    #[view]
    public fun outflow_floor(vault: address): u64 acquires Vault { borrow(vault).outflow_floor }

    #[view]
    public fun held(vault: address): u64 acquires Vault { borrow(vault).held }

    #[view]
    /// The address of the vault's coins' store.
    public fun store(vault: address): address acquires Vault { object::object_address(&borrow(vault).store) }

    #[view]
    /// The APT the vault's store holds: `held`, and whatever someone deposited there directly.
    public fun coins(vault: address): u64 acquires Vault { fungible_asset::balance(borrow(vault).store) }

    #[view]
    /// The nonce marks of cap updates, freezer changes and rotations.
    public fun nonces(vault: address): vector<u64> acquires Vault {
        let v = borrow(vault);
        vector[v.cap_nonce, v.freezer_nonce, v.rotation_nonce]
    }

    #[view]
    /// The waiting change of `kind`: its body's hash and ready time, zero when none waits.
    public fun pending(vault: address, kind: u8): (vector<u8>, u64) acquires Vault {
        let v = borrow(vault);
        let p = if (kind == CAP_UPDATE) {
            v.pending_cap
        } else if (kind == FREEZER_CHANGE) {
            v.pending_freezer
        } else {
            v.pending_rotation
        };
        (p.body_hash, p.ready_at)
    }

    #[view]
    public fun checkpoint(vault: address): (u64, u64, vector<u8>) acquires Vault {
        let c = borrow(vault).checkpoint;
        (c.block, c.timestamp, c.state_root)
    }

    #[view]
    public fun exit_snapshot(vault: address): (u64, u64, vector<u8>) acquires Vault {
        let c = borrow(vault).snapshot;
        (c.block, c.timestamp, c.state_root)
    }

    #[view]
    public fun successor(vault: address): (address, address, u64) acquires Vault {
        let s = borrow(vault).successor;
        (s.p1, s.p2, s.review_ends)
    }

    #[view]
    public fun last_message(vault: address): vector<u8> acquires Vault { borrow(vault).last_message }

    #[view]
    public fun vetoes(vault: address): u8 acquires Vault { borrow(vault).vetoes }

    #[view]
    public fun is_index(vault: address, index: vector<u8>): bool acquires Vault { borrow(vault).indexes.contains(index) }

    #[view]
    /// An index's books: whether it holds APT, its balance, its paid total, its digest, and what it may pay out now.
    public fun index_state(vault: address, index: vector<u8>): (bool, u64, u64, vector<u8>, u64) acquires Vault {
        let v = borrow(vault);
        let s = v.indexes.borrow(index);
        (s.has_native, s.balance, s.paid_total, s.digest, available_of(s, v.outflow_floor))
    }

    #[view]
    /// An intake's state, total and digest; state 0 for one never opened.
    public fun intake(vault: address, index: vector<u8>, intake_id: vector<u8>): (u8, u64, vector<u8>) acquires Vault {
        let v = borrow(vault);
        let key = IntakeKey { index, intake_id };
        if (!v.intakes.contains(key)) return (INTAKE_NONE, 0, vector[]);
        let i = v.intakes.borrow(key);
        (i.state, i.total, i.digest)
    }

    #[view]
    public fun deposited(vault: address, index: vector<u8>, intake_id: vector<u8>, depositor: address): u64 acquires Vault {
        let v = borrow(vault);
        let key = DepositKey { index, intake_id, depositor };
        if (v.deposits.contains(key)) *v.deposits.borrow(key) else 0
    }

    #[view]
    /// An owed payout: whether it goes into an index, its recipient or new index, and what remains; none owed reads
    /// zero.
    public fun owed(vault: address, index: vector<u8>, id: vector<u8>): (bool, address, vector<u8>, u64) acquires Vault {
        let v = borrow(vault);
        let key = OwedKey { index, id };
        if (!v.owed.contains(key)) return (false, @0x0, vector[], 0);
        let o = v.owed.borrow(key);
        (o.to_index, o.recipient, o.new_index, o.remaining)
    }

    #[view]
    public fun used(vault: address, id: vector<u8>): bool acquires Vault { borrow(vault).used.contains(id) }

    #[view]
    /// The value `attest` vouches for at `slot`: zero for one never written.
    public fun slot(vault: address, slot: vector<u8>): vector<u8> acquires Vault {
        slot_of(borrow(vault), slot)
    }

    #[view]
    /// A week without a new checkpoint: P1 and P2 may have stopped working.
    public fun stalled(vault: address): bool acquires Vault { stalled_of(borrow(vault)) }

    #[view]
    public fun stall_start(vault: address): u64 acquires Vault { borrow(vault).checkpoint.timestamp + STALL_PERIOD }

    /// An `Attested` event's record.
    public fun record(a: &Attested): vector<u8> { a.record }

    #[test_only]
    /// `attest`, for tests in other modules: the entry function itself is not public.
    public fun attest_for_testing(vault: address, slots: vector<vector<u8>>, values: vector<vector<u8>>) acquires Vault {
        attest(vault, slots, values);
    }

    #[test_only]
    /// Credits `fa` to `index` as a settled intake would: for gas tests that need a funded index without a delivery.
    public fun credit_for_testing(vault: address, index: vector<u8>, fa: FungibleAsset) acquires Vault {
        let v = borrow_mut(vault);
        let amount = fungible_asset::amount(&fa);
        v.held += amount;
        fungible_asset::deposit(v.store, fa);
        let state = v.indexes.borrow_mut(index);
        state.balance += amount;
        state.has_native = true;
        refresh_index(v, vault, &index);
    }

    #[test_only]
    public fun apt_for_testing(): Object<Metadata> { apt() }

    #[test_only]
    /// The `Attested` records emitted so far in this test.
    public fun attested_for_testing(): vector<vector<u8>> {
        let events = event::emitted_events<Attested>();
        let out = vector::empty<vector<u8>>();
        let i = 0;
        while (i < events.length()) {
            out.push_back(events[i].record);
            i += 1;
        };
        out
    }

    #[test_only]
    /// The BCS of an `Attested` event's data, as the ledger stores it.
    public fun attested_bcs_for_testing(record: vector<u8>): vector<u8> {
        bcs::to_bytes(&Attested { record })
    }
}
