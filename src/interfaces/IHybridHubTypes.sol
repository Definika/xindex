// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IHybridHubTypes
/// @notice The types, events and errors a HybridHub index raises, shared by the hub and the module it delegates to.
interface IHybridHubTypes is IXindexErrors {
    /// @notice Pyth returned an update for `id` that is not the one asked for, or one published outside the slot the
    ///         fill reads.
    error PriceMismatch(bytes32 id, uint256 publishTime);
    /// @notice A hub takes no plain ether.
    error NoEther();
    enum OrderStatus {
        None,
        Open,
        Locked,
        Claimed,
        Failed
    }

    /// @notice One vault chain's intake for an order: the state verifier's proof of the vault's intake digest, and the
    ///         digest's preimage, the tokens deposited and their totals.
    struct ChainProof {
        bytes proof;
        address[] tokens;
        uint256[] totals;
    }

    /// @notice Where a component is held: its chain, its token id there and that chain's vault; all zero on Ethereum.
    struct Placement {
        uint256 chainId;
        bytes32 vaultToken;
        bytes32 vault;
    }

    /// @notice An order as stored: its minter, shares, the intake deadline (on the vault chains' clocks), the end of
    ///         its lock, when it was last settled or re-confirmed, and its status.
    struct Order {
        address minter;
        uint256 shares;
        uint256 deadline;
        uint256 lockEnds;
        uint256 settledAt;
        OrderStatus status;
    }

