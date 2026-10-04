// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";

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
        // The name also occurs in the step that requires the secret, so the test step's own env block is what is checked:
        // without it the four fork suites skip silently, and the run stays green (A7-12).
        assertTrue(
            _contains(
                workflow,
                "run: forge test -vvv\n        env:\n          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}\n"
            ),
            "the fork-test RPC is passed to the test step"
        );
        assertTrue(_contains(workflow, "Add the MAINNET_RPC_URL repository secret"), "and required on main");
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
        // The phrase is also quoted in a sentence near the top, so the section itself is what is checked: its heading, and
        // the bullets under it, up to the next section (A7-12).
        assertTrue(_contains(readme, "\n## Known limitations\n"), "the README keeps its known limitations section");
        string[] memory halves = vm.split(readme, "\n## Known limitations\n");
        assertEq(halves.length, 2, "once");
        string memory section = vm.split(halves[1], "\n## ")[0];
        assertGe(_count(section, "\n- **"), 10, "and it lists the limitations");
        assertTrue(_contains(section, "A lone executor can take up to the band"), "the first of them");
    }

    /// @dev XA-10: CI runs every gate of the definition of done. Wake's generated config must leave out `audit/`, whose
    ///      PoC tests compile only inside the audited commit, `prototype/`, a separate Foundry project that needs via-IR,
    ///      `demo/`, one whose remapping only it knows, and `vendor/`, third-party verifiers with their own import paths:
    ///      Wake stops on any of them before running a detector. The
    ///      extension must ignore a local `wake.toml`, which would otherwise replace its committed config.
    function test_XA10_ciRunsEveryGate() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        // Items 1 to 5 of the definition of done, each as a step of its own: a step deleted from the workflow fails here
        // (A7-12, A7-17).
        assertTrue(_contains(workflow, "run: forge fmt --check\n"), "formatting is checked");
        assertTrue(
            _contains(workflow, "run: forge build --sizes --deny warnings\n"), "the build is checked, warnings denied"
        );
        assertTrue(_contains(workflow, "run: forge test -vvv\n"), "the tests run");
        assertTrue(_contains(workflow, "forge lint -D notes"), "lint fails on notes");
        assertTrue(_contains(workflow, "forge coverage --report summary"), "coverage is measured");
        assertTrue(_contains(workflow, "coverage is below 100% in "), "coverage below 100% fails");
        assertTrue(
            _contains(workflow, "github.event.pull_request.head.repo.full_name == github.repository"),
            "pull requests from this repository need the fork-test RPC"
        );
        assertTrue(_contains(workflow, "wake init config --force"), "Wake's config comes from foundry.toml");
        assertTrue(
            _contains(workflow, 'exclude_paths = ["audit", "prototype", "demo", "vendor", '),
            "Wake compiles neither the PoCs, the prototype, the demo nor the vendored verifiers"
        );
        assertTrue(_contains(workflow, "wake detect all src"), "the Wake detectors run");
        string memory settings = _read(".vscode/settings.json");
        assertTrue(
            _contains(settings, '"audit"') && _contains(settings, '"prototype"') && _contains(settings, '"demo"')
                && _contains(settings, '"vendor"'),
            "nor does the Wake extension"
        );
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

    /// @dev XA-44: the ABIs the web app decodes with are committed, and CI regenerates them and fails on a diff: Stage A's,
    ///      the hybrid factory v4 launches on, a hybrid index's three parts as one interface, and the vault.
    function test_XA44_theAbisAreCommittedAndChecked() public view {
        string[7] memory contracts = [
            "IndexFactory", "IndexHub", "IndexZap", "MintRequests", "HybridIndexFactory", "IHybridIndex", "XindexVault"
        ];
        for (uint256 i = 0; i < contracts.length; ++i) {
            assertTrue(
                _contains(_read(string.concat("abi/", contracts[i], ".json")), '"type": "function"'),
                string.concat("abi/", contracts[i], ".json is committed")
            );
        }
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(
            _contains(
                workflow,
                "for contract in IndexFactory IndexHub IndexZap MintRequests HybridIndexFactory IHybridIndex XindexVault; do"
            ),
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

    /// @dev A7-18: the cheatcodes' read access is the directories and files the tests and scripts use, never the project
    ///      root, so no script, test or dependency can read `.env` (the RPC URL and the Etherscan key) or the gitignored
    ///      broadcast records. Reading each is refused by Foundry before any file is opened, whether or not it exists.
    function test_A718_theCheatcodesCannotReadDotEnvOrTheBroadcastRecords() public {
        string memory config = _read("foundry.toml");
        assertFalse(_contains(config, 'path = "./" }'), "the project root is not readable");
        assertFalse(_contains(config, 'path = "." }'), "nor as a dot");
        assertFalse(_contains(config, 'path = "./.env"'), "nor .env by name");
        string[4] memory secret = [".env", "broadcast/Deploy.s.sol/1/run-latest.json", ".git/config", "audit/triage.md"];
        for (uint256 i = 0; i < secret.length; ++i) {
            try this.readOf(secret[i]) returns (string memory) {
                fail(string.concat(secret[i], " is readable"));
            } catch (bytes memory reason) {
                assertTrue(
                    _contains(string(reason), "is not allowed to be accessed for read operations"),
                    string.concat(secret[i], " is refused for permission, not for another reason")
                );
            }
        }
        // What the tests read stays readable.
        assertTrue(_contains(this.readOf(".env.example"), "ETHERSCAN_API_KEY"));
    }

    /// @dev A cheatcode read through an external call, so its refusal is a revert the test catches.
    function readOf(string memory path) external view returns (string memory) {
        return vm.readFile(path);
    }

    /// @dev C1-04: CI runs the Rust and Move gates AGENTS.md lists for the shared core, NEAR's, Stellar's and Aptos's
    ///      vaults, not only Foundry's, so a change to a rule in `crates/xindex-core` that breaks or loosens it on the
    ///      chains that custody funds cannot merge green. Every toolchain and tool is pinned: Rust to the version the
    ///      workspaces' own toolchain files name, the two CLIs by version and SHA-256. Solana, Sui, the proof statements
    ///      and the TRON and VeChain tools are not run in CI yet; their gates are in their READMEs.
    function test_C104_theRustAndMoveGatesRunInCi() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        string[3] memory toolchains = ["crates/xindex-core", "near", "stellar"];
        for (uint256 i = 0; i < toolchains.length; ++i) {
            assertTrue(
                _contains(_read(string.concat(toolchains[i], "/rust-toolchain.toml")), 'channel = "1.98.1"'),
                string.concat(toolchains[i], " pins the toolchain the workflow installs")
            );
        }
        assertEq(
            _count(workflow, "run: rustup toolchain install 1.98.1 --profile minimal"), 3, "Rust is pinned by version"
        );
        assertFalse(_contains(workflow, "toolchain install stable"), "and never floats");
        // The core.
        assertTrue(_contains(workflow, "working-directory: crates/xindex-core"), "the core's job");
        assertTrue(_contains(workflow, "run: cargo test --locked --release"), "the core's tests run");
        assertTrue(_contains(workflow, "cargo build --locked --target wasm32-unknown-unknown --no-default-features"));
        // NEAR's and Stellar's vaults.
        assertTrue(_contains(workflow, "working-directory: near"), "NEAR's job");
        assertTrue(_contains(workflow, "run: cargo test --locked -p xindex-vault-near --lib"), "NEAR's tests run");
        assertTrue(_contains(workflow, "working-directory: stellar"), "Stellar's job");
        assertTrue(_contains(workflow, "run: stellar contract build"), "Stellar's contracts are built for its tests");
        assertTrue(_contains(workflow, "run: cargo test --locked\n"), "and its tests run");
        assertEq(_count(workflow, "run: cargo fmt --all --check"), 2, "NEAR's and Stellar's formatting");
        assertEq(_count(workflow, "run: cargo fmt --check"), 1, "and the core's");
        assertEq(_count(workflow, "run: cargo clippy --locked --all-targets -- -D warnings"), 3, "all three lint");
        // Aptos's.
        assertTrue(_contains(workflow, "run: aptos move compile --dev --fail-on-warning"), "Aptos compiles clean");
        assertTrue(_contains(workflow, "run: aptos move test --dev"), "and its tests run");
        // The CLIs, by version and checksum.
        assertTrue(_contains(workflow, "download/v28.1.0/stellar-cli-28.1.0-x86_64-unknown-linux-gnu.tar.gz"));
        assertTrue(
            _contains(
                workflow, "c1680deee94301d33ada7a17f98411e642a4248c727afbd2e43050d345746462  $RUNNER_TEMP/stellar"
            ),
            "the Stellar CLI's checksum"
        );
        assertTrue(_contains(workflow, "download/aptos-cli-v9.6.0/aptos-cli-9.6.0-Ubuntu-22.04-x86_64.zip"));
        assertTrue(
            _contains(workflow, "f8494d72e3e537479143e70251363f69e8364ac2a9cd3b92d636c928482f29ba  $RUNNER_TEMP/aptos"),
            "the Aptos CLI's checksum"
        );
        assertEq(_count(workflow, "sha256sum -c -"), 2, "each download is checked");
        // The Aptos CLI's key and network commands never run.
        string[6] memory never = [" init", " account ", " key ", " publish", " node ", "aptos move run"];
        for (uint256 i = 0; i < never.length; ++i) {
            assertFalse(_contains(workflow, string.concat("run: aptos", never[i])), never[i]);
        }
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

    /// @dev v4 reads no price anywhere: no file in `src/` and no shipped ABI in `abi/` names a price feed, a pool's
    ///      price or its oracle, and the v3 price contracts are gone. Every file of both folders is read, Stage B's
    ///      included, so a new file is covered without being listed. A change that brought a price back would have to
    ///      delete this test to do it.
    function test_noContractReadsAPrice() public view {
        string[] memory priceWords = _priceWords();
        uint256 read = _assertNoPriceIn("src", priceWords) + _assertNoPriceIn("abi", priceWords);
        assertGt(read, 50, "every source and ABI file is read");
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

    /// @dev The ways a contract reads a price: Chainlink's feeds, Uniswap V3's and V4's pool state and oracle, V2's
    ///      reserves, quoters and time-weighted averages, Pyth. The list is a blacklist, so it names every route the
    ///      reviews found, and `test_A713_thePriceScannerTripsOnEachWord` shows each word trips the scanner (A7-13).
    function _priceWords() internal pure returns (string[] memory words) {
        words = new string[](16);
        words[0] = "latestRoundData";
        words[1] = "latestAnswer";
        words[2] = "getRoundData";
        words[3] = "AggregatorV3";
        words[4] = "slot0";
        words[5] = "Slot0";
        words[6] = "observe(";
        words[7] = "getReserves";
        words[8] = "sqrtPriceX96";
        words[9] = "consult(";
        words[10] = "getPrice";
        words[11] = "navPerToken";
        words[12] = "extsload";
        words[13] = "getAmountsOut";
        words[14] = "quoteExact";
        words[15] = "priceFeed";
    }

    /// @dev A7-13. The scanner finds each price word wherever it stands in a file, and passes text that names none; so a
    ///      price read in a spelling the old five-word list missed (`getSlot0`, `latestAnswer`, an `extsload` of a pool's
    ///      slot, `getReserves`) trips it, and the scanner cannot have been emptied without this failing.
    function test_A713_thePriceScannerTripsOnEachWord() public pure {
        string[] memory words = _priceWords();
        assertGe(words.length, 12, "at least the word list the finding asked for");
        for (uint256 i = 0; i < words.length; ++i) {
            string memory text = string.concat("function f() external { return pool.", words[i], "; }");
            assertEq(_firstPriceWord(text, words), words[i], "the word is found inside a statement");
            assertEq(_firstPriceWord(words[i], words), words[i], "and alone");
        }
        assertEq(_firstPriceWord("function f() external { return units * supply; }", words), "", "clean text passes");
        assertEq(_firstPriceWord("", words), "", "so does an empty file");
        // The ways the old list missed.
        assertEq(_firstPriceWord("(uint160 p,,,) = IPoolManager(m).getSlot0(id);", words), "Slot0");
        assertEq(_firstPriceWord("int256 a = feed.latestAnswer();", words), "latestAnswer");
        assertEq(_firstPriceWord("bytes32 s = manager.extsload(key);", words), "extsload");
    }

    /// @dev The first price word `text` names, or the empty string.
    function _firstPriceWord(string memory text, string[] memory words) internal pure returns (string memory) {
        for (uint256 j = 0; j < words.length; ++j) {
            if (_contains(text, words[j])) return words[j];
        }
        return "";
    }

    /// @dev Reads every file under `dir` and fails on any price word; returns how many files it read.
    function _assertNoPriceIn(string memory dir, string[] memory priceWords) internal view returns (uint256 read) {
        VmSafe.DirEntry[] memory entries = vm.readDir(dir, 8);
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir) continue;
            string memory word = _firstPriceWord(vm.readFile(entries[i].path), priceWords);
            assertEq(word, "", string.concat(entries[i].path, " names a price word"));
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

    /// @dev HybridHub delegates to its module on the index's own storage, so the two must agree slot for slot: every
    ///      variable, in order, at the same slot, offset and type. Both inherit HybridHubStorage and declare nothing of
    ///      their own; this pins it from the compiler's own layouts (`extra_output` in foundry.toml).
    function test_theHubAndTheModuleShareOneLayout() public view {
        string memory hub = _read("out/HybridHub.sol/HybridHub.json");
        _sameLayout(hub, _read("out/HybridHubModule.sol/HybridHubModule.json"), "the module");
        _sameLayout(hub, _read("out/HybridHubExtension.sol/HybridHubExtension.json"), "the extension");
    }

    /// @dev `other`'s storage variables are `hub`'s, one for one, in the same slots, offsets and types.
    function _sameLayout(string memory hub, string memory other, string memory name) internal view {
        uint256 i = 0;
        for (; vm.keyExistsJson(hub, _entry(i, "")); ++i) {
            assertTrue(vm.keyExistsJson(other, _entry(i, "")), string.concat(name, " has fewer variables"));
            assertEq(vm.parseJsonString(hub, _entry(i, ".label")), vm.parseJsonString(other, _entry(i, ".label")));
            assertEq(vm.parseJsonString(hub, _entry(i, ".slot")), vm.parseJsonString(other, _entry(i, ".slot")));
            assertEq(vm.parseJsonUint(hub, _entry(i, ".offset")), vm.parseJsonUint(other, _entry(i, ".offset")));
            // A type names its struct with the compiler's AST id, which differs between separately cached builds.
            assertEq(
                _withoutDigits(vm.parseJsonString(hub, _entry(i, ".type"))),
                _withoutDigits(vm.parseJsonString(other, _entry(i, ".type")))
            );
        }
        assertFalse(vm.keyExistsJson(other, _entry(i, "")), string.concat(name, " has more variables"));
        assertGt(i, 30, "every variable of the storage base");
    }

    /// @dev The slots the vault and the hub read of each other's storage from proofs, against the compiler's layouts:
    ///      the vault reads the hub's `_components`, `_claimOf`, `_recovery` and `_settledIntakes` for a snapshot exit,
    ///      and the hub reads the vault's `_snapshot` to record it. A reordered variable would read the wrong slot.
    function test_theHubLayoutIsPinned() public view {
        string memory hub = _read("out/HybridHub.sol/HybridHub.json");
        assertEq(_slotOf(hub, "_components"), 0);
        assertEq(_slotOf(hub, "_claimOf"), 11);
        assertEq(_slotOf(hub, "_recovery"), 59);
        assertEq(_slotOf(hub, "_settledIntakes"), 60);
        assertEq(_slotOf(hub, "_sentMessages"), 62);
        string memory vault = _read("out/XindexVault.sol/XindexVault.json");
        assertEq(_slotOf(vault, "indexDigest"), 14);
        assertEq(_slotOf(vault, "intakeDigest"), 15);
        // The snapshot is (blockNumber, timestamp) in one slot and its state root in the next.
        assertEq(_slotOf(vault, "_snapshot") + 1, 25);
    }

    /// @dev C1-05: the copies of the hub's slots outside Solidity, which a vault reads at its snapshot exit, are the
    ///      compiler's: the Rust core's (shared by the Solana, NEAR and Stellar vaults) and both Move vaults' snapshot
    ///      modules, and the vault's own digest and snapshot-root slots in the NEAR, Sui and Aptos vaults. A reordered or
    ///      inserted variable that updates the Solidity pins but not these copies would make a real exit read the wrong
    ///      slots while every Rust and Move test still passed.
    function test_C105_theHubSlotsOutsideSolidityAreTheCompilersAndTheErc20Namespace() public view {
        string memory hub = _read("out/HybridHub.sol/HybridHub.json");
        string memory vault = _read("out/XindexVault.sol/XindexVault.json");
        // Each copy's block of hub slots, from the shares' namespace on.
        string[3] memory copies = [
            _block(_read("crates/xindex-core/src/constants.rs"), "pub const HUB_SHARES:", BLOCK),
            _block(_read("sui/sources/snapshot.move"), "const HUB_SHARES:", BLOCK),
            _block(_read("aptos/sources/snapshot.move"), "const HUB_SHARES:", BLOCK)
        ];
        string[5] memory labels = ["_components", "_claimOf", "_recovery", "_settledIntakes", "_sentMessages"];
        string[5] memory names = [
            "HUB_COMPONENTS_SLOT",
            "HUB_CLAIMS_SLOT",
            "HUB_RECOVERY_SLOT",
            "HUB_SETTLED_INTAKES_SLOT",
            "HUB_SENT_MESSAGES_SLOT"
        ];
        // OpenZeppelin's ERC-7201 namespace of the shares' balances: keccak256(abi.encode(uint256(keccak256(
        // "openzeppelin.storage.ERC20")) - 1)) & ~0xff.
        bytes32 shares =
            keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff));
        for (uint256 c = 0; c < copies.length; ++c) {
            for (uint256 i = 0; i < labels.length; ++i) {
                assertEq(_constant(copies[c], _marker(c, names[i])), _slotOf(hub, labels[i]), names[i]);
            }
            assertTrue(_contains(copies[c], vm.replace(vm.toString(shares), "0x", "")), "the shares' namespace");
        }
        // The vault's own slots, in the vaults that keep them as constants.
        string[3] memory vaults = [
            _read("near/contracts/xindex-vault/src/lib.rs"),
            _read("sui/sources/vault.move"),
            _read("aptos/sources/vault.move")
        ];
        for (uint256 v = 0; v < vaults.length; ++v) {
            string memory kw = v == 0 ? "pub const " : "const ";
            string memory slots = _block(vaults[v], string.concat(kw, "INTAKE_DIGEST_SLOT:"), BLOCK);
            assertEq(_constant(slots, string.concat(kw, "INDEX_DIGEST_SLOT:")), _slotOf(vault, "indexDigest"));
            assertEq(_constant(slots, string.concat(kw, "INTAKE_DIGEST_SLOT:")), _slotOf(vault, "intakeDigest"));
            assertEq(_constant(slots, string.concat(kw, "SNAPSHOT_ROOT_SLOT:")), _slotOf(vault, "_snapshot") + 1);
        }
    }

    /// @dev How many characters of a file a block of constants spans, from its first marker: far past every group the
    ///      tests read, and far less than a file, whose copying each lookup would otherwise pay for.
    uint256 internal constant BLOCK = 4000;

    /// @dev Up to `length` characters of `source` from the first `marker` on: the block a file keeps a group of constants
    ///      in. Reading a constant out of the whole file copies the file for every lookup, and the whole suite's lookups
    ///      cost a few hundred million gas; a missing marker is an error.
    function _block(string memory source, string memory marker, uint256 length) internal pure returns (string memory) {
        uint256 at = vm.indexOf(source, marker);
        require(at != type(uint256).max, string.concat("no ", marker));
        bytes memory text = bytes(source);
        uint256 end = at + length > text.length ? text.length : at + length;
        bytes memory out = new bytes(end - at);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = text[at + i];
        }
        return string(out);
    }

    /// @dev The marker of constant `name` in copy `c`: the Rust core's are `pub const`, the Move modules' are `const`.
    function _marker(uint256 c, string memory name) internal pure returns (string memory) {
        return string.concat(c == 0 ? "pub const " : "const ", name, ":");
    }

    /// @dev The value of the one constant `marker` opens, such as `const FREEZE_DURATION:`, read from its source line: the
    ///      text after the `=` up to the `;`, with underscores and spaces dropped, as a product of integers
    ///      (`14 * 86_400`). It fails when the marker is missing or appears twice, so a renamed or duplicated constant
    ///      fails the test that reads it instead of being skipped.
    function _constant(string memory source, string memory marker) internal pure returns (uint256 value) {
        string[] memory parts = vm.split(source, marker);
        require(parts.length == 2, string.concat("not exactly one ", marker));
        string[] memory declaration = vm.split(vm.split(parts[1], ";")[0], "=");
        require(declaration.length == 2, string.concat("no value after ", marker));
        string[] memory factors = vm.split(vm.replace(vm.replace(declaration[1], "_", ""), " ", ""), "*");
        value = 1;
        for (uint256 i = 0; i < factors.length; ++i) {
            value *= _factor(factors[i]);
        }
    }

    /// @dev A factor of a constant: an integer, or one of Solidity's `N days` and `N hours`.
    function _factor(string memory text) internal pure returns (uint256) {
        if (vm.contains(text, "days")) return vm.parseUint(vm.replace(text, "days", "")) * 1 days;
        if (vm.contains(text, "hours")) return vm.parseUint(vm.replace(text, "hours", "")) * 1 hours;
        return vm.parseUint(text);
    }

    /// @dev C1-01: the rules every vault holds to, as the EVM vault's: the speed limit, freeze, governance, intake, stall,
    ///      recovery and snapshot-exit constants, the hourly buckets, the message kinds and the intake states, in the Rust
    ///      core (the Solana, NEAR and Stellar vaults) and in the Sui and Aptos vaults, read from their sources. The cores'
    ///      tests only compare the constants with themselves, and each Move test compares a literal it declares, so a
    ///      safety rule changed on one chain alone, such as a freeze of 15 days or a speed limit of 5%, passed every
    ///      suite but this one.
    function test_C101_theVaultRulesAreTheEvmVaultsInEveryImplementation() public view {
        // Each implementation's block of rules, from its first rule on.
        string[3] memory sources = [
            _block(_read("crates/xindex-core/src/constants.rs"), "pub const SPEED_LIMIT_PERCENT:", BLOCK),
            _block(_read("sui/sources/vault.move"), "const FREEZE_DURATION:", BLOCK),
            _block(_read("aptos/sources/vault.move"), "const FREEZE_DURATION:", BLOCK)
        ];
        // The EVM vault's own figures, from its source, which is also held to the design's.
        string memory evm = _read("src/vault/XindexVault.sol");
        string[8] memory names = [
            "FREEZE_DURATION",
            "GOVERNANCE_DELAY",
            "MAX_INTAKE_LIFE",
            "STALL_PERIOD",
            "RECOVERY_DELAY",
            "MAX_RECOVERY_VETOES",
            "SNAPSHOT_EXIT_DELAY",
            "SPEED_LIMIT_PERCENT"
        ];
        uint256[8] memory rules = [uint256(14 days), 7 days, 7 days, 7 days, 30 days, 2, 180 days, 4];
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(_constant(evm, string.concat("constant ", names[i])), rules[i], names[i]);
        }
        // 4% a day, as a fraction of a WAD.
        assertTrue(_contains(evm, "uint256 public constant SPEED_LIMIT = 0.04e18;"), "SPEED_LIMIT");
        for (uint256 c = 0; c < sources.length; ++c) {
            for (uint256 i = 0; i < names.length; ++i) {
                assertEq(_constant(sources[c], _marker(c, names[i])), rules[i], names[i]);
            }
            // The hourly buckets of the speed limit, as the EVM vault and the hub keep them.
            assertEq(_constant(sources[c], _marker(c, "BUCKETS")), 25, "BUCKETS");
            assertEq(_constant(sources[c], _marker(c, "HOUR")), 1 hours, "HOUR");
            // The message kinds and the intake states.
            string[8] memory kinds = [
                "BURN",
                "INTAKE_SETTLED",
                "INTAKE_FAILED",
                "MIGRATE",
                "CAP_UPDATE",
                "FREEZE",
                "FREEZER_CHANGE",
                "VERIFIER_ROTATION"
            ];
            uint8[8] memory kindValues = [
                VaultMessages.BURN,
                VaultMessages.INTAKE_SETTLED,
                VaultMessages.INTAKE_FAILED,
                VaultMessages.MIGRATE,
                VaultMessages.CAP_UPDATE,
                VaultMessages.FREEZE,
                VaultMessages.FREEZER_CHANGE,
                VaultMessages.VERIFIER_ROTATION
            ];
            for (uint256 k = 0; k < kinds.length; ++k) {
                assertEq(_constant(sources[c], _marker(c, kinds[k])), kindValues[k], kinds[k]);
            }
            assertEq(_constant(sources[c], _marker(c, "INTAKE_NONE")), uint256(IXindexVault.IntakeState.None));
            assertEq(_constant(sources[c], _marker(c, "INTAKE_OPEN")), uint256(IXindexVault.IntakeState.Open));
            assertEq(
                _constant(sources[c], _marker(c, "INTAKE_SETTLED_STATE")), uint256(IXindexVault.IntakeState.Settled)
            );
            assertEq(_constant(sources[c], _marker(c, "INTAKE_FAILED_STATE")), uint256(IXindexVault.IntakeState.Failed));
        }
        // The hourly buckets and the hour are private to the EVM vault, which holds them as these literals.
        assertTrue(_contains(evm, "uint256 private constant BUCKETS = 25;"), "the EVM vault's buckets");
        assertTrue(_contains(evm, "uint256 private constant HOUR = 1 hours;"), "and its hour");
    }

    /// @dev The scanner of constants fails closed: a constant that is renamed, duplicated or written in another shape is
    ///      an error, not a skipped check.
    function test_C101_theConstantReaderFailsClosed() public {
        string memory src = "pub const A: i64 = 14 * 24 * 3600;\nconst B: u8 = 2;\nconst B: u8 = 3;\n";
        assertEq(_constant(src, "pub const A:"), 14 * 24 * 3600);
        vm.expectRevert(bytes("not exactly one const B:"));
        this.constantOf(src, "const B:");
        vm.expectRevert(bytes("not exactly one const C:"));
        this.constantOf(src, "const C:");
        vm.expectRevert(bytes("no value after const D:"));
        this.constantOf("const D: u8;", "const D:");
    }

    /// @dev `_constant` through an external call, so a revert inside it is an expected revert of the test.
    function constantOf(string memory source, string memory marker) external pure returns (uint256) {
        return _constant(source, marker);
    }

    /// @dev A7-16: the constants that name a verifier or a network, repeated across Solidity, the TRON and VeChain tools,
    ///      the Rust core and the mocks, agree: the SP1 verifier's hash and version, RISC Zero's selector and version, and
    ///      the two beacon genesis times. The main suite checks each only against copies of the same literal, and the JS
    ///      tools by nothing. The hash is also the one the vendored SP1 verifier names itself by, and the selector the
    ///      first four bytes of RISC Zero's own v3.0 receipt, which are the vendored sources' own figures.
    function test_A716_theIdentityLiteralsAgreeAcrossSolidityJsRustAndMocks() public view {
        string memory hashLiteral = "0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896";
        string memory selector = "0x73c457ba";
        string[3] memory deployers =
            [_read("script/ScriptUtils.sol"), _read("tron/deploy.mjs"), _read("vechain/deploy.mjs")];
        for (uint256 i = 0; i < deployers.length; ++i) {
            assertTrue(_contains(deployers[i], hashLiteral), "the SP1 verifier hash");
            assertTrue(_contains(deployers[i], i == 0 ? '"v6.0.0"' : "'v6.0.0'"), "its version");
        }
        assertTrue(_contains(_read("script/DeployVault.s.sol"), "RISC_ZERO_SELECTOR = 0x73c457ba"));
        assertTrue(_contains(_read("script/DeployVault.s.sol"), 'RISC_ZERO_VERSION = "3.0.0"'));
        for (uint256 i = 1; i < deployers.length; ++i) {
            assertTrue(_contains(deployers[i], selector), "RISC Zero's selector");
            assertTrue(_contains(deployers[i], "'3.0.0'"), "and version");
            assertTrue(_contains(deployers[i], "MAINNET_GENESIS_TIME = 1_606_824_023n"), "mainnet's beacon genesis");
            assertTrue(_contains(deployers[i], "SEPOLIA_GENESIS_TIME = 1_655_733_600n"), "and Sepolia's");
        }
        string memory deployVault = _read("script/DeployVault.s.sol");
        assertTrue(_contains(deployVault, "MAINNET_GENESIS_TIME = 1_606_824_023"));
        assertTrue(_contains(deployVault, "SEPOLIA_GENESIS_TIME = 1_655_733_600"));
        assertTrue(_contains(_read("test/mocks/MockSP1Verifier.sol"), hashLiteral), "the SP1 mock");
        assertTrue(_contains(_read("test/mocks/MockRiscZeroVerifier.sol"), "0x73c457ba"), "the RISC Zero mock");
        assertTrue(
            _contains(_read("crates/xindex-core/src/sp1.rs"), vm.replace(hashLiteral, "0x", "")), "the Rust core's"
        );
        assertTrue(
            _contains(_read("vechain/deploy-test.mjs"), vm.replace(hashLiteral, "0x", "")), "and the VeChain test's"
        );
        // What the vendored sources themselves say.
        assertTrue(
            _contains(_read("prototype/evm/src/sp1/SP1VerifierGroth16.sol"), hashLiteral),
            "the vendored SP1 verifier names itself by it"
        );
        assertTrue(
            _contains(_read("vendor/risc0-ethereum/test/TestReceiptV3_0.sol"), 'hex"73c457ba'),
            "RISC Zero's own v3.0 seal begins with the selector"
        );
    }

    function _slotOf(string memory artifact, string memory label) internal view returns (uint256) {
        for (uint256 i = 0; vm.keyExistsJson(artifact, _entry(i, "")); ++i) {
            if (keccak256(bytes(vm.parseJsonString(artifact, _entry(i, ".label")))) == keccak256(bytes(label))) {
                return vm.parseUint(vm.parseJsonString(artifact, _entry(i, ".slot")));
            }
        }
        revert(string.concat("no variable ", label));
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
