// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";

/// @notice Repository facts that security-review findings rest on and that no contract test can reach: the pinned
///         compiler (v1 I10), the pinned CI toolchain and required fork RPC (I11), the dependency lock against
///         `.gitmodules` (L08 and FR04) and the documented known limitations (I09); from the whole-repo audit, the CI
///         gates (XA-10, XA-64), the ignored chain-1 broadcasts (XA-43), the committed ABIs (XA-44), the single copy
///         of the agent instructions (XA-46) and the verification key (XA-58); from the logic review of 2026-09-18,
///         the test linking mode that lets checks after an expected constructor revert run (LR-01); from the security
///         audit of 2026-09-23, the ignored Sepolia-fork broadcasts (CR-I40). CI checks the submodule commits
///         themselves, which needs git; these tests check everything a local run can.
contract RepoTest is Test {
    function _read(string memory path) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/", path));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return vm.contains(haystack, needle);
    }

    /// @dev I10: the compiler is pinned in foundry.toml and every source and script file pins the same version.
    function test_I10_theCompilerIsPinned() public view {
        assertTrue(_contains(_read("foundry.toml"), 'solc = "0.8.28"'), "foundry.toml pins the compiler");
        _assertPragma("src");
        _assertPragma("script");
    }

    function _assertPragma(string memory dir) internal view {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), "/", dir), 3);
        uint256 checked = 0;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir || !vm.contains(entries[i].path, ".sol")) continue;
            ++checked;
            assertTrue(
                vm.contains(vm.readFile(entries[i].path), "pragma solidity 0.8.28;"),
                string.concat(entries[i].path, " must pin pragma 0.8.28")
            );
        }
        assertGt(checked, 0, "the directory holds Solidity files");
    }

    /// @dev I11: CI pins Foundry and Wake and refuses to pass on main without the fork-test RPC.
    function test_I11_theCiToolchainIsPinned() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(_contains(workflow, "version: v1.8.1"), "Foundry is pinned");
        assertTrue(_contains(workflow, "eth-wake==4.22.1"), "Wake is pinned");
        assertTrue(_contains(workflow, "MAINNET_RPC_URL"), "the fork-test RPC is required and passed to the tests");
        assertTrue(_contains(workflow, "forge lint -D notes"), "lint fails on notes");
        assertTrue(_contains(workflow, "wake detect all src"), "the Wake detectors run");
    }

    /// @dev CF-6: Wake's run-time PyPI install never shares a job with Foundry's RPC cache, which the check job saves
    ///      and later fork-suite runs read as chain state; the Wake job keeps no cache of its own.
    function test_CF6_wakeRunsInAJobWithoutTheRpcCache() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        uint256 wakeJob = vm.indexOf(workflow, "\n  wake:\n");
        assertTrue(wakeJob != type(uint256).max, "Wake has a job of its own");
        assertGt(vm.indexOf(workflow, "pipx install eth-wake"), wakeJob, "the PyPI install runs in it");
        assertLt(vm.indexOf(workflow, "run: forge test -vvv"), wakeJob, "the fork suites run in the check job");
        assertEq(_count(workflow, "pipx install"), 1, "nothing else installs from PyPI");
        assertGt(vm.indexOf(workflow, "cache: false"), wakeJob, "and the Wake job's Foundry keeps no RPC cache");
    }

    /// @dev L08 and FR04: every submodule is pinned in foundry.lock and every pinned path is a submodule. CI compares
    ///      the committed commits against the lock; that needs git, so it stays there.
    function test_L08_FR04_theDependencyLockAndGitmodulesAgree() public view {
        string memory gitmodules = _read(".gitmodules");
        string memory lock = _read("foundry.lock");
        string[] memory paths = new string[](3);
        paths[0] = "lib/forge-std";
        paths[1] = "lib/openzeppelin-contracts";
        paths[2] = "lib/openzeppelin-contracts-upgradeable";
        for (uint256 i = 0; i < paths.length; ++i) {
            assertTrue(_contains(gitmodules, string.concat("path = ", paths[i])), "submodule is declared");
            assertTrue(_contains(lock, string.concat('"', paths[i], '"')), "submodule is pinned");
        }
        // Both files list exactly these three, so neither can gain an unpinned or ghost entry unnoticed.
        assertEq(_count(gitmodules, "[submodule "), paths.length, ".gitmodules lists only the pinned submodules");
        assertEq(_count(lock, '"lib/'), paths.length, "foundry.lock pins only the declared submodules");
        assertTrue(_contains(lock, '"name": "v5.7.0"'), "OpenZeppelin stays on the reviewed release");
        assertTrue(_contains(lock, '"name": "v1.16.2"'), "forge-std stays on the reviewed release");
    }

    /// @dev I09: the residual risks the reviews accepted are written down for users. XS-17: each one is pinned by its
    ///      anchor inside the section itself, so a limitation cannot go missing while a cross-reference to the heading
    ///      keeps the old check green.
    function test_I09_XS17_theKnownLimitationsAreDocumented() public view {
        string memory section = _section(_read("README.md"), "\n## Known limitations\n");
        string[23] memory anchors = [
            "**A lone executor can take up to 2% of what it trades.**",
            "**A wrong price costs at most the turnover cap.**",
            "**Rebalancing needs Pyth's Hermes, and Hermes needs a key.**",
            "**Wrapped legs rest on Wormhole.**",
            "**A collapsing coin can stop the fills.**",
            "**An issuer's corporate action is not accounted for.**",
            "**Price ids are data the owner maintains.**",
            "**Rebalances clear only when the moving value pays for the fill.**",
            "**An exit sent during the auction can be overtaken by the fill.**",
            "**The guardian can stall rebalancing.**",
            "**Issuers can freeze components, and some can burn them.**",
            "**A request's surplus goes to the fastest filler.**",
            "**Circle and Tether freeze differently, and `MintRequests` cannot tell.**",
            "**A request is an option held by every filler until it closes.**",
            "**Fees in shares only.**",
            "**The streaming fee is charged on the supply that was there.**",
            "**The basket builder is one custody point.**",
            "**Airdrops, rewards and governance votes**",
            "**A hooked V4 pool cannot be routed through.**",
            "**`PYTH` cannot be repointed.**",
            "**An executor that also builds the block sees further.**",
            "**A `tokenIn` that calls back into the zap is unsupported**",
            "**Zap gas grows with components and hops, and nothing on chain bounds it.**"
        ];
        for (uint256 i = 0; i < anchors.length; ++i) {
            assertTrue(_contains(section, anchors[i]), anchors[i]);
        }
        assertEq(_count(section, "\n- **"), anchors.length, "every limitation is pinned here, and only those");
        assertTrue(_contains(section, "until its own interval, 7 to 91 days"), "a fresh index waits its own interval");
        assertTrue(_contains(section, "restarts only `MIN_REBALANCE_INTERVAL` for a rebalance without a keep mask"));
        assertTrue(
            _contains(section, "first fillable block is the next open, near `MU_MIN`"), "RX-3, as the owner chose"
        );
        assertTrue(_contains(section, "five of seven named guardians suffice to mint"), "RX-6");
    }

    /// @dev The text of `text` from `heading` up to the next second-level heading, or to its end.
    function _section(string memory text, string memory heading) internal pure returns (string memory) {
        bytes memory t = bytes(text);
        bytes memory h = bytes(heading);
        uint256 start = type(uint256).max;
        for (uint256 i = 0; i + h.length <= t.length; ++i) {
            if (keccak256(_slice(t, i, i + h.length)) == keccak256(h)) {
                start = i + h.length;
                break;
            }
        }
        assertTrue(start != type(uint256).max, heading);
        uint256 end = t.length;
        for (uint256 i = start; i + 4 <= t.length; ++i) {
            if (t[i] == "\n" && t[i + 1] == "#" && t[i + 2] == "#" && t[i + 3] == " ") {
                end = i;
                break;
            }
        }
        return string(_slice(t, start, end));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
    }

    /// @dev XA-10: CI runs every gate of the definition of done. Wake's generated config must leave out `keeper/`, the
    ///      bot's executor, a separate Foundry project whose remapping only it knows: Wake stops on it before running a
    ///      detector. The extension must ignore a local `wake.toml`, which would otherwise replace its committed config.
    function test_XA10_ciRunsEveryGate() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(_contains(workflow, "forge lint -D notes"), "lint fails on notes");
        assertTrue(_contains(workflow, "forge coverage --report summary"), "coverage is measured");
        assertTrue(_contains(workflow, "coverage is below 100% in "), "coverage below 100% fails");
        assertTrue(
            _contains(workflow, "github.event.pull_request.head.repo.full_name == github.repository"),
            "pull requests from this repository need the fork-test RPC"
        );
        assertTrue(_contains(workflow, "wake init config --force"), "Wake's config comes from foundry.toml");
        assertTrue(_contains(workflow, 'exclude_paths = ["keeper", '), "Wake does not compile the keeper");
        assertTrue(_contains(workflow, "wake detect all src"), "the Wake detectors run");
        string memory settings = _read(".vscode/settings.json");
        assertTrue(_contains(settings, '"keeper"'), "nor does the Wake extension");
        assertTrue(
            _contains(settings, '"wake.configuration.use_toml_if_present": false'),
            "and no local wake.toml replaces the extension's committed config"
        );
    }

    /// @dev XA-43: mainnet-fork rehearsals keep chain id 1, so chain-1 broadcast records stay out of git unless a real
    ///      deployment's record is added on purpose.
    function test_XA43_chainOneBroadcastsAreIgnored() public view {
        assertTrue(_contains(_read(".gitignore"), "\n/broadcast/*/1/\n"), "chain-1 broadcast records are ignored");
    }

    /// @dev CR-I40: a Sepolia-fork rehearsal keeps chain id 11155111, since SetupTestMarket refuses any other, so its
    ///      records landed beside the real Sepolia history and were committed with it, an aborted run among them.
    function test_CRI40_sepoliaForkBroadcastsAreIgnored() public view {
        assertTrue(
            _contains(_read(".gitignore"), "\n/broadcast/*/11155111/\n"), "Sepolia broadcast records are ignored"
        );
    }

    /// @dev XA-44: the ABIs the web app decodes with are committed, and CI regenerates them and fails on a diff: the zap,
    ///      the basket builder, `MintRequests`, and v5's weighted factory and index. v4's market-cap factory and hub are deleted, and their
    ///      ABIs with them; so are Stage B's hybrid factory, hybrid index and vault
    ///      (`audit/2026-10-07-stage-b-retirement.md`).
    function test_XA44_theAbisAreCommittedAndChecked() public view {
        string[5] memory contracts =
            ["IndexZap", "BasketBuilder", "MintRequests", "WeightedIndexFactory", "WeightedHub"];
        for (uint256 i = 0; i < contracts.length; ++i) {
            assertTrue(
                _contains(_read(string.concat("abi/", contracts[i], ".json")), '"type": "function"'),
                string.concat("abi/", contracts[i], ".json is committed")
            );
        }
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(
            _contains(
                workflow, "for contract in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub; do"
            ),
            "CI regenerates every ABI"
        );
        assertTrue(_contains(workflow, "git diff --exit-code abi/"), "a stale ABI fails CI");
        assertFalse(vm.exists("abi/IndexFactory.json"), "v4's factory ABI is gone");
        assertFalse(vm.exists("abi/IndexHub.json"), "and its hub's");
        assertFalse(vm.exists("abi/HybridIndexFactory.json"), "Stage B's factory ABI is gone");
        assertFalse(vm.exists("abi/IHybridIndex.json"), "and its index's");
        assertFalse(vm.exists("abi/XindexVault.json"), "and its vault's");
    }

    /// @dev DA-10. A token config carried a list of excluded holders whose balances `IndexRule._supply` subtracted
    ///      with a live `balanceOf` inside the rebalance snapshot, so a config naming an address a third party could
    ///      fund and drain made that component's market cap manipulable inside one transaction: flash loan in, start a
    ///      rebalance, flash loan out. Nothing shipped used it, and a reference supply behind the listing timelock
    ///      covers the same need, so the field is gone from the config, the events, the rule and the listing script.
    ///      v5 lists a token with a price id and nothing else, and neither its listing ABIs nor its listing script's
    ///      entries carry an exclusion list.
    function test_DA10_noConfigCanCarryExclusions() public view {
        assertFalse(
            _contains(_read("abi/WeightedIndexFactory.json"), "excluded"), "the listing ABI has no exclusion list"
        );
        assertFalse(_contains(_read("script/ConfigureWeighted.s.sol"), "excluded"), "nor the listing script's entries");
    }

    /// @dev XA-46: the agent instructions have one copy; CLAUDE.md only imports AGENTS.md.
    function test_XA46_claudeMdOnlyImportsAgentsMd() public view {
        string memory claude = _read("CLAUDE.md");
        assertTrue(_contains(claude, "\n@AGENTS.md"), "CLAUDE.md imports AGENTS.md");
        assertFalse(_contains(claude, "\n## "), "and repeats none of its sections");
    }

    /// @dev XA-58: `--verify` finds its key: `.env.example` names it and foundry.toml uses it for mainnet and Sepolia.
    function test_XA58_verificationHasItsApiKey() public view {
        assertTrue(_contains(_read(".env.example"), "\nETHERSCAN_API_KEY="), "the example environment names the key");
        string memory config = _read("foundry.toml");
        assertTrue(_contains(config, 'mainnet = { key = "${ETHERSCAN_API_KEY}" }'), "mainnet verification uses it");
        assertTrue(_contains(config, 'sepolia = { key = "${ETHERSCAN_API_KEY}" }'), "Sepolia verification uses it");
    }

    /// @dev XA-64: CI clones only the direct submodules and checks the lock both ways, so a ghost lock entry fails.
    function test_XA64_ciChecksOutDirectSubmodulesAndTheLockBothWays() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(_contains(workflow, "submodules: true"), "only lib/* is cloned");
        assertFalse(_contains(workflow, "submodules: recursive"), "not the dependencies' nested submodules");
        assertTrue(_contains(workflow, "has no entry in foundry.lock"), "every submodule is pinned");
        assertTrue(_contains(workflow, "but .gitmodules has no such submodule"), "every pin is a submodule");
    }

    /// @dev No committed file names a path on its author's machine: a home folder, a temporary folder, or the folder an
    ///      agent names after a home folder and keeps its scratchpad in. Three audit records showed the author's user
    ///      name so until 2026-10-25. CI greps every committed text file and fails on a match, and on a grep that could
    ///      not run, which would otherwise pass as a clean tree. The step is pinned whole, keys and script: a pin on a
    ///      few of its lines let an `if: false`, a `continue-on-error`, a commented-out `exit 1` and a dropped
    ///      `status=0` through (a match then leaves the status empty, which neither test catches). The brackets keep
    ///      each pattern from matching itself.
    function test_ciRefusesAPathOnItsAuthorsMachine() public view {
        assertEq(
            _step(_read(".github/workflows/test.yml"), "Check no committed file names a local path"),
            string.concat(
                "        run: |\n",
                "          users='/Use[r]s/|\\\\Use[r]s\\\\|-Use[r]s-'\n",
                "          rooted='(^|[^[:alnum:]._-])(/hom[e]/|-hom[e]-|/privat[e]/(tmp|var)/|/va[r]/folders/)'\n",
                "          status=0\n",
                "          git grep -n -I -E -e \"$users\" -e \"$rooted\" || status=$?\n",
                "          if [ \"$status\" -eq 0 ]; then\n",
                "            echo \"::error::the lines above name a path on their author's machine\"\n",
                "            exit 1\n",
                "          fi\n",
                "          if [ \"$status\" -ne 1 ]; then\n",
                "            echo \"::error::git grep could not run (status $status)\"\n",
                "            exit 1\n",
                "          fi\n"
            ),
            "CI runs exactly this step: no key added, no line changed"
        );
    }

    /// @dev The CI step named `name`, less its name line: the lines after it up to the next line indented less than a
    ///      step's keys (the next step, a comment above it, or the next job), trailing blank lines left out. The name
    ///      line must start a line, indented as a step, and no other step may carry the name, so neither a
    ///      commented-out copy nor a second step stands in for it.
    function _step(string memory workflow, string memory name) internal pure returns (string memory) {
        bytes memory t = bytes(workflow);
        bytes memory h = bytes(string.concat("\n      - name: ", name, "\n"));
        uint256 at = _indexOf(t, h, 0);
        assertTrue(at < t.length, name);
        assertEq(_indexOf(t, h, at + 1), t.length, "no other step carries the name");
        uint256 start = at + h.length;
        uint256 end = start;
        for (uint256 line = start; line < t.length;) {
            uint256 next = _indexOf(t, bytes("\n"), line);
            uint256 indent = 0;
            while (line + indent < next && t[line + indent] == bytes1(" ")) {
                ++indent;
            }
            if (line + indent < next) {
                if (indent < 8) break;
                end = next < t.length ? next + 1 : next;
            }
            line = next + 1;
        }
        return string(_slice(t, start, end));
    }

    /// @dev Where `needle` first occurs in `t` at or after `from`, or `t.length` if it does not.
    function _indexOf(bytes memory t, bytes memory needle, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + needle.length <= t.length; ++i) {
            uint256 j = 0;
            while (j < needle.length && t[i + j] == needle[j]) {
                ++j;
            }
            if (j == needle.length) return i;
        }
        return t.length;
    }

    /// @dev LR-01: forge's default `dynamic_test_linking` deploys a `src/` contract a test creates through a
    ///      cheatcode, and the test function then ended, reported as a pass, at the first expected constructor revert:
    ///      the checks after it never ran, and neither did an unmet `expectCall`. Nothing placed after such a revert
    ///      can detect that mode, so the setting is checked first; the rest shows what it buys, a marker call that is
    ///      only made if the function runs to its end.
    function test_LR01_checksAfterAnExpectedConstructorRevertStillRun() public {
        assertTrue(_contains(_read("foundry.toml"), "\ndynamic_test_linking = false\n"), "test linking stays static");
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexZap(IIndexFactory(address(0)), IUniversalRouter(address(0)));
        vm.expectCall(address(this), abi.encodeCall(this.reachedAfterTheRevert, ()));
        this.reachedAfterTheRevert();
    }

    function reachedAfterTheRevert() external {}

    /// @dev No file in `src/` and no shipped ABI in `abi/` names a Chainlink feed, a pool's price or its oracle, and the
    ///      v3 price contracts are gone. Every file of both folders is read, Stage B's included, so a new file is covered
    ///      without being listed. v5's one price source is Pyth, read only by `WeightedHub`'s settlement
    ///      (`test_V5I4_onlyTheWeightedHubReadsAPrice`).
    function test_noContractReadsAPrice() public view {
        string[5] memory priceWords = ["latestRoundData", "AggregatorV3", "slot0", "observe(", "navPerToken"];
        uint256 read = _assertNoPriceIn("src", priceWords) + _assertNoPriceIn("abi", priceWords);
        assertGt(read, 20, "every source and ABI file is read");
        string[5] memory gone = [
            "src/IndexRule.sol",
            "src/CompositeFeed.sol",
            "src/interfaces/IAggregatorV3.sol",
            "src/interfaces/IIndexRule.sol",
            "abi/IndexRule.json"
        ];
        for (uint256 i = 0; i < gone.length; ++i) {
            assertFalse(vm.exists(gone[i]), string.concat(gone[i], " is gone"));
        }
    }

    /// @dev v5 reads one price source, Pyth, in one place: `WeightedHub`'s settlement. Only the hub, its interface (which
    ///      names Pyth's fee quote and takes Pyth's price struct for executors), its ABI and the vendored Pyth files name
    ///      Pyth's contract, its parse, its getters, its pushes or its price struct; the factory, the zap and
    ///      `MintRequests` name none of them. A new file is covered without being listed. The words cover every way to
    ///      read a Pyth price, not only the one the hub uses (V5-I4).
    function test_V5I4_onlyTheWeightedHubReadsAPrice() public view {
        string[6] memory allowed = [
            "src/WeightedHub.sol",
            "src/interfaces/IWeightedHub.sol",
            "src/interfaces/pyth/IPyth.sol",
            "src/interfaces/pyth/IPythEvents.sol",
            "src/interfaces/pyth/PythStructs.sol",
            "abi/WeightedHub.json"
        ];
        string[5] memory pythWords = ["IPyth", "parsePriceFeedUpdates", "getPrice", "updatePriceFeeds", "PythStructs"];
        uint256 read = 0;
        string[2] memory dirs = ["src", "abi"];
        for (uint256 d = 0; d < dirs.length; ++d) {
            VmSafe.DirEntry[] memory entries = vm.readDir(dirs[d], 8);
            for (uint256 i = 0; i < entries.length; ++i) {
                if (entries[i].isDir || _isFinderMetadata(entries[i].path)) continue;
                ++read;
                bool exempt = false;
                for (uint256 a = 0; a < allowed.length; ++a) {
                    exempt = exempt || _endsWith(entries[i].path, allowed[a]);
                }
                if (exempt) continue;
                string memory text = vm.readFile(entries[i].path);
                for (uint256 j = 0; j < pythWords.length; ++j) {
                    assertFalse(_contains(text, pythWords[j]), string.concat(entries[i].path, " names ", pythWords[j]));
                }
            }
        }
        assertGt(read, 20, "every source and ABI file is read");
        assertTrue(_contains(_read("src/WeightedHub.sol"), "parsePriceFeedUpdatesUnique"), "the hub reads Pyth");
        assertFalse(_contains(_read("src/WeightedIndexFactory.sol"), "Pyth("), "the factory never calls Pyth");
    }

    function _endsWith(string memory text, string memory suffix) internal pure returns (bool) {
        bytes memory t = bytes(text);
        bytes memory s = bytes(suffix);
        if (s.length > t.length) return false;
        for (uint256 i = 0; i < s.length; ++i) {
            if (t[t.length - s.length + i] != s[i]) return false;
        }
        return true;
    }

    /// @dev macOS Finder writes a binary `.DS_Store` into any folder it opens. It is never a source or an ABI, and
    ///      `vm.readFile` fails on it as invalid UTF-8, so the walks that read every file skip it and nothing else.
    function _isFinderMetadata(string memory path) internal pure returns (bool) {
        return _endsWith(path, "/.DS_Store");
    }

    /// @dev Reads every file under `dir`, Finder's `.DS_Store` aside, and fails on any price word; returns how many files
    ///      it read.
    function _assertNoPriceIn(string memory dir, string[5] memory priceWords) internal view returns (uint256 read) {
        VmSafe.DirEntry[] memory entries = vm.readDir(dir, 8);
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir || _isFinderMetadata(entries[i].path)) continue;
            string memory text = vm.readFile(entries[i].path);
            for (uint256 j = 0; j < priceWords.length; ++j) {
                assertFalse(_contains(text, priceWords[j]), string.concat(entries[i].path, " names ", priceWords[j]));
            }
            ++read;
        }
    }

    function _count(string memory haystack, string memory needle) internal pure returns (uint256 found) {
        bytes memory hay = bytes(haystack);
        bytes memory pin = bytes(needle);
        for (uint256 i = 0; i + pin.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < pin.length; ++j) {
                if (hay[i + j] != pin[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) ++found;
        }
    }
}