    event OrderOpened(
        uint256 indexed orderId, address indexed minter, uint256 shares, uint256 intakeId, uint256[] amounts
    );
    event OrderSettled(uint256 indexed orderId, uint256 lockEnds, uint256[] deposits);
    event OrderReconfirmed(uint256 indexed orderId);
    event OrderClaimed(uint256 indexed orderId, address indexed minter, uint256 shares);
    event OrderFailed(uint256 indexed orderId, address indexed by);
    /// @notice A proof of `chainId`'s intake showed `proven` where the order rests on `recorded`.
    event OrderVoided(uint256 indexed orderId, uint256 indexed chainId, bytes32 proven, bytes32 recorded);
    /// @notice An intake of no order was failed, so its depositors can take their coins back.
    event IntakeFailed(uint256 indexed chainId, uint256 intakeId);
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);
    /// @notice `amount` of vault token `token` is burned toward `recipient` on `chainId` by message `messageId`.
    event BurnSent(
        address indexed token, uint256 indexed chainId, bytes32 recipient, uint256 amount, bytes32 messageId
    );

    error NotFactory();
    error NotInitialized();
    error InvalidComponents();
    error ZeroShares();
    error InvalidSkipMask(uint256 skipMask);
    error NothingToClaim(address token);
    error TransferAmountMismatch(address token);
    /// @notice An order's deadline must lie after now and at most MAX_ORDER_LIFE ahead.
    error BadDeadline(uint256 deadline);
    error WrongStatus(uint256 orderId, OrderStatus status);
    error NotYet(uint256 until);
    error ChainIsFrozen(uint256 chainId, uint256 until);
    /// @notice Settling `shares` would make more than MINT_CAP of the supply claimable in 24 hours; `room` is left.
    error MintCapExceeded(uint256 shares, uint256 room);
    error DepositShort(address token, uint256 deposited, uint256 required);
    /// @notice A proof of `chainId`'s vault is of a block at `time`, not after `after`.
    error ProofTooEarly(uint256 chainId, uint256 time, uint256 after_);
    error DigestMismatch(uint256 chainId, bytes32 proven, bytes32 expected);
    error NotAContradiction(uint256 chainId);
    error NotAVaultChain(uint256 chainId);
    error IntakeOfAnOrder(uint256 intakeId);
    error IntakeStillOpen(uint256 deadline);
    error IntakeAlreadyFailed(uint256 intakeId);
    /// @notice `chainId` froze after the order settled: a fresh proof from after the freeze must re-confirm it.
    error NeedsReconfirmation(uint256 orderId, uint256 chainId);
    error NotAnEthereumToken(address token);
    error NotAVaultToken(address token);
    /// @notice `module` is not a HybridHubModule built for this template's factory.
    error WrongModule(address module);

    /// @notice Where a rebalance fill stands: none, accepted and awaiting its deliveries, or settled with its bond held.
    enum FillStatus {
        None,
        Accepted,
        Settled
    }

    /// @notice A rebalance fill: its executor, status, the rebalance nonce it takes, its λ, its bond in shares, its
    ///         delivery deadline and, once settled, when the bond is released.
    struct Fill {
        address executor;
        FillStatus status;
        uint256 nonce;
        uint256 lambda;
        uint256 bond;
        uint256 deadline;
        uint256 bondRelease;
    }

    /// @notice A rebalance was proposed, as in Stage A's `IndexHub`: its band, and when its auction opens.
    event RebalanceStarted(
        uint256 indexed proposalId,
        uint256 indexed nonce,
        address indexed caller,
        uint256 keepMask,
        uint256 lambdaMin,
        uint256 lambdaMax,
        uint256[] ratios,
        uint256 eta
    );
    event RebalanceCancelled(uint256 indexed proposalId, address indexed caller, uint256 restartAllowedAt);
    /// @notice `executor` took the auction at `lambda`: the new units, what it must deliver of each component, the
    ///         intake id its vault deliveries go under, their deadline, and its bond in shares.
    event RebalanceAccepted(
        uint256 indexed nonce,
        address indexed executor,
        uint256 lambda,
        uint256[] units,
        uint256[] deliveries,
        uint256 intakeId,
        uint256 deadline,
        uint256 bond
    );
    /// @notice A fill settled: the new units, what the executor was paid of each component, and what it delivered.
    event Rebalanced(
        uint256 indexed nonce, address indexed executor, uint256[] units, uint256[] amountsOut, uint256[] delivered
    );
    event RebalanceFailed(uint256 indexed nonce, address indexed by, bool bondBurned);
    event BondReleased(uint256 indexed nonce, address indexed executor, uint256 bond);
    /// @notice A proof showed a delivery on `chainId` short of what the fill recorded: the bond is burned.
    event RebalanceSlashed(uint256 indexed nonce, uint256 indexed chainId, uint256 bond);

    error RebalanceTooSoon(uint256 earliest);
    error RebalancePending(uint256 deadline);
    error InvalidKeepMask(uint256 keepMask);
    error NoPendingRebalance();
    error RebalanceNotReady(uint256 eta);
    error RebalanceExpired(uint256 deadline);
    error RebalanceMovedOn(address token, uint256 required, uint256 maxAmountIn);
    error RebalanceUnderfunded(address token, uint256 held, uint256 required);
    /// @notice A fill is accepted and awaiting its deliveries: mint claims wait for it to settle or fail.
    error RebalanceInProgress();
    error WrongFillStatus(FillStatus status);
    error IntakeOfARebalance(uint256 intakeId);
    error DeliveryShort(address token, uint256 delivered, uint256 required);

    // ---------------------------------------------------------------------
    // Layer 3: migration and evidence
    // ---------------------------------------------------------------------

    /// @notice A vault's own records, the preimage of its digest for this index: its tokens, and for each its balance
    ///         and everything paid out of it.
    struct IndexRecord {
        address[] tokens;
        uint256[] balances;
        uint256[] paid;
    }

    /// @notice `holder` moved `shares` of this index into `newShares` of `newIndex`, minted to `to`.
    event MigratedOut(
        address indexed holder, address indexed newIndex, address indexed to, uint256 shares, uint256 newShares
    );
    /// @notice `shares` of this index were minted to `to` against backing migrated from `oldIndex`.
    event MigratedIn(address indexed oldIndex, address indexed to, uint256 shares);
    /// @notice `amount` of `token` is moving inside its vault to `newIndex`, within the vault's speed limit.
    event MigrateSent(
        address indexed token, uint256 indexed chainId, address indexed newIndex, uint256 amount, bytes32 id
    );
    /// @notice `chainId`'s vault shows `paid` of `token` paid out of this index, more than the `sent` it ever sent out:
    ///         a forged payout, which only a break of both Ethereum-side proofs allows.
    event OutflowDisproved(uint256 indexed chainId, address indexed token, uint256 paid, uint256 sent);
    /// @notice A proof of order `orderId`'s intake on `chainId` showed `proven`, neither the deposits the order was
    ///         claimed on nor the same deposits settled: the proof it was claimed on was false.
    event DepositDisproved(uint256 indexed orderId, uint256 indexed chainId, bytes32 proven);

    /// @notice `holder` will be paid at `recipient` on `chainId`'s snapshot exit.
    event RecoveryAddressSet(address indexed holder, uint256 indexed chainId, bytes32 recipient);
    /// @notice `chainId`'s vault began its snapshot exit, at the Ethereum state `root`.
    event ChainExitRecorded(uint256 indexed chainId, bytes32 root);

    /// @notice `index` is not another HybridHub index of this factory.
    error NotAVersion(address index);
    /// @notice `chainId`'s vault has begun its snapshot exit: recorded here, or shown by the state proven.
    error ChainExited(uint256 chainId);
    /// @notice No vault message with id `id` was sent from here, so none can be sent again. The factory raises it
    ///         too, for its own messages.
    error NotSent(bytes32 id);
    /// @notice `chainId` has not exited.
    error ChainNotExited(uint256 chainId);
    /// @notice `required` of `token` is needed for the new shares and only `available` comes from the old ones.
    error MigrationShort(address token, uint256 available, uint256 required);
}
