// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

    /// @dev XA-10: CI runs every gate of the definition of done. Wake's generated config must leave out `audit/`, whose
    ///      PoC tests compile only inside the audited commit, and `prototype/`, a separate Foundry project that needs
    ///      via-IR: Wake stops on either before running a detector.
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
        assertTrue(
            _contains(workflow, 'exclude_paths = ["audit", "prototype", '),
            "Wake compiles neither the PoCs nor the prototype"
        );
        assertTrue(_contains(workflow, "wake detect all src"), "the Wake detectors run");
        string memory settings = _read(".vscode/settings.json");
        assertTrue(_contains(settings, '"audit"') && _contains(settings, '"prototype"'), "nor does the Wake extension");
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

    /// @dev XA-44: the ABIs the web app decodes with are committed, and CI regenerates them and fails on a diff.
    function test_XA44_theAbisAreCommittedAndChecked() public view {
        string[4] memory contracts = ["IndexFactory", "IndexHub", "IndexZap", "MintRequests"];
        for (uint256 i = 0; i < contracts.length; ++i) {
            assertTrue(
                _contains(_read(string.concat("abi/", contracts[i], ".json")), '"type": "function"'),
                string.concat("abi/", contracts[i], ".json is committed")
            );
        }
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(
            _contains(workflow, "for contract in IndexFactory IndexHub IndexZap MintRequests; do"),
            "CI regenerates every ABI"
        );
        assertTrue(_contains(workflow, "git diff --exit-code abi/"), "a stale ABI fails CI");
    }

    /// @dev DA-10. A token config carried a list of excluded holders whose balances `IndexRule._supply` subtracted
    ///      with a live `balanceOf` inside the rebalance snapshot, so a config naming an address a third party could
    ///      fund and drain made that component's market cap manipulable inside one transaction: flash loan in, start a
    ///      rebalance, flash loan out. Nothing shipped used it, and a reference supply behind the listing timelock
    ///      covers the same need, so the field is gone from the config, the events, the rule and the listing script.
    function test_DA10_noConfigCanCarryExclusions() public view {
        assertFalse(_contains(_read("abi/IndexFactory.json"), "excluded"), "the listing ABI has no exclusion list");
        assertFalse(
            _contains(_read("script/ConfigureWhitelist.s.sol"), "entry.excluded"), "nor the whitelist script's entries"
        );
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

    /// @dev v4 reads no price anywhere: no contract in `src/` and no shipped ABI names a price feed, a pool's price
    ///      or its oracle, and the v3 price contracts are gone. A change that brought one back would have to delete
    ///      this test to do it.
    function test_noContractReadsAPrice() public view {
        string[15] memory files = [
            "src/IndexHub.sol",
            "src/IndexFactory.sol",
            "src/IndexZap.sol",
            "src/MintRequests.sol",
            "src/interfaces/IIndexHub.sol",
            "src/interfaces/IIndexFactory.sol",
            "src/interfaces/IIndexZap.sol",
            "src/interfaces/IMintRequests.sol",
            "src/interfaces/IXindexErrors.sol",
            "src/interfaces/IRebalanceExecutor.sol",
            "src/interfaces/IUniversalRouter.sol",
            "abi/IndexHub.json",
            "abi/IndexFactory.json",
            "abi/IndexZap.json",
            "abi/MintRequests.json"
        ];
        string[5] memory priceWords = ["latestRoundData", "AggregatorV3", "slot0", "observe(", "navPerToken"];
        for (uint256 i = 0; i < files.length; ++i) {
            string memory text = _read(files[i]);
            for (uint256 j = 0; j < priceWords.length; ++j) {
                assertFalse(_contains(text, priceWords[j]), string.concat(files[i], " names ", priceWords[j]));
            }
        }
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

    /// @dev HybridHub delegates to its module on the index's own storage, so the two must agree slot for slot: every
    ///      variable, in order, at the same slot, offset and type. Both inherit HybridHubStorage and declare nothing of
    ///      their own; this pins it from the compiler's own layouts (`extra_output` in foundry.toml).
    function test_theHubAndTheModuleShareOneLayout() public view {
        string memory hub = _read("out/HybridHub.sol/HybridHub.json");
        string memory module = _read("out/HybridHubModule.sol/HybridHubModule.json");
        uint256 i = 0;
        for (; vm.keyExistsJson(hub, _entry(i, "")); ++i) {
            assertTrue(vm.keyExistsJson(module, _entry(i, "")), "the module has fewer variables");
            assertEq(vm.parseJsonString(hub, _entry(i, ".label")), vm.parseJsonString(module, _entry(i, ".label")));
            assertEq(vm.parseJsonString(hub, _entry(i, ".slot")), vm.parseJsonString(module, _entry(i, ".slot")));
            assertEq(vm.parseJsonUint(hub, _entry(i, ".offset")), vm.parseJsonUint(module, _entry(i, ".offset")));
            // A type names its struct with the compiler's AST id, which differs between separately cached builds.
            assertEq(
                _withoutDigits(vm.parseJsonString(hub, _entry(i, ".type"))),
                _withoutDigits(vm.parseJsonString(module, _entry(i, ".type")))
            );
        }
        assertFalse(vm.keyExistsJson(module, _entry(i, "")), "the module has more variables");
        assertGt(i, 30, "every variable of the storage base");
    }

    function _withoutDigits(string memory text) internal pure returns (string memory) {
        bytes memory b = bytes(text);
        bytes memory out = new bytes(b.length);
        uint256 n = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] >= "0" && b[i] <= "9") continue;
            out[n++] = b[i];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
        return string(out);
    }

    function _entry(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".storageLayout.storage[", vm.toString(i), "]", field);
    }
}
