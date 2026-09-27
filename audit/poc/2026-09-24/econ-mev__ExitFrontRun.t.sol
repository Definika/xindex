// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {Methodology} from "../../src/libraries/Methodology.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

/// @notice A lone executor front-runs a holder's in-kind exit with the settlement, so the holder who tried to leave
///         before the fill bears the fill's haircut anyway, and the executor's take grows by that holder's share.
///         The zap's burn is protected by `expectedNonce`; `redeem` / `redeemSkipping`, the "guaranteed exit", has no
///         equivalent guard, and nothing else lets a holder make an in-kind exit conditional on the basket it quoted.
contract ExitFrontRunTest is RedTeamBase {
    IndexToken index;
    address alice = makeAddr("alice"); // whale who decides to leave during the auction
    address bob = makeAddr("bob");

    function setUp() public {
        _setUpLaunch();
        index = _createOnRule(makeAddr("creator"), launch, Methodology.CAPPED, 100e18);
        _issue(index, alice, 50_000e18); // ~ $5M
        _issue(index, bob, 50_000e18); // ~ $5M
    }

    function test_executorFrontRunsInKindExit() public {
        // A month of ordinary moves: SOL +20%, LINK +10%, BTC -8%.
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _move(launch[I_WSOL], 120, 100);
        _move(launch[I_LINK], 110, 100);
        _move(launch[I_WBTC], 92, 100);

        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();

        // Late in the auction the multiplier nears its 0.9 floor. Alice broadcasts redeem(all) in this block.
        vm.warp(eta + index.AUCTION_DURATION() - 10 minutes);
        uint256 shares = index.balanceOf(alice);
        console2.log("multiplier at fill (1e18)      ", index.currentMultiplier());

        // (a) Alice's redeem lands first; the executor fills afterwards.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        index.redeem(shares, alice);
        uint256 aliceClean = _walletValue(index, alice);
        executor.execute(IIndexToken(address(index)), "");
        uint256 execClean = _value(index, executor.lastAmountsOut()) - _value(index, executor.lastAmountsIn());
        vm.revertToState(snap);

        // (b) The executor sees Alice's redeem in the mempool and settles in front of it.
        executor.execute(IIndexToken(address(index)), "");
        uint256 execFront = _value(index, executor.lastAmountsOut()) - _value(index, executor.lastAmountsIn());
        vm.prank(alice);
        index.redeem(shares, alice);
        uint256 aliceFront = _walletValue(index, alice);

        console2.log("alice exit value, no front-run  ", aliceClean / 1e18);
        console2.log("alice exit value, front-run     ", aliceFront / 1e18);
        console2.log("alice loss (USD)                ", (aliceClean - aliceFront) / 1e18);
        console2.log("executor take, no front-run     ", execClean / 1e18);
        console2.log("executor take, front-run        ", execFront / 1e18);

        // The holder who left before the settlement loses value only because of the ordering the executor chose...
        assertLt(aliceFront, aliceClean, "front-run exit is worth less");
        // ...and the executor's take roughly doubles, since Alice's half of the supply now pays it too.
        assertGt(execFront, execClean * 19 / 10, "executor takes Alice's share as well");
    }

    /// @dev The mirror image: a large mint during the auction, including one through the zap (whose nonce check runs
    ///      before `issue` and so cannot see a settlement that lands after it), is back-run by the settlement.
    function test_executorBackRunsMintDuringAuction() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _move(launch[I_WSOL], 120, 100);
        _move(launch[I_LINK], 110, 100);
        _move(launch[I_WBTC], 92, 100);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() - 10 minutes);

        address carol = makeAddr("carol");
        uint256 paid = _value(index, index.previewIssue(100_000e18)); // ~ $10.25M deposited in kind
        _issue(index, carol, 100_000e18);
        // The executor waited for the mint and settles right behind it.
        executor.execute(IIndexToken(address(index)), "");
        vm.prank(carol);
        index.redeem(100_000e18, carol);
        uint256 back = _walletValue(index, carol);
        console2.log("carol deposited (USD)           ", paid / 1e18);
        console2.log("carol can take out one block on ", back / 1e18);
        console2.log("carol loss (USD)                ", (paid - back) / 1e18);
        assertLt(back, paid, "minter pays the settlement it minted into");
    }
}
