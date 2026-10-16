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

    /// @dev I09: the residual risks the reviews accepted are written down for users.
    function test_I09_theKnownLimitationsAreDocumented() public view {
        string memory readme = _read("README.md");
        assertTrue(_contains(readme, "Known limitations"), "the README keeps its known limitations section");
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
                if (entries[i].isDir) continue;
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

    /// @dev Reads every file under `dir` and fails on any price word; returns how many files it read.
    function _assertNoPriceIn(string memory dir, string[5] memory priceWords) internal view returns (uint256 read) {
        VmSafe.DirEntry[] memory entries = vm.readDir(dir, 8);
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir) continue;
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
