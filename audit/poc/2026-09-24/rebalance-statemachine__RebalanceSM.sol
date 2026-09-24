// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPausableToken} from "../mocks/MockPausableToken.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";

/// @notice Reference model of the rebalance state machine, written from the NatSpec in IIndexToken, ARCHITECTURE.md
///         section 2/3 and AGENTS.md, driven side by side with the real IndexToken. Every action predicts success or
///         the exact revert data, the exact rebalance event, and every rebalance view afterwards; any divergence is
///         recorded in `violation`.
/// @dev Launch-like capped basket: WETH, wstETH, WBTC (8 dec, pausable), wSOL (9 dec), UNI, LINK, AAVE with the
///      dated reference supplies of script/MainnetAddresses.sol, listed through the real listing flow.
contract RebalanceSM is Test {
    uint256 internal constant RD = 2 days;
    uint256 internal constant MRI = 28 days;
    uint256 internal constant AD = 24 hours;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant N = 7;
    uint32 internal constant STALE_BOUND = 1 hours + 30 minutes; // MockMarket.configWith's bound

    MockMarket public market;
    IndexFactory public factory;
    IndexToken public index;
    MockRebalanceExecutor public executor;
    MockPausableToken public wbtc;
    address[] public toks;
    uint8[] public decs;

    address public owner0 = makeAddr("owner0");
    address public owner1 = makeAddr("owner1");
    address public guardian0 = makeAddr("guardian0");
    address public guardian1 = makeAddr("guardian1");
    address public stranger = makeAddr("stranger");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // ---- model state ----
    uint256 public mEta;
    uint256 public mMask;
    uint256[] internal mTargets;
    uint256 public mPc;
    uint256 public mNonce;
    uint256 public mLast;
    uint256 public mRestart;
    uint256[] internal mUnits;

    string public violation;
    mapping(bytes4 => uint256) public execRevertBySel;
    mapping(bytes4 => uint256) public startRevertBySel;
    bool internal lastOk;
    uint256 public nOk;
    uint256 public nRevert;
    uint256 public nStartOk;
    uint256 public nCancelOk;
    uint256 public nExecOk;

    bytes32 internal constant SIG_STARTED = keccak256("RebalanceStarted(uint256,uint256,address,uint256[],uint256,uint256)");
    bytes32 internal constant SIG_CANCELLED = keccak256("RebalanceCancelled(uint256,address,uint256)");
    bytes32 internal constant SIG_REBALANCED =
        keccak256("Rebalanced(uint256,uint256,address,uint256,uint256[],uint256[],uint256[])");

    function _deploySystem(uint8 methodology) internal {
        vm.warp(1_750_000_000);
        market = new MockMarket();
        factory = new IndexFactory(owner0, guardian0);
        executor = new MockRebalanceExecutor();
        int256[7] memory prices = [int256(3000e8), 3600e8, 110_000e8, 200e8, 10e8, 20e8, 300e8];
        uint256[7] memory supplies = [
            uint256(122_070_499e18),
            3_715_183e18,
            20_087_871e8,
            587_507_739e9,
            620_716_422e18,
            748_099_970e18,
            15_428_841e18
        ];
        uint8[7] memory d = [uint8(18), 18, 8, 9, 18, 18, 18];
        IIndexFactory.TokenConfig[] memory cfgs = new IIndexFactory.TokenConfig[](N);
        for (uint256 i = 0; i < N; ++i) {
            address t;
            if (i == 2) {
                wbtc = new MockPausableToken("WBTC", "WBTC", 8);
                t = address(wbtc);
            } else {
                t = address(new MockERC20("C", "C", d[i]));
            }
            toks.push(t);
            decs.push(d[i]);
            cfgs[i] = market.configWith(t, prices[i], supplies[i]);
        }
        vm.startPrank(owner0);
        for (uint256 i = 0; i < N; ++i) {
            factory.proposeListing(toks[i], cfgs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < N; ++i) {
            factory.executeListing(toks[i]);
        }
        uint256[] memory units = IIndexRule(factory.RULE()).initialUnits(toks, methodology, 1000e18);
        vm.prank(bob);
        index = IndexToken(factory.createIndex("Launch", "L7", toks, units, methodology));
        _issueAs(alice, 1000e18);
        // Move the market so the rule wants a rebalance: SOL -30%, LINK +40%, BTC +10%.
        market.movePrice(toks[3], 70, 100);
        market.movePrice(toks[5], 140, 100);
        market.movePrice(toks[2], 110, 100);
        // A reference-supply revision through the listing flow (UNI +60%), so the uncapped rule also wants a rebalance.
        {
            IIndexFactory.TokenConfig memory c = factory.tokenConfig(toks[4]);
            c.referenceSupply = c.referenceSupply * 160 / 100;
            vm.prank(owner0);
            factory.proposeConfig(toks[4], c);
            vm.warp(block.timestamp + factory.LISTING_DELAY());
            factory.executeListing(toks[4]);
        }
        mLast = index.lastRebalance();
        for (uint256 i = 0; i < N; ++i) {
            mUnits.push(units[i]);
        }
    }

    function _issueAs(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < N; ++i) {
            if (i == 2) wbtc.mint(who, need[i]);
            else MockERC20(toks[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(toks[i]).approve(address(index), need[i]);
        }
        vm.prank(who);
        index.issue(shares, who);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _flag(string memory what) internal {
        if (bytes(violation).length == 0) {
            violation = string.concat(what, " @t=", vm.toString(block.timestamp));
        }
    }

    function _priv(address a) internal view returns (bool) {
        return a == factory.owner() || (a == factory.guardian() && a != address(0));
    }

    /// @dev Documented stranger hold-off: after a cancel, restartAllowedAt; after an auction nobody filled,
    ///      REBALANCE_DELAY past its last fillable second.
    function _strangerAt() internal view returns (uint256) {
        uint256 afterExpiry = mEta == 0 ? 0 : mEta + AD + RD;
        return Math.max(mRestart, afterExpiry);
    }

    function _modelCanStart() internal view returns (bool) {
        uint256 t = block.timestamp;
        if (t < mLast + MRI) return false;
        if (mEta != 0 && t <= mEta + AD) return false;
        return t >= _strangerAt();
    }

    function _inAuction() internal view returns (bool) {
        return mEta != 0 && block.timestamp >= mEta && block.timestamp <= mEta + AD;
    }

    function _price(uint256 i) internal view returns (uint256) {
        TestAggregator f = market.feedOf(toks[i]);
        return uint256(f.answer()) * 10 ** (36 - 8 - decs[i]);
    }

    struct Settle {
        uint256 m;
        uint256[] units;
        uint256[] out;
        uint256[] inn;
    }

    function _modelSettle() internal view returns (Settle memory s) {
        uint256 S = index.totalSupply();
        s.units = new uint256[](N);
        s.out = new uint256[](N);
        s.inn = new uint256[](N);
        bool sells = false;
        for (uint256 i = 0; i < N; ++i) {
            uint256 cur = mUnits[i];
            uint256 tgt = mTargets[i];
            if (tgt < cur) {
                s.units[i] = tgt;
                s.out[i] = S * cur / WAD - S * tgt / WAD;
                if (s.out[i] != 0) sells = true;
            }
        }
        // Linear decay from 1.5 to 0.9 over the auction, the decrement rounded down; parity when nothing leaves.
        s.m = sells ? 1.5e18 - (0.6e18 * (block.timestamp - mEta)) / AD : WAD;
        for (uint256 i = 0; i < N; ++i) {
            uint256 cur = mUnits[i];
            uint256 tgt = mTargets[i];
            if (tgt >= cur) {
                uint256 extra = Math.mulDiv(tgt - cur, s.m, WAD, Math.Rounding.Ceil);
                s.units[i] = cur + extra;
                s.inn[i] = S * s.units[i] / WAD - S * cur / WAD;
            }
        }
    }

    function _eqArr(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _mTargets() internal view returns (uint256[] memory t) {
        t = mTargets;
    }

    function _mUnits() internal view returns (uint256[] memory u) {
        u = mUnits;
    }

    // ---------------------------------------------------------------------
    // view check
    // ---------------------------------------------------------------------

    function _checkViews() internal {
        (uint256 eta, uint256 mask, uint256[] memory tg) = index.pendingRebalance();
        if (eta != mEta) _flag("pendingRebalance.eta");
        if (mask != mMask) _flag("pendingRebalance.keepMask");
        if (!_eqArr(tg, _mTargets())) _flag("pendingRebalance.targets");
        if (index.proposalCount() != mPc) _flag("proposalCount");
        if (index.rebalanceNonce() != mNonce) _flag("rebalanceNonce");
        if (index.lastRebalance() != mLast) _flag("lastRebalance");
        if (index.restartAllowedAt() != mRestart) _flag("restartAllowedAt");
        (, uint256[] memory u) = index.components();
        if (!_eqArr(u, _mUnits())) _flag("units");
        if (index.canStartRebalance() != _modelCanStart()) _flag("canStartRebalance");

        uint256 cm = index.currentMultiplier();
        if (_inAuction()) {
            Settle memory s = _modelSettle();
            if (cm != s.m) _flag("currentMultiplier");
            try index.previewRebalance() returns (
                uint256 m, uint256[] memory units, uint256[] memory out, uint256[] memory inn
            ) {
                if (m != s.m || !_eqArr(units, s.units) || !_eqArr(out, s.out) || !_eqArr(inn, s.inn)) {
                    _flag("previewRebalance values");
                }
            } catch {
                _flag("previewRebalance reverted in auction");
            }
        } else {
            if (cm != 0) _flag("currentMultiplier outside auction");
            bytes memory exp;
            if (mEta == 0) exp = abi.encodeWithSelector(IIndexToken.NoPendingRebalance.selector);
            else if (block.timestamp < mEta) exp = abi.encodeWithSelector(IIndexToken.RebalanceNotReady.selector, mEta);
            else exp = abi.encodeWithSelector(IIndexToken.RebalanceExpired.selector, mEta + AD);
            try index.previewRebalance() returns (uint256, uint256[] memory, uint256[] memory, uint256[] memory) {
                _flag("previewRebalance answered outside auction");
            } catch (bytes memory err) {
                if (keccak256(err) != keccak256(exp)) _flag("previewRebalance revert data");
            }
        }
        // Backing invariant.
        uint256 S = index.totalSupply();
        if (!wbtc.readsBroken()) {
            for (uint256 i = 0; i < N; ++i) {
                uint256 req = S * mUnits[i] / WAD + index.totalClaims(toks[i]);
                if (MockERC20(toks[i]).balanceOf(address(index)) < req) _flag("backing");
            }
        }
    }

    function _rebalanceLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out, uint256 k) {
        out = new Vm.Log[](logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(index)) continue;
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (t0 == SIG_STARTED || t0 == SIG_CANCELLED || t0 == SIG_REBALANCED) out[k++] = logs[i];
        }
    }

    function _expectOneLog(Vm.Log[] memory logs, bytes32[] memory topics, bytes memory data, string memory what)
        internal
    {
        (Vm.Log[] memory rl, uint256 k) = _rebalanceLogs(logs);
        if (k != 1) {
            _flag(string.concat(what, ": event count"));
            return;
        }
        if (keccak256(abi.encode(rl[0].topics)) != keccak256(abi.encode(topics))) _flag(string.concat(what, ": topics"));
        if (keccak256(rl[0].data) != keccak256(data)) _flag(string.concat(what, ": data"));
    }

    /// @dev Only meaningful for calls that succeeded: forge's recordLogs also captures logs of reverted frames.
    function _expectNoLog(Vm.Log[] memory logs, string memory what) internal {
        if (!lastOk) return;
        (, uint256 k) = _rebalanceLogs(logs);
        if (k != 0) _flag(string.concat(what, ": unexpected event"));
    }

    function _cmpRevert(bool ok, bytes memory ret, bool expOk, bytes memory expErr, bool anyErr, string memory what)
        internal
        returns (bool)
    {
        if (ok != expOk) {
            _flag(string.concat(what, ok ? ": succeeded, model says revert " : ": reverted, model says ok ", vm.toString(ret)));
            return false;
        }
        if (!ok && !anyErr && keccak256(ret) != keccak256(expErr)) {
            _flag(string.concat(what, ": revert data ", vm.toString(ret), " expected ", vm.toString(expErr)));
            return false;
        }
        lastOk = ok;
        if (ok) ++nOk;
        else ++nRevert;
        return true;
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    function _start(address caller, uint256 mask) internal {
        uint256 t = block.timestamp;
        bool expOk = false;
        bytes memory expErr;
        uint256[] memory tg;
        if (t < mLast + MRI) {
            expErr = abi.encodeWithSelector(IIndexToken.RebalanceTooSoon.selector, mLast + MRI);
        } else if (mEta != 0 && t <= mEta + AD) {
            expErr = abi.encodeWithSelector(IIndexToken.RebalancePending.selector, mEta + AD);
        } else if (mask >> N != 0 || mask == (1 << N) - 1) {
            expErr = abi.encodeWithSelector(IIndexToken.InvalidKeepMask.selector, mask);
        } else if ((mask != 0 || t < _strangerAt()) && !_priv(caller)) {
            expErr = abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, caller);
        } else {
            try index.previewTarget(mask) returns (uint256[] memory targets, uint256 turnover) {
                if (turnover < index.MIN_TURNOVER()) {
                    expErr = abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, turnover);
                } else {
                    expOk = true;
                    tg = targets;
                    // Rule-side sanity the token relies on: kept components stay, every target within its band.
                    for (uint256 i = 0; i < N; ++i) {
                        uint256 u = mUnits[i];
                        if ((mask >> i) & 1 == 1 && targets[i] != u) _flag("kept target moved");
                        uint256 hi = Math.max(u, Math.min(2 * u, uint256(type(uint96).max) * 2 / 3));
                        if (targets[i] < (u + 1) / 2 || targets[i] > hi) _flag("target out of band");
                    }
                }
            } catch (bytes memory e) {
                expErr = e;
            }
        }
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(index).call(abi.encodeCall(IIndexToken.startRebalance, (mask)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) startRevertBySel[bytes4(ret)] += 1;
        if (!_cmpRevert(ok, ret, expOk, expErr, false, "start")) return;
        if (ok) {
            ++nStartOk;
            uint256 eta = t + RD;
            bytes32[] memory topics = new bytes32[](4);
            topics[0] = SIG_STARTED;
            topics[1] = bytes32(mPc + 1);
            topics[2] = bytes32(mNonce + 1);
            topics[3] = bytes32(uint256(uint160(caller)));
            _expectOneLog(logs, topics, abi.encode(tg, mask, eta), "start");
            mEta = eta;
            mMask = mask;
            mTargets = tg;
            ++mPc;
        } else {
            _expectNoLog(logs, "start");
        }
        _checkViews();
    }

    function _cancel(address caller) internal {
        uint256 t = block.timestamp;
        bool expOk = false;
        bytes memory expErr;
        uint256 restart;
        if (mEta == 0) {
            expErr = abi.encodeWithSelector(IIndexToken.NoPendingRebalance.selector);
        } else if (!_priv(caller)) {
            expErr = abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, caller);
        } else {
            expOk = true;
            // Live (notice or auction): a full REBALANCE_DELAY from the cancel. Expired: the expiry's own hold-off
            // stands, neither shortened nor extended (VR-04).
            restart = t <= mEta + AD ? t + RD : _strangerAt();
        }
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(index).call(abi.encodeCall(IIndexToken.cancelRebalance, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!_cmpRevert(ok, ret, expOk, expErr, false, "cancel")) return;
        if (ok) {
            ++nCancelOk;
            uint256 strangerBefore = _strangerAt();
            bool expired = t > mEta + AD;
            bytes32[] memory topics = new bytes32[](3);
            topics[0] = SIG_CANCELLED;
            topics[1] = bytes32(mPc);
            topics[2] = bytes32(uint256(uint160(caller)));
            _expectOneLog(logs, topics, abi.encode(restart), "cancel");
            mEta = 0;
            mMask = 0;
            delete mTargets;
            mRestart = restart;
            // Documented property: cancelling an expired auction neither shortens nor extends the stranger hold-off.
            if (expired && _strangerAt() != strangerBefore) _flag("expired cancel moved the hold-off");
        } else {
            _expectNoLog(logs, "cancel");
        }
        _checkViews();
    }

    /// @param mode 0 unbounded honest, 1 bounded exact, 2 bounded one short, 3 bounded wrong length, 4 short executor,
    ///        5 noop executor.
    function _execute(uint256 mode) internal {
        uint256 t = block.timestamp;
        bool expOk = false;
        bool anyErr = false;
        bytes memory expErr;
        Settle memory s;
        uint256[] memory maxIn;
        uint256 shortIdx = type(uint256).max;
        if (mEta == 0) {
            expErr = abi.encodeWithSelector(IIndexToken.NoPendingRebalance.selector);
        } else if (t < mEta) {
            expErr = abi.encodeWithSelector(IIndexToken.RebalanceNotReady.selector, mEta);
        } else if (t > mEta + AD) {
            expErr = abi.encodeWithSelector(IIndexToken.RebalanceExpired.selector, mEta + AD);
        } else {
            s = _modelSettle();
            expOk = true;
            if (mode == 1 || mode == 2) {
                maxIn = new uint256[](N);
                for (uint256 i = 0; i < N; ++i) {
                    maxIn[i] = s.inn[i];
                }
                if (mode == 2) {
                    for (uint256 i = 0; i < N; ++i) {
                        if (s.inn[i] != 0) {
                            maxIn[i] -= 1;
                            expOk = false;
                            expErr = abi.encodeWithSelector(
                                IIndexToken.RebalanceMovedOn.selector, toks[i], s.inn[i], s.inn[i] - 1
                            );
                            break;
                        }
                    }
                }
            } else if (mode == 3) {
                maxIn = new uint256[](N - 1);
                expOk = false;
                expErr = abi.encodeWithSelector(IXindexErrors.LengthMismatch.selector);
            }
            if (expOk) {
                // Every moving leg's feed is read: a stale one stops the settlement.
                for (uint256 i = 0; i < N; ++i) {
                    if (s.out[i] == 0 && s.inn[i] == 0) continue;
                    (, , , uint256 upd,) = market.feedOf(toks[i]).latestRoundData();
                    if (upd > t || t - upd > STALE_BOUND) {
                        expOk = false;
                        expErr = abi.encodeWithSelector(IIndexRule.StalePrice.selector, toks[i], upd);
                        break;
                    }
                }
            }
            if (expOk) {
                uint256 outV = 0;
                uint256 inV = 0;
                for (uint256 i = 0; i < N; ++i) {
                    if (s.out[i] == 0 && s.inn[i] == 0) continue;
                    outV += Math.mulDiv(s.out[i], _price(i), WAD);
                    inV += Math.mulDiv(s.inn[i], _price(i), WAD);
                }
                uint256 req = Math.mulDiv(outV, 0.875e18, WAD);
                if (inV < req) {
                    expOk = false;
                    expErr = abi.encodeWithSelector(IIndexToken.SettlementValueTooLow.selector, inV, outV, req);
                }
            }
            if (expOk && wbtc.paused() && (s.out[2] != 0 || s.inn[2] != 0)) {
                expOk = false;
                anyErr = true;
            }
            if (expOk && (mode == 4 || mode == 5)) {
                for (uint256 i = 0; i < N; ++i) {
                    if (s.inn[i] != 0) {
                        shortIdx = i;
                        break;
                    }
                }
                if (shortIdx != type(uint256).max) {
                    expOk = false;
                    uint256 S = index.totalSupply();
                    uint256 held = MockERC20(toks[shortIdx]).balanceOf(address(index));
                    uint256 bal = held + (mode == 4 ? s.inn[shortIdx] - 1 : 0);
                    uint256 req =
                        Math.max(S * s.units[shortIdx] / WAD + index.totalClaims(toks[shortIdx]), held + s.inn[shortIdx]);
                    expErr = abi.encodeWithSelector(IIndexToken.RebalanceUnderfunded.selector, toks[shortIdx], bal, req);
                }
            }
        }
        if (mode == 4 && shortIdx != type(uint256).max) {
            executor.setMode(MockRebalanceExecutor.Mode.Short);
            executor.setShortComponent(shortIdx);
        } else if (mode == 5) {
            executor.setMode(MockRebalanceExecutor.Mode.Noop);
        } else {
            executor.setMode(MockRebalanceExecutor.Mode.Honest);
        }
        uint256[] memory before = new uint256[](N);
        if (!wbtc.readsBroken()) {
            for (uint256 i = 0; i < N; ++i) {
                before[i] = MockERC20(toks[i]).balanceOf(address(index));
            }
        }
        vm.recordLogs();
        bool ok;
        bytes memory ret;
        if (mode == 0 || mode == 4 || mode == 5) {
            (ok, ret) = address(executor).call(abi.encodeCall(MockRebalanceExecutor.execute, (index, "x")));
        } else {
            (ok, ret) =
                address(executor).call(abi.encodeCall(MockRebalanceExecutor.executeBounded, (index, "x", maxIn)));
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        executor.setMode(MockRebalanceExecutor.Mode.Honest);
        if (!ok) execRevertBySel[bytes4(ret)] += 1;
        if (!_cmpRevert(ok, ret, expOk, expErr, anyErr, "execute")) return;
        if (ok) {
            ++nExecOk;
            bytes32[] memory topics = new bytes32[](4);
            topics[0] = SIG_REBALANCED;
            topics[1] = bytes32(mPc);
            topics[2] = bytes32(mNonce + 1);
            topics[3] = bytes32(uint256(uint160(address(executor))));
            _expectOneLog(logs, topics, abi.encode(s.m, s.units, s.out, s.inn), "execute");
            // Balances moved by exactly the settlement.
            if (!wbtc.readsBroken()) {
                for (uint256 i = 0; i < N; ++i) {
                    if (MockERC20(toks[i]).balanceOf(address(index)) != before[i] - s.out[i] + s.inn[i]) {
                        _flag("execute: balance delta");
                    }
                }
            }
            if (!_eqArr(executor.lastAmountsOut(), s.out) || !_eqArr(executor.lastAmountsIn(), s.inn)) {
                _flag("execute: callback args");
            }
            ++mNonce;
            mLast = t;
            mEta = 0;
            mMask = 0;
            delete mTargets;
            for (uint256 i = 0; i < N; ++i) {
                mUnits[i] = s.units[i];
            }
        } else {
            _expectNoLog(logs, "execute");
        }
        _checkViews();
    }

    function _issue(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        bool paused = wbtc.paused();
        for (uint256 i = 0; i < N; ++i) {
            if (i == 2) {
                wbtc.setPaused(false);
                wbtc.mint(who, need[i]);
                wbtc.setPaused(paused);
            }
            else MockERC20(toks[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(toks[i]).approve(address(index), need[i]);
        }
        bool expOk = !(wbtc.paused() && need[2] != 0) && !wbtc.readsBroken();
        vm.recordLogs();
        vm.prank(who);
        (bool ok, bytes memory ret) = address(index).call(abi.encodeCall(IIndexToken.issue, (shares, who)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _cmpRevert(ok, ret, expOk, "", true, "issue");
        _expectNoLog(logs, "issue");
        _checkViews();
    }

    function _redeem(address who, uint256 shares, uint256 skipMask) internal {
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        shares = shares == type(uint256).max ? bal : 1 + shares % bal;
        uint256[] memory amt = index.previewRedeem(shares);
        bool touchesWbtc = amt[2] != 0 && (skipMask >> 2) & 1 == 0;
        bool expOk = !(wbtc.paused() && touchesWbtc);
        vm.recordLogs();
        vm.prank(who);
        (bool ok, bytes memory ret) = skipMask == 0
            ? address(index).call(abi.encodeCall(IIndexToken.redeem, (shares, who)))
            : address(index).call(abi.encodeCall(IIndexToken.redeemSkipping, (shares, who, skipMask)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _cmpRevert(ok, ret, expOk, "", true, "redeem");
        _expectNoLog(logs, "redeem");
        _checkViews();
    }
}
